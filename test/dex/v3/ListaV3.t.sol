// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { ListaV3Factory } from "../../../src/dex/v3/core/ListaV3Factory.sol";
import { ListaV3Pool } from "../../../src/dex/v3/core/ListaV3Pool.sol";
import { IListaV3Pool } from "../../../src/dex/v3/core/interfaces/IListaV3Pool.sol";
import { IListaV3MintCallback } from "../../../src/dex/v3/core/interfaces/callback/IListaV3MintCallback.sol";
import { IListaV3SwapCallback } from "../../../src/dex/v3/core/interfaces/callback/IListaV3SwapCallback.sol";
import { TickMath } from "../../../src/dex/v3/core/libraries/TickMath.sol";
import { LiquidityAmounts } from "../../../src/dex/v3/periphery/libraries/LiquidityAmounts.sol";
import { NonfungiblePositionManager } from "../../../src/dex/v3/periphery/NonfungiblePositionManager.sol";
import { INonfungiblePositionManager } from "../../../src/dex/v3/periphery/interfaces/INonfungiblePositionManager.sol";
import { PoolAddress } from "../../../src/dex/v3/periphery/libraries/PoolAddress.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/* ─────────────────────── Mock ERC20 ─────────────────────── */

contract MockERC20 is ERC20 {
  uint8 private _dec;

  constructor(string memory name, string memory symbol, uint8 dec_) ERC20(name, symbol) {
    _dec = dec_;
  }

  function decimals() public view override returns (uint8) {
    return _dec;
  }

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }
}

/* ───────────── Mock WETH9 (needed by NPM constructor) ───────────── */

contract MockWETH9 is MockERC20 {
  constructor() MockERC20("Wrapped BNB", "WBNB", 18) {}

  function deposit() external payable {
    _mint(msg.sender, msg.value);
  }

  function withdraw(uint256 amount) external {
    _burn(msg.sender, amount);
    (bool ok, ) = msg.sender.call{ value: amount }("");
    require(ok);
  }

  receive() external payable {
    _mint(msg.sender, msg.value);
  }
}

/* ──────────── Mock token descriptor (returns empty URI) ──────────── */

contract MockTokenDescriptor {
  function tokenURI(address, uint256) external pure returns (string memory) {
    return "";
  }
}

/* ═══════════════════════════════════════════════════════════════════
   Test Suite
   ═══════════════════════════════════════════════════════════════════ */

