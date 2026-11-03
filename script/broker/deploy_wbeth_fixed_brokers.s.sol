// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { LendingBroker } from "../../src/broker/LendingBroker.sol";
import { Id } from "../../src/moolah/interfaces/IMoolah.sol";

/// @notice BSC mainnet, wBETH fixed-term step 1/4: deploy the two fixed-term LendingBrokers
///         (wBETH/USD1 and wBETH/U), each bound to its Gauntlet vault's BrokerInterestRelayer.
///
///         Reuses the LIVE implementation 0xf1db84c5…b128 (MIN_FIXED_TERM_APR = 1.005e27, the build
///         every BSC broker runs) — no new implementation is deployed.
///
///         ORACLE = MultiOracle, matching the wBETH/USD1 flexible market. NOTE: ORACLE is effectively
///         immutable — setOracle only works while ORACLE is address(0), which initialize() fills.
///
///         Deployer roles are deliberately NOT revoked here: market creation, fixed-term setup still
///         need them. Revoke with wbeth_fixed_revokeDeployerRoles.s.sol once the markets are live.
contract DeployWbethFixedBrokers is DeployBase {
  // live implementation, reused as-is
  address constant BROKER_IMPL = 0xf1db84c5788fb2174d61E1C98F962F56c224b128;

  address constant MOOLAH = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
  address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
  address constant RATE_CALCULATOR = 0xF81A3067ACF683B7f2f40a22bCF17c8310be2330;
  address constant ORACLE = 0xf3afD82A4071f272F403dC176916141f44E6c750; // MultiOracle
  address constant FACTORY = 0xce26859127d236a61f168d2d0905f77d7E286Ab2;

  address constant RELAYER_USD1 = 0x35720fcA79F33E3817479E0c6abFaD38ea1a9DaC; // -> Gauntlet x Lista USD1 Vault
  address constant RELAYER_U = 0x9348923C2f0AD218A8736Ab28cfAe7D93027E73f; // -> Gauntlet x Lista U Vault

  address constant ADMIN_TIMELOCK = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
  address constant MANAGER_SAFE = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  address constant PAUSER_ADDR = 0xEEfebb1546d88EA0909435DF6f615084DD3c5Bd8;
  address constant EMERGENCY_HUB = 0x4455E7aE8b0F5cDdFEfeF5CEfDFC62F51A8801DF; // EmergencySwitchHub
  address constant BOT_RATE = 0x91fC4BA20685339781888eCA3E9E1c12d40F0e13;
  address constant BATCH_UTILS = 0x458437d173A7d5b8E92b0DC5aF513584cAB4bf3D;

  address constant USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
  address constant U = 0xcE24439F2D9C6a2289F741120FE202248B666666;

  uint256 constant MAX_FIXED_LOAN_POSITIONS = 100;

  bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 constant MANAGER = keccak256("MANAGER");
  bytes32 constant BOT = keccak256("BOT");
  bytes32 constant PAUSER = keccak256("PAUSER");

  function run() public {
    uint256 pk = _deployerKey();
    address deployer = vm.addr(pk);
    console.log("Deployer:", deployer);
    console.log("Reusing broker impl:", BROKER_IMPL);

    // the reused impl must match this chain's wiring before anything is deployed
    require(address(LendingBroker(payable(BROKER_IMPL)).MOOLAH()) == MOOLAH, "impl/moolah-mismatch");
    require(LendingBroker(payable(BROKER_IMPL)).WBNB() == WBNB, "impl/wbnb-mismatch");
    require(LendingBroker(payable(BROKER_IMPL)).MIN_FIXED_TERM_APR() == 1005000000000000000000000000, "impl/min-apr");
    // each relayer must carry its broker's loan token, or addBroker rejects the broker at market creation
    require(IRelayerToken(RELAYER_USD1).token() == USD1, "relayer/not-USD1");
    require(IRelayerToken(RELAYER_U).token() == U, "relayer/not-U");

    vm.startBroadcast(pk);
    address bUSD1 = _deploy(deployer, RELAYER_USD1);
    address bU = _deploy(deployer, RELAYER_U);
    vm.stopBroadcast();

    _checkRoles(bUSD1, deployer);
    _checkRoles(bU, deployer);

    console.log("Broker (wBETH/USD1):", bUSD1);
    console.log("Broker (wBETH/U):", bU);
  }

  function _deploy(address deployer, address relayer_) internal returns (address) {
    LendingBroker b = LendingBroker(
      payable(
        address(
          new ERC1967Proxy(
            BROKER_IMPL,
            abi.encodeWithSelector(
              LendingBroker.initialize.selector,
              deployer, // admin
              deployer, // manager
              deployer, // bot
              deployer, // pauser
              RATE_CALCULATOR,
              MAX_FIXED_LOAN_POSITIONS,
              relayer_,
              ORACLE
            )
          )
        )
      )
    );

    // init sanity — ORACLE/RELAYER can never be corrected after this point
    require(address(b.ORACLE()) == ORACLE, "broker/oracle-mismatch");
    require(b.RELAYER() == relayer_, "broker/relayer-mismatch");
    require(b.rateCalculator() == RATE_CALCULATOR, "broker/rateCalculator-mismatch");
    require(address(b.MOOLAH()) == MOOLAH && b.WBNB() == WBNB, "broker/immutable-mismatch");
    require(b.maxFixedLoanPositions() == MAX_FIXED_LOAN_POSITIONS, "broker/maxpos-mismatch");
    require(Id.unwrap(b.MARKET_ID()) == bytes32(0), "broker/market-already-set");

    // governance holders; deployer keeps its roles for the remaining bootstrap steps
    b.grantRole(DEFAULT_ADMIN_ROLE, ADMIN_TIMELOCK);
    b.grantRole(MANAGER, MANAGER_SAFE);
    b.grantRole(PAUSER, PAUSER_ADDR);
    b.grantRole(PAUSER, EMERGENCY_HUB);
    b.grantRole(BOT, BOT_RATE);
    b.grantRole(BOT, BATCH_UTILS);
    // MarketFactory needs MANAGER for setMarketId / toggleLiquidationWhitelist at market creation
    b.grantRole(MANAGER, FACTORY);

    return address(b);
  }

  function _checkRoles(address broker, address deployer) internal view {
    LendingBroker b = LendingBroker(payable(broker));
    require(b.hasRole(DEFAULT_ADMIN_ROLE, ADMIN_TIMELOCK), "role/admin-timelock");
    require(b.hasRole(MANAGER, MANAGER_SAFE), "role/manager-safe");
    require(b.hasRole(MANAGER, FACTORY), "role/manager-factory");
    require(b.hasRole(PAUSER, PAUSER_ADDR), "role/pauser");
    require(b.hasRole(PAUSER, EMERGENCY_HUB), "role/pauser-emergency-hub");
    require(b.hasRole(BOT, BOT_RATE), "role/bot-rate");
    require(b.hasRole(BOT, BATCH_UTILS), "role/bot-batchutils");
    require(
      b.hasRole(DEFAULT_ADMIN_ROLE, deployer) &&
        b.hasRole(MANAGER, deployer) &&
        b.hasRole(BOT, deployer) &&
        b.hasRole(PAUSER, deployer),
      "role/deployer-dropped"
    );
  }
}

interface IRelayerToken {
  function token() external view returns (address);
}
