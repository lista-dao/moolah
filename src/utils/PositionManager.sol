// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import { Id, IMoolah, MarketParams } from "../moolah/interfaces/IMoolah.sol";
import { IMoolahFlashLoanCallback } from "../moolah/interfaces/IMoolahCallbacks.sol";
import { MarketParamsLib } from "../moolah/libraries/MarketParamsLib.sol";
import { MoolahBalancesLib } from "../moolah/libraries/periphery/MoolahBalancesLib.sol";
import { SharesMathLib } from "../moolah/libraries/SharesMathLib.sol";
import { UtilsLib } from "../moolah/libraries/UtilsLib.sol";
import { IBroker } from "../broker/interfaces/IBroker.sol";
import { IPositionManager } from "./interfaces/IPositionManager.sol";
import { IERC20Provider, INativeProvider } from "../moolah/interfaces/IProvider.sol";

/// @notice Atomically migrates a variable-rate borrow position to a fixed-term position.
contract PositionManager is
  UUPSUpgradeable,
  AccessControlEnumerableUpgradeable,
  IPositionManager,
  IMoolahFlashLoanCallback
{
  using SafeERC20 for IERC20;
  using MarketParamsLib for MarketParams;
  using MoolahBalancesLib for IMoolah;
  using SharesMathLib for uint256;

  IMoolah public immutable MOOLAH;
  /// @dev Address of the WBNB token. Used to detect native-token providers (BNBProvider).
  address public immutable WBNB;

  bytes32 public constant MANAGER = keccak256("MANAGER");

  /// @dev Encoded parameters passed through the flash loan callback.
  struct MigrateParams {
    MarketParams outMarket;
    MarketParams inMarket;
    uint256 collateralAmount;
    uint256 borrowShares; // non-zero when repaying by shares (full migration)
    uint256 termId;
    address user; // captured from msg.sender in migrate(); never use msg.sender in callback
  }

  /**
   * @notice Constructor sets the Moolah reference and WBNB address.
   * @param moolah The address of the Moolah contract (cannot be changed
   * after deployment).
   * @param wbnb The address of the WBNB token; used to identify native-token providers. Can be address(0) if native BNB collateral is not used in any market.
   */
  constructor(address moolah, address wbnb) {
    require(moolah != address(0), "pm/zero-address");
    MOOLAH = IMoolah(moolah);
    WBNB = wbnb; // may be address(0) if native BNB collateral is not used

    _disableInitializers();
  }

  /**
   * @notice Initializes the PositionManager with admin and manager roles.
   * @param admin The address to grant the DEFAULT_ADMIN_ROLE, which can authorize upgrades.
   * @param manager The address to grant the MANAGER role, which can perform migrations.
   */
  function initialize(address admin, address manager) public initializer {
    __AccessControlEnumerable_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MANAGER, manager);
  }

  /// @dev Required to receive native BNB/ETH from native-token providers on collateral withdrawal.
  receive() external payable {}

  /// @inheritdoc IPositionManager
  function migrateCommonMarketToFixedTermMarket(
    MarketParams calldata outMarket,
    MarketParams calldata inMarket,
    uint256 collateralAmount,
    uint256 borrowAmount,
    uint256 borrowShares,
    uint256 termId
  ) external override {
    require(collateralAmount > 0, "zero-collateral-amount");
    require(UtilsLib.exactlyOneZero(borrowAmount, borrowShares), "exactly-one-of-borrowAmount-or-borrowShares");
    require(MOOLAH.isAuthorized(msg.sender, address(this)), "not-authorized");
    require(outMarket.loanToken == inMarket.loanToken, "loan-token-mismatch");
    require(outMarket.collateralToken == inMarket.collateralToken, "collateral-token-mismatch");
    require(inMarket.lltv >= outMarket.lltv, "in-market-lltv-too-low");

    // When repaying by shares, convert borrowShares to the expected asset amount for the flash loan.
    if (borrowAmount == 0) {
      (, , uint256 totalBorrowAssets, uint256 totalBorrowShares) = MOOLAH.expectedMarketBalances(outMarket);
      borrowAmount = borrowShares.toAssetsUp(totalBorrowAssets, totalBorrowShares);
    }

    bytes memory data = abi.encode(
      MigrateParams({
        outMarket: outMarket,
        inMarket: inMarket,
        collateralAmount: collateralAmount,
        borrowShares: borrowShares,
        termId: termId,
        user: msg.sender
      })
    );

    // Initiates the flash loan; execution continues in onMoolahFlashLoan.
    MOOLAH.flashLoan(outMarket.loanToken, borrowAmount, data);
    IERC20(outMarket.loanToken).forceApprove(address(MOOLAH), 0);
  }

  /// @inheritdoc IMoolahFlashLoanCallback
  /// @dev Called by Moolah during flashLoan. Executes the atomic migration steps.
  function onMoolahFlashLoan(uint256 assets, bytes calldata data) external override {
    require(msg.sender == address(MOOLAH), "invalid-caller");

    MigrateParams memory p = abi.decode(data, (MigrateParams));

    // Step 1: Repay user's variable-rate debt in outMarket.
    //         When borrowShares > 0, repay by shares for exact full migration;
    //         when borrowShares == 0, assets is used (partial migration).
    //         Moolah requires exactlyOneZero(assets, shares).
    IERC20(p.outMarket.loanToken).safeIncreaseAllowance(address(MOOLAH), assets);
    (uint256 assetsRepaid, ) = MOOLAH.repay(p.outMarket, p.borrowShares > 0 ? 0 : assets, p.borrowShares, p.user, "");
    require(assetsRepaid <= assets, "insufficient-flash-loan");

    // outMarket.collateralToken == inMarket.collateralToken (enforced in migrate), so isNative is shared.
    bool isNative = p.outMarket.collateralToken == WBNB;

    // Step 2: Withdraw collateral from outMarket; receiver is this contract.
    address outProvider = MOOLAH.providers(p.outMarket.id(), p.outMarket.collateralToken);
    if (outProvider != address(0)) {
      if (isNative) {
        // Native-token provider (BNBProvider): unwraps collateral and sends native BNB to this
        // contract; receive() accepts it for use in the supply step below.
        INativeProvider(outProvider).withdrawCollateral(
          p.outMarket,
          p.collateralAmount,
          p.user,
          payable(address(this))
        );
      } else {
        // ERC20 provider (SlisBNBProvider): sends collateral token directly to this contract.
        IERC20Provider(outProvider).withdrawCollateral(p.outMarket, p.collateralAmount, p.user, address(this));
      }
    } else {
      MOOLAH.withdrawCollateral(p.outMarket, p.collateralAmount, p.user, address(this));
    }

    // Step 3: Supply collateral to inMarket on behalf of user.
    address inProvider = MOOLAH.providers(p.inMarket.id(), p.inMarket.collateralToken);
    if (inProvider != address(0)) {
      if (isNative) {
        // Native-token provider (BNBProvider): supply using native BNB received in step 2;
        // the 3-arg payable supplyCollateral wraps it internally.
        INativeProvider(inProvider).supplyCollateral{ value: p.collateralAmount }(p.inMarket, p.user, "");
      } else {
        // ERC20 provider (SlisBNBProvider): approve provider to pull the collateral token.
        IERC20(p.inMarket.collateralToken).safeIncreaseAllowance(inProvider, p.collateralAmount);
        IERC20Provider(inProvider).supplyCollateral(p.inMarket, p.collateralAmount, p.user, "");
      }
    } else {
      IERC20(p.inMarket.collateralToken).safeIncreaseAllowance(address(MOOLAH), p.collateralAmount);
      MOOLAH.supplyCollateral(p.inMarket, p.collateralAmount, p.user, "");
    }

    // Step 4: Borrow fixed-term via inMarket's LendingBroker on behalf of user.
    //         Borrow only assetsRepaid (not the full flash loan amount) so the user's new
    //         fixed-term debt matches exactly what was repaid from the variable-rate market.
    //         Tokens are sent here (receiver = address(this)) for flash loan repayment.
    address broker = MOOLAH.brokers(p.inMarket.id());
    require(broker != address(0), "no-broker-for-market");
    IBroker(broker).borrow(assetsRepaid, p.termId, p.user, address(this));

    // Step 5: Approve Moolah to pull back the flash-loaned amount.
    //         Moolah calls safeTransferFrom(this, moolah, assets) after this callback returns.
    IERC20(p.outMarket.loanToken).safeIncreaseAllowance(address(MOOLAH), assets);
  }

  /**
   * @notice Emergency function to withdraw tokens from the contract. Restricted to MANAGER role.
   * @param token The address of the token to withdraw; use address(0) for
   * native BNB/ETH. Must be the same token as the collateral in the markets, since that's the only token this contract should hold.
   * @param amount The amount of the token to withdraw.
   */
  function emergencyWithdraw(address token, uint256 amount) external onlyRole(MANAGER) {
    if (token == address(0)) {
      // Withdraw native BNB/ETH
      (bool ok, ) = msg.sender.call{ value: amount }("");
      require(ok, "withdraw-failed");
    } else {
      // Withdraw ERC20 token
      IERC20(token).safeTransfer(msg.sender, amount);
    }
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
