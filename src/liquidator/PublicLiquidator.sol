// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import "./IPublicLiquidator.sol";

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { UtilsLib } from "moolah/libraries/UtilsLib.sol";
import { MathLib, WAD } from "moolah/libraries/MathLib.sol";
import { SharesMathLib } from "moolah/libraries/SharesMathLib.sol";
import "moolah/libraries/ConstantsLib.sol";

contract PublicLiquidator is UUPSUpgradeable, AccessControlEnumerableUpgradeable, IPublicLiquidator {
  using MarketParamsLib for IMoolah.MarketParams;
  using MathLib for uint256;
  using SharesMathLib for uint256;

  /// @dev Thrown when passing the zero address.
  string internal constant ZERO_ADDRESS = "zero address";
  error NoProfit();
  error OnlyMoolah();
  error WhitelistSameStatus();
  error NotWhitelisted();
  error SwapFailed();
  error EitherOneZero();

  address public immutable MOOLAH;
  mapping(bytes32 => bool) public marketWhitelist;
  mapping(bytes32 => mapping(address => bool)) public marketUserWhitelist;

  bytes32 public constant MANAGER = keccak256("MANAGER"); // manager role
  bytes32 public constant BOT = keccak256("BOT"); // bot role

  event MarketWhitelistChanged(bytes32 id, bool added);
  event MarketUserWhitelistChanged(bytes32 id, address user, bool added);
  event Liquidated(
    bytes32 indexed id,
    address indexed borrower,
    uint256 seizedAssets,
    uint256 repaidAssets,
    uint256 repaidShares,
    address liquidator
  );

  /// @custom:oz-upgrades-unsafe-allow constructor
  /// @param moolah The address of the Moolah contract.
  constructor(address moolah) {
    require(moolah != address(0), ZERO_ADDRESS);
    _disableInitializers();
    MOOLAH = moolah;
  }

  /// @dev initializes the contract.
  /// @param admin The address of the admin.
  /// @param manager The address of the manager.
  /// @param bot The address of the bot.
  function initialize(address admin, address manager, address bot) public initializer {
    require(admin != address(0), ZERO_ADDRESS);
    require(manager != address(0), ZERO_ADDRESS);
    require(bot != address(0), ZERO_ADDRESS);
    __AccessControl_init();
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MANAGER, manager);
    _grantRole(BOT, bot);
  }

  /// @dev sets the market whitelist.
  /// @param id The id of the market.
  /// @param status The status of the market.
  function setMarketWhitelist(bytes32 id, bool status) external onlyRole(BOT) {
    require(IMoolah(MOOLAH).idToMarketParams(id).loanToken != address(0), "Invalid market");
    require(!IMoolah(MOOLAH).isLiquidationWhitelist(id, address(0)), "market is already open for liquidate");
    require(marketWhitelist[id] != status, WhitelistSameStatus());
    marketWhitelist[id] = status;
    emit MarketWhitelistChanged(id, status);
  }

  /// @dev sets the market user whitelist.
  /// @param id The id of the market.
  /// @param user The address of the user.
  /// @param status The status of the user.
  function setMarketUserWhitelist(bytes32 id, address user, bool status) external onlyRole(BOT) {
    require(IMoolah(MOOLAH).idToMarketParams(id).loanToken != address(0), "Invalid market");
    require(
      !marketWhitelist[id] || !IMoolah(MOOLAH).isLiquidationWhitelist(id, address(0)),
      "market is already open for liquidate"
    );
    require(marketUserWhitelist[id][user] != status, WhitelistSameStatus());
    marketUserWhitelist[id][user] = status;
    emit MarketUserWhitelistChanged(id, user, status);
  }

  /// @dev flash liquidates a position.
  /// @param id The id of the market.
  /// @param borrower The address of the borrower.
  /// @param seizedAssets The amount of assets to seize.
  /// @param pair The address of the pair.
  /// @param swapData The swap data.
  function flashLiquidate(
    bytes32 id,
    address borrower,
    uint256 seizedAssets,
    address pair,
    bytes calldata swapData
  ) external {
    require(isLiquidatable(id, borrower), NotWhitelisted());
    IMoolah.MarketParams memory params = IMoolah(MOOLAH).idToMarketParams(id);
    // calculate how much loan token to repay
    uint256 repayAmount = loanTokenAmountNeed(id, seizedAssets, 0);
    // pre-balance of loan token
    uint256 loanTokenBalanceBefore = SafeTransferLib.balanceOf(params.loanToken, address(this));
    // liquidate borrower's position
    IMoolah(MOOLAH).liquidate(
      params,
      borrower,
      seizedAssets,
      0,
      abi.encode(MoolahLiquidateData(params.collateralToken, params.loanToken, seizedAssets, pair, swapData, true))
    );
    // post-balance of loan token
    uint256 loanTokenBalanceAfter = SafeTransferLib.balanceOf(params.loanToken, address(this));
    // check if the liquidator made a profit
    if (loanTokenBalanceAfter <= loanTokenBalanceBefore) revert NoProfit();
    // transfer profit to the liquidator
    SafeTransferLib.safeTransfer(params.loanToken, msg.sender, loanTokenBalanceAfter - loanTokenBalanceBefore);
    // remove user from whitelist
    postLiquidate(params, id, borrower);
    // broadcast event
    emit Liquidated(id, borrower, seizedAssets, repayAmount, 0, msg.sender);
  }

  /// @dev liquidates a position.
  /// @param id The id of the market.
  /// @param borrower The address of the borrower.
  /// @param seizedAssets The amount of assets to seize.
  function liquidate(bytes32 id, address borrower, uint256 seizedAssets, uint256 repaidShares) external {
    require(isLiquidatable(id, borrower), NotWhitelisted());
    require(seizedAssets == 0 || repaidShares == 0, EitherOneZero());
    IMoolah.MarketParams memory params = IMoolah(MOOLAH).idToMarketParams(id);

    // accrue interest for the market before calculate how much loan token is needed
    IMoolah(MOOLAH).accrueInterest(params);
    // calculate how much loan token to transfer
    uint256 loanTokenAmount = loanTokenAmountNeed(id, seizedAssets, repaidShares);
    // transfer loan token to this contract
    SafeTransferLib.safeTransferFrom(params.loanToken, msg.sender, address(this), loanTokenAmount);

    // pre-balance of loan token
    uint256 loanTokenBalanceBefore = SafeTransferLib.balanceOf(params.loanToken, address(this));
    // pre-balance of collateral token
    uint256 collateralTokenBalanceBefore = SafeTransferLib.balanceOf(params.collateralToken, address(this));
    // liquidate borrower's position
    IMoolah(MOOLAH).liquidate(
      params,
      borrower,
      seizedAssets,
      repaidShares,
      abi.encode(MoolahLiquidateData(params.collateralToken, params.loanToken, seizedAssets, address(0), "", false))
    );
    // post-balance of collateral token
    uint256 collateralTokenBalanceAfter = SafeTransferLib.balanceOf(params.collateralToken, address(this));
    // post-balance of loan token
    uint256 loanTokenBalanceAfter = SafeTransferLib.balanceOf(params.loanToken, address(this));
    // check if the liquidator made a profit
    if (collateralTokenBalanceAfter <= collateralTokenBalanceBefore) revert NoProfit();
    // transfer bid collateral to the liquidator
    SafeTransferLib.safeTransfer(
      params.collateralToken,
      msg.sender,
      collateralTokenBalanceAfter - collateralTokenBalanceBefore
    );
    // transfer unused loan token back to the liquidator
    if (loanTokenBalanceAfter > loanTokenBalanceBefore) {
      SafeTransferLib.safeTransfer(params.loanToken, msg.sender, loanTokenBalanceAfter - loanTokenBalanceBefore);
    }
    // remove user from whitelist
    postLiquidate(params, id, borrower);
    // broadcast event
    emit Liquidated(id, borrower, seizedAssets, loanTokenAmount, repaidShares, msg.sender);
  }

  /// @dev calculates the amount of loan token needed to repay the shares.
  ///      exactly the same logic as in the Moolah contract.
  /// @param id The id of the market.
  /// @param seizedAssets The amount of assets seized.
  /// @param repaidShares The amount of shares to repay.
  function loanTokenAmountNeed(bytes32 id, uint256 seizedAssets, uint256 repaidShares) public view returns (uint256) {
    IMoolah.MarketParams memory params = IMoolah(MOOLAH).idToMarketParams(id);
    IMoolah.Market memory market = IMoolah(MOOLAH).market(id);
    uint256 _repaidShares = repaidShares;
    // calculate by amt of collateral to buy
    if (seizedAssets > 0) {
      uint256 liquidationIncentiveFactor = UtilsLib.min(
        MAX_LIQUIDATION_INCENTIVE_FACTOR,
        WAD.wDivDown(WAD - LIQUIDATION_CURSOR.wMulDown(WAD - params.lltv))
      );
      uint256 collateralPrice = IMoolah(MOOLAH).getPrice(params);
      uint256 seizedAssetsQuoted = seizedAssets.mulDivUp(collateralPrice, ORACLE_PRICE_SCALE);
      _repaidShares = seizedAssetsQuoted.wDivUp(liquidationIncentiveFactor).toSharesUp(
        market.totalBorrowAssets,
        market.totalBorrowShares
      );
    }
    // calculate by loan token amt need to repay the shares
    return _repaidShares.toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
  }

  /// @dev remove borrower from the whitelist after liquidation.
  /// @param id The id of the market.
  /// @param borrower The address of the borrower.
  function postLiquidate(IMoolah.MarketParams memory params, bytes32 id, address borrower) internal {
    // remove user from whitelist if position is healthy and inside whitelist
    if (IMoolah(MOOLAH).isHealthy(params, id, borrower) && marketUserWhitelist[id][borrower]) {
      marketUserWhitelist[id][borrower] = false;
      emit MarketUserWhitelistChanged(id, borrower, false);
    }
  }

  /// @dev checks if a position is able to liquidate.
  /// @param id The id of the market.
  /// @param borrower The address of the borrower.
  function isLiquidatable(bytes32 id, address borrower) internal view returns (bool) {
    return
      IMoolah(MOOLAH).isLiquidationWhitelist(id, address(0)) ||
      marketWhitelist[id] ||
      marketUserWhitelist[id][borrower];
  }

  /// @dev the function will be called by the Moolah contract when liquidate.
  /// @param repaidAssets The amount of assets repaid.
  /// @param data The callback data.
  function onMoolahLiquidate(uint256 repaidAssets, bytes calldata data) external {
    require(msg.sender == MOOLAH, OnlyMoolah());
    MoolahLiquidateData memory arb = abi.decode(data, (MoolahLiquidateData));
    if (arb.swap) {
      uint256 before = SafeTransferLib.balanceOf(arb.loanToken, address(this));

      SafeTransferLib.safeApprove(arb.collateralToken, arb.pair, arb.seized);
      (bool success, ) = arb.pair.call(arb.swapData);
      require(success, SwapFailed());

      uint256 out = SafeTransferLib.balanceOf(arb.loanToken, address(this)) - before;

      if (out < repaidAssets) revert NoProfit();

      // revoke approval for the pair
      SafeTransferLib.safeApprove(arb.collateralToken, arb.pair, 0);
    }

    SafeTransferLib.safeApprove(arb.loanToken, MOOLAH, repaidAssets);
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
