// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { V3ProviderOracle } from "./V3ProviderOracle.sol";

/**
 * @title SlisBNBV3ProviderOracle
 * @author Lista DAO
 * @notice slisBNB/BNB specialization of {V3ProviderOracle}: identical pricing logic, with a
 *         constructor guard pinning the pair to slisBNB/WBNB. Retained as a distinct type so the
 *         audited slisBNB deployment and its tests stay byte-stable; can be collapsed into the
 *         generic V3ProviderOracle once the slisBNB audit PR has merged.
 */
contract SlisBNBV3ProviderOracle is V3ProviderOracle {
  /// @dev slisBNB/BNB-only pair (token0 < token1; slisBNB < WBNB).
  address public constant SLISBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
  address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

  error NotSlisBnbWbnbPair();

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(
    address _adapter,
    address _providerShare,
    address _token0,
    address _token1
  ) V3ProviderOracle(_adapter, _providerShare, _token0, _token1) {
    // slisBNB/BNB-ONLY: reject any other pair. The base already verifies the pair matches the adapter.
    if (!(_token0 == SLISBNB && _token1 == WBNB)) revert NotSlisBnbWbnbPair();
  }
}
