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

/// @title BNB Provider for Lista Lending
/// @author Lista DAO
/// @notice This contract allows users to interact with the Moolah protocol using native BNB.
/// @dev
/// - Handles interactions with the WBNB vault for deposit, mint, withdraw, and redeem operations.
/// - Integrates with the Moolah core contract to support borrowing, repayment, and collateral management using BNB.
contract BNBProvider is UUPSUpgradeable, AccessControlEnumerableUpgradeable {
  using MarketParamsLib for MarketParams;
  using SharesMathLib for uint256;

  /* IMMUTABLES */

  IMoolah public immutable MOOLAH;
  IMoolahVault public immutable MOOLAH_VAULT;
  IWBNB public immutable WBNB;

  bytes32 public constant MANAGER = keccak256("MANAGER");

  /* CONSTRUCTOR */

  /// @custom:oz-upgrades-unsafe-allow constructor
  /// @param moolah The address of the Moolah contract.
  /// @param moolahVault The address of the WBNB Moolah Vault contract.
  /// @param wbnb The address of the WBNB contract.
  constructor(address moolah, address moolahVault, address wbnb) {
    require(moolah != address(0), ErrorsLib.ZERO_ADDRESS);
    require(moolahVault != address(0), ErrorsLib.ZERO_ADDRESS);
    require(moolah == address(IMoolahVault(moolahVault).MOOLAH()), ErrorsLib.NOT_SET);
    require(wbnb != address(0), ErrorsLib.ZERO_ADDRESS);
    require(wbnb == IMoolahVault(moolahVault).asset(), "asset mismatch");

    MOOLAH = IMoolah(moolah);
    MOOLAH_VAULT = IMoolahVault(moolahVault);
    WBNB = IWBNB(wbnb);
  }

  /// @param admin The admin of the contract.
  /// @param manager The manager of the contract.
  function initialize(address admin, address manager) public initializer {
    require(admin != address(0), ErrorsLib.ZERO_ADDRESS);
    require(manager != address(0), ErrorsLib.ZERO_ADDRESS);

    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MANAGER, manager);
  }

  /// @dev Deposit BNB and receive shares.
  /// @param receiver The address to receive the shares.
  /// @return shares The number of shares received.
  function deposit(address receiver) external payable returns (uint256 shares) {
    uint256 assets = msg.value;
    require(assets > 0, ErrorsLib.ZERO_ASSETS);

    WBNB.deposit{ value: assets }();
    require(WBNB.approve(address(MOOLAH_VAULT), assets));

    shares = MOOLAH_VAULT.deposit(assets, receiver);
  }

  /// @dev Deposit BNB and receive shares by specifying the amount of shares.
  /// @param shares The amount of shares to mint.
  /// @param receiver The address to receive the shares.
  function mint(uint256 shares, address receiver) external payable returns (uint256 assets) {
    require(shares > 0, ErrorsLib.ZERO_ASSETS);
    uint256 previewAssets = MOOLAH_VAULT.previewMint(shares); // ceiling rounding
    require(msg.value >= previewAssets, "invalid BNB amount");

    WBNB.deposit{ value: previewAssets }();
    require(WBNB.balanceOf(address(this)) >= previewAssets, "not enough WBNB");
    require(WBNB.approve(address(MOOLAH_VAULT), previewAssets));
    assets = MOOLAH_VAULT.mint(shares, receiver);

    if (msg.value > assets) {
      (bool success, ) = msg.sender.call{ value: msg.value - assets }("");
      require(success, "transfer failed");
    }
  }

  /// @dev Withdraw shares from owner and send BNB to receiver by specifying the amount of assets.
  /// @param assets The amount of assets to withdraw.
  /// @param receiver The address to receive the assets.
  /// @param owner The address of the owner of the shares.
  function withdraw(uint256 assets, address payable receiver, address owner) external returns (uint256 shares) {
    require(assets > 0, ErrorsLib.ZERO_ASSETS);
    uint256 previewShares = MOOLAH_VAULT.previewWithdraw(assets);

    // 1. withdraw WBNB from moolah vault
    shares = MOOLAH_VAULT.withdrawFor(assets, owner, msg.sender);

    // 2. unwrap WBNB
    WBNB.withdraw(assets);

    // 3. transfer WBNB to receiver
    (bool success, ) = receiver.call{ value: assets }("");
    require(success, "transfer failed");
  }

  /// @dev Withdraw shares from owner and send BNB to receiver by specifying the amount of shares.
  /// @param shares The amount of shares to withdraw.
  /// @param receiver The address to receive the assets.
  /// @param owner The address of the owner of the shares.
  function redeem(uint256 shares, address payable receiver, address owner) external returns (uint256 assets) {
    require(shares > 0, ErrorsLib.ZERO_ASSETS);

    // 1. redeem WBNB from moolah vault
    assets = MOOLAH_VAULT.redeemFor(shares, owner, msg.sender);

    // 2. unwrap WBNB
    WBNB.withdraw(assets);

    // 3. transfer BNB to receiver
    (bool success, ) = receiver.call{ value: assets }("");
    require(success, "transfer failed");
  }

  /// @dev Borrow BNB from onBehalf's position and send BNB to receiver
  /// @param marketParams The market parameters.
  /// @param assets The amount of assets to borrow.
  /// @param shares The amount of shares to borrow.
  /// @param onBehalf The address of the position owner to borrow from.
  /// @param receiver The address to receive the BNB.
  function borrow(
    MarketParams calldata marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    address payable receiver
  ) external returns (uint256 _assets, uint256 _shares) {
    // No need to verify assets and shares, as they are already verified in the Moolah contract.
    require(marketParams.loanToken == address(WBNB), "invalid loan token");
    require(isSenderAuthorized(msg.sender, onBehalf), ErrorsLib.UNAUTHORIZED);

    // 1. borrow WBNB from moolah
    (_assets, _shares) = MOOLAH.borrow(marketParams, assets, shares, onBehalf, address(this));

    // 2. unwrap WBNB
    WBNB.withdraw(_assets);

    // 3. transfer BNB to receiver
    (bool success, ) = receiver.call{ value: assets }("");
    require(success, "transfer failed");
  }

  /// @dev Repay BNB to onBehalf's position
  /// @param marketParams The market parameters.
  /// @param assets The amount of assets to repay.
  /// @param shares The amount of shares to repay.
  /// @param onBehalf The address of the position owner to repay.
  /// @param data The data to pass to the Moolah contract.
  function repay(
    MarketParams calldata marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    bytes calldata data
  ) external payable returns (uint256 _assets, uint256 _shares) {
    require(marketParams.loanToken == address(WBNB), "invalid loan token");
    require(msg.value >= assets, "invalid BNB amount");

    uint256 wrapAmount = assets;
    if (wrapAmount == 0) {
      // If assets is 0, we need to wrap the shares amount
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

    // 4. return excess BNB to sender
    if (msg.value > wrapAmount) {
      (bool success, ) = msg.sender.call{ value: msg.value - wrapAmount }("");
      require(success, "transfer failed");
    }
  }

  /// @dev Supply collateral to onBehalf's position
  /// @param marketParams The market parameters.
  /// @param onBehalf The address of the position owner to supply collateral to.
  /// @param data The data to pass to the Moolah contract.
  function supplyCollateral(
    MarketParams calldata marketParams,
    address onBehalf,
    bytes calldata data
  ) external payable {
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

  /// @dev Withdraw collateral from onBehalf's position
  /// @param marketParams The market parameters.
  /// @param assets The amount of assets to withdraw.
  /// @param onBehalf The address of the position owner to withdraw collateral from. msg.sender must be authorized to manage onBehalf's position.
  /// @param receiver The address to receive the assets.
  function withdrawCollateral(
    MarketParams calldata marketParams,
    uint256 assets,
    address onBehalf,
    address payable receiver
  ) external {
    require(marketParams.collateralToken == address(WBNB), "invalid collateral token");
    require(isSenderAuthorized(msg.sender, onBehalf), ErrorsLib.UNAUTHORIZED);

    // 1. withdraw WBNB from moolah by specifying the amount
    MOOLAH.withdrawCollateral(marketParams, assets, onBehalf, address(this));

    // 2. unwrap WBNB
    WBNB.withdraw(assets);

    // 3. transfer BNB to receiver
    (bool success, ) = receiver.call{ value: assets }("");
    require(success, "transfer failed");
  }

  /// @dev empty function
  function liquidate(Id id, address borrower) external {}

  /// @dev Returns whether the sender is authorized to manage `onBehalf`'s positions.
  /// @param sender The address of the sender to check.
  /// @param onBehalf The address of the position owner.
  function isSenderAuthorized(address sender, address onBehalf) public view returns (bool) {
    return sender == onBehalf || MOOLAH.isAuthorized(onBehalf, sender);
  }

  receive() external payable {}

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
