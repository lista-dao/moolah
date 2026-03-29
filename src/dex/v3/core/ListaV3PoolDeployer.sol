// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { IListaV3PoolDeployer } from "./interfaces/IListaV3PoolDeployer.sol";

import { ListaV3Pool } from "./ListaV3Pool.sol";

contract ListaV3PoolDeployer is IListaV3PoolDeployer {
  struct Parameters {
    address factory;
    address token0;
    address token1;
    uint24 fee;
    int24 tickSpacing;
  }

  /// @inheritdoc IListaV3PoolDeployer
  Parameters public override parameters;

  /// @dev Deploys a pool with the given parameters by transiently setting the parameters storage slot and then
  /// clearing it after deploying the pool.
  function deploy(
    address factory,
    address token0,
    address token1,
    uint24 fee,
    int24 tickSpacing
  ) internal returns (address pool) {
    parameters = Parameters({ factory: factory, token0: token0, token1: token1, fee: fee, tickSpacing: tickSpacing });
    pool = address(new ListaV3Pool{ salt: keccak256(abi.encode(token0, token1, fee)) }());
    delete parameters;
  }
}
