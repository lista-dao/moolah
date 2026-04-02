// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import { IListaV3Factory } from "./interfaces/IListaV3Factory.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import { ListaV3PoolDeployer } from "./ListaV3PoolDeployer.sol";

import { ListaV3Pool } from "./ListaV3Pool.sol";

/// @title Canonical Lista V3 factory (UUPS upgradeable)
/// @notice Deploys Lista V3 pools and manages ownership and control over pool protocol fees
contract ListaV3Factory is IListaV3Factory, ListaV3PoolDeployer, Initializable, UUPSUpgradeable {
  /// @inheritdoc IListaV3Factory
  address public override owner;

  /// @inheritdoc IListaV3Factory
  mapping(uint24 => int24) public override feeAmountTickSpacing;
  /// @inheritdoc IListaV3Factory
  mapping(address => mapping(address => mapping(uint24 => address))) public override getPool;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize(address _owner) external initializer {
    require(_owner != address(0), "zero address");
    owner = _owner;
    emit OwnerChanged(address(0), _owner);

    feeAmountTickSpacing[500] = 10;
    emit FeeAmountEnabled(500, 10);
    feeAmountTickSpacing[3000] = 60;
    emit FeeAmountEnabled(3000, 60);
    feeAmountTickSpacing[10000] = 200;
    emit FeeAmountEnabled(10000, 200);
  }

  /// @inheritdoc IListaV3Factory
  function createPool(address tokenA, address tokenB, uint24 fee) external override returns (address pool) {
    require(tokenA != tokenB);
    (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    require(token0 != address(0));
    int24 tickSpacing = feeAmountTickSpacing[fee];
    require(tickSpacing != 0);
    require(getPool[token0][token1][fee] == address(0));
    pool = deploy(address(this), token0, token1, fee, tickSpacing);
    getPool[token0][token1][fee] = pool;
    getPool[token1][token0][fee] = pool;
    emit PoolCreated(token0, token1, fee, tickSpacing, pool);
  }

  /// @inheritdoc IListaV3Factory
  function setOwner(address _owner) external override {
    require(msg.sender == owner);
    emit OwnerChanged(owner, _owner);
    owner = _owner;
  }

  /// @inheritdoc IListaV3Factory
  function enableFeeAmount(uint24 fee, int24 tickSpacing) public override {
    require(msg.sender == owner);
    require(fee < 1000000);
    require(tickSpacing > 0 && tickSpacing < 16384);
    require(feeAmountTickSpacing[fee] == 0);

    feeAmountTickSpacing[fee] = tickSpacing;
    emit FeeAmountEnabled(fee, tickSpacing);
  }

  /// @notice Returns the init code hash for pool deployment.
  ///         Used by periphery contracts (PoolAddress.computeAddress) to deterministically
  ///         derive pool addresses from (factory, token0, token1, fee).
  function poolInitCodeHash() external pure returns (bytes32) {
    return keccak256(type(ListaV3Pool).creationCode);
  }

  function _authorizeUpgrade(address) internal override {
    require(msg.sender == owner);
  }
}
