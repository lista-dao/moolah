// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { LendingBroker } from "../../src/broker/LendingBroker.sol";

/// @notice Deploy LendingBrokers for XAUT 定期 markets (SmartCollateral).
///         - 3 brokers: USDT&USDC LP collateral → USDT / USD1 / U
///         - 4 brokers: BNB&slisBNB LP collateral → USDT / USD1 / U / WBNB
contract DeployXautBrokers is DeployBase {
  // ── core ──────────────────────────────────────────────────────────────
  address constant MOOLAH = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
  address constant TIMELOCK = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
  address constant MANAGER = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  address constant PAUSER = 0xEEfebb1546d88EA0909435DF6f615084DD3c5Bd8;
  address constant BOT = 0x91fC4BA20685339781888eCA3E9E1c12d40F0e13;
  address constant RATE_CALCULATOR = 0xF81A3067ACF683B7f2f40a22bCF17c8310be2330;

  // ── interest relayers ─────────────────────────────────────────────────
  address constant RELAYER_USDT = 0x2A119f506ce71cF427D5ae88540fAec580840587;
  address constant RELAYER_USD1 = 0x35720fcA79F33E3817479E0c6abFaD38ea1a9DaC;
  address constant RELAYER_U = 0x9348923C2f0AD218A8736Ab28cfAe7D93027E73f;
  address constant RELAYER_BNB = 0xF2D18e9201d1fE752e3115c029F0f5Ef2Ec2bdbe;

  // ── SmartProvider oracles (used as oracle for SmartCollateral markets) ─
  address constant SP_USDT_USDC = 0x5fD3971104cF3bAB1dC89EF904Da26F54f75C06B;
  address constant SP_BNB_SLISBNB = 0xC3be83DE4b19aFC4F6021Ea5011B75a3542024dE;

  uint256 constant MAX_FIXED_LOAN_POSITIONS = 100;

  bytes32 constant MANAGER_ROLE = keccak256("MANAGER");
  bytes32 constant DEFAULT_ADMIN_ROLE = 0x0000000000000000000000000000000000000000000000000000000000000000;

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // ── USDT&USDC LP collateral brokers ──────────────────────────────
    _deployBroker("USDT_USDC_LP/USDT", RELAYER_USDT, SP_USDT_USDC, deployer);
    _deployBroker("USDT_USDC_LP/USD1", RELAYER_USD1, SP_USDT_USDC, deployer);
    _deployBroker("USDT_USDC_LP/U", RELAYER_U, SP_USDT_USDC, deployer);

    // ── BNB&slisBNB LP collateral brokers ────────────────────────────
    _deployBroker("BNB_slisBNB_LP/USDT", RELAYER_USDT, SP_BNB_SLISBNB, deployer);
    _deployBroker("BNB_slisBNB_LP/USD1", RELAYER_USD1, SP_BNB_SLISBNB, deployer);
    _deployBroker("BNB_slisBNB_LP/U", RELAYER_U, SP_BNB_SLISBNB, deployer);
    _deployBroker("BNB_slisBNB_LP/WBNB", RELAYER_BNB, SP_BNB_SLISBNB, deployer);

    vm.stopBroadcast();
  }

  function _deployBroker(string memory label, address relayer, address oracle, address deployer) internal {
    // Deploy implementation
    LendingBroker impl = new LendingBroker(MOOLAH, address(0));
    console.log(string.concat("LendingBroker(", label, ") impl: "), address(impl));

    // Deploy proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(
        impl.initialize.selector,
        deployer,
        deployer,
        BOT,
        PAUSER,
        RATE_CALCULATOR,
        MAX_FIXED_LOAN_POSITIONS
      )
    );
    console.log(string.concat("LendingBroker(", label, ") proxy: "), address(proxy));

    // Grant roles
    LendingBroker broker = LendingBroker(payable(address(proxy)));
    broker.grantRole(MANAGER_ROLE, MANAGER);
    broker.grantRole(DEFAULT_ADMIN_ROLE, TIMELOCK);
  }
}
