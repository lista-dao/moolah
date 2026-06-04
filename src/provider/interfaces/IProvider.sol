// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";

interface IProvider {
  function liquidate(Id id, address borrower) external;

  function TOKEN() external view returns (address);
}
interface ISlisBnbProvider is IProvider {
  function supplyCollateral(
    MarketParams memory marketParams,
    uint256 assets,
    address onBehalf,
    bytes calldata data
  ) external;

  function withdrawCollateral(
    MarketParams memory marketParams,
    uint256 assets,
    address onBehalf,
    address receiver
  ) external;

  function userTotalDeposit(address account) external view returns (uint256);

  function slisBNBxMinter() external view returns (address);

  function STAKE_MANAGER() external view returns (address);
}
interface ISmartProvider is IProvider {
  function dexLP() external view returns (address);

  function token(uint256 id) external view returns (address);

  function redeemLpCollateral(
    uint256 lpAmount,
    uint256 minToken0Out,
    uint256 minToken1Out
  ) external returns (uint256 token0Out, uint256 token1Out);
}
