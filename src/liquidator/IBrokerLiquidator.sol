pragma solidity 0.8.34;
// import "./Interface.sol";

interface IBrokerLiquidator {
  struct MoolahLiquidateData {
    address collateralToken;
    address loanToken;
    uint256 seized;
    address collateralPair;
    bytes swapCollateralData;
    bool swapCollateral;
    bool swapSmartCollateral; // Below fields are only used for smart collateral liquidation callback
    address smartProvider;
    uint256 minToken0Amt;
    uint256 minToken1Amt;
    address token0Pair;
    address token1Pair;
    bytes swapToken0Data;
    bytes swapToken1Data;
  }
  function withdrawERC20(address token, uint256 amount) external;
  function withdrawETH(uint256 amount) external;
  function flashLiquidate(
    bytes32 id,
    address borrower,
    uint256 seizedAssets,
    address pair,
    bytes calldata swapData
  ) external;

  function liquidate(bytes32 id, address borrower, uint256 seizedAssets, uint256 repaidShares) external;

  function liquidateSmartCollateral(
    bytes32 id,
    address borrower,
    address smartProvider,
    uint256 seizedAssets,
    uint256 repaidShares,
    bytes memory payload
  ) external returns (uint256, uint256);

  function flashLiquidateSmartCollateral(
    bytes32 id,
    address borrower,
    address smartProvider,
    uint256 seizedAssets,
    address token0Pair,
    address token1Pair,
    bytes calldata swapToken0Data,
    bytes calldata swapToken1Data,
    bytes memory payload
  ) external returns (uint256, uint256);

  function sellToken(
    address pair,
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 amountOutMin,
    bytes calldata swapData
  ) external;

  function sellBNB(
    address pair,
    address tokenOut,
    uint256 amountIn,
    uint256 amountOutMin,
    bytes calldata swapData
  ) external;

  function setTokenWhitelist(address token, bool status) external;

  function setMarketToBroker(bytes32 id, address broker, bool status) external;

  function batchSetMarketToBroker(bytes32[] calldata ids, address[] calldata brokers, bool status) external;

  function setPairWhitelist(address pair, bool status) external;

  function marketIdToBroker(bytes32 id) external view returns (address);

  function brokerToMarketId(address broker) external view returns (bytes32);

  function tokenWhitelist(address token) external view returns (bool);
}
