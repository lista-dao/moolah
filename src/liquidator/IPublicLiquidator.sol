pragma solidity 0.8.28;
import "./Interface.sol";

interface IPublicLiquidator {
  struct MoolahLiquidateData {
    address collateralToken;
    address loanToken;
    uint256 seized;
    address collateralPair;
    bytes swapCollateralData;
    bool swapCollateral;
    bool swapSmartCollateral; // Below fields are only used for smart collateral liquidation callback
    address smartProvider;
    uint256 minToken0Amt; // should be used to obtain token0 swap data from 1inch API
    uint256 minToken1Amt; // should be used to obtain token1 swap data from 1inch API
    address token0Pair;
    address token1Pair;
    bytes swapToken0Data;
    bytes swapToken1Data;
  }

  function pairWhitelist(address pair) external view returns (bool);

  function flashLiquidate(
    bytes32 id,
    address borrower,
    uint256 seizedAssets,
    address pair,
    bytes calldata swapData
  ) external;

  function liquidate(bytes32 id, address borrower, uint256 seizedAssets, uint256 repaidShares) external;

  function setMarketWhitelist(bytes32 id, bool status) external;

  function setMarketUserWhitelist(bytes32 id, address user, bool status) external;

  function setPairWhitelist(address pair, bool status) external;
}
