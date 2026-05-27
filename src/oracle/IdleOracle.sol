// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IOracle, TokenConfig } from "../moolah/interfaces/IOracle.sol";

/// @title IdleOracle
/// @notice Oracle for Moolah idle markets: returns 0 for the idle collateral, delegates to the
///         resilient oracle for every other asset.
contract IdleOracle is IOracle {
  address public immutable IDLE_COLLATERAL;
  address public immutable RESILIENT_ORACLE;

  error ZeroAddress();

  constructor(address idleCollateral, address resilientOracle) {
    if (idleCollateral == address(0) || resilientOracle == address(0)) revert ZeroAddress();
    IDLE_COLLATERAL = idleCollateral;
    RESILIENT_ORACLE = resilientOracle;
  }

  function peek(address asset) external view returns (uint256) {
    if (asset == IDLE_COLLATERAL) return 0;
    // Intentional: loanToken must return a real, non-zero price so Moolah._getPrice does not
    // divide by zero. Misuse (assigning this oracle to a non-idle market) is OPERATOR-gated.
    return IOracle(RESILIENT_ORACLE).peek(asset);
  }

  function getTokenConfig(address asset) external view returns (TokenConfig memory) {
    if (asset == IDLE_COLLATERAL) {
      return
        TokenConfig({
          asset: asset,
          oracles: [address(this), address(0), address(0)],
          enableFlagsForOracles: [true, false, false],
          timeDeltaTolerance: 0
        });
    }
    return IOracle(RESILIENT_ORACLE).getTokenConfig(asset);
  }
}
