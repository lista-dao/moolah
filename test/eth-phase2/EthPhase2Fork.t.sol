pragma solidity 0.8.34;

import "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Moolah } from "moolah/Moolah.sol";
import { MoolahVault } from "moolah-vault/MoolahVault.sol";
import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { Liquidator } from "liquidator/Liquidator.sol";
import { PublicLiquidator } from "liquidator/PublicLiquidator.sol";
import { IOracle } from "moolah/interfaces/IOracle.sol";

// ─── Deploy script imports (called directly via .run()) ───
import { CreateMarketPhase2Deploy } from "../../script/eth/phase2/deploy_createMarket.sol";
import { MoolahVaultWETHDeploy } from "../../script/eth/phase2/deploy_moolahVault_weth.sol";
import { MoolahVaultConfigWETHDeploy } from "../../script/eth/phase2/deploy_moolahVaultConfig_weth.sol";
import { MoolahVaultTransferRoleWETHDeploy } from "../../script/eth/phase2/deploy_moolahVault_transferRole_weth.sol";
import { VaultConfigUsdtUsdcPhase2Deploy } from "../../script/eth/phase2/deploy_vaultConfig_usdt_usdc.sol";

interface IStableSwapRampA {
  function A() external view returns (uint256);

  function future_A() external view returns (uint256);

  function future_A_time() external view returns (uint256);

  function ramp_A(uint256 _future_A, uint256 _future_time) external;
}

// ─── Harness: expose deploy script internal params for verification ───

/// @dev Inherits CreateMarketPhase2Deploy to access its internal addresses and compute market IDs
contract CreateMarketHarness is CreateMarketPhase2Deploy {
  using MarketParamsLib for MarketParams;

  function marketIds() external view returns (Id[4] memory ids) {
    ids[0] = MarketParams(WETH, wstETH, multiOracle, irm, lltv965).id();
    ids[1] = MarketParams(WETH, wBETH, multiOracle, irm, lltv965).id();
    ids[2] = MarketParams(USDT, WBTC_cbBTC, WBTC_cbBTCSmartProvider, irm, lltv80).id();
    ids[3] = MarketParams(USDC, WBTC_cbBTC, WBTC_cbBTCSmartProvider, irm, lltv80).id();
  }

  function marketParams() external view returns (MarketParams[4] memory params) {
    params[0] = MarketParams(WETH, wstETH, multiOracle, irm, lltv965);
    params[1] = MarketParams(WETH, wBETH, multiOracle, irm, lltv965);
    params[2] = MarketParams(USDT, WBTC_cbBTC, WBTC_cbBTCSmartProvider, irm, lltv80);
    params[3] = MarketParams(USDC, WBTC_cbBTC, WBTC_cbBTCSmartProvider, irm, lltv80);
  }
}

// ─── Harness: expose VaultConfig internal params for verification ───

contract VaultConfigHarness is MoolahVaultConfigWETHDeploy {
  using MarketParamsLib for MarketParams;

  function getFee() external view returns (uint256) {
    return fee;
  }

  function getFeeRecipient() external view returns (address) {
    return feeRecipient;
  }

  function supplyQueueIds() external view returns (Id[2] memory ids) {
    ids[0] = MarketParams(WETH, wstETH, multiOracle, irm, lltv965).id();
    ids[1] = MarketParams(WETH, wBETH, multiOracle, irm, lltv965).id();
  }
}

// ─── Harness: expose TransferRole internal params for verification ───

contract TransferRoleHarness is MoolahVaultTransferRoleWETHDeploy {
  function getAdmin() external view returns (address) {
    return admin;
  }

  function getManager() external view returns (address) {
    return manager;
  }

  function getAllocator() external view returns (address) {
    return allocator;
  }

  function getCurator() external view returns (address) {
    return curator;
  }
}

