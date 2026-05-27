// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";
import { stdError } from "forge-std/StdError.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IMoolah, MarketParams, Id, Market } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { MoolahBalancesLib } from "moolah/libraries/periphery/MoolahBalancesLib.sol";
import { MoolahVault } from "../../src/moolah-vault/MoolahVault.sol";
import { MarketAllocation } from "../../src/moolah-vault/interfaces/IMoolahVault.sol";

import { IdleCollateralToken } from "../../src/utils/IdleCollateralToken.sol";
import { IdleOracle } from "../../src/oracle/IdleOracle.sol";

contract IdleMarketForkTest is Test {
  using MarketParamsLib for MarketParams;
  using MoolahBalancesLib for IMoolah;

  // ─── BSC mainnet addresses ───────────────────────────────────────────────
  IMoolah constant MOOLAH = IMoolah(0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C);
  address constant MULTI_ORACLE = 0xf3afD82A4071f272F403dC176916141f44E6c750;
  address constant TIMELOCK_ADMIN = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
  address constant MOOLAH_MANAGER = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  address constant LISUSD = 0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5;
  address constant SLISBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
  address constant ALPHA_IRM = 0x5F9f9173B405C6CEAfa7f98d09e4B8447e9797E6;

  bytes32 constant OPERATOR_ROLE = keccak256("OPERATOR");
  bytes32 constant CURATOR_ROLE = keccak256("CURATOR");
  bytes32 constant ALLOCATOR_ROLE = keccak256("ALLOCATOR");

  // ─── Test fixtures ───────────────────────────────────────────────────────
  IdleCollateralToken idleCollateral;
  IdleOracle idleOracle;
  MarketParams idleMarket;
  Id idleId;

  MarketParams realMarket =
    MarketParams({ loanToken: LISUSD, collateralToken: SLISBNB, oracle: MULTI_ORACLE, irm: ALPHA_IRM, lltv: 85e16 });
  Id realId;

  MoolahVault vault;
  address SUPPLIER = makeAddr("supplier");

  function setUp() public {
    vm.createSelectFork(vm.envString("BSC_RPC"));

    // 1) Deploy idle contracts.
    idleCollateral = new IdleCollateralToken();
    idleOracle = new IdleOracle(address(idleCollateral), MULTI_ORACLE);

    idleMarket = MarketParams({
      loanToken: LISUSD,
      collateralToken: address(idleCollateral),
      oracle: address(idleOracle),
      irm: address(0),
      lltv: 0
    });
    idleId = idleMarket.id();
    realId = realMarket.id();

    // 2) Enable irm=0 and lltv=0 on Moolah (idempotent).
    vm.startPrank(MOOLAH_MANAGER);
    if (!MOOLAH.isIrmEnabled(address(0))) MOOLAH.enableIrm(address(0));
    if (!MOOLAH.isLltvEnabled(0)) MOOLAH.enableLltv(0);
    vm.stopPrank();

    // 3) Grant OPERATOR to this test contract so it can call createMarket.
    vm.prank(TIMELOCK_ADMIN);
    MOOLAH.grantRole(OPERATOR_ROLE, address(this));
    MOOLAH.createMarket(idleMarket);

    // 4) Make sure the real market is already live on mainnet (sanity).
    Market memory rm = MOOLAH.market(realId);
    require(rm.lastUpdate != 0, "real market not on this fork block");

    // 5) Deploy a fresh lisUSD MoolahVault and grant self CURATOR + ALLOCATOR.
    MoolahVault vaultImpl = new MoolahVault(address(MOOLAH), LISUSD);
    ERC1967Proxy vaultProxy = new ERC1967Proxy(
      address(vaultImpl),
      abi.encodeWithSelector(
        vaultImpl.initialize.selector,
        address(this),
        address(this),
        LISUSD,
        "lisUSD Idle Test Vault",
        "lisUSD-ITV"
      )
    );
    vault = MoolahVault(address(vaultProxy));
    vault.grantRole(CURATOR_ROLE, address(this));
    vault.grantRole(ALLOCATOR_ROLE, address(this));

    // 6) Whitelist the vault on the real market in case it's gated.
    vm.startPrank(MOOLAH_MANAGER);
    if (!_isVaultWhitelisted(realId)) {
      try MOOLAH.setWhiteList(realId, address(vault), true) {} catch {}
    }
    vm.stopPrank();

    // 7) Configure vault caps + queues.
    vault.setCap(realMarket, type(uint184).max);
    vault.setCap(idleMarket, type(uint184).max);
    // supplyQueue: real first, idle last (overflow buffer).
    Id[] memory sq = new Id[](2);
    sq[0] = realId;
    sq[1] = idleId;
    vault.setSupplyQueue(sq);
    // withdrawQueue: idle first so user redemptions drain idle before touching real.
    uint256[] memory wqIdx = new uint256[](2);
    // After two setCap calls the queue is [realId, idleId]; swap to [idleId, realId].
    wqIdx[0] = 1;
    wqIdx[1] = 0;
    vault.updateWithdrawQueue(wqIdx);

    // 8) Fund supplier.
    deal(LISUSD, SUPPLIER, 1_000_000 ether);
    vm.prank(SUPPLIER);
    IERC20(LISUSD).approve(address(vault), type(uint256).max);
  }

  function _isVaultWhitelisted(Id) internal pure returns (bool) {
    // The MoolahVault path does not require we re-check; helper exists only to avoid hard fails.
    return false;
  }

  // ─── Tests ───────────────────────────────────────────────────────────────

  function test_idleMarket_created() public view {
    Market memory m = MOOLAH.market(idleId);
    assertGt(m.lastUpdate, 0, "idle market not created");
    assertEq(m.totalSupplyAssets, 0);
    assertEq(m.totalBorrowAssets, 0);
  }

  function test_idleOracle_returnsZeroForCollateral_andRealPriceForLoan() public view {
    assertEq(idleOracle.peek(address(idleCollateral)), 0, "idle collateral price should be 0");
    assertGt(idleOracle.peek(LISUSD), 0, "loan price should be non-zero");
  }

  function test_supplyCollateralToIdle_reverts() public {
    // Moolah wraps the transferFrom revert in SafeTransferLib's TRANSFER_FROM_REVERTED string.
    vm.expectRevert(bytes("transferFrom reverted"));
    MOOLAH.supplyCollateral(idleMarket, 1, address(this), hex"");
  }

  function test_borrowFromIdle_reverts() public {
    // Seed the idle market with supply so the borrow path is not blocked by INSUFFICIENT_LIQUIDITY.
    deal(LISUSD, address(this), 100 ether);
    IERC20(LISUSD).approve(address(MOOLAH), type(uint256).max);
    MOOLAH.supply(idleMarket, 100 ether, 0, address(this), hex"");

    // Borrow must fail at the health check: position.collateral == 0 → maxBorrow == 0.
    vm.expectRevert(bytes("insufficient collateral"));
    MOOLAH.borrow(idleMarket, 1 ether, 0, address(this), address(this));
  }

  function test_withdrawCollateralFromIdle_reverts() public {
    // position.collateral is uint128(0); subtracting any positive amount underflows.
    vm.expectRevert(stdError.arithmeticError);
    MOOLAH.withdrawCollateral(idleMarket, 1, address(this), address(this));
  }

  function test_liquidateOnIdle_reverts() public {
    // No one can ever be unhealthy on idle (no collateral, no borrow). Liquidate must revert
    // with HEALTHY_POSITION because borrowShares == 0 short-circuits _isHealthy to true.
    vm.expectRevert(bytes("position is healthy"));
    MOOLAH.liquidate(idleMarket, address(this), 0, 1, hex"");
  }

  function test_repayOnIdle_reverts() public {
    // No one has any borrow shares; subtraction in position[id].borrowShares -= ... underflows.
    deal(LISUSD, address(this), 1 ether);
    IERC20(LISUSD).approve(address(MOOLAH), type(uint256).max);
    vm.expectRevert(stdError.arithmeticError);
    MOOLAH.repay(idleMarket, 1, 0, address(this), hex"");
  }

  function test_vaultMint_routesByQueue() public {
    // mint(shares, receiver) rounds assets up. Supply queue starts with real; idle stays empty.
    uint256 shares = vault.previewDeposit(50_000 ether);
    vm.prank(SUPPLIER);
    uint256 assetsPaid = vault.mint(shares, SUPPLIER);

    assertGt(assetsPaid, 0, "mint pulled assets");
    assertApproxEqAbs(_vaultAssetsIn(realMarket), assetsPaid, 2, "real market took mint");
    assertEq(_vaultAssetsIn(idleMarket), 0, "idle untouched by mint");
  }

  function test_vaultRedeem_drainsIdleFirst() public {
    uint256 amount = 80_000 ether;
    vm.prank(SUPPLIER);
    vault.deposit(amount, SUPPLIER);

    // Park 30k in idle; rest in real.
    MarketAllocation[] memory split = new MarketAllocation[](2);
    split[0] = MarketAllocation({ marketParams: realMarket, assets: amount - 30_000 ether });
    split[1] = MarketAllocation({ marketParams: idleMarket, assets: type(uint256).max });
    vault.reallocate(split);

    uint256 idleBefore = _vaultAssetsIn(idleMarket);
    uint256 realBefore = _vaultAssetsIn(realMarket);

    // Redeem half the supplier's shares. Floor rounding may yield < idleBefore assets, so the
    // entire redemption should resolve from idle without touching real.
    uint256 sharesHalf = vault.balanceOf(SUPPLIER) / 4;
    vm.prank(SUPPLIER);
    uint256 assetsOut = vault.redeem(sharesHalf, SUPPLIER, SUPPLIER);

    assertGt(assetsOut, 0, "redeem returned assets");
    assertLe(assetsOut, idleBefore, "redeem must not exceed idle balance for this size");
    assertApproxEqAbs(_vaultAssetsIn(idleMarket), idleBefore - assetsOut, 2, "idle drained by redeem");
    assertApproxEqAbs(_vaultAssetsIn(realMarket), realBefore, 2, "real untouched by redeem");
  }

  function test_vaultDeposit_routesByQueue() public {
    // supplyQueue: real first. Without a cap difference, real should absorb everything.
    uint256 amount = 100_000 ether;
    vm.prank(SUPPLIER);
    vault.deposit(amount, SUPPLIER);

    uint256 realAssets = _vaultAssetsIn(realMarket);
    uint256 idleAssets = _vaultAssetsIn(idleMarket);

    assertApproxEqAbs(realAssets, amount, 2, "real market should hold deposit");
    assertEq(idleAssets, 0, "idle should be empty when real has capacity");
  }

  function test_reallocate_realToIdle_andBack() public {
    uint256 amount = 50_000 ether;
    vm.prank(SUPPLIER);
    vault.deposit(amount, SUPPLIER);
    uint256 totalBefore = vault.totalAssets();

    // Pull everything out of the real market into idle.
    MarketAllocation[] memory toIdle = new MarketAllocation[](2);
    toIdle[0] = MarketAllocation({ marketParams: realMarket, assets: 0 }); // withdraw all
    toIdle[1] = MarketAllocation({ marketParams: idleMarket, assets: type(uint256).max });
    vault.reallocate(toIdle);

    assertApproxEqAbs(_vaultAssetsIn(realMarket), 0, 1, "real drained");
    assertApproxEqAbs(_vaultAssetsIn(idleMarket), totalBefore, 2, "idle holds principal");
    assertApproxEqAbs(vault.totalAssets(), totalBefore, 2, "totalAssets unchanged across reallocate");

    // Send it back.
    MarketAllocation[] memory toReal = new MarketAllocation[](2);
    toReal[0] = MarketAllocation({ marketParams: idleMarket, assets: 0 });
    toReal[1] = MarketAllocation({ marketParams: realMarket, assets: type(uint256).max });
    vault.reallocate(toReal);

    assertApproxEqAbs(_vaultAssetsIn(idleMarket), 0, 1, "idle drained");
    assertApproxEqAbs(_vaultAssetsIn(realMarket), totalBefore, 2, "real refilled");
  }

  function test_idleMarket_doesNotAccrueInterest() public {
    // Park principal entirely in idle, warp 30 days, verify idle assets unchanged.
    uint256 amount = 50_000 ether;
    vm.prank(SUPPLIER);
    vault.deposit(amount, SUPPLIER);

    MarketAllocation[] memory toIdle = new MarketAllocation[](2);
    toIdle[0] = MarketAllocation({ marketParams: realMarket, assets: 0 });
    toIdle[1] = MarketAllocation({ marketParams: idleMarket, assets: type(uint256).max });
    vault.reallocate(toIdle);

    uint256 idleBefore = _vaultAssetsIn(idleMarket);
    uint256 totalBefore = vault.totalAssets();

    vm.warp(block.timestamp + 30 days);
    vm.roll(block.number + 30 * 24 * 60 * 20);

    assertEq(_vaultAssetsIn(idleMarket), idleBefore, "idle principal must be flat");
    assertEq(vault.totalAssets(), totalBefore, "vault accrues 0 yield while fully idle");
  }

  function test_userWithdraw_drainsIdleFirst() public {
    uint256 amount = 80_000 ether;
    vm.prank(SUPPLIER);
    vault.deposit(amount, SUPPLIER);

    // Split: move 30k to idle, leave the rest in real.
    MarketAllocation[] memory split = new MarketAllocation[](2);
    split[0] = MarketAllocation({ marketParams: realMarket, assets: amount - 30_000 ether });
    split[1] = MarketAllocation({ marketParams: idleMarket, assets: type(uint256).max });
    vault.reallocate(split);

    uint256 idleBefore = _vaultAssetsIn(idleMarket);
    uint256 realBefore = _vaultAssetsIn(realMarket);
    assertApproxEqAbs(idleBefore, 30_000 ether, 2, "30k parked in idle");

    // Redeem 20k; should come entirely from idle (withdrawQueue starts with idle).
    vm.prank(SUPPLIER);
    vault.withdraw(20_000 ether, SUPPLIER, SUPPLIER);

    assertApproxEqAbs(_vaultAssetsIn(idleMarket), idleBefore - 20_000 ether, 2, "idle reduced");
    assertApproxEqAbs(_vaultAssetsIn(realMarket), realBefore, 2, "real untouched");
  }

  // ─── Helpers ─────────────────────────────────────────────────────────────

  function _vaultAssetsIn(MarketParams memory mp) internal view returns (uint256) {
    return MOOLAH.expectedSupplyAssets(mp, address(vault));
  }
}