contract ListaV3Test is Test, IListaV3MintCallback, IListaV3SwapCallback {
  ListaV3Factory factory;
  NonfungiblePositionManager npm;
  MockWETH9 weth;
  MockERC20 tokenA;
  MockERC20 tokenB;
  address token0;
  address token1;

  uint24 constant FEE = 3000;
  int24 constant TICK_SPACING = 60;

  // TickMath constants
  uint160 constant MIN_SQRT_RATIO = 4295128739;
  uint160 constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

  function setUp() public {
    // Deploy Factory behind UUPS proxy
    ListaV3Factory factoryImpl = new ListaV3Factory();
    factory = ListaV3Factory(
      address(new ERC1967Proxy(address(factoryImpl), abi.encodeCall(ListaV3Factory.initialize, (address(this)))))
    );

    weth = new MockWETH9();
    MockTokenDescriptor descriptor = new MockTokenDescriptor();

    // Deploy NPM behind UUPS proxy
    NonfungiblePositionManager npmImpl = new NonfungiblePositionManager();
    npm = NonfungiblePositionManager(
      payable(
        new ERC1967Proxy(
          address(npmImpl),
          abi.encodeCall(
            NonfungiblePositionManager.initialize,
            (address(factory), address(weth), address(descriptor), address(this), factory.poolInitCodeHash())
          )
        )
      )
    );

    // Deploy tokens and sort
    tokenA = new MockERC20("Token A", "TKA", 18);
    tokenB = new MockERC20("Token B", "TKB", 18);
    (token0, token1) = address(tokenA) < address(tokenB)
      ? (address(tokenA), address(tokenB))
      : (address(tokenB), address(tokenA));
  }

  /* ─────────────────────── helpers ─────────────────────── */

  function _createAndInitPool(uint160 sqrtPriceX96) internal returns (IListaV3Pool pool) {
    address poolAddr = factory.createPool(token0, token1, FEE);
    pool = IListaV3Pool(poolAddr);
    pool.initialize(sqrtPriceX96);
  }

  function _mintTokens(address to, uint256 amount0, uint256 amount1) internal {
    MockERC20(token0).mint(to, amount0);
    MockERC20(token1).mint(to, amount1);
  }

  /* ─────────────── V3 pool callbacks (for direct pool interaction) ─────────────── */

  function listaV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata) external override {
    if (amount0Owed > 0) IERC20(token0).transfer(msg.sender, amount0Owed);
    if (amount1Owed > 0) IERC20(token1).transfer(msg.sender, amount1Owed);
  }

  function listaV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external override {
    if (amount0Delta > 0) IERC20(token0).transfer(msg.sender, uint256(amount0Delta));
    if (amount1Delta > 0) IERC20(token1).transfer(msg.sender, uint256(amount1Delta));
  }

  /* ═══════════════════════════════════════════════════════════
     Factory Tests
     ═══════════════════════════════════════════════════════════ */

  function test_factory_defaultFeeTiers() public view {
    assertEq(factory.feeAmountTickSpacing(500), 10);
    assertEq(factory.feeAmountTickSpacing(3000), 60);
    assertEq(factory.feeAmountTickSpacing(10000), 200);
    assertEq(factory.feeAmountTickSpacing(100), 0, "unsupported fee should return 0");
  }

  function test_factory_owner() public view {
    assertEq(factory.owner(), address(this));
  }

  function test_factory_createPool() public {
    address pool = factory.createPool(token0, token1, FEE);
    assertTrue(pool != address(0), "pool should be created");
    assertEq(factory.getPool(token0, token1, FEE), pool);
    assertEq(factory.getPool(token1, token0, FEE), pool, "reverse lookup should work");
  }

  function test_factory_createPool_revertsOnDuplicate() public {
    factory.createPool(token0, token1, FEE);
    vm.expectRevert();
    factory.createPool(token0, token1, FEE);
  }

  function test_factory_createPool_revertsOnSameToken() public {
    vm.expectRevert();
    factory.createPool(token0, token0, FEE);
  }

  function test_factory_createPool_revertsOnUnsupportedFee() public {
    vm.expectRevert();
    factory.createPool(token0, token1, 100); // 100 not enabled
  }

  function test_factory_enableFeeAmount() public {
    factory.enableFeeAmount(100, 1);
    assertEq(factory.feeAmountTickSpacing(100), 1);

    // Can now create a pool with the new fee
    address pool = factory.createPool(token0, token1, 100);
    assertTrue(pool != address(0));
  }

  function test_factory_setOwner() public {
    address newOwner = makeAddr("newOwner");
    factory.setOwner(newOwner);
    assertEq(factory.owner(), newOwner);
  }

  function test_factory_setOwner_revertsIfNotOwner() public {
    vm.prank(makeAddr("rando"));
    vm.expectRevert();
    factory.setOwner(makeAddr("newOwner"));
  }

  /* ═══════════════════════════════════════════════════════════
     Pool Tests
     ═══════════════════════════════════════════════════════════ */

  function test_pool_initialize() public {
    uint160 sqrtPriceX96 = 79228162514264337593543950336; // sqrt(1) * 2^96 ≈ price = 1.0
    IListaV3Pool pool = _createAndInitPool(sqrtPriceX96);

    (uint160 sqrtPrice, int24 tick, , , , , ) = pool.slot0();
    assertEq(sqrtPrice, sqrtPriceX96);
    assertEq(tick, 0, "tick should be 0 at price 1.0");
    assertEq(pool.token0(), token0);
    assertEq(pool.token1(), token1);
    assertEq(pool.fee(), FEE);
    assertEq(pool.tickSpacing(), TICK_SPACING);
  }

  function test_pool_initialize_revertsOnDouble() public {
    uint160 sqrtPriceX96 = 79228162514264337593543950336;
    IListaV3Pool pool = _createAndInitPool(sqrtPriceX96);
    vm.expectRevert();
    pool.initialize(sqrtPriceX96);
  }

  function test_pool_mint() public {
    uint160 sqrtPriceX96 = 79228162514264337593543950336; // price = 1.0
    IListaV3Pool pool = _createAndInitPool(sqrtPriceX96);

    // Mint liquidity around tick 0 (price 1.0)
    int24 tickLower = -TICK_SPACING;
    int24 tickUpper = TICK_SPACING;
    uint128 liquidityAmount = 1_000_000;

    _mintTokens(address(this), 10 ether, 10 ether);

    (uint256 amount0, uint256 amount1) = pool.mint(address(this), tickLower, tickUpper, liquidityAmount, "");
    assertGt(amount0, 0, "should consume token0");
    assertGt(amount1, 0, "should consume token1");

    // Verify position
    bytes32 posKey = keccak256(abi.encodePacked(address(this), tickLower, tickUpper));
    (uint128 liq, , , , ) = pool.positions(posKey);
    assertEq(liq, liquidityAmount, "position liquidity should match");
  }

  function test_pool_swap() public {
    uint160 sqrtPriceX96 = 79228162514264337593543950336;
    IListaV3Pool pool = _createAndInitPool(sqrtPriceX96);

    // Add wide-range liquidity
    int24 tickLower = -600;
    int24 tickUpper = 600;
    uint128 liquidityAmount = 100_000_000_000;
    _mintTokens(address(this), 100 ether, 100 ether);
    pool.mint(address(this), tickLower, tickUpper, liquidityAmount, "");

    // Swap token0 → token1 (zeroForOne = true, pushes price down)
    uint256 swapAmount = 0.1 ether;
    _mintTokens(address(this), swapAmount, 0);
    uint256 bal1Before = IERC20(token1).balanceOf(address(this));

    pool.swap(address(this), true, int256(swapAmount), MIN_SQRT_RATIO + 1, "");

    uint256 bal1After = IERC20(token1).balanceOf(address(this));
    assertGt(bal1After, bal1Before, "should receive token1 from swap");

    // Price should have moved down
    (uint160 newSqrtPrice, , , , , , ) = pool.slot0();
    assertLt(newSqrtPrice, sqrtPriceX96, "price should decrease after zeroForOne swap");
  }

  function test_pool_burn_and_collect() public {
    uint160 sqrtPriceX96 = 79228162514264337593543950336;
    IListaV3Pool pool = _createAndInitPool(sqrtPriceX96);

    int24 tickLower = -TICK_SPACING;
    int24 tickUpper = TICK_SPACING;
    uint128 liquidityAmount = 1_000_000;
    _mintTokens(address(this), 10 ether, 10 ether);
    pool.mint(address(this), tickLower, tickUpper, liquidityAmount, "");

    // Burn all liquidity
    (uint256 amount0, uint256 amount1) = pool.burn(tickLower, tickUpper, liquidityAmount);
    assertGt(amount0 + amount1, 0, "should return tokens on burn");

    // Collect
    uint256 bal0Before = IERC20(token0).balanceOf(address(this));
    uint256 bal1Before = IERC20(token1).balanceOf(address(this));
    pool.collect(address(this), tickLower, tickUpper, type(uint128).max, type(uint128).max);
    uint256 collected0 = IERC20(token0).balanceOf(address(this)) - bal0Before;
    uint256 collected1 = IERC20(token1).balanceOf(address(this)) - bal1Before;

    assertEq(collected0, amount0, "collected0 should match burned amount0");
    assertEq(collected1, amount1, "collected1 should match burned amount1");
  }

  function test_pool_observe() public {
    uint160 sqrtPriceX96 = 79228162514264337593543950336;
    IListaV3Pool pool = _createAndInitPool(sqrtPriceX96);

    // Need to increase cardinality for TWAP
    pool.increaseObservationCardinalityNext(10);

    // Add liquidity so the pool is active
    _mintTokens(address(this), 10 ether, 10 ether);
    pool.mint(address(this), -TICK_SPACING, TICK_SPACING, 1_000_000, "");

    // Observation at time 0 should work
    uint32[] memory secondsAgos = new uint32[](2);
    secondsAgos[0] = 0;
    secondsAgos[1] = 0;
    (int56[] memory tickCumulatives, ) = pool.observe(secondsAgos);
    assertEq(tickCumulatives[0], tickCumulatives[1], "same timestamp should give same cumulative");
  }

  function test_pool_feeGrowth_afterSwaps() public {
    uint160 sqrtPriceX96 = 79228162514264337593543950336;
    IListaV3Pool pool = _createAndInitPool(sqrtPriceX96);

    // Add liquidity
    int24 tickLower = -600;
    int24 tickUpper = 600;
    _mintTokens(address(this), 100 ether, 100 ether);
    pool.mint(address(this), tickLower, tickUpper, 100_000_000_000, "");

    // Perform multiple swaps to generate fees
    for (uint256 i = 0; i < 5; i++) {
      _mintTokens(address(this), 1 ether, 1 ether);
      pool.swap(address(this), true, int256(0.5 ether), MIN_SQRT_RATIO + 1, "");
      pool.swap(address(this), false, int256(0.5 ether), MAX_SQRT_RATIO - 1, "");
    }

    // Fee growth should be non-zero
    uint256 fg0 = pool.feeGrowthGlobal0X128();
    uint256 fg1 = pool.feeGrowthGlobal1X128();
    assertGt(fg0 + fg1, 0, "fees should have accrued from swaps");
  }

  /* ═══════════════════════════════════════════════════════════
     NonfungiblePositionManager Tests
     ═══════════════════════════════════════════════════════════ */

  function test_npm_mintPosition() public {
    // Create and init pool directly via factory (NPM uses computeAddress internally)
    uint160 sqrtPriceX96 = 79228162514264337593543950336;
    address poolAddr = factory.createPool(token0, token1, FEE);
    IListaV3Pool(poolAddr).initialize(sqrtPriceX96);

    // Mint tokens and approve NPM
    _mintTokens(address(this), 10 ether, 10 ether);
    IERC20(token0).approve(address(npm), 10 ether);
    IERC20(token1).approve(address(npm), 10 ether);

    (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = npm.mint(
      INonfungiblePositionManager.MintParams({
        token0: token0,
        token1: token1,
        fee: FEE,
        tickLower: -TICK_SPACING,
        tickUpper: TICK_SPACING,
        amount0Desired: 1 ether,
        amount1Desired: 1 ether,
        amount0Min: 0,
        amount1Min: 0,
        recipient: address(this),
        deadline: block.timestamp
      })
    );

    assertEq(tokenId, 1, "first token ID should be 1");
    assertGt(liquidity, 0, "should have minted liquidity");
    assertGt(amount0 + amount1, 0, "should have consumed tokens");
    assertEq(npm.ownerOf(tokenId), address(this));
  }

  function test_npm_increaseLiquidity() public {
    uint160 sqrtPriceX96 = 79228162514264337593543950336;
    address poolAddr = factory.createPool(token0, token1, FEE);
    IListaV3Pool(poolAddr).initialize(sqrtPriceX96);

    _mintTokens(address(this), 20 ether, 20 ether);
    IERC20(token0).approve(address(npm), 20 ether);
    IERC20(token1).approve(address(npm), 20 ether);

    (uint256 tokenId, uint128 liqBefore, , ) = npm.mint(
      INonfungiblePositionManager.MintParams({
        token0: token0,
        token1: token1,
        fee: FEE,
        tickLower: -TICK_SPACING,
        tickUpper: TICK_SPACING,
        amount0Desired: 1 ether,
        amount1Desired: 1 ether,
        amount0Min: 0,
        amount1Min: 0,
        recipient: address(this),
        deadline: block.timestamp
      })
    );

    (uint128 addedLiq, , ) = npm.increaseLiquidity(
      INonfungiblePositionManager.IncreaseLiquidityParams({
        tokenId: tokenId,
        amount0Desired: 1 ether,
        amount1Desired: 1 ether,
        amount0Min: 0,
        amount1Min: 0,
        deadline: block.timestamp
      })
    );

    assertGt(addedLiq, 0, "should add liquidity");

    // Check total via positions()
    (, , , , , , , uint128 totalLiq, , , , ) = npm.positions(tokenId);
    assertEq(totalLiq, liqBefore + addedLiq, "total liquidity should be sum");
  }

  function test_npm_decreaseLiquidity_and_collect() public {
    uint160 sqrtPriceX96 = 79228162514264337593543950336;
    address poolAddr = factory.createPool(token0, token1, FEE);
    IListaV3Pool(poolAddr).initialize(sqrtPriceX96);

    _mintTokens(address(this), 10 ether, 10 ether);
    IERC20(token0).approve(address(npm), 10 ether);
    IERC20(token1).approve(address(npm), 10 ether);

    (uint256 tokenId, uint128 liquidity, , ) = npm.mint(
      INonfungiblePositionManager.MintParams({
        token0: token0,
        token1: token1,
        fee: FEE,
        tickLower: -TICK_SPACING,
        tickUpper: TICK_SPACING,
        amount0Desired: 1 ether,
        amount1Desired: 1 ether,
        amount0Min: 0,
        amount1Min: 0,
        recipient: address(this),
        deadline: block.timestamp
      })
    );

    // Decrease all liquidity
    (uint256 dec0, uint256 dec1) = npm.decreaseLiquidity(
      INonfungiblePositionManager.DecreaseLiquidityParams({
        tokenId: tokenId,
        liquidity: liquidity,
        amount0Min: 0,
        amount1Min: 0,
        deadline: block.timestamp
      })
    );
    assertGt(dec0 + dec1, 0, "should return tokens");

    // Collect
    uint256 bal0Before = IERC20(token0).balanceOf(address(this));
    uint256 bal1Before = IERC20(token1).balanceOf(address(this));
    npm.collect(
      INonfungiblePositionManager.CollectParams({
        tokenId: tokenId,
        recipient: address(this),
        amount0Max: type(uint128).max,
        amount1Max: type(uint128).max
      })
    );
    uint256 collected0 = IERC20(token0).balanceOf(address(this)) - bal0Before;
    uint256 collected1 = IERC20(token1).balanceOf(address(this)) - bal1Before;
    assertGt(collected0 + collected1, 0, "should collect tokens");
  }

  function test_npm_burn() public {
    uint160 sqrtPriceX96 = 79228162514264337593543950336;
    address poolAddr = factory.createPool(token0, token1, FEE);
    IListaV3Pool(poolAddr).initialize(sqrtPriceX96);

    _mintTokens(address(this), 10 ether, 10 ether);
    IERC20(token0).approve(address(npm), 10 ether);
    IERC20(token1).approve(address(npm), 10 ether);

    (uint256 tokenId, uint128 liquidity, , ) = npm.mint(
      INonfungiblePositionManager.MintParams({
        token0: token0,
        token1: token1,
        fee: FEE,
        tickLower: -TICK_SPACING,
        tickUpper: TICK_SPACING,
        amount0Desired: 1 ether,
        amount1Desired: 1 ether,
        amount0Min: 0,
        amount1Min: 0,
        recipient: address(this),
        deadline: block.timestamp
      })
    );

    // Must decrease + collect before burn
    npm.decreaseLiquidity(
      INonfungiblePositionManager.DecreaseLiquidityParams({
        tokenId: tokenId,
        liquidity: liquidity,
        amount0Min: 0,
        amount1Min: 0,
        deadline: block.timestamp
      })
    );
    npm.collect(
      INonfungiblePositionManager.CollectParams({
        tokenId: tokenId,
        recipient: address(this),
        amount0Max: type(uint128).max,
        amount1Max: type(uint128).max
      })
    );

    npm.burn(tokenId);

    vm.expectRevert();
    npm.ownerOf(tokenId);
  }

  function test_npm_positions_returnsCorrectData() public {
    uint160 sqrtPriceX96 = 79228162514264337593543950336;
    address poolAddr = factory.createPool(token0, token1, FEE);
    IListaV3Pool(poolAddr).initialize(sqrtPriceX96);

    _mintTokens(address(this), 10 ether, 10 ether);
    IERC20(token0).approve(address(npm), 10 ether);
    IERC20(token1).approve(address(npm), 10 ether);

    int24 tickLower = -120;
    int24 tickUpper = 120;

    (uint256 tokenId, uint128 expectedLiq, , ) = npm.mint(
      INonfungiblePositionManager.MintParams({
        token0: token0,
        token1: token1,
        fee: FEE,
        tickLower: tickLower,
        tickUpper: tickUpper,
        amount0Desired: 1 ether,
        amount1Desired: 1 ether,
        amount0Min: 0,
        amount1Min: 0,
        recipient: address(this),
        deadline: block.timestamp
      })
    );

    (, , address t0, address t1, uint24 fee, int24 tl, int24 tu, uint128 liq, , , , ) = npm.positions(tokenId);

    assertEq(t0, token0);
    assertEq(t1, token1);
    assertEq(fee, FEE);
    assertEq(tl, tickLower);
    assertEq(tu, tickUpper);
    assertEq(liq, expectedLiq);
  }

  /* ═══════════════════════════════════════════════════════════
     Init Code Hash (utility test)
     ═══════════════════════════════════════════════════════════ */

  function test_poolInitCodeHash() public {
    bytes32 hash = factory.poolInitCodeHash();
    assertGt(uint256(hash), 0, "poolInitCodeHash should be non-zero");
    emit log_named_bytes32("poolInitCodeHash", hash);

    // Verify the hash correctly derives pool addresses:
    // create a pool, then check computeAddress matches
    address pool = factory.createPool(token0, token1, FEE);
    address derived = PoolAddress.computeAddress(address(factory), PoolAddress.PoolKey(token0, token1, FEE), hash);
    assertEq(derived, pool, "computeAddress should match actual pool address");
  }
}
