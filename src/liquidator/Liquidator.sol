// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import "./ILiquidator.sol";

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

contract Liquidator is UUPSUpgradeable, AccessControlUpgradeable, ILiquidator {
  /// @dev Thrown when passing the zero address.
  string internal constant ZERO_ADDRESS = "zero address";
  error NoProfit();
  error OnlyMoolah();
  error ExceedAmount();
  error WhitelistSameStatus();
  error NotWhitelisted();
  error SwapFailed();

  address public immutable MOOLAH;
  mapping(address => bool) public tokenWhitelist;

  bytes32 public constant MANAGER = keccak256("MANAGER"); // manager role
  bytes32 public constant BOT = keccak256("BOT"); // manager role

  event TokenWhitelistChanged(address indexed token, bool added);
  event SellToken(address pair, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin);

  /// @custom:oz-upgrades-unsafe-allow constructor
  /// @param moolah The address of the Moolah contract.
  constructor(address moolah) payable {
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

  receive() external payable {}

  /// @dev withdraws ERC20 tokens.
  /// @param token The address of the token.
  /// @param amount The amount to withdraw.
  function withdrawERC20(address token, uint256 amount) external onlyRole(MANAGER) {
    SafeTransferLib.safeTransfer(token, msg.sender, amount);
  }
  /// @dev withdraws ETH.
  /// @param amount The amount to withdraw.
  function withdrawETH(uint256 amount) external onlyRole(MANAGER) {
    SafeTransferLib.safeTransferETH(msg.sender, amount);
  }

  /// @dev sets the token whitelist.
  /// @param token The address of the token.
  /// @param status The status of the token.
  function setTokenWhitelist(address token, bool status) external onlyRole(MANAGER) {
    require(tokenWhitelist[token] != status, WhitelistSameStatus());
    tokenWhitelist[token] = status;
    emit TokenWhitelistChanged(token, status);
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

    emit SellToken(pair, tokenIn, tokenOut, actualAmountIn, actualAmountOut);
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
  ) external payable onlyRole(BOT) {
    IMoolah.MarketParams memory params = IMoolah(MOOLAH).idToMarketParams(id);
    IMoolah(MOOLAH).liquidate(
      params,
      borrower,
      seizedAssets,
      0,
      abi.encode(MoolahLiquidateData(params.collateralToken, params.loanToken, seizedAssets, pair, swapData, true))
    );
  }

  /// @dev liquidates a position.
  /// @param id The id of the market.
  /// @param borrower The address of the borrower.
  /// @param seizedAssets The amount of assets to seize.
  /// @param pair The address of the pair.
  function liquidate(bytes32 id, address borrower, uint256 seizedAssets, address pair) external payable onlyRole(BOT) {
    IMoolah.MarketParams memory params = IMoolah(MOOLAH).idToMarketParams(id);
    IMoolah(MOOLAH).liquidate(
      params,
      borrower,
      seizedAssets,
      0,
      abi.encode(MoolahLiquidateData(params.collateralToken, params.loanToken, seizedAssets, pair, "", false))
    );
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
    }

    SafeTransferLib.safeApprove(arb.loanToken, MOOLAH, repaidAssets);
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
