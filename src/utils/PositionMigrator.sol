// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { IMoolah, MarketParams, Id, Position } from "moolah/interfaces/IMoolah.sol";
import { IMoolahFlashLoanCallback } from "moolah/interfaces/IMoolahCallbacks.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { IInteraction } from "./interfaces/IInteraction.sol";
import { IBnbProviderCdp, ISlisBnbProviderCdp } from "./interfaces/ICdpProvider.sol";
import { ISlisBnbProvider } from "../provider/interfaces/IProvider.sol";

contract PositionMigrator is
  IMoolahFlashLoanCallback,
  UUPSUpgradeable,
  AccessControlEnumerableUpgradeable,
  ReentrancyGuardUpgradeable
{
  using EnumerableSet for EnumerableSet.AddressSet;
  using MarketParamsLib for MarketParams;
  using SafeTransferLib for address;

  /// @dev Moolah contract
  IMoolah public constant MOOLAH = IMoolah(0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C);

  /// @dev CDP Interaction contract; entry point to pay back CDP debt
  IInteraction public constant INTERACTION = IInteraction(0xB68443Ee3e828baD1526b3e0Bdf2Dfc6b1975ec4);

  /// @dev lisUSD token address
  address public constant LISUSD = 0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5;

  /// @dev slisBNB token address
  address public constant SLISBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;

  /// @dev CDP BNBProvider contract; entry point to withdraw BNB collateral from CDP
  /// @notice BNB collateral wil be migrated in the form of slisBNB
  address public constant bnbProvider = 0xa835F890Fcde7679e7F7711aBfd515d2A267Ed0B;

  /// @dev CDP SlisBnbProvider contract; entry point to withdraw slisBNB collateral from CDP
  address public constant slisBnbProviderCDP = 0xfD31e1C5e5571f8E7FE318f80888C1e6da97819b;

  /// @dev Lending SlisBnbProvider contract; entry point to supply slisBNB collateral to Moolah
  address public constant slisBnbProviderLending = 0x33f7A980a246f9B8FEA2254E3065576E127D4D5f;

  /// @dev CDP collateral address for BNB; ceToken address representing BNB collateral in CDP
  address public constant cdpBnbCollateral = 0x563282106A5B0538f8673c787B3A16D3Cc1DbF1a;

  /// @dev Whitelist of accounts allowed to call migratePosition
  EnumerableSet.AddressSet private whitelist;

  /// @dev Supported CDP collateral tokens for migration
  EnumerableSet.AddressSet private collaterals;

  modifier onlyWhitelisted() {
    require(whitelist.contains(msg.sender), "not whitelisted");
    _;
  }

  /// @dev Manager role
  bytes32 public constant MANAGER = keccak256("MANAGER");

  event PositionMigrated(
    address indexed user,
    address indexed collAddr,
    Id indexed marketId,
    uint256 collateralAmount,
    uint256 borrowAmount,
    bool isBnb
  );
  event UpdateWhitelist(address indexed account, bool status);
  event UpdateSupportedCollateral(address indexed collAddr, bool supported);

  struct CallbackData {
    /// @dev the market to migrate to
    MarketParams marketParams;
    /// @dev the owner of the position to migrate
    address onBehalf;
    /// @dev the amount of collateral to withdraw from CDP and supply to Moolah
    uint256 collateralAmount;
    /// @dev CDP debt to payback
    uint256 debt;
    /// @dev whether the CDP collateral is BNB, which requires special handling for migration
    bool isBnb;
    /// @dev the minimum amount of slisBNB expected to receive when migrating BNB collateral
    /// @dev used to protect against slippage in the release and supply process; only applicable when isBnb is true
    uint256 minSlisBnb;
  }

  constructor() {
    _disableInitializers();
  }

  /**
   * @dev Initializes the contract with the given admin, manager, and supported CDP collaterals for migration.
   * @param admin The address to be granted the default admin role.
   * @param manager The address to be granted the manager role, which can manage the whitelist.
   * @param supportedCollaterals An array of addresses representing the supported CDP collateral tokens for migration.
   */
  function initialize(address admin, address manager, address[] memory supportedCollaterals) external initializer {
    require(admin != address(0), "zero address");
    require(manager != address(0), "zero address");

    __AccessControl_init();
    __ReentrancyGuard_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MANAGER, manager);

    for (uint256 i = 0; i < supportedCollaterals.length; i++) {
      address coll = supportedCollaterals[i];
      require(coll != address(0), "zero address");
      require(collaterals.add(coll), "collateral already added");

      emit UpdateSupportedCollateral(coll, true);
    }

    // add Bnb collateral by default
    require(collaterals.add(cdpBnbCollateral), "Bnb already added");
    emit UpdateSupportedCollateral(cdpBnbCollateral, true);

    // add slisBNB collateral by default
    require(collaterals.add(SLISBNB), "slisBNB already added");
    emit UpdateSupportedCollateral(SLISBNB, true);
  }

  /**
   * @dev Migrates a position from CDP to Moolah.
   * @param marketParams The market parameters of the Moolah position to migrate to.
   * @param isBnb Whether the CDP collateral is BNB, which requires special handling for migration.
   * @param minSlisBnb The minimum amount of slisBNB expected to receive when migrating BNB collateral; for slippage protection; only applicable when isBnb is true
   *
   * @notice If the caller already has a position in the target Moolah market, the migrated
   *         collateral and debt are ADDED to the existing position. The combined position's
   *         LTV will be a weighted average of the two.
   *
   *         Immediate liquidation after migration is not possible because the target Moolah
   *         slisBNB/lisUSD market has an LLTV of 85%, which is higher than both CDP LLTVs
   *         (slisBNB: 80%, BNB: 83.33%). Any position healthy in the CDP is therefore
   *         healthy after migration. BTCB/lisUSD and wBETH/lisUSD markets will also be
   *         created for migration.
   *
   *         Migrating during an active CDP liquidation auction: if a user's CDP position
   *         is being liquidated and the user migrates while the auction is ongoing, the
   *         migration operates on the reduced position (collateral partially seized by the
   *         auction). When the auction later concludes, any leftover collateral is returned
   *         to the user's gem balance in the Vat via vat.flux. This collateral is not
   *         migrated, but the user can withdraw it from the CDP system later. No funds are
   *         lost, but users should be aware that migrating during an active auction may
   *         leave collateral behind in the CDP system.
   */
  function migratePosition(
    MarketParams calldata marketParams,
    bool isBnb,
    uint256 minSlisBnb
  ) external nonReentrant onlyWhitelisted returns (uint256) {
    address collAddr = isBnb ? cdpBnbCollateral : marketParams.collateralToken;
    require(collaterals.contains(collAddr), "unsupported collateral");

    // if CDP collateral is BNB, the target collateral in Moolah must be slisBNB
    if (isBnb) {
      require(marketParams.collateralToken == SLISBNB, "invalid target collateral for BNB");
    }

    // refresh CDP debt
    INTERACTION.drip(collAddr); // accrue interest to get the updated debt amount
    uint256 cdpDebt = INTERACTION.borrowed(collAddr, msg.sender);
    require(cdpDebt > 0, "no debt to migrate");
    uint256 collateralAmount = INTERACTION.locked(collAddr, msg.sender);

    // pack data for flash loan callback
    bytes memory data = abi.encode(
      CallbackData({
        marketParams: marketParams,
        onBehalf: msg.sender,
        collateralAmount: collateralAmount,
        debt: cdpDebt,
        isBnb: isBnb,
        minSlisBnb: minSlisBnb
      })
    );

    MOOLAH.flashLoan(LISUSD, cdpDebt, data);

    LISUSD.safeApprove(address(MOOLAH), 0);

    emit PositionMigrated(msg.sender, collAddr, marketParams.id(), collateralAmount, cdpDebt, isBnb);

    return cdpDebt;
  }

  function onMoolahFlashLoan(uint256 assets, bytes calldata _data) external {
    require(msg.sender == address(MOOLAH), "caller must be moolah");

    // 1. validate data
    CallbackData memory data = abi.decode(_data, (CallbackData));
    require(whitelist.contains(data.onBehalf), "not whitelisted");
    require(assets >= data.debt, "insufficient flash loan amount");

    MarketParams memory params = data.marketParams;
    require(params.loanToken == LISUSD, "invalid loan token");
    require(collaterals.contains(params.collateralToken), "unsupported collateral token");

    // 2. pay back CDP debt using the flash loaned lisUSD
    uint256 repaid = LISUSD.balanceOf(address(this));
    LISUSD.safeApprove(address(INTERACTION), data.debt);
    address collAddr = data.isBnb ? cdpBnbCollateral : params.collateralToken;
    INTERACTION.paybackFor(collAddr, data.debt, data.onBehalf);
    LISUSD.safeApprove(address(INTERACTION), 0);
    repaid = repaid - LISUSD.balanceOf(address(this));
    require(repaid <= data.debt, "overpaid CDP debt");

    uint256 releasedSlisBnb = IERC20(SLISBNB).balanceOf(address(this));

    // 3. withdraw CDP collateral
    address cdpProvider = INTERACTION.helioProviders(params.collateralToken);
    if (data.isBnb) {
      // withdraw from CDP BnbProvider, which will release the collateral in the form of slisBNB
      IBnbProviderCdp(bnbProvider).releaseInTokenFor(data.onBehalf, data.collateralAmount);
    } else if (cdpProvider == address(0)) {
      // no provider configured, withdraw directly from Interaction
      INTERACTION.withdrawFor(data.onBehalf, params.collateralToken, data.collateralAmount);
    } else if (cdpProvider == slisBnbProviderCDP) {
      // withdraw slisBnb from CDP SlisBnbProvider
      ISlisBnbProviderCdp(slisBnbProviderCDP).releaseFor(data.onBehalf, data.collateralAmount);
    } else {
      revert("unsupported collateral");
    }

    releasedSlisBnb = IERC20(SLISBNB).balanceOf(address(this)) - releasedSlisBnb;
    if (data.isBnb) {
      require(releasedSlisBnb >= data.minSlisBnb, "slippage too high");
    }

    // 4. supply collateral
    // Note: slisBNBProvider must be configured for all slisBNB Moolah markets, ensuring
    // the isBnb flow always takes the provider branch (which correctly uses releasedSlisBnb).
    // The no-provider branch uses collateralAmount, which is only correct for non-BNB
    // collaterals (BTCB, wBETH) where no conversion occurs.
    address provider = MOOLAH.providers(params.id(), params.collateralToken);
    if (provider == address(0)) {
      params.collateralToken.safeApprove(address(MOOLAH), data.collateralAmount);
      MOOLAH.supplyCollateral(params, data.collateralAmount, data.onBehalf, "");
      params.collateralToken.safeApprove(address(MOOLAH), 0);
    } else {
      require(provider == slisBnbProviderLending, "invalid moolah provider");
      params.collateralToken.safeApprove(provider, releasedSlisBnb);
      ISlisBnbProvider(provider).supplyCollateral(params, releasedSlisBnb, data.onBehalf, "");
      params.collateralToken.safeApprove(provider, 0);
    }

    // 5. borrow from Moolah, receive lisUSD in this contract
    MOOLAH.borrow(params, repaid, 0, data.onBehalf, address(this));

    // 6. approve Moolah to pull the borrowed amount for flash loan repayment
    LISUSD.safeApprove(address(MOOLAH), assets);
  }

  /**
   * @dev Updates the whitelist status of multiple accounts.
   * @param accounts The addresses of the accounts to update.
   * @param enable A boolean indicating whether to add (true) or remove (false) the accounts from the whitelist.
   */
  function updateWhitelist(address[] memory accounts, bool enable) external onlyRole(MANAGER) {
    require(accounts.length > 0, "no accounts provided");

    for (uint256 i = 0; i < accounts.length; i++) {
      address account = accounts[i];
      require(account != address(0), "zero address");
      if (enable) {
        require(whitelist.add(account), "account already whitelisted");
      } else {
        require(whitelist.remove(account), "account not in whitelist");
      }
      emit UpdateWhitelist(account, enable);
    }
  }

  /**
   * @dev Adds or removes a collateral token from the supported collaterals list.
   * @param collAddr The address of the collateral token to add or remove.
   * @param supported A boolean indicating whether to add (true) or remove (false) the collateral token from the supported list.
   */
  function setSupportedCollateral(address collAddr, bool supported) external onlyRole(MANAGER) {
    require(collAddr != address(0), "zero address");
    if (supported) {
      require(collaterals.add(collAddr), "collateral already added");
    } else {
      require(collaterals.remove(collAddr), "collateral not in list");
    }
    emit UpdateSupportedCollateral(collAddr, supported);
  }

  /**
   * @dev Checks if an account is whitelisted.
   */
  function isWhitelisted(address account) external view returns (bool) {
    return whitelist.contains(account);
  }

  /**
   * @dev Returns the list of supported collateral tokens for migration.
   */
  function getCollaterals() external view returns (address[] memory) {
    return collaterals.values();
  }

  /**
   * @dev Checks if a collateral token is supported for migration.
   * @param collAddr The address of the collateral token to check.
   * @return A boolean indicating whether the collateral token is supported for migration.
   */
  function isCollateralSupported(address collAddr) external view returns (bool) {
    return collaterals.contains(collAddr);
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
