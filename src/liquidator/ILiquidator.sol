pragma solidity 0.8.28;
import "./Interface.sol";

interface ILiquidator {
  struct MoolahLiquidateData {
    address collateralToken;
    address loanToken;
    uint256 seized;
    address pair;
    bytes swapData;
    bool swap;
  }
  function withdrawETH(uint256 amount) external;
  function withdrawERC20(address token, uint256 amount) external;
  function flashLiquidate(
    bytes32 id,
    address borrower,
    uint256 seizedAssets,
    address pair,
    bytes calldata swapData
  ) external payable;

  function liquidate(bytes32 id, address borrower, uint256 seizedAssets, uint256 repaidShares) external payable;

  function sellToken(
    address pair,
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 amountOutMin,
    bytes calldata swapData
  ) external;

  function setTokenWhitelist(address token, bool status) external;

  function setMarketWhitelist(bytes32 id, bool status) external;

  function setPairWhitelist(address pair, bool status) external;
}
