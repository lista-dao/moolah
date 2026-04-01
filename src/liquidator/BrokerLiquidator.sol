// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { IBroker, IBrokerBase } from "../broker/interfaces/IBroker.sol";
import { Id, MarketParams, IMoolah } from "moolah/interfaces/IMoolah.sol";
import { IBrokerLiquidator } from "./IBrokerLiquidator.sol";
import { ISmartProvider } from "../provider/interfaces/IProvider.sol";

contract BrokerLiquidator is UUPSUpgradeable, AccessControlUpgradeable, IBrokerLiquidator {
  using MarketParamsLib for MarketParams;

  /// @dev Thrown when passing the zero address.
  string internal constant ZERO_ADDRESS = "zero address";
  error NoProfit();
  error OnlyBroker();
  error ExceedAmount();
  error WhitelistSameStatus();
  error NotWhitelisted();
  error SwapFailed();
  error BrokerMarketIdMismatch();

  address public immutable MOOLAH;
  mapping(address => bool) public tokenWhitelist;
  mapping(address => bool) public pairWhitelist;
  /// @dev market id => broker address
  // zero address means market not whitelisted
  mapping(bytes32 => address) public marketIdToBroker;
  /// @dev broker address => market id
  // then we will know broker is whitelisted or not
  // by checking broker address => marketIdToBroker[market id] == broker address
  mapping(address => bytes32) public brokerToMarketId;
  // @dev smart collateral provider whitelist
  mapping(address => bool) public smartProviders;

  bytes32 public constant MANAGER = keccak256("MANAGER"); // manager role
  bytes32 public constant BOT = keccak256("BOT"); // manager role

  event TokenWhitelistChanged(address indexed token, bool added);
  event MarketWhitelistChanged(bytes32 id, address broker, bool added);
  event PairWhitelistChanged(address pair, bool added);
  event SellToken(address pair, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin);
  event SmartProvidersChanged(address provider, bool added);

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

  /// @dev withdraws ERC20 tokens.
  /// @param token The address of the token.
  /// @param amount The amount to withdraw.
  function withdrawERC20(address token, uint256 amount) external onlyRole(MANAGER) {
    SafeTransferLib.safeTransfer(token, msg.sender, amount);
  }

  /// @dev sets the token whitelist.
  /// @param token The address of the token.
  /// @param status The status of the token.
  function setTokenWhitelist(address token, bool status) external onlyRole(MANAGER) {
    require(tokenWhitelist[token] != status, WhitelistSameStatus());
    tokenWhitelist[token] = status;
    emit TokenWhitelistChanged(token, status);
  }

  /// @dev sets the market whitelist.
  /// @param id The id of the market.
  /// @param broker The address of the broker.
  /// @param status The status of the market.
  function setMarketToBroker(bytes32 id, address broker, bool status) external onlyRole(MANAGER) {
    _setMarketToBroker(id, broker, status);
  }

  /// @dev batch sets the market whitelist.
  /// @param ids The array of market ids.
  /// @param brokers The array of broker addresses.
  /// @param status The status to set for all markets.
  function batchSetMarketToBroker(
    bytes32[] calldata ids,
    address[] calldata brokers,
    bool status
  ) external onlyRole(MANAGER) {
    require(ids.length == brokers.length, "ids and brokers length mismatch");
    for (uint256 i = 0; i < ids.length; i++) {
      bytes32 id = ids[i];
      address broker = brokers[i];
      _setMarketToBroker(id, broker, status);
    }
  }

  function _setMarketToBroker(bytes32 id, address broker, bool status) internal {
    require(IMoolah(MOOLAH).idToMarketParams(Id.wrap(id)).loanToken != address(0), "Invalid market");
    require(Id.unwrap(IBrokerBase(broker).MARKET_ID()) == id, BrokerMarketIdMismatch());
    // add market and broker to whitelist
    if (status) {
      require(marketIdToBroker[id] != broker, WhitelistSameStatus());
      require(_checkBrokerMarketId(broker, id), BrokerMarketIdMismatch());
      marketIdToBroker[id] = broker;
      brokerToMarketId[broker] = id;
    } else {
      marketIdToBroker[id] = address(0);
      brokerToMarketId[broker] = bytes32(0);
    }
    emit MarketWhitelistChanged(id, broker, status);
  }

  function _checkBrokerMarketId(address broker, bytes32 id) internal view returns (bool) {
    IMoolah moolah = IMoolah(MOOLAH);
    return moolah.brokers(Id.wrap(id)) == broker;
  }

  /// @dev sets the pair whitelist.
  /// @param pair The address of the pair.
  /// @param status The status of the pair.
  function setPairWhitelist(address pair, bool status) external onlyRole(MANAGER) {
    require(pair != address(0), ZERO_ADDRESS);
    require(pairWhitelist[pair] != status, WhitelistSameStatus());
    pairWhitelist[pair] = status;
    emit PairWhitelistChanged(pair, status);
  }

  /// @dev sell tokens.
  /// @param pair The address of the pair.
  /// @param tokenIn The address of the input token.
  /// @param tokenOut The address of the output token.
  /// @param amountIn The amount to sell.
  /// @param amountOutMin The minimum amount to receive.
  /// @param swapData The swap data.
  function sellToken(
    address pair,
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 amountOutMin,
    bytes calldata swapData
  ) external onlyRole(BOT) {
    require(tokenWhitelist[tokenIn], NotWhitelisted());
    require(tokenWhitelist[tokenOut], NotWhitelisted());
    require(pairWhitelist[pair], NotWhitelisted());
    require(amountIn > 0, "amountIn zero");

    require(SafeTransferLib.balanceOf(tokenIn, address(this)) >= amountIn, ExceedAmount());

    uint256 beforeTokenIn = SafeTransferLib.balanceOf(tokenIn, address(this));
    uint256 beforeTokenOut = SafeTransferLib.balanceOf(tokenOut, address(this));

    SafeTransferLib.safeApprove(tokenIn, pair, amountIn);
    (bool success, ) = pair.call(swapData);
    require(success, SwapFailed());

    uint256 actualAmountIn = beforeTokenIn - SafeTransferLib.balanceOf(tokenIn, address(this));
    uint256 actualAmountOut = SafeTransferLib.balanceOf(tokenOut, address(this)) - beforeTokenOut;

    require(actualAmountIn <= amountIn, ExceedAmount());
    require(actualAmountOut >= amountOutMin, NoProfit());

    // reset allowance to zero
    SafeTransferLib.safeApprove(tokenIn, pair, 0);

    emit SellToken(pair, tokenIn, tokenOut, actualAmountIn, actualAmountOut);
  }

  /// @dev flash liquidates a position.
  /// @param id The id of the market.
  /// @param borrower The address of the borrower.
  /// @param seizedAssets The amount of assets to seize.
  /// @param pair The address of the pair.
  /// @param swapCollateralData The swap data to swap collateral to loan token.
  function flashLiquidate(
    bytes32 id,
    address borrower,
    uint256 seizedAssets,
    address pair,
    bytes calldata swapCollateralData
  ) external onlyRole(BOT) {
    address broker = marketIdToBroker[id];
    require(broker != address(0), NotWhitelisted());
    require(_checkBrokerMarketId(broker, id), BrokerMarketIdMismatch());
    require(pairWhitelist[pair], NotWhitelisted());
    MarketParams memory params = IMoolah(MOOLAH).idToMarketParams(Id.wrap(id));
    IBrokerBase(broker).liquidate(
      params,
      borrower,
      seizedAssets,
      0,
      abi.encode(
        MoolahLiquidateData(
          params.collateralToken,
          params.loanToken,
          seizedAssets,
          pair,
          swapCollateralData,
          true,
          // --- below fields are only used for smart collateral liquidation callback ---
          false,
          address(0),
          0,
          0,
          address(0),
          address(0),
          "",
          ""
        )
      )
    );
  }

  /// @dev liquidates a position.
  /// @param id The id of the market.
  /// @param borrower The address of the borrower.
  /// @param seizedAssets The amount of assets to seize.
  /// @param repaidShares The amount of shares to repay.
  function liquidate(bytes32 id, address borrower, uint256 seizedAssets, uint256 repaidShares) external onlyRole(BOT) {
    address broker = marketIdToBroker[id];
    require(broker != address(0), NotWhitelisted());
    require(_checkBrokerMarketId(broker, id), BrokerMarketIdMismatch());
    MarketParams memory params = IMoolah(MOOLAH).idToMarketParams(Id.wrap(id));
    IBrokerBase(broker).liquidate(
      params,
      borrower,
      seizedAssets,
      repaidShares,
      abi.encode(
        MoolahLiquidateData(
          params.collateralToken,
          params.loanToken,
          seizedAssets,
          address(0),
          "",
          false,
          // --- below fields are only used for smart collateral liquidation callback ---
          false,
          address(0),
          0,
          0,
          address(0),
          address(0),
          "",
          ""
        )
      )
    );
  }

  /// @dev the function will be called by the the Broker, when Broker's onMoolahLiquidate is called by Moolah.
  /// @param repaidAssets The amount of assets repaid.
  /// @param data The callback data.
  function onMoolahLiquidate(uint256 repaidAssets, bytes calldata data) external {
    bytes32 id = brokerToMarketId[msg.sender];
    require(marketIdToBroker[id] == msg.sender, OnlyBroker());
    MoolahLiquidateData memory arb = abi.decode(data, (MoolahLiquidateData));
    if (arb.swapCollateral) {
      require(!arb.swapSmartCollateral, "only swap collateral or smart collateral");
      uint256 before = SafeTransferLib.balanceOf(arb.loanToken, address(this));

      SafeTransferLib.safeApprove(arb.collateralToken, arb.collateralPair, arb.seized);
      (bool success, ) = arb.collateralPair.call(arb.swapCollateralData);
      require(success, SwapFailed());

      uint256 out = SafeTransferLib.balanceOf(arb.loanToken, address(this)) - before;

      if (out < repaidAssets) revert NoProfit();

      SafeTransferLib.safeApprove(arb.collateralToken, arb.collateralPair, 0);
    }

    SafeTransferLib.safeApprove(arb.loanToken, msg.sender, repaidAssets);
  }

  /// @dev redeems smart collateral LP tokens.
  /// @param smartProvider The address of the smart collateral provider.
  /// @param lpAmount The amount of LP collateral tokens to redeem.
  /// @param minToken0Amt The minimum amount of token0 to receive.
  /// @param minToken1Amt The minimum amount of token1 to receive.
  /// @return The amount of token0 and token1 redeemed.
  function redeemSmartCollateral(
    address smartProvider,
    uint256 lpAmount,
    uint256 minToken0Amt,
    uint256 minToken1Amt
  ) external onlyRole(BOT) returns (uint256, uint256) {
    require(smartProviders[smartProvider], NotWhitelisted());
    return ISmartProvider(smartProvider).redeemLpCollateral(lpAmount, minToken0Amt, minToken1Amt);
  }

  /// @dev sets the smart collateral providers.
  /// @param providers The array of smart collateral providers.
  /// @param status The status of the providers.
  function batchSetSmartProviders(address[] calldata providers, bool status) external onlyRole(MANAGER) {
    for (uint256 i = 0; i < providers.length; i++) {
      address provider = providers[i];
      smartProviders[provider] = status;
      emit SmartProvidersChanged(provider, status);
    }
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
