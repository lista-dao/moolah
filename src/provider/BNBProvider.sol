// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { SharesMathLib } from "moolah/libraries/SharesMathLib.sol";
import { IMoolahVault } from "../moolah-vault/interfaces/IMoolahVault.sol";
import { Id, IMoolah, MarketParams, Market } from "../moolah/interfaces/IMoolah.sol";
import { IWBNB } from "./interfaces/IWBNB.sol";
import { ErrorsLib } from "../moolah/libraries/ErrorsLib.sol";

/// @title BNBProvider
/// @author Lista DAO
/// @notice Provider for BNB.
/// @dev TODO: add more comments
contract BNBProvider is UUPSUpgradeable, AccessControlEnumerableUpgradeable {
  using MarketParamsLib for MarketParams;
  using SharesMathLib for uint256;

  /* IMMUTABLES */

  IMoolah public immutable MOOLAH;
  IMoolahVault public immutable MOOLAH_VAULT;
  IWBNB public immutable WBNB;

  bytes32 public constant MANAGER = keccak256("MANAGER"); // manager role

  constructor(address moolah, address moolahVault, address wbnb) {
    require(moolah != address(0), ErrorsLib.ZERO_ADDRESS);
    require(moolahVault != address(0), ErrorsLib.ZERO_ADDRESS);
    //    require(moolah ==  moolahVault.MOOLAH(), ErrorsLib.NOT_SET);
    require(wbnb != address(0), ErrorsLib.ZERO_ADDRESS);

    MOOLAH = IMoolah(moolah);
    MOOLAH_VAULT = IMoolahVault(moolahVault);
    WBNB = IWBNB(wbnb);
  }

  function initialize(address admin, address manager) public initializer {
    require(admin != address(0), ErrorsLib.ZERO_ADDRESS);
    require(manager != address(0), ErrorsLib.ZERO_ADDRESS);

    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MANAGER, manager);
  }

  function deposit(address receiver) external payable returns (uint256 shares) {
    uint256 assets = msg.value;
    require(assets > 0, ErrorsLib.ZERO_ASSETS);

    uint256 previewShares = MOOLAH_VAULT.convertToShares(assets);

    WBNB.deposit{ value: assets }();
    require(WBNB.approve(address(MOOLAH_VAULT), assets));

    shares = MOOLAH_VAULT.deposit(assets, receiver);
    require(shares == previewShares, "inconsistent shares");
  }

  function mint(uint256 shares, address receiver) external payable returns (uint256 assets) {
    require(shares > 0, ErrorsLib.ZERO_ASSETS);
    // uint256 previewAssets = MOOLAH_VAULT.convertToAssets(shares);
    uint256 previewAssets = MOOLAH_VAULT.previewMint(shares); // use preview because `convertToAssets` is not accurate, 1 wei less than expected
    require(msg.value >= previewAssets, "invalid BNB amount");

    WBNB.deposit{ value: previewAssets }();
    require(WBNB.balanceOf(address(this)) >= previewAssets, "not enough WBNB");
    require(WBNB.approve(address(MOOLAH_VAULT), previewAssets));
    assets = MOOLAH_VAULT.mint(shares, receiver);
    require(assets == previewAssets, "inconsistent assets");

    // TODO: return excess BNB to sender
  }

  function withdraw(uint256 assets, address payable receiver, address owner) external returns (uint256 shares) {
    require(assets > 0, ErrorsLib.ZERO_ASSETS);
    uint256 previewShares = MOOLAH_VAULT.previewWithdraw(assets);

    // 1. withdraw WBNB from moolah vault
    shares = MOOLAH_VAULT.withdrawFor(assets, owner, msg.sender);
    require(shares == previewShares, "inconsistent shares");

    // 2. unwrap WBNB
    WBNB.withdraw(assets);

    // 3. transfer WBNB to receiver
    (bool success, ) = receiver.call{ value: assets }("");
    require(success, "transfer failed");
  }

  function redeem(uint256 shares, address payable receiver, address owner) external returns (uint256 assets) {
    require(shares > 0, ErrorsLib.ZERO_ASSETS);
    //uint256 previewAssets = MOOLAH_VAULT.previewRedeem(shares);
    uint256 previewAssets = MOOLAH_VAULT.convertToAssets(shares); // use convertToAssets because `previewRedeem` is not accurate, 1 wei less than expected

    // 1. redeem WBNB from moolah vault
    assets = MOOLAH_VAULT.redeemFor(shares, owner, msg.sender);
    require(assets == previewAssets, "inconsistent assets");

    // 2. unwrap WBNB
    WBNB.withdraw(assets);

    // 3. transfer WBNB to receiver
    (bool success, ) = receiver.call{ value: assets }("");
    require(success, "transfer failed");
  }

  function borrow(
    MarketParams memory marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    address payable receiver
  ) external returns (uint256 _assets, uint256 _shares) {
    require(assets > 0, ErrorsLib.ZERO_ASSETS);
    require(marketParams.loanToken == address(WBNB), "invalid loan token");
    require(isSenderAuthorized(msg.sender, onBehalf), ErrorsLib.UNAUTHORIZED);

    // 1. borrow WBNB from moolah
    //    uint256 previewShares = MOOLAH.previewBorrow(marketParams, assets);
    (_assets, _shares) = MOOLAH.borrow(marketParams, assets, shares, onBehalf, address(this));
    // TODO: check amount
    // require(shares == previewShares, "inconsistent shares");

    // 2. unwrap WBNB
    WBNB.withdraw(_assets);

    // 3. transfer BNB to receiver
    (bool success, ) = receiver.call{ value: assets }("");
    require(success, "transfer failed");
  }

  function repay(
    MarketParams calldata marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    bytes calldata data
  ) external payable returns (uint256 _assets, uint256 _shares) {
    require(marketParams.loanToken == address(WBNB), "invalid loan token");

    uint256 wrapAmount = assets;
    if (assets > 0) {
      require(msg.value >= assets, "invalid BNB amount");
      // TODO: return excess BNB to sender
    } else {
      require(shares > 0, ErrorsLib.ZERO_ASSETS);
      Market memory market = MOOLAH.market(marketParams.id());

      wrapAmount = shares.toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
    }

    // 1. wrap BNB to WBNB
    WBNB.deposit{ value: wrapAmount }();
    // 2. approve moolah to transfer WBNB
    require(WBNB.approve(address(MOOLAH), wrapAmount));
    // 3. repay WBNB to moolah
    (_assets, _shares) = MOOLAH.repay(marketParams, assets, shares, onBehalf, data);
  }

  function supplyCollateral(MarketParams memory marketParams, address onBehalf, bytes calldata data) external payable {
    uint256 assets = msg.value;
    require(assets > 0, ErrorsLib.ZERO_ASSETS);
    require(marketParams.collateralToken == address(WBNB), "invalid collateral token");

    // 1. deposit WBNB
    WBNB.deposit{ value: assets }();
    // 2. approve moolah to transfer WBNB
    require(WBNB.approve(address(MOOLAH), assets));
    // 3. supply collateral to moolah
    MOOLAH.supplyCollateral(marketParams, assets, onBehalf, data);
  }

  function withdrawCollateral(
    MarketParams memory marketParams,
    uint256 assets,
    address onBehalf,
    address payable receiver
  ) external {
    require(assets > 0, ErrorsLib.ZERO_ASSETS);
    require(marketParams.collateralToken == address(WBNB), "invalid collateral token");

    // 1. withdraw WBNB from moolah by specifying the amount
    uint256 balance = WBNB.balanceOf(address(this));
    MOOLAH.withdrawCollateral(marketParams, assets, onBehalf, address(this));
    require(WBNB.balanceOf(address(this)) - balance == assets, "wrong amount");

    // 2. unwrap WBNB
    WBNB.withdraw(assets);

    // 3. transfer BNB to receiver
    (bool success, ) = receiver.call{ value: assets }("");
    require(success, "transfer failed");
  }

  function liquidate(Id id, address borrower) external {
    revert("BNB liquidation via provider is not supported");
  }

  /// @dev Returns whether the sender is authorized to manage `onBehalf`'s positions.
  function isSenderAuthorized(address sender, address onBehalf) public view returns (bool) {
    return sender == onBehalf || MOOLAH.isAuthorized(onBehalf, sender);
  }

  receive() external payable {}

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
