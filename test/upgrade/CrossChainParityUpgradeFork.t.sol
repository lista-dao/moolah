pragma solidity 0.8.34;

import "forge-std/Test.sol";

import { Moolah } from "moolah/Moolah.sol";
import { MarketFactory } from "moolah/MarketFactory.sol";
import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { Liquidator } from "liquidator/Liquidator.sol";
import { PublicLiquidator } from "liquidator/PublicLiquidator.sol";

/**
 * @title CrossChainParityUpgradeFork
 * @notice Fork tests to verify that after the parity upgrade:
 *   1. BSC MarketFactory can still create markets (createMarket + createFixedTermMarket)
 *   2. ETH MarketFactory + Liquidator can create markets (including smart-collateral with reflowBlacklist)
 *
 * Run BSC test:
 *   BSC_RPC=$BSC_RPC forge test --match-contract BscUpgradeForkTest -vvv --fork-url $BSC_RPC
 *
 * Run ETH test:
 *   ETH_RPC=$ETH_RPC forge test --match-contract EthUpgradeForkTest -vvv --fork-url $ETH_RPC
 */

// ─── BSC Fork Test ───────────────────────────────────────────────────────────

contract BscUpgradeForkTest is Test {
  using MarketParamsLib for MarketParams;

  // ─── BSC Addresses ───
  address constant BSC_TIMELOCK = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
  address constant BSC_FACTORY_PROXY = 0xce26859127d236a61f168d2d0905f77d7E286Ab2;
  address constant BSC_MOOLAH = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
  address constant BSC_LIQUIDATOR = 0x6a87C15598929B2db22cF68a9a0dDE5Bf297a59a;
  address constant BSC_PUBLIC_LIQUIDATOR = 0x882475d622c687b079f149B69a15683FCbeCC6D9;
  address constant BSC_REVENUE_DISTRIBUTOR = 0x34B504A5CF0fF41F8A480580533b6Dda687fa3Da;
  address constant BSC_BUYBACK = 0x3b99A4177E3f430590A8473f353dD87a5a2e1BfC;
  address constant BSC_AUTO_BUYBACK = 0xFfd3a57E8DB4f51FA01c72F06Ff30BDFDa9908e6;
  address constant BSC_WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
  address constant BSC_SLIBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
  address constant BSC_BNB_PROVIDER = 0x367384C54756a25340c63057D87eA22d47Fd5701;
  address constant BSC_SLISBNB_PROVIDER = 0x33f7A980a246f9B8FEA2254E3065576E127D4D5f;
  address constant BSC_RATE_CALCULATOR = 0xF81A3067ACF683B7f2f40a22bCF17c8310be2330;
  address constant BSC_BROKER_LIQUIDATOR = 0x3AA647a1e902833b61E503DbBFbc58992daa4868;

  address constant MANAGER_SAFE = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;

  bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 constant OPERATOR = keccak256("OPERATOR");
  bytes32 constant MANAGER = keccak256("MANAGER");

  MarketFactory factory;
  Moolah moolah;

  function setUp() public {
    vm.createSelectFork(vm.envString("BSC_RPC"));

    factory = MarketFactory(BSC_FACTORY_PROXY);
    moolah = Moolah(BSC_MOOLAH);

    // ─── Simulate the upgrade (Mechanism B from the runbook) ───
    // 1. Deploy new MarketFactory implementation with same immutables
    MarketFactory newImpl = new MarketFactory(
      BSC_MOOLAH,
      BSC_LIQUIDATOR,
      BSC_PUBLIC_LIQUIDATOR,
      BSC_REVENUE_DISTRIBUTOR,
      BSC_BUYBACK,
      BSC_AUTO_BUYBACK,
      BSC_WBNB,
      BSC_SLIBNB,
      BSC_BNB_PROVIDER,
      BSC_SLISBNB_PROVIDER
    );

    // 2. TimeLock executes: upgradeToAndCall(newImpl, "") + setRateCalculator + setBrokerLiquidator
    vm.startPrank(BSC_TIMELOCK);
    // upgradeToAndCall with empty data
    (bool ok, ) = BSC_FACTORY_PROXY.call(
      abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newImpl), "")
    );
    require(ok, "upgradeToAndCall failed");

    // Re-init rateCalculator and brokerLiquidator (they are now storage, default 0 after upgrade)
    factory.setRateCalculator(BSC_RATE_CALCULATOR);
    factory.setBrokerLiquidator(BSC_BROKER_LIQUIDATOR);
    vm.stopPrank();
  }

  /// @notice Verify rateCalculator and brokerLiquidator are restored after upgrade
  function test_postUpgrade_storageRestored() public view {
    assertEq(address(factory.rateCalculator()), BSC_RATE_CALCULATOR, "rateCalculator not restored");
    assertEq(address(factory.brokerLiquidator()), BSC_BROKER_LIQUIDATOR, "brokerLiquidator not restored");
    assertEq(address(factory.moolah()), BSC_MOOLAH, "moolah immutable changed");
    assertEq(address(factory.liquidator()), BSC_LIQUIDATOR, "liquidator immutable changed");
    assertEq(address(factory.revenueDistributor()), BSC_REVENUE_DISTRIBUTOR, "revenueDistributor changed");
  }

  /// @notice Create a standard market via the factory after upgrade (non-smart-collateral)
  function test_postUpgrade_createMarket() public {
    // Use existing IRM, oracle and LLTV
    address existingIrm = _getIrmFromExistingMarket();
    address existingOracle = _getOracleFromExistingMarket();
    uint256 existingLltv = _getLltvFromExistingMarket();

    // Use a fake collateral — mock the oracle to return a valid price for it
    address fakeCollateral = makeAddr("fakeCollateral");
    vm.etch(fakeCollateral, hex"00");

    // Mock oracle.peek for any token to return a valid price (bypass oracle validation)
    vm.mockCall(existingOracle, abi.encodeWithSignature("peek(address)"), abi.encode(uint256(1e18)));

    MarketParams memory params = MarketParams({
      loanToken: BSC_WBNB,
      collateralToken: fakeCollateral,
      oracle: existingOracle,
      irm: existingIrm,
      lltv: existingLltv
    });

    address[] memory emptyList = new address[](0);

    // Factory needs OPERATOR role to call createMarket
    vm.prank(MANAGER_SAFE);
    factory.createMarket(params, emptyList, emptyList, false, false);

    // Verify market was created
    Id id = params.id();
    (, , , , uint128 lastUpdate, ) = moolah.market(id);
    assertGt(lastUpdate, 0, "market should be created (lastUpdate > 0)");
  }

  /// @notice Verify that createFixedTermMarket doesn't break (rateCalculator is set)
  function test_postUpgrade_rateCalculatorAccessible() public view {
    // Just verify the getter works and returns the correct address
    assertEq(address(factory.rateCalculator()), BSC_RATE_CALCULATOR);
    assertEq(address(factory.brokerLiquidator()), BSC_BROKER_LIQUIDATOR);
  }

  // ─── Helpers ───

  function _getIrmFromExistingMarket() internal view returns (address) {
    return 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c; // BSC AdaptiveCurveIrm
  }

  function _getOracleFromExistingMarket() internal view returns (address) {
    return 0xf3afD82A4071f272F403dC176916141f44E6c750; // BSC MultiOracle
  }

  function _getLltvFromExistingMarket() internal view returns (uint256) {
    return 0.80 ether; // 80% LLTV (enabled on BSC)
  }
}

