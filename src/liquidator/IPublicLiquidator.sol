pragma solidity 0.8.28;
import "./Interface.sol";

interface IPublicLiquidator {
  struct MoolahLiquidateData {
    address collateralToken;
    address loanToken;
    uint256 seized;
    address pair;
    bytes swapData;
    bool swap;
  }

  function flashLiquidate(
    bytes32 id,
    address borrower,
    uint256 seizedAssets,
    address pair,
    bytes calldata swapData
  ) external;

  function liquidate(bytes32 id, address borrower, uint256 seizedAssets, uint256 repaidShares) external payable;

  function setMarketWhitelist(bytes32 id, bool status) external;

  function setMarketUserWhitelist(bytes32 id, address user, bool status) external;
}
