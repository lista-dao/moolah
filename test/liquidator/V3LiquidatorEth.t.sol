// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import { WstETHV3Provider } from "../../src/provider/v3/WstETHV3Provider.sol";
import { WstETHV3DexAdapter } from "../../src/provider/v3/WstETHV3DexAdapter.sol";
import { V3ProviderOracle } from "../../src/provider/v3/V3ProviderOracle.sol";
import { IWstETH } from "../../src/provider/interfaces/IWstETH.sol";
import { V3Liquidator } from "../../src/liquidator/V3Liquidator.sol";
import { Moolah } from "../../src/moolah/Moolah.sol";
import { IMoolah, MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { IOracle, TokenConfig } from "moolah/interfaces/IOracle.sol";

import { MockOneInch } from "./mocks/MockOneInch.sol";

/// @dev Minimal resilient-oracle mock: 8-decimal USD prices, settable per token.
contract MockOracle is IOracle {
  mapping(address => uint256) public price;

  function setPrice(address token, uint256 value) external {
    price[token] = value;
  }

  function peek(address token) external view returns (uint256) {
    return price[token];
  }

  function getTokenConfig(address) external pure returns (TokenConfig memory c) {
    return c;
  }
}

/// @dev A whitelisted "swap venue" that always reverts — used to exercise the SwapFailed() path.
contract RevertingPair {
  fallback() external payable {
    revert("nope");
  }
}

/// @notice Ethereum fork tests for V3Liquidator against a wstETH/WETH V3 LP market. The wrapped-native
///         leg on Ethereum is WETH (not BSC's WBNB); the provider unwraps it to native ETH on redeem, so
///         the liquidator must sell that leg via call{value}. This suite is the regression coverage for
///         H2: a chain-hardcoded WBNB check would route the WETH leg down the ERC-20 path and revert.
contract V3LiquidatorEthTest is Test {
  using MarketParamsLib for MarketParams;
  using SafeERC20 for IERC20;

  /* live Uniswap V3 wstETH/WETH 0.01% pool */
  address constant POOL = 0x109830a1AAaD605BbF02a9dFA7B0B92EC2FB7dAa;
  address constant NPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
  uint24 constant FEE = 100;

  address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0; // token0
  address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // token1 = wrapped-native
  address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // loan token (6 decimals)
  address constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE; // native sentinel (MockOneInch)

  address constant MOOLAH_PROXY = 0xf820fB4680712CD7263a0D3D024D5b5aEA82Fd70;
  address constant MOOLAH_ADMIN = 0xa18ae79AEDA3e711E0CD64cfe1Cd06402d400D61; // DEFAULT_ADMIN timelock
  address constant IRM = 0x8b7d334d243b74D63C4b963893267A0F5240F990;

  bytes32 constant OPERATOR = keccak256("OPERATOR");
  bytes32 constant MOOLAH_MANAGER = keccak256("MANAGER");

  uint32 constant TWAP_PERIOD = 1800;
  uint256 constant LLTV = 86 * 1e16;
  uint256 constant ETH_USD = 3000e8; // 8-dec mock ETH/USD

  Moolah moolah;
  WstETHV3DexAdapter adapter;
  WstETHV3Provider provider;
  V3ProviderOracle providerOracle;
  V3Liquidator liquidator;
  MockOneInch mockSwap;
  MockOracle oracle;
  MarketParams marketParams;
  Id marketId;

  address admin = makeAddr("admin");
  address manager = makeAddr("manager");
  address bot = makeAddr("bot");
  address user = makeAddr("user");

  function setUp() public {
    vm.createSelectFork(vm.envString("ETH_RPC"), 23566432);

    address newMoolahImpl = address(new Moolah());
    vm.prank(MOOLAH_ADMIN);
    UUPSUpgradeable(MOOLAH_PROXY).upgradeToAndCall(newMoolahImpl, bytes(""));
    moolah = Moolah(MOOLAH_PROXY);

    // Resilient-oracle mock: WETH = ETH; wstETH = ETH × stEthPerToken (rate-derived); USDC = $1.
    oracle = new MockOracle();
    uint256 rate = IWstETH(WSTETH).stEthPerToken();
    oracle.setPrice(WETH, ETH_USD);
    oracle.setPrice(WSTETH, (ETH_USD * rate) / 1e18);
    oracle.setPrice(USDC, 1e8);
    oracle.setPrice(BNB_ADDRESS, ETH_USD);

    // 1) DEX adapter.
    WstETHV3DexAdapter adapterImpl = new WstETHV3DexAdapter(NPM, WSTETH, WETH, FEE, TWAP_PERIOD);
    adapter = WstETHV3DexAdapter(
      payable(new ERC1967Proxy(address(adapterImpl), abi.encodeCall(WstETHV3DexAdapter.initialize, (admin, manager))))
    );

    // 2) Vault. accountingAsset = WETH.
    WstETHV3Provider provImpl = new WstETHV3Provider(MOOLAH_PROXY, address(adapter));
    provider = WstETHV3Provider(
      payable(
        new ERC1967Proxy(
          address(provImpl),
          abi.encodeCall(
            WstETHV3Provider.initialize,
            (admin, manager, bot, address(oracle), WETH, "wstETH/WETH vLP", "vLP-wstETH-WETH")
          )
        )
      )
    );

    vm.prank(admin);
    adapter.setProvider(address(provider));

    // 3) Share oracle (Moolah market.oracle).
    V3ProviderOracle oracleImpl = new V3ProviderOracle(address(adapter), address(provider), WSTETH, WETH);
    providerOracle = V3ProviderOracle(
      payable(
        new ERC1967Proxy(
          address(oracleImpl),
          abi.encodeCall(V3ProviderOracle.initialize, (admin, manager, address(oracle), uint256(0)))
        )
      )
    );

    // 4) V3Liquidator.
    V3Liquidator implL = new V3Liquidator(MOOLAH_PROXY);
    liquidator = V3Liquidator(
      payable(new ERC1967Proxy(address(implL), abi.encodeCall(V3Liquidator.initialize, (admin, manager, bot))))
    );

    mockSwap = new MockOneInch();

    // Grant ourselves OPERATOR (createMarket) + MANAGER (setProvider) on the forked Moolah.
    vm.startPrank(MOOLAH_ADMIN);
    IAccessControl(MOOLAH_PROXY).grantRole(OPERATOR, address(this));
    IAccessControl(MOOLAH_PROXY).grantRole(MOOLAH_MANAGER, address(this));
    vm.stopPrank();

    marketParams = MarketParams({
      loanToken: USDC,
      collateralToken: address(provider),
      oracle: address(providerOracle),
      irm: IRM,
      lltv: LLTV
    });
    marketId = marketParams.id();

    moolah.createMarket(marketParams);
    moolah.setProvider(marketId, address(provider), true);

    // Seed USDC liquidity so the borrow can draw from the market.
    deal(USDC, address(this), 10_000_000e6);
    IERC20(USDC).forceApprove(MOOLAH_PROXY, 10_000_000e6);
    moolah.supply(marketParams, 10_000_000e6, 0, address(this), "");

    // Liquidator whitelists.
    vm.startPrank(manager);
    liquidator.setTokenWhitelist(WSTETH, true);
    liquidator.setTokenWhitelist(WETH, true);
    liquidator.setTokenWhitelist(USDC, true);
    liquidator.setTokenWhitelist(BNB_ADDRESS, true);
    liquidator.setMarketWhitelist(Id.unwrap(marketId), true);
    liquidator.setPairWhitelist(address(mockSwap), true);
    liquidator.setV3ProviderWhitelist(address(provider), true);
    vm.stopPrank();
  }

  /* ──────────────────────── helpers ───────────────────────────────── */

  function _deposit(uint256 amtWst, uint256 amtWeth) internal returns (uint256 shares) {
    return _depositTo(marketParams, amtWst, amtWeth);
  }

  function _depositTo(MarketParams memory mp, uint256 amtWst, uint256 amtWeth) internal returns (uint256 shares) {
    deal(WSTETH, user, amtWst);
    deal(WETH, user, amtWeth);
    (, uint256 e0, uint256 e1) = provider.previewDepositAmounts(amtWst, amtWeth);
    vm.startPrank(user);
    IERC20(WSTETH).approve(address(provider), amtWst);
    IERC20(WETH).approve(address(provider), amtWeth);
    (shares, , ) = provider.deposit(mp, amtWst, amtWeth, (e0 * 99) / 100, (e1 * 99) / 100, user);
    vm.stopPrank();
  }

  function _collateral(address _user) internal view returns (uint256) {
    return _collateralIn(marketId, _user);
  }

  function _collateralIn(Id id, address _user) internal view returns (uint256) {
    (, , uint256 col) = moolah.position(id, _user);
    return col;
  }

  /// @dev Borrow 60% of the user's collateral value in USDC (6-dec loan token). The BSC liquidator test
  ///      sizes an 18-dec loan the same way; the extra /1e12 rescales to USDC's 6 decimals.
  function _borrowAgainstCollateral(address _user) internal returns (uint256 borrowed) {
    (, , uint128 col) = moolah.position(marketId, _user);
    uint256 sharePrice = providerOracle.peek(address(provider)); // 8-dec USD / 1e18 shares
    uint256 loanPrice = providerOracle.peek(USDC); // 1e8
    borrowed = (uint256(col) * sharePrice * 60) / (loanPrice * 100 * 1e12);
    vm.prank(_user);
    moolah.borrow(marketParams, borrowed, 0, _user, _user);
  }

  /// @dev Drop the collateral oracle to zero, making any indebted position liquidatable.
  function _makeUnhealthy() internal {
    vm.mockCall(
      address(providerOracle),
      abi.encodeWithSelector(IOracle.peek.selector, address(provider)),
      abi.encode(uint256(0))
    );
  }

  /* ──────────────────────── tests ─────────────────────────────────── */

  /// @notice On Ethereum the WETH leg is unwrapped to native ETH on redeem (token1 == WRAPPED_NATIVE),
  ///         so redeemV3Shares pays it as native ETH — the wstETH leg arrives as an ERC-20.
  function test_redeemV3Shares_wethLegPaidAsNativeEth() public {
    uint256 shares = _deposit(10 ether, 10 ether);
    _borrowAgainstCollateral(user);
    _makeUnhealthy();

    // Seize the shares into the liquidator via a pre-funded liquidation.
    deal(USDC, address(liquidator), 1_000_000e6);
    vm.prank(bot);
    liquidator.liquidate(Id.unwrap(marketId), user, shares, 0);

    uint256 held = provider.balanceOf(address(liquidator));
    assertGt(held, 0, "setup: liquidator holds seized shares");

    (uint256 exp0, uint256 exp1) = provider.previewRedeemUnderlying(held);
    uint256 wstBefore = IERC20(WSTETH).balanceOf(address(liquidator));
    uint256 ethBefore = address(liquidator).balance;

    vm.prank(bot);
    (uint256 out0, uint256 out1) = liquidator.redeemV3Shares(
      address(provider),
      held,
      (exp0 * 99) / 100,
      (exp1 * 99) / 100,
      address(liquidator)
    );

    assertEq(provider.balanceOf(address(liquidator)), 0, "shares burned");
    assertEq(IERC20(WSTETH).balanceOf(address(liquidator)) - wstBefore, out0, "wstETH leg paid as ERC-20");
    assertEq(address(liquidator).balance - ethBefore, out1, "WETH leg paid as native ETH");
    assertGt(out1, 0, "native ETH leg non-zero");
  }

  /// @notice H2 regression: flashLiquidate redeems shares and sells the WETH leg. Because the provider
  ///         hands that leg over as native ETH, the liquidator must sell it via call{value}. The mock
  ///         venue REQUIRES msg.value (native `amountIn` > 0), so the buggy ERC-20 path (which would
  ///         approve WETH and call with no value) reverts, while the WRAPPED_NATIVE()-driven path passes.
  function test_flashLiquidate_sellsNativeWethLeg() public {
    uint256 shares = _deposit(10 ether, 10 ether);
    uint256 borrowed = _borrowAgainstCollateral(user);
    _makeUnhealthy();

    // Expected native WETH-leg amount; require the venue to be paid this as msg.value.
    (, uint256 exp1) = provider.previewRedeemUnderlying(shares);
    uint256 nativeAmountIn = (exp1 * 99) / 100;

    // WETH leg (native): MockOneInch requires msg.value >= nativeAmountIn, then mints borrowed*2 USDC.
    bytes memory swap1Data = abi.encodeWithSelector(
      mockSwap.swap.selector,
      BNB_ADDRESS, // native-coin path
      USDC,
      nativeAmountIn,
      borrowed * 2 // produce enough USDC to cover repayment
    );

    // token0 (wstETH) leg: no swap — left in the liquidator as residue.
    V3Liquidator.FlashLiquidateParams memory params = V3Liquidator.FlashLiquidateParams({
      v3Provider: address(provider),
      minToken0Amt: 0,
      minToken1Amt: 0,
      redeemShares: true,
      token0Pair: address(0),
      token0Spender: address(0),
      token1Pair: address(mockSwap),
      token1Spender: address(0),
      swapToken0Data: "",
      swapToken1Data: swap1Data
    });

    vm.prank(bot);
    liquidator.flashLiquidate(Id.unwrap(marketId), user, shares, params);

    assertEq(_collateral(user), 0, "borrower collateral seized");
    assertEq(provider.balanceOf(address(liquidator)), 0, "shares redeemed in callback");
    assertGt(IERC20(USDC).balanceOf(address(liquidator)), 0, "USDC produced by native WETH-leg swap");
    assertGt(IERC20(WSTETH).balanceOf(address(liquidator)), 0, "wstETH residue retained (leg not swapped)");
  }

  /// @notice When the loan token IS the wrapped-native (a market that borrows WETH against the LP), the
  ///         redeemed WETH leg comes back as native ETH and its swap is skipped (loanToken→loanToken).
  ///         The liquidator must wrap that native ETH back to WETH so the ERC-20 repayment works — else
  ///         the WETH-leg value is stranded as native and the loanToken balance check / Moolah pull fail.
  function test_flashLiquidate_loanTokenIsWrappedNative_wrapsNativeLeg() public {
    // A WETH-loan market against the same wstETH/WETH LP collateral.
    MarketParams memory wethMarket = MarketParams({
      loanToken: WETH,
      collateralToken: address(provider),
      oracle: address(providerOracle),
      irm: IRM,
      lltv: LLTV
    });
    Id wethId = wethMarket.id();
    moolah.createMarket(wethMarket);
    moolah.setProvider(wethId, address(provider), true);

    deal(WETH, address(this), 1_000 ether);
    IERC20(WETH).approve(MOOLAH_PROXY, 1_000 ether);
    moolah.supply(wethMarket, 1_000 ether, 0, address(this), "");

    vm.prank(manager);
    liquidator.setMarketWhitelist(Id.unwrap(wethId), true);

    uint256 shares = _depositTo(wethMarket, 10 ether, 10 ether);
    {
      (, , uint128 col) = moolah.position(wethId, user);
      uint256 sharePrice = providerOracle.peek(address(provider));
      uint256 loanPrice = providerOracle.peek(WETH); // 8-dec USD; WETH is 18-dec
      uint256 borrowed = (uint256(col) * sharePrice * 60) / (loanPrice * 100);
      vm.prank(user);
      moolah.borrow(wethMarket, borrowed, 0, user, user);
    }
    _makeUnhealthy();

    (, uint256 exp1) = provider.previewRedeemUnderlying(shares);

    // No swaps: token0 (wstETH) is held as residue; token1 (WETH) returns native and must be wrapped.
    V3Liquidator.FlashLiquidateParams memory params = V3Liquidator.FlashLiquidateParams({
      v3Provider: address(provider),
      minToken0Amt: 0,
      minToken1Amt: 0,
      redeemShares: true,
      token0Pair: address(0),
      token0Spender: address(0),
      token1Pair: address(0),
      token1Spender: address(0),
      swapToken0Data: "",
      swapToken1Data: ""
    });

    uint256 wethBefore = IERC20(WETH).balanceOf(address(liquidator));
    vm.prank(bot);
    liquidator.flashLiquidate(Id.unwrap(wethId), user, shares, params);

    assertEq(_collateralIn(wethId, user), 0, "collateral seized");
    assertEq(provider.balanceOf(address(liquidator)), 0, "shares redeemed");
    assertEq(address(liquidator).balance, 0, "native WETH leg fully wrapped, not stranded");
    assertGe(
      IERC20(WETH).balanceOf(address(liquidator)) - wethBefore,
      (exp1 * 99) / 100,
      "WETH leg wrapped back to ERC-20 for repayment"
    );
  }

  /// @notice The native-leg swap path propagates venue failure as SwapFailed() (no silent success).
  function test_flashLiquidate_nativeSwapReverts_revertsSwapFailed() public {
    uint256 shares = _deposit(10 ether, 10 ether);
    _borrowAgainstCollateral(user);
    _makeUnhealthy();

    RevertingPair badPair = new RevertingPair();
    vm.prank(manager);
    liquidator.setPairWhitelist(address(badPair), true);

    // token1 (WETH, native) routed to a venue that reverts → SwapFailed must bubble up.
    bytes memory swap1Data = abi.encodeWithSignature("doSwap()");
    V3Liquidator.FlashLiquidateParams memory params = V3Liquidator.FlashLiquidateParams({
      v3Provider: address(provider),
      minToken0Amt: 0,
      minToken1Amt: 0,
      redeemShares: true,
      token0Pair: address(0),
      token0Spender: address(0),
      token1Pair: address(badPair),
      token1Spender: address(0),
      swapToken0Data: "",
      swapToken1Data: swap1Data
    });

    vm.prank(bot);
    vm.expectRevert(V3Liquidator.SwapFailed.selector);
    liquidator.flashLiquidate(Id.unwrap(marketId), user, shares, params);
  }
}