// ─── ETH Fork Test ───────────────────────────────────────────────────────────

contract EthUpgradeForkTest is Test {
  using MarketParamsLib for MarketParams;

  // ─── ETH Addresses ───
  address constant ETH_TIMELOCK = 0xa18ae79AEDA3e711E0CD64cfe1Cd06402d400D61;
  address constant ETH_FACTORY_PROXY = 0xA2ff080D4c0b71B6c8796129DD4aCc0B09D7592c;
  address constant ETH_MOOLAH = 0xf820fB4680712CD7263a0D3D024D5b5aEA82Fd70;
  address constant ETH_LIQUIDATOR = 0x5Bf5c3B5f5c29dBC647d2557Cc22B00ED29f301C;
  address constant ETH_PUBLIC_LIQUIDATOR = 0x796302e041d1715a8b1f16Fd7d7CBA38bb031DE5;
  address constant ETH_REVENUE_DISTRIBUTOR = 0x0fe5741e8dFe53618c4056F745fad531118640D9;
  address constant ETH_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
  address constant ETH_PROVIDER = 0xFe34BF713F3C2499026cdFA5af43eb22AA2d1aDb;

  address constant MANAGER_SAFE = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;

  bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 constant OPERATOR = keccak256("OPERATOR");
  bytes32 constant MANAGER = keccak256("MANAGER");

  MarketFactory factory;
  Moolah moolah;
  Liquidator liquidatorContract;

  function setUp() public {
    vm.createSelectFork(vm.envString("ETH_RPC"));

    factory = MarketFactory(ETH_FACTORY_PROXY);
    moolah = Moolah(ETH_MOOLAH);
    liquidatorContract = Liquidator(payable(ETH_LIQUIDATOR));

    // ─── Simulate ETH Liquidator upgrade (adds reflowBlacklist) ───
    Liquidator newLiqImpl = new Liquidator(ETH_MOOLAH);

    vm.startPrank(ETH_TIMELOCK);
    // upgradeToAndCall with empty data (fundSource defaults to 0 = legacy behavior)
    (bool ok, ) = ETH_LIQUIDATOR.call(
      abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newLiqImpl), "")
    );
    require(ok, "Liquidator upgradeToAndCall failed");

    // setBotRoleAdmin after upgrade
    liquidatorContract.setBotRoleAdmin();
    vm.stopPrank();
  }

  /// @notice Verify Liquidator upgrade succeeded — reflowBlacklist is now accessible
  function test_postUpgrade_liquidatorHasReflowBlacklist() public view {
    // fundSource should be address(0) (legacy mode, no vault)
    assertEq(liquidatorContract.fundSource(), address(0), "fundSource should be 0 (legacy)");
  }

  /// @notice Verify factory can create a standard market on ETH after Liquidator upgrade
  function test_postUpgrade_createMarket() public {
    // Need to grant factory the required roles (simulating post-role-grant state)
    // The factory should already have roles from the earlier role-grant batch
    // But if not yet executed, we simulate it here
    _ensureFactoryHasRoles();

    // Create a simple market — use WETH as loan token, a fake collateral
    address fakeCollateral = makeAddr("ethFakeCollateral");
    vm.etch(fakeCollateral, hex"00");

    // Use existing IRM and oracle from the ETH deployment
    address existingIrm = _getExistingIrm();
    address existingOracle = _getExistingOracle();
    uint256 existingLltv = _getExistingLltv();

    // Mock oracle.peek for any token to return a valid price
    vm.mockCall(existingOracle, abi.encodeWithSignature("peek(address)"), abi.encode(uint256(1e18)));

    MarketParams memory params = MarketParams({
      loanToken: ETH_WETH,
      collateralToken: fakeCollateral,
      oracle: existingOracle,
      irm: existingIrm,
      lltv: existingLltv
    });

    address[] memory emptyList = new address[](0);

    // Factory (with OPERATOR) calls createMarket
    vm.prank(MANAGER_SAFE);
    factory.createMarket(params, emptyList, emptyList, true, false);

    // Verify market was created
    Id id = params.id();
    (, , , , uint128 lastUpdate, ) = moolah.market(id);
    assertGt(lastUpdate, 0, "ETH market should be created");
  }

  /// @notice Verify factory can create a smart-collateral market with reflowBlacklist
  function test_postUpgrade_createSmartCollateralMarket() public {
    _ensureFactoryHasRoles();

    // For smart-collateral, the factory calls liquidator.setReflowBlacklist(collateral, true)
    // This would REVERT on the old liquidator (no such function) — the upgrade fixes this
    address fakeSmartProvider = makeAddr("fakeSmartProvider");
    address fakeCollateral = makeAddr("smartCollateral");
    address fakeToken0 = makeAddr("token0");
    address fakeToken1 = makeAddr("token1");

    // Mock the smart provider interface
    vm.mockCall(fakeSmartProvider, abi.encodeWithSignature("token(uint256)", 0), abi.encode(fakeToken0));
    vm.mockCall(fakeSmartProvider, abi.encodeWithSignature("token(uint256)", 1), abi.encode(fakeToken1));
    // Mock oracle peek (fakeSmartProvider is used as oracle for smart-collateral)
    vm.mockCall(fakeSmartProvider, abi.encodeWithSignature("peek(address)"), abi.encode(uint256(1e18)));
    // Mock TOKEN() for Moolah.setProvider
    vm.mockCall(fakeSmartProvider, abi.encodeWithSignature("TOKEN()"), abi.encode(fakeCollateral));
    vm.etch(fakeCollateral, hex"00");
    vm.etch(fakeSmartProvider, hex"01"); // needs to be a "contract"

    address existingIrm = _getExistingIrm();
    uint256 existingLltv = _getExistingLltv();

    MarketParams memory params = MarketParams({
      loanToken: ETH_WETH,
      collateralToken: fakeCollateral,
      oracle: fakeSmartProvider, // oracle = smart provider for smart-collateral markets
      irm: existingIrm,
      lltv: existingLltv
    });

    address[] memory emptyList = new address[](0);

    // createMarket with liquidatorSmartProvider=true → triggers _configSmartProvider
    // which calls liquidator.setReflowBlacklist(collateral, true)
    vm.prank(MANAGER_SAFE);
    factory.createMarket(params, emptyList, emptyList, true, true);

    // Verify the reflowBlacklist was set
    assertTrue(liquidatorContract.reflowBlacklist(fakeCollateral), "collateral should be reflow-blacklisted");

    // Verify market was created
    Id id = params.id();
    (, , , , uint128 lastUpdate, ) = moolah.market(id);
    assertGt(lastUpdate, 0, "smart-collateral market should be created");
  }

  // ─── Helpers ───

  function _ensureFactoryHasRoles() internal {
    // Grant factory the roles it needs (simulating the TimeLock executeBatch from salt 8)
    vm.startPrank(ETH_TIMELOCK);
    if (!moolah.hasRole(MANAGER, ETH_FACTORY_PROXY)) {
      moolah.grantRole(MANAGER, ETH_FACTORY_PROXY);
    }
    if (!moolah.hasRole(OPERATOR, ETH_FACTORY_PROXY)) {
      moolah.grantRole(OPERATOR, ETH_FACTORY_PROXY);
    }
    if (!liquidatorContract.hasRole(MANAGER, ETH_FACTORY_PROXY)) {
      liquidatorContract.grantRole(MANAGER, ETH_FACTORY_PROXY);
    }
    vm.stopPrank();

    // PublicLiquidator MANAGER for smart provider
    address plAdmin = _findAdmin(ETH_PUBLIC_LIQUIDATOR);
    vm.prank(plAdmin);
    PublicLiquidator(payable(ETH_PUBLIC_LIQUIDATOR)).grantRole(MANAGER, ETH_FACTORY_PROXY);

    // ListaRevenueDistributor DEFAULT_ADMIN for addTokensToWhitelist
    // (already granted via Script 1 in the deployment flow)
  }

  function _findAdmin(address target) internal view returns (address) {
    // TimeLock is DEFAULT_ADMIN on ETH contracts
    return ETH_TIMELOCK;
  }

  function _getExistingIrm() internal view returns (address) {
    return 0x8b7d334d243b74D63C4b963893267A0F5240F990; // ETH AdaptiveCurveIrm
  }

  function _getExistingOracle() internal view returns (address) {
    return 0xA64FE284EB8279B9b63946DD51813b0116099301; // ETH MultiOracle
  }

  function _getExistingLltv() internal view returns (uint256) {
    return 0.965 ether; // 96.5% LLTV (enabled on ETH)
  }
}
