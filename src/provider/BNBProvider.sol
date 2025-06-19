// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import { IWBNB } from "./interfaces/IWBNB.sol";
import { IProvider } from "./interfaces/IProvider.sol";

import { MarketParamsLib } from "../moolah/libraries/MarketParamsLib.sol";
import { SharesMathLib } from "../moolah/libraries/SharesMathLib.sol";
import { IMoolahVault } from "../moolah-vault/interfaces/IMoolahVault.sol";
import { Id, IMoolah, MarketParams, Market } from "../moolah/interfaces/IMoolah.sol";
import { ErrorsLib } from "../moolah/libraries/ErrorsLib.sol";
import { UtilsLib } from "../moolah/libraries/UtilsLib.sol";

/// @title BNB Provider for Lista Lending
/// @author Lista DAO
/// @notice This contract allows users to interact with the Moolah protocol using native BNB.
/// @dev
/// - Handles interactions with the WBNB vault for deposit, mint, withdraw, and redeem operations.
/// - Integrates with the Moolah core contract to support borrowing, repayment, and collateral management using BNB.
contract BNBProvider is UUPSUpgradeable, AccessControlEnumerableUpgradeable, IProvider {
  using MarketParamsLib for MarketParams;
  using SharesMathLib for uint256;

  /* IMMUTABLES */

  IMoolah public immutable MOOLAH;
  IMoolahVault public immutable MOOLAH_VAULT;
  address public immutable TOKEN;

  mapping(address => bool) public vaults;

  bytes32 public constant MANAGER = keccak256("MANAGER");

  modifier onlyMoolah() {
    require(msg.sender == address(MOOLAH), "not moolah");
    _;
  }

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
    TOKEN = wbnb;

    _disableInitializers();
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
    return deposit(address(MOOLAH_VAULT), receiver);
  }

  /// @dev Deposit BNB and receive shares by specifying the amount of shares.
  /// @param shares The amount of shares to mint.
  /// @param receiver The address to receive the shares.
  function mint(uint256 shares, address receiver) external payable returns (uint256 assets) {
    return mint(address(MOOLAH_VAULT), shares, receiver);
  }

  /// @dev Withdraw shares from owner and send BNB to receiver by specifying the amount of assets.
  /// @param assets The amount of assets to withdraw.
  /// @param receiver The address to receive the assets.
  /// @param owner The address of the owner of the shares.
  function withdraw(uint256 assets, address payable receiver, address owner) external returns (uint256 shares) {
    return withdraw(address(MOOLAH_VAULT), assets, receiver, owner);
  }

  /// @dev Withdraw shares from owner and send BNB to receiver by specifying the amount of shares.
  /// @param shares The amount of shares to withdraw.
  /// @param receiver The address to receive the assets.
  /// @param owner The address of the owner of the shares.
  function redeem(uint256 shares, address payable receiver, address owner) external returns (uint256 assets) {
    return redeem(address(MOOLAH_VAULT), shares, receiver, owner);
  }

  /// @dev Deposit BNB and receive shares.
  /// @param receiver The address to receive the shares.
  /// @return shares The number of shares received.
  function deposit(address vault, address receiver) public payable returns (uint256 shares) {
    require(vaults[vault], "vault not added");
    uint256 assets = msg.value;
    require(assets > 0, ErrorsLib.ZERO_ASSETS);

    IWBNB(TOKEN).deposit{ value: assets }();
    require(IWBNB(TOKEN).approve(vault, assets));

    shares = IMoolahVault(vault).deposit(assets, receiver);
  }

  /// @dev Deposit BNB and receive shares by specifying the amount of shares.
  /// @param vault The address of the Moolah vault to deposit into.
  /// @param shares The amount of shares to mint.
  /// @param receiver The address to receive the shares.
  function mint(address vault, uint256 shares, address receiver) public payable returns (uint256 assets) {
    require(vaults[vault], "vault not added");
    require(shares > 0, ErrorsLib.ZERO_ASSETS);
    uint256 previewAssets = IMoolahVault(vault).previewMint(shares); // ceiling rounding
    require(msg.value >= previewAssets, "invalid BNB amount");

    IWBNB(TOKEN).deposit{ value: previewAssets }();
    require(IWBNB(TOKEN).approve(vault, previewAssets));
    assets = IMoolahVault(vault).mint(shares, receiver);

    if (msg.value > assets) {
      (bool success, ) = msg.sender.call{ value: msg.value - assets }("");
      require(success, "transfer failed");
    }
  }

  /// @dev Withdraw shares from owner and send BNB to receiver by specifying the amount of assets.
  /// @param vault The address of the Moolah vault to withdraw from.
  /// @param assets The amount of assets to withdraw.
  /// @param receiver The address to receive the assets.
  /// @param owner The address of the owner of the shares.
  function withdraw(
    address vault,
    uint256 assets,
    address payable receiver,
    address owner
  ) public returns (uint256 shares) {
    require(vaults[vault], "vault not added");
    require(assets > 0, ErrorsLib.ZERO_ASSETS);
    require(receiver != address(0), ErrorsLib.ZERO_ADDRESS);

    // 1. withdraw WBNB from moolah vault
    shares = IMoolahVault(vault).withdrawFor(assets, owner, msg.sender);

    // 2. unwrap WBNB
    IWBNB(TOKEN).withdraw(assets);

    // 3. transfer WBNB to receiver
    (bool success, ) = receiver.call{ value: assets }("");
    require(success, "transfer failed");
  }

  /// @dev Withdraw shares from owner and send BNB to receiver by specifying the amount of shares.
  /// @param vault The address of the Moolah vault to withdraw from.
  /// @param shares The amount of shares to withdraw.
  /// @param receiver The address to receive the assets.
  /// @param owner The address of the owner of the shares.
  function redeem(
    address vault,
    uint256 shares,
    address payable receiver,
    address owner
  ) public returns (uint256 assets) {
    require(vaults[vault], "vault not added");
    require(shares > 0, ErrorsLib.ZERO_ASSETS);
    require(receiver != address(0), ErrorsLib.ZERO_ADDRESS);

    // 1. redeem WBNB from moolah vault
    assets = IMoolahVault(vault).redeemFor(shares, owner, msg.sender);

    // 2. unwrap WBNB
    IWBNB(TOKEN).withdraw(assets);

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
    require(marketParams.loanToken == TOKEN, "invalid loan token");
    require(isSenderAuthorized(msg.sender, onBehalf), ErrorsLib.UNAUTHORIZED);
    require(receiver != address(0), ErrorsLib.ZERO_ADDRESS);

    // 1. borrow WBNB from moolah
    (_assets, _shares) = MOOLAH.borrow(marketParams, assets, shares, onBehalf, address(this));

    // 2. unwrap WBNB
    IWBNB(TOKEN).withdraw(_assets);

    // 3. transfer BNB to receiver
    (bool success, ) = receiver.call{ value: _assets }("");
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
    require(UtilsLib.exactlyOneZero(assets, shares), ErrorsLib.INCONSISTENT_INPUT);
    require(marketParams.loanToken == TOKEN, "invalid loan token");
    require(msg.value >= assets, "invalid BNB amount");

    // accrue interest on the market and then calculate `wrapAmount`
    MOOLAH.accrueInterest(marketParams);

    uint256 wrapAmount = assets;
    if (wrapAmount == 0) {
      // If assets is 0, we need to wrap the shares amount
      require(shares > 0, ErrorsLib.ZERO_ASSETS);
      Market memory market = MOOLAH.market(marketParams.id());
      wrapAmount = shares.toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
      require(msg.value >= wrapAmount, "insufficient funds");
    }

    // 1. wrap BNB to WBNB
    IWBNB(TOKEN).deposit{ value: wrapAmount }();
    // 2. approve moolah to transfer WBNB
    require(IWBNB(TOKEN).approve(address(MOOLAH), wrapAmount));
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
    require(marketParams.collateralToken == TOKEN, "invalid collateral token");

    // 1. deposit WBNB
    IWBNB(TOKEN).deposit{ value: assets }();
    // 2. approve moolah to transfer WBNB
    require(IWBNB(TOKEN).approve(address(MOOLAH), assets));
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
    require(marketParams.collateralToken == TOKEN, "invalid collateral token");
    require(isSenderAuthorized(msg.sender, onBehalf), ErrorsLib.UNAUTHORIZED);
    require(receiver != address(0), ErrorsLib.ZERO_ADDRESS);

    // 1. withdraw WBNB from moolah by specifying the amount
    MOOLAH.withdrawCollateral(marketParams, assets, onBehalf, address(this));

    // 2. unwrap WBNB
    IWBNB(TOKEN).withdraw(assets);

    // 3. transfer BNB to receiver
    (bool success, ) = receiver.call{ value: assets }("");
    require(success, "transfer failed");
  }

  /// @dev empty function to allow moolah to do liquidation
  /// @dev may support burn clisBnb in the future (mint clisBnb by providing BNB)
  function liquidate(Id id, address borrower) external onlyMoolah {}

  /// @dev Add a Moolah vault to the provider.
  function addVault(address vault) external {
    require(hasRole(MANAGER, msg.sender) || hasRole(DEFAULT_ADMIN_ROLE, msg.sender), ErrorsLib.UNAUTHORIZED);
    require(vault != address(0), ErrorsLib.ZERO_ADDRESS);
    require(!vaults[vault], "vault already added");
    require(address(IMoolahVault(vault).MOOLAH()) == address(MOOLAH), "invalid moolah vault");
    require(IMoolahVault(vault).asset() == TOKEN, "invalid asset");
    vaults[vault] = true;
  }

  /// @dev Remove a Moolah vault from the provider.
  function removeVault(address vault) external {
    require(hasRole(MANAGER, msg.sender) || hasRole(DEFAULT_ADMIN_ROLE, msg.sender), ErrorsLib.UNAUTHORIZED);
    require(vaults[vault], "vault not added");
    delete vaults[vault];
  }

  /// @dev Returns whether the sender is authorized to manage `onBehalf`'s positions.
  /// @param sender The address of the sender to check.
  /// @param onBehalf The address of the position owner.
  function isSenderAuthorized(address sender, address onBehalf) public view returns (bool) {
    return sender == onBehalf || MOOLAH.isAuthorized(onBehalf, sender);
  }

  receive() external payable {}

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
