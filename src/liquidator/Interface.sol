// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IMoolah {
  struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
  }

  struct Market {
    uint128 totalSupplyAssets;
    uint128 totalSupplyShares;
    uint128 totalBorrowAssets;
    uint128 totalBorrowShares;
    uint128 lastUpdate;
    uint128 fee;
  }

  function idToMarketParams(bytes32 id) external view returns (MarketParams memory);

  function market(bytes32 id) external view returns (Market memory m);

  function liquidate(
    MarketParams memory marketParams,
    address borrower,
    uint256 seizedAssets,
    uint256 repaidShares,
    bytes memory data
  ) external returns (uint256, uint256);

  function isLiquidationWhitelist(bytes32 id, address account) external view returns (bool);

  function getPrice(MarketParams calldata marketParams) external view returns (uint256);
}
