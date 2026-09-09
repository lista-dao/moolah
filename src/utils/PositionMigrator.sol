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
import { IYieldAccount } from "./interfaces/IYieldAccount.sol";

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

  /// @dev The BNB CDP account routed to a YieldAccount. Hardcoded: no setter means no key can
  ///      redirect the routing, and `yieldAccount` is the only position owner it can migrate into.
  address public constant YIELD_ACCOUNT_OWNER = 0x0966602E47F6a3CA5692529F1D54EcD1d9B09175;

  /// @dev Whitelist of accounts allowed to call migratePosition
  EnumerableSet.AddressSet private whitelist;

  /// @dev Supported CDP collateral tokens for migration
  EnumerableSet.AddressSet private collaterals;

  /// @dev End of the voluntary migration window. Once passed, BOT can migrate without a
  ///      transaction from the owner. Zero — the default — disables `forceMigrate` entirely.
  uint256 public migrationDeadline;

  /// @dev The YieldAccount that owns YIELD_ACCOUNT_OWNER's Moolah position. Changing it changes
  ///      where the migrated funds land, so it is DEFAULT_ADMIN-only. Zero — the default — blocks
  ///      that account's migration entirely, deliberately: migrating into a plain position would
  ///      hand the yield to the owner.
  address public yieldAccount;

  /// @dev The only market YIELD_ACCOUNT_OWNER may migrate into. Set together with `yieldAccount`
  ///      and cross-checked against it, so the two can never disagree.
  bytes32 public yieldAccountMarket;

  modifier onlyWhitelisted() {
    require(whitelist.contains(msg.sender), "not whitelisted");
    _;
  }

  /// @dev Manager role
  bytes32 public constant MANAGER = keccak256("MANAGER");

  /// @dev may run `forceMigrate` once the migration window has closed
  bytes32 public constant BOT = keccak256("BOT");

  event PositionMigrated(
    address indexed user,
    address indexed collAddr,
    Id indexed marketId,
    uint256 collateralAmount,
    uint256 borrowAmount,
    bool isBnb
  );
  event UpdateWhitelist(address indexed account, bool status);
  event MigrationDeadlineChanged(uint256 oldDeadline, uint256 newDeadline);
  event SetYieldAccount(address indexed account, bytes32 marketId);
  event ForcedMigration(address indexed bot, uint256 debtAmount);
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
    /// @dev owner of the resulting Moolah position; equals `onBehalf` for ordinary migrations, and
    /// `yieldAccount` for the routed one, so the CDP side still acts on the owner's own address.
    address moolahOwner;
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
    return _migrate(marketParams, msg.sender, isBnb, minSlisBnb);
  }

  /**
   * @dev Migrates YIELD_ACCOUNT_OWNER's whole BNB CDP position after the migration window closed,
   *      without a transaction from that address.
   * @notice The CDP's `Interaction.migrator()` role is what permits repaying and releasing on its
   *         behalf, so no CDP contract change is needed.
   * @notice The destination is not a choice this function makes: funds can only land in
   *         `yieldAccount`, and the owner keeps its usual withdraw and repay rights there.
   * @notice The whole debt is flash-loaned and re-borrowed in one transaction, so the market needs
   *         both the flash-loan liquidity and the borrowable supply to cover it in full.
   * @param minSlisBnb minimum slisBNB expected from the release
   */
  function forceMigrate(
    MarketParams calldata marketParams,
    uint256 minSlisBnb
  ) external nonReentrant onlyRole(BOT) returns (uint256) {
    uint256 deadline = migrationDeadline;
    require(deadline != 0, "deadline not set");
    require(block.timestamp >= deadline, "migration window open");
    // the same whitelist gate as the voluntary path
    require(whitelist.contains(YIELD_ACCOUNT_OWNER), "not whitelisted");

    uint256 migrated = _migrate(marketParams, YIELD_ACCOUNT_OWNER, true, minSlisBnb);

    emit ForcedMigration(msg.sender, migrated);

    return migrated;
  }

  /// @dev Migrates `onBehalf`'s whole CDP position for the given collateral. The CDP side always
  ///      acts on `onBehalf`; only YIELD_ACCOUNT_OWNER is routed to a YieldAccount on the Moolah
  ///      side, everyone else keeps their own position.
  function _migrate(
    MarketParams calldata marketParams,
    address onBehalf,
    bool isBnb,
    uint256 minSlisBnb
  ) internal returns (uint256) {
    address collAddr = isBnb ? cdpBnbCollateral : marketParams.collateralToken;
    require(collaterals.contains(collAddr), "unsupported collateral");

    // if CDP collateral is BNB, the target collateral in Moolah must be slisBNB
    if (isBnb) {
      require(marketParams.collateralToken == SLISBNB, "invalid target collateral for BNB");
    }

    // refresh CDP debt
    INTERACTION.drip(collAddr); // accrue interest to get the updated debt amount
    uint256 cdpDebt = INTERACTION.borrowed(collAddr, onBehalf);
    require(cdpDebt > 0, "no debt to migrate");
    uint256 collateralAmount = INTERACTION.locked(collAddr, onBehalf);

    // the routed account migrates into its YieldAccount, never into a plain position
    address moolahOwner = onBehalf == YIELD_ACCOUNT_OWNER ? _yieldAccount(marketParams) : onBehalf;

    // pack data for flash loan callback
    bytes memory data = abi.encode(
      CallbackData({
        marketParams: marketParams,
        onBehalf: onBehalf,
        collateralAmount: collateralAmount,
        debt: cdpDebt,
        isBnb: isBnb,
        minSlisBnb: minSlisBnb,
        moolahOwner: moolahOwner
      })
    );

    MOOLAH.flashLoan(LISUSD, cdpDebt, data);

    LISUSD.safeApprove(address(MOOLAH), 0);

    emit PositionMigrated(onBehalf, collAddr, marketParams.id(), collateralAmount, cdpDebt, isBnb);

    return cdpDebt;
  }

  /**
   * @dev Points the routing at a YieldAccount and its market. Zero account clears the routing.
   * @notice DEFAULT_ADMIN (TimeLock), not MANAGER: this is where migrated collateral and debt land,
   *         so a key that could change it could redirect the owner's whole position.
   * @param account the YieldAccount that will own the migrated Moolah position
   * @param marketId the market it operates on; must match the account's own `marketId()`
   */
  function setYieldAccount(address account, bytes32 marketId) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (account == address(0)) {
      require(marketId == bytes32(0), "market must be zero");
    } else {
      require(marketId != bytes32(0), "zero market");
      require(IYieldAccount(account).OWNER() == YIELD_ACCOUNT_OWNER, "account owner mismatch");
      require(Id.unwrap(IYieldAccount(account).marketId()) == marketId, "account market mismatch");
      require(MOOLAH.market(Id.wrap(marketId)).lastUpdate != 0, "market not created");
    }
    require(account != yieldAccount || marketId != yieldAccountMarket, "same yield account");

    yieldAccount = account;
    yieldAccountMarket = marketId;

    emit SetYieldAccount(account, marketId);
  }

  /// @dev Zero disables `forceMigrate`.
  /// @dev DEFAULT_ADMIN, not MANAGER: shortening this window is what turns a voluntary migration
  ///      into a forced one, so any change should be publicly visible before it takes effect.
  function setMigrationDeadline(uint256 deadline) external onlyRole(DEFAULT_ADMIN_ROLE) {
    uint256 old = migrationDeadline;
    require(deadline != old, "same deadline");
    // a past deadline would open `forceMigrate` in the same block, skipping the window entirely
    require(deadline == 0 || deadline > block.timestamp, "deadline in the past");
    migrationDeadline = deadline;

    emit MigrationDeadlineChanged(old, deadline);
  }

  /// @dev MANAGER-callable because it can only ever delay a forced migration, never advance one
  function extendMigrationDeadline(uint256 deadline) external onlyRole(MANAGER) {
    uint256 old = migrationDeadline;
    require(old != 0, "deadline not set");
    require(deadline > old, "not an extension");
    // an extension has to reopen the window, not just move an already-passed deadline forward
    require(deadline > block.timestamp, "deadline in the past");
    migrationDeadline = deadline;

    emit MigrationDeadlineChanged(old, deadline);
  }

  /// @dev the routing target, with the checks that make it safe
  function _yieldAccount(MarketParams calldata marketParams) internal view returns (address) {
    address account = yieldAccount;
    bytes32 market = yieldAccountMarket;
    require(account != address(0), "yield account not set");
    require(Id.unwrap(marketParams.id()) == market, "wrong market");
    // re-checked at call time: the account is upgradeable, so its owner and market could have moved
    require(IYieldAccount(account).OWNER() == YIELD_ACCOUNT_OWNER, "account owner mismatch");
    require(Id.unwrap(IYieldAccount(account).marketId()) == market, "account market mismatch");
    // the borrow lands on the account, so it must have authorized this contract
    require(MOOLAH.isAuthorized(account, address(this)), "account not authorized");
    return account;
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
    // the only Moolah owner that may differ from the CDP-side address is the routed account's
    bool viaAccount = data.moolahOwner != data.onBehalf;
    if (viaAccount) {
      require(data.onBehalf == YIELD_ACCOUNT_OWNER && data.moolahOwner == yieldAccount, "invalid moolah owner");
      require(Id.unwrap(params.id()) == yieldAccountMarket, "wrong market");
    }

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
    // slisBNBProvider is configured for every slisBNB market, so the isBnb flow always takes a
    // provider branch (which uses releasedSlisBnb); the no-provider branch is for BTCB/wBETH.
    if (viaAccount) {
      // the account records the BNB principal, which is what keeps the growth with the protocol
      require(MOOLAH.providers(params.id(), params.collateralToken) == slisBnbProviderLending, "invalid provider");
      SLISBNB.safeApprove(data.moolahOwner, releasedSlisBnb);
      IYieldAccount(data.moolahOwner).depositSlisBnb(releasedSlisBnb);
      SLISBNB.safeApprove(data.moolahOwner, 0);
    } else {
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
    }

    // 5. borrow from Moolah, receive lisUSD in this contract
    MOOLAH.borrow(params, repaid, 0, data.moolahOwner, address(this));

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