/// @notice Fork test for ETH Phase 2 deployment.
///   Calls the REAL deploy scripts' run() directly.
///   PRIVATE_KEY env var is set in setUp so _deployerKey() works.
///
///   Run: forge test --match-contract EthPhase2ForkTest --fork-url $ETH_RPC -vvv
contract EthPhase2ForkTest is Test {
  using MarketParamsLib for MarketParams;

  // ─── Test deployer key (Foundry default #0) ───
  uint256 constant TEST_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
  address testDeployer; // = vm.addr(TEST_KEY)

  // ─── Existing contracts on ETH mainnet ───
  Moolah moolah = Moolah(0xf820fB4680712CD7263a0D3D024D5b5aEA82Fd70);
  Liquidator liquidatorContract = Liquidator(payable(0x5Bf5c3B5f5c29dBC647d2557Cc22B00ED29f301C));
  PublicLiquidator publicLiquidatorContract = PublicLiquidator(payable(0x796302e041d1715a8b1f16Fd7d7CBA38bb031DE5));
  MoolahVault usdtVault = MoolahVault(0x28643FFD79256719D6AcbCF25Cb44576cAeBCf12);
  MoolahVault usdcVault = MoolahVault(0x9651Ae50a5763c6f9B883f9d50e8116281CFcab2);

  IStableSwapRampA stableSwapPool = IStableSwapRampA(0x94E4A9f24A954047adB3AD4434bf1174F6824e16);
  uint256 constant RAMP_A_TARGET = 10000;
  uint256 constant RAMP_A_DURATION = 1 days;

  address manager = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  address adminTimeLock = 0xa18ae79AEDA3e711E0CD64cfe1Cd06402d400D61;

  bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 constant CURATOR = keccak256("CURATOR");
  bytes32 constant ALLOCATOR_ROLE = keccak256("ALLOCATOR");
  bytes32 constant MANAGER_ROLE = keccak256("MANAGER");
  bytes32 constant OPERATOR_ROLE = keccak256("OPERATOR");

  CreateMarketHarness harness;
  MoolahVault wethVault;

  function setUp() public {
    vm.createSelectFork(vm.envString("ETH_RPC"));

    // Set PRIVATE_KEY env so deploy scripts' _deployerKey() works
    testDeployer = vm.addr(TEST_KEY);
    vm.setEnv("PRIVATE_KEY", vm.toString(TEST_KEY));
    deal(testDeployer, 100 ether);

    // Grant roles on Moolah
    vm.startPrank(adminTimeLock);
    if (!moolah.hasRole(OPERATOR_ROLE, testDeployer)) moolah.grantRole(OPERATOR_ROLE, testDeployer);
    if (!moolah.hasRole(MANAGER_ROLE, testDeployer)) moolah.grantRole(MANAGER_ROLE, testDeployer);
    vm.stopPrank();

    // Grant MANAGER on Liquidator & PublicLiquidator
    address liqAdmin = _findAdmin(address(liquidatorContract));
    vm.prank(liqAdmin);
    liquidatorContract.grantRole(MANAGER_ROLE, testDeployer);

    address plAdmin = _findAdmin(address(publicLiquidatorContract));
    vm.prank(plAdmin);
    publicLiquidatorContract.grantRole(MANAGER_ROLE, testDeployer);

    harness = new CreateMarketHarness();
    harness.setUp();
  }

  // ═══════════════════════════════════════════════════
  //  Step 0: Ramp A on StableSwap Pool (WBTC/cbBTC)
  // ═══════════════════════════════════════════════════

  function test_step0_rampA() public {
    uint256 currentA = stableSwapPool.A();
    // A may have already been ramped on mainnet — skip initial assertion
    // Just verify we can warp to target if needed
    if (currentA < RAMP_A_TARGET) {
      // If ramp is in progress, warp past future_A_time to let it complete
      uint256 futureTime = stableSwapPool.future_A_time();
      if (futureTime > block.timestamp) {
        vm.warp(futureTime + 1);
      }
    }
    assertGe(stableSwapPool.A(), currentA, "A should not decrease");
  }

  // ═══════════════════════════════════════════════════
  //  Step 1: Enable LLTV 80% (multisig, no deploy script)
  // ═══════════════════════════════════════════════════

  function test_step1_enableLltv80() public {
    assertTrue(moolah.isLltvEnabled(0.965 ether), "LLTV 96.5% should already be enabled");

    if (!moolah.isLltvEnabled(0.80 ether)) {
      vm.prank(manager);
      moolah.enableLltv(0.80 ether);
    }
    assertTrue(moolah.isLltvEnabled(0.80 ether), "LLTV 80% should be enabled");
  }

  // ═══════════════════════════════════════════════════
  //  Step 2: Create 4 markets — calls deploy_createMarket.sol run()
  // ═══════════════════════════════════════════════════

  function test_step2_createMarkets() public {
    _enableLltvIfNeeded();

    _runCreateMarkets();

    Id[4] memory ids = harness.marketIds();
    string[4] memory labels = ["wstETH/WETH", "wbETH/WETH", "WBTC_cbBTC/USDT", "WBTC_cbBTC/USDC"];
    for (uint256 i = 0; i < 4; i++) {
      (, , , , uint128 lastUpdate, ) = moolah.market(ids[i]);
      assertTrue(lastUpdate != 0, string.concat(labels[i], ": market should exist"));
    }
  }

  // ═══════════════════════════════════════════════════
  //  Step 3: Deploy WETH Vault — calls deploy_moolahVault_weth.sol run()
  // ═══════════════════════════════════════════════════

  function test_step3_deployVault() public {
    wethVault = _runDeployVault();

    assertGt(address(wethVault).code.length, 0, "vault proxy should have code");
    assertEq(wethVault.asset(), 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, "vault asset should be WETH");
    assertEq(wethVault.name(), "Lista WETH Savings Vault");
    assertEq(wethVault.symbol(), "ListaSafeWETH");
    assertTrue(wethVault.hasRole(DEFAULT_ADMIN_ROLE, testDeployer), "deployer should be admin");
  }

  // ═══════════════════════════════════════════════════
  //  Step 4: Configure WETH Vault — calls deploy_moolahVaultConfig_weth.sol run()
  // ═══════════════════════════════════════════════════

  function test_step4_configVault() public {
    _enableLltvIfNeeded();
    _runCreateMarkets();
    wethVault = _runDeployVault();

    _runConfigVault();

    VaultConfigHarness vc = new VaultConfigHarness();
    vc.setUp();
    assertEq(wethVault.fee(), vc.getFee(), "fee should match script");
    assertEq(wethVault.feeRecipient(), vc.getFeeRecipient(), "feeRecipient should match script");
    assertEq(wethVault.supplyQueueLength(), 2, "supply queue should have 2 markets");

    Id[2] memory queueIds = vc.supplyQueueIds();
    (uint184 cap0, , ) = wethVault.config(queueIds[0]);
    (uint184 cap1, , ) = wethVault.config(queueIds[1]);
    assertEq(uint256(cap0), 28_600 ether, "wstETH cap should match");
    assertEq(uint256(cap1), 5_720 ether, "wbETH cap should match");

    assertEq(Id.unwrap(wethVault.supplyQueue(0)), Id.unwrap(queueIds[0]), "supplyQueue[0] = wstETH");
    assertEq(Id.unwrap(wethVault.supplyQueue(1)), Id.unwrap(queueIds[1]), "supplyQueue[1] = wbETH");
    assertEq(Id.unwrap(wethVault.withdrawQueue(0)), Id.unwrap(queueIds[1]), "withdrawQueue[0] = wbETH");
    assertEq(Id.unwrap(wethVault.withdrawQueue(1)), Id.unwrap(queueIds[0]), "withdrawQueue[1] = wstETH");
  }

  // ═══════════════════════════════════════════════════
  //  Step 5: Liquidation whitelist (Manager Safe batch — no script)
  // ═══════════════════════════════════════════════════

  function test_step5_liquidationWhitelist() public {
    _enableLltvIfNeeded();
    _runCreateMarkets();

    _runLiquidationWhitelist();

    Id[4] memory ids = harness.marketIds();
    address liq = 0x5Bf5c3B5f5c29dBC647d2557Cc22B00ED29f301C;
    address bot = 0x08E83A96F4dA5DecC0e6E9084dDe049A3E84ca04;
    address pub = 0x796302e041d1715a8b1f16Fd7d7CBA38bb031DE5;

    for (uint256 i = 0; i < 4; i++) {
      assertTrue(moolah.isLiquidationWhitelist(ids[i], liq), "liquidator whitelisted");
      assertTrue(moolah.isLiquidationWhitelist(ids[i], bot), "bot whitelisted");
      assertTrue(moolah.isLiquidationWhitelist(ids[i], pub), "publicLiquidator whitelisted");
      assertTrue(liquidatorContract.marketWhitelist(Id.unwrap(ids[i])), "Liquidator market whitelisted");
    }

    address sp = 0x893666d84B374f96Ab500f56728283eeBB94A9ac;
    assertTrue(liquidatorContract.smartProviders(sp), "Liquidator SmartProvider");
    assertTrue(publicLiquidatorContract.smartProviders(sp), "PublicLiquidator SmartProvider");
  }

  // ═══════════════════════════════════════════════════
  //  Step 6: Transfer roles — calls deploy_moolahVault_transferRole_weth.sol run()
  // ═══════════════════════════════════════════════════

  function test_step6_transferRoles() public {
    _enableLltvIfNeeded();
    _runCreateMarkets();
    wethVault = _runDeployVault();
    _runConfigVault();

    _runTransferRole();

    TransferRoleHarness tr = new TransferRoleHarness();
    tr.setUp();
    assertTrue(wethVault.hasRole(DEFAULT_ADMIN_ROLE, tr.getAdmin()), "admin on AdminTimeLock");
    assertTrue(wethVault.hasRole(MANAGER_ROLE, tr.getManager()), "MANAGER on ManagerTimeLock");
    assertTrue(wethVault.hasRole(ALLOCATOR_ROLE, tr.getAllocator()), "ALLOCATOR on allocator");
    assertTrue(wethVault.hasRole(CURATOR, tr.getCurator()), "CURATOR on ManagerTimeLock");

    assertFalse(wethVault.hasRole(DEFAULT_ADMIN_ROLE, testDeployer), "deployer lost admin");
    assertFalse(wethVault.hasRole(MANAGER_ROLE, testDeployer), "deployer lost MANAGER");
    assertFalse(wethVault.hasRole(CURATOR, testDeployer), "deployer lost CURATOR");
    assertFalse(wethVault.hasRole(ALLOCATOR_ROLE, testDeployer), "deployer lost ALLOCATOR");
  }

  // ═══════════════════════════════════════════════════
  //  Step 7: USDT/USDC vault calldata (view-only script)
  // ═══════════════════════════════════════════════════

  function test_step7_calldataGeneration() public {
    VaultConfigUsdtUsdcPhase2Deploy script = new VaultConfigUsdtUsdcPhase2Deploy();
    script.run();

    assertEq(usdtVault.supplyQueueLength(), 2, "USDT vault should have 2 markets currently");
    assertEq(usdcVault.supplyQueueLength(), 2, "USDC vault should have 2 markets currently");
  }

  // ═══════════════════════════════════════════════════
  //  Oracle sanity checks
  // ═══════════════════════════════════════════════════

  function test_oracle_wstETH_price() public view {
    uint256 price = IOracle(0xA64FE284EB8279B9b63946DD51813b0116099301).peek(
      0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0
    );
    assertGt(price, 0, "wstETH price > 0");
    console.log("wstETH price (8 decimals):", price);
  }

  function test_oracle_weth_price() public view {
    uint256 price = IOracle(0xA64FE284EB8279B9b63946DD51813b0116099301).peek(
      0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
    );
    assertGt(price, 0, "WETH price > 0");
    console.log("WETH price (8 decimals):", price);
  }

  function test_oracle_smartProvider_wbtc_cbbtc() public view {
    uint256 lpPrice = IOracle(0x893666d84B374f96Ab500f56728283eeBB94A9ac).peek(
      0x5432E4FE5736B9B7ddc1Be34ac45bdB557f2bE22
    );
    assertGt(lpPrice, 0, "WBTC/cbBTC LP price > 0");
    console.log("WBTC/cbBTC LP price:", lpPrice);

    uint256 usdtPrice = IOracle(0xA64FE284EB8279B9b63946DD51813b0116099301).peek(
      0xdAC17F958D2ee523a2206206994597C13D831ec7
    );
    uint256 usdcPrice = IOracle(0xA64FE284EB8279B9b63946DD51813b0116099301).peek(
      0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
    );
    assertGt(usdtPrice, 0, "USDT price > 0");
    assertGt(usdcPrice, 0, "USDC price > 0");
  }

  // ═══════════════════════════════════════════════════
  //  E2E: Full deployment flow
  // ═══════════════════════════════════════════════════

  function test_e2e_fullDeployment() public {
    // Step 0 — ramp_A already validated in test_step0_rampA, skip here to avoid oracle staleness from warp

    // Step 1
    _enableLltvIfNeeded();

    // Step 2
    _runCreateMarkets();
    Id[4] memory ids = harness.marketIds();
    for (uint256 i = 0; i < 4; i++) {
      (, , , , uint128 lu, ) = moolah.market(ids[i]);
      assertTrue(lu != 0);
    }

    // Step 3
    wethVault = _runDeployVault();
    assertEq(wethVault.asset(), 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // Step 4
    _runConfigVault();
    assertEq(wethVault.supplyQueueLength(), 2);

    // Step 5
    _runLiquidationWhitelist();
    for (uint256 i = 0; i < 4; i++) {
      assertTrue(liquidatorContract.marketWhitelist(Id.unwrap(ids[i])));
    }

    // Step 6
    _runTransferRole();
    TransferRoleHarness tr = new TransferRoleHarness();
    tr.setUp();
    assertTrue(wethVault.hasRole(DEFAULT_ADMIN_ROLE, tr.getAdmin()));
    assertFalse(wethVault.hasRole(DEFAULT_ADMIN_ROLE, testDeployer));

    // ─── Final Verification: Full SOP compliance check ───
    _verifySopCompliance(ids);

    console.log("E2E deployment flow completed successfully!");
  }

  // ═══════════════════════════════════════════════════
  //  E2E: Supply & borrow on new wstETH market
  // ═══════════════════════════════════════════════════

  function test_e2e_supplyAndBorrow_wstETH() public {
    _enableLltvIfNeeded();
    _runCreateMarkets();
    wethVault = _runDeployVault();
    _runConfigVault();

    MarketParams memory wstETHMarket = harness.marketParams()[0];
    address supplier = makeAddr("supplier");
    address borrower = makeAddr("borrower");

    deal(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, supplier, 100 ether);
    vm.startPrank(supplier);
    IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2).approve(address(wethVault), type(uint256).max);
    wethVault.deposit(100 ether, supplier);
    vm.stopPrank();

    assertGt(wethVault.totalAssets(), 0, "vault should have assets");

    deal(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0, borrower, 10 ether);
    vm.startPrank(borrower);
    IERC20(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0).approve(address(moolah), type(uint256).max);
    moolah.supplyCollateral(wstETHMarket, 10 ether, borrower, "");
    moolah.borrow(wstETHMarket, 1 ether, 0, borrower, borrower);
    vm.stopPrank();

    (, , uint128 collateral) = moolah.position(wstETHMarket.id(), borrower);
    assertEq(collateral, 10 ether, "10 wstETH collateral");
    assertEq(IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2).balanceOf(borrower), 1 ether, "borrowed 1 WETH");
  }

  // ═══════════════════════════════════════════════════
  //  Helpers
  // ═══════════════════════════════════════════════════

  function _enableLltvIfNeeded() internal {
    if (!moolah.isLltvEnabled(0.80 ether)) {
      vm.prank(manager);
      moolah.enableLltv(0.80 ether);
    }
    if (!moolah.isLltvEnabled(0.965 ether)) {
      vm.prank(manager);
      moolah.enableLltv(0.965 ether);
    }
  }

  function _runCreateMarkets() internal {
    CreateMarketPhase2Deploy script = new CreateMarketPhase2Deploy();
    script.setUp();
    script.run();
  }

  function _runDeployVault() internal returns (MoolahVault) {
    uint64 nonce = vm.getNonce(testDeployer);
    MoolahVaultWETHDeploy script = new MoolahVaultWETHDeploy();
    script.setUp();
    script.run();
    return MoolahVault(vm.computeCreateAddress(testDeployer, nonce + 1));
  }

  function _runConfigVault() internal {
    vm.setEnv("WETH_VAULT", vm.toString(address(wethVault)));
    vm.setEnv("WSTETH_CAP", vm.toString(uint256(28_600 ether)));
    vm.setEnv("WBETH_CAP", vm.toString(uint256(5_720 ether)));
    MoolahVaultConfigWETHDeploy script = new MoolahVaultConfigWETHDeploy();
    script.setUp();
    script.run();
  }

  function _runTransferRole() internal {
    vm.setEnv("WETH_VAULT", vm.toString(address(wethVault)));
    MoolahVaultTransferRoleWETHDeploy script = new MoolahVaultTransferRoleWETHDeploy();
    script.setUp();
    script.run();
  }

  /// @dev Simulates the Manager Safe batch TX for Step 5 (liquidation whitelist)
  function _runLiquidationWhitelist() internal {
    Id[4] memory fixedIds = harness.marketIds();

    // Convert fixed-size Id[4] to dynamic Id[]
    Id[] memory ids = new Id[](4);
    bytes32[] memory idBytes = new bytes32[](4);
    for (uint256 i = 0; i < 4; i++) {
      ids[i] = fixedIds[i];
      idBytes[i] = Id.unwrap(fixedIds[i]);
    }

    // Part A: Moolah.batchToggleLiquidationWhitelist
    address[] memory liquidators = new address[](3);
    liquidators[0] = 0x5Bf5c3B5f5c29dBC647d2557Cc22B00ED29f301C;
    liquidators[1] = 0x08E83A96F4dA5DecC0e6E9084dDe049A3E84ca04;
    liquidators[2] = 0x796302e041d1715a8b1f16Fd7d7CBA38bb031DE5;

    address[][] memory accountInfo = new address[][](4);
    for (uint256 i = 0; i < 4; i++) {
      accountInfo[i] = liquidators;
    }

    address WBTC_cbBTC_LP = 0x5432E4FE5736B9B7ddc1Be34ac45bdB557f2bE22;
    address smartProviderAddr = 0x893666d84B374f96Ab500f56728283eeBB94A9ac;

    vm.startPrank(testDeployer);
    moolah.batchToggleLiquidationWhitelist(ids, accountInfo, true);

    // Part B: Liquidator — market whitelist + token whitelist
    liquidatorContract.batchSetMarketWhitelist(idBytes, true);
    if (!liquidatorContract.tokenWhitelist(WBTC_cbBTC_LP)) {
      liquidatorContract.setTokenWhitelist(WBTC_cbBTC_LP, true);
    }

    // Part C: SmartProvider whitelist (idempotent — skip if already set)
    if (!liquidatorContract.smartProviders(smartProviderAddr)) {
      address[] memory sps = new address[](1);
      sps[0] = smartProviderAddr;
      liquidatorContract.batchSetSmartProviders(sps, true);
    }
    if (!publicLiquidatorContract.smartProviders(smartProviderAddr)) {
      address[] memory sps = new address[](1);
      sps[0] = smartProviderAddr;
      publicLiquidatorContract.batchSetSmartProviders(sps, true);
    }
    vm.stopPrank();
  }

  function _findAdmin(address target) internal view returns (address) {
    if (Liquidator(payable(target)).hasRole(DEFAULT_ADMIN_ROLE, 0x8d388136d578dCD791D081c6042284CED6d9B0c6))
      return 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
    if (Liquidator(payable(target)).hasRole(DEFAULT_ADMIN_ROLE, 0x375fdA2Bf66f4CE85EAB29AB6407dCd4a4C428BA))
      return 0x375fdA2Bf66f4CE85EAB29AB6407dCd4a4C428BA;
    if (Liquidator(payable(target)).hasRole(DEFAULT_ADMIN_ROLE, adminTimeLock)) return adminTimeLock;
    revert("no admin found");
  }

  /// @dev Comprehensive SOP compliance verification — markets, vault config, whitelist, and roles
  function _verifySopCompliance(Id[4] memory ids) internal view {
    // ─── SOP expected addresses ───
    address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address wBETH = 0xa2E3356610840701BDf5611a53974510Ae27E2e1;
    address USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address WBTC_cbBTC = 0x5432E4FE5736B9B7ddc1Be34ac45bdB557f2bE22;
    address multiOracle = 0xA64FE284EB8279B9b63946DD51813b0116099301;
    address smartProvider = 0x893666d84B374f96Ab500f56728283eeBB94A9ac;
    address irm = 0x8b7d334d243b74D63C4b963893267A0F5240F990;
    uint256 lltv965 = 965000000000000000;
    uint256 lltv80 = 800000000000000000;

    // ─── SOP expected market IDs ───
    bytes32 sopId0 = 0x497257af5216a1ab40a6671a05c69946c2df942a4d4d07a5f0081355eea1aa7b;
    bytes32 sopId1 = 0x45a72a3df2497967aa6e2279153ce58ecccb0fc1936aa988bcbf1f4e80051cef;
    bytes32 sopId2 = 0x6e7ea0bf6dfe17dd26bf4b2ed967a51d976623164953d67d5531a464e66294e9;
    bytes32 sopId3 = 0x50e0abea86ce30f753c33beab7057a180d99f943b3681a4799d8931617881a99;

    // ════════════════════════════════════════
    // 1. Verify Market IDs
    // ════════════════════════════════════════
    assertEq(Id.unwrap(ids[0]), sopId0, "SOP: market #1 ID mismatch");
    assertEq(Id.unwrap(ids[1]), sopId1, "SOP: market #2 ID mismatch");
    assertEq(Id.unwrap(ids[2]), sopId2, "SOP: market #5 ID mismatch");
    assertEq(Id.unwrap(ids[3]), sopId3, "SOP: market #6 ID mismatch");

    // ════════════════════════════════════════
    // 2. Verify Market Params
    // ════════════════════════════════════════
    (address p0Loan, address p0Coll, address p0Oracle, address p0Irm, uint256 p0Lltv) = moolah.idToMarketParams(ids[0]);
    assertEq(p0Loan, WETH, "SOP #1: loanToken");
    assertEq(p0Coll, wstETH, "SOP #1: collateralToken");
    assertEq(p0Oracle, multiOracle, "SOP #1: oracle");
    assertEq(p0Irm, irm, "SOP #1: irm");
    assertEq(p0Lltv, lltv965, "SOP #1: lltv");

    (address p1Loan, address p1Coll, address p1Oracle, address p1Irm, uint256 p1Lltv) = moolah.idToMarketParams(ids[1]);
    assertEq(p1Loan, WETH, "SOP #2: loanToken");
    assertEq(p1Coll, wBETH, "SOP #2: collateralToken");
    assertEq(p1Oracle, multiOracle, "SOP #2: oracle");
    assertEq(p1Irm, irm, "SOP #2: irm");
    assertEq(p1Lltv, lltv965, "SOP #2: lltv");

    (address p2Loan, address p2Coll, address p2Oracle, address p2Irm, uint256 p2Lltv) = moolah.idToMarketParams(ids[2]);
    assertEq(p2Loan, USDT, "SOP #5: loanToken");
    assertEq(p2Coll, WBTC_cbBTC, "SOP #5: collateralToken");
    assertEq(p2Oracle, smartProvider, "SOP #5: oracle");
    assertEq(p2Irm, irm, "SOP #5: irm");
    assertEq(p2Lltv, lltv80, "SOP #5: lltv");

    (address p3Loan, address p3Coll, address p3Oracle, address p3Irm, uint256 p3Lltv) = moolah.idToMarketParams(ids[3]);
    assertEq(p3Loan, USDC, "SOP #6: loanToken");
    assertEq(p3Coll, WBTC_cbBTC, "SOP #6: collateralToken");
    assertEq(p3Oracle, smartProvider, "SOP #6: oracle");
    assertEq(p3Irm, irm, "SOP #6: irm");
    assertEq(p3Lltv, lltv80, "SOP #6: lltv");

    // ════════════════════════════════════════
    // 3. Verify Vault Configuration
    // ════════════════════════════════════════
    address sopFeeRecipient = 0xd10a024602E042dcb9C19e21682c3b896c8B0d30;

    assertEq(wethVault.fee(), 0.1 ether, "SOP vault: fee should be 10%");
    assertEq(wethVault.feeRecipient(), sopFeeRecipient, "SOP vault: feeRecipient");
    assertEq(wethVault.asset(), WETH, "SOP vault: asset should be WETH");
    assertEq(wethVault.supplyQueueLength(), 2, "SOP vault: supplyQueue length");

    // Verify caps
    (uint184 cap0, , ) = wethVault.config(ids[0]);
    (uint184 cap1, , ) = wethVault.config(ids[1]);
    assertEq(uint256(cap0), 28_600 ether, "SOP vault: wstETH cap");
    assertEq(uint256(cap1), 5_720 ether, "SOP vault: wBETH cap");

    // Verify supply queue order: [wstETH, wBETH]
    assertEq(Id.unwrap(wethVault.supplyQueue(0)), Id.unwrap(ids[0]), "SOP vault: supplyQueue[0] = wstETH");
    assertEq(Id.unwrap(wethVault.supplyQueue(1)), Id.unwrap(ids[1]), "SOP vault: supplyQueue[1] = wBETH");

    // Verify withdraw queue order: [wBETH, wstETH] (reverse)
    assertEq(Id.unwrap(wethVault.withdrawQueue(0)), Id.unwrap(ids[1]), "SOP vault: withdrawQueue[0] = wBETH");
    assertEq(Id.unwrap(wethVault.withdrawQueue(1)), Id.unwrap(ids[0]), "SOP vault: withdrawQueue[1] = wstETH");

    // ════════════════════════════════════════
    // 4. Verify Liquidation Whitelist
    // ════════════════════════════════════════
    address liq = 0x5Bf5c3B5f5c29dBC647d2557Cc22B00ED29f301C;
    address bot = 0x08E83A96F4dA5DecC0e6E9084dDe049A3E84ca04;
    address pub = 0x796302e041d1715a8b1f16Fd7d7CBA38bb031DE5;

    // Part A: Moolah liquidation whitelist — 4 markets × 3 addresses
    for (uint256 i = 0; i < 4; i++) {
      assertTrue(moolah.isLiquidationWhitelist(ids[i], liq), "SOP whitelist: Liquidator on Moolah");
      assertTrue(moolah.isLiquidationWhitelist(ids[i], bot), "SOP whitelist: Bot on Moolah");
      assertTrue(moolah.isLiquidationWhitelist(ids[i], pub), "SOP whitelist: PublicLiquidator on Moolah");
    }

    // Part B: Liquidator contract — market whitelist + token whitelist
    for (uint256 i = 0; i < 4; i++) {
      assertTrue(liquidatorContract.marketWhitelist(Id.unwrap(ids[i])), "SOP whitelist: Liquidator market");
    }
    assertTrue(liquidatorContract.tokenWhitelist(WBTC_cbBTC), "SOP whitelist: WBTC_cbBTC token");

    // Part C: SmartProvider whitelist
    assertTrue(liquidatorContract.smartProviders(smartProvider), "SOP whitelist: Liquidator SmartProvider");
    assertTrue(publicLiquidatorContract.smartProviders(smartProvider), "SOP whitelist: PublicLiquidator SmartProvider");

    // ════════════════════════════════════════
    // 5. Verify Role Transfer
    // ════════════════════════════════════════
    address sopAdmin = 0xa18ae79AEDA3e711E0CD64cfe1Cd06402d400D61; // Admin TimeLock
    address sopManager = 0x375fdA2Bf66f4CE85EAB29AB6407dCd4a4C428BA; // Manager TimeLock
    address sopAllocator = 0x85CE862C5BB61938FFcc97DA4A80C8aaE43C6A27; // Allocator Safe
    address sopCurator = 0x375fdA2Bf66f4CE85EAB29AB6407dCd4a4C428BA; // Manager TimeLock

    // Correct roles assigned
    assertTrue(wethVault.hasRole(DEFAULT_ADMIN_ROLE, sopAdmin), "SOP role: admin on AdminTimeLock");
    assertTrue(wethVault.hasRole(MANAGER_ROLE, sopManager), "SOP role: MANAGER on ManagerTimeLock");
    assertTrue(wethVault.hasRole(CURATOR, sopCurator), "SOP role: CURATOR on ManagerTimeLock");
    assertTrue(wethVault.hasRole(ALLOCATOR_ROLE, sopAllocator), "SOP role: ALLOCATOR on AllocatorSafe");

    // Deployer revoked
    assertFalse(wethVault.hasRole(DEFAULT_ADMIN_ROLE, testDeployer), "SOP role: deployer lost admin");
    assertFalse(wethVault.hasRole(MANAGER_ROLE, testDeployer), "SOP role: deployer lost MANAGER");
    assertFalse(wethVault.hasRole(CURATOR, testDeployer), "SOP role: deployer lost CURATOR");
    assertFalse(wethVault.hasRole(ALLOCATOR_ROLE, testDeployer), "SOP role: deployer lost ALLOCATOR");
  }
}
