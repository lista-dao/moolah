// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";
import { FullMath } from "lista-dao-contracts/oracle/libraries/FullMath.sol";
import { V3DexAdapter } from "../../src/provider/v3/V3DexAdapter.sol";

/// @dev Test-only concrete adapter exposing the internal rate→sqrtPrice math. The wrapped-native is the
///      18-dec token1; the paired token0 may have any decimals — this verifies the conversion accounts
///      for the decimal difference (not just 18/18 pairs).
contract DecimalProbeAdapter is V3DexAdapter {
  constructor(address npm, address t0, address t1, uint24 fee, uint32 twap) V3DexAdapter(npm, t0, t1, fee, twap, t1) {}

  function sqrtPriceFromRate(uint256 rate) external view returns (uint160) {
    return _sqrtPriceX96FromRate(rate);
  }
}

/// @notice Unit tests for V3DexAdapter._sqrtPriceX96FromRate's decimal handling, against real Uniswap V3
///         pools so the constructor's pool/decimals reads are genuine. Proves a non-18-decimal paired
///         token (USDC, 6-dec) is priced correctly, and that an 18/18 pair is unchanged.
contract V3DexAdapterDecimalsTest is Test {
  address constant NPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
  address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // 18-dec (token1 / wrapped-native)
  address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // 6-dec  (token0)
  address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0; // 18-dec (token0)

  function setUp() public {
    vm.createSelectFork(vm.envString("ETH_RPC"), 23566432);
  }

  /// @dev Implied RAW price token1/token0 scaled by 1e18 = (sqrtP/2^96)^2 · 1e18 (two-step to avoid overflow).
  function _impliedPriceX18(uint160 sqrtP) internal pure returns (uint256) {
    uint256 priceX96 = FullMath.mulDiv(uint256(sqrtP), uint256(sqrtP), 1 << 96); // rawPrice · 2^96
    return FullMath.mulDiv(priceX96, 1e18, 1 << 96); // rawPrice · 1e18
  }

  /// @notice USDC(6)/WETH(18): the raw price must be scaled by 10^(18-6) vs the human rate.
  function test_sqrtPriceFromRate_nonEqualDecimals() public {
    DecimalProbeAdapter a = new DecimalProbeAdapter(NPM, USDC, WETH, 500, 1800);
    assertEq(a.DECIMALS0(), 6, "USDC 6 dec");
    assertEq(a.DECIMALS1(), 18, "WETH 18 dec");

    uint256 rate = 1e18; // 1 whole USDC priced at 1 whole WETH (arbitrary; just exercising the math)
    // RAW price token1/token0 = (rate/1e18)·10^(18-6) ⇒ priceX18 = rate·10^12.
    assertApproxEqRel(_impliedPriceX18(a.sqrtPriceFromRate(rate)), rate * (10 ** 12), 1e12, "scaled by 10^12");

    // Linear in the rate.
    assertApproxEqRel(_impliedPriceX18(a.sqrtPriceFromRate(3e18)), 3e18 * (10 ** 12), 1e12, "tracks rate");
  }

  /// @notice wstETH(18)/WETH(18): equal decimals ⇒ factor 10^0 = 1 ⇒ raw price == rate/1e18 (no change).
  function test_sqrtPriceFromRate_equalDecimals_unchanged() public {
    DecimalProbeAdapter a = new DecimalProbeAdapter(NPM, WSTETH, WETH, 100, 1800);
    assertEq(a.DECIMALS0(), 18);
    assertEq(a.DECIMALS1(), 18);

    uint256 rate = 12e17; // 1.2
    assertApproxEqRel(_impliedPriceX18(a.sqrtPriceFromRate(rate)), rate, 1e12, "18/18: priceX18 == rate");
  }
}
