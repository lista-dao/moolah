// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { LendingBroker } from "../../src/broker/LendingBroker.sol";

contract DeployLendingBroker is Script {
  address moolah;
  address interestRelayer;
  address oracle;
  address wbnb;
  address timelock;
  address manager;
  address pauser;
  address bot;
  address rateCalculator;
  uint256 maxFixedLoanPositions;

  function setUp() public {
    moolah = vm.envAddress("MOOLAH");
    interestRelayer = vm.envAddress("INTEREST_RELAYER");
    oracle = vm.envAddress("ORACLE");
    wbnb = vm.envOr("WBNB", address(0));
    timelock = vm.envAddress("TIMELOCK");
    manager = vm.envAddress("MANAGER");
    pauser = vm.envAddress("PAUSER");
    bot = vm.envAddress("BOT");
    rateCalculator = vm.envAddress("RATE_CALCULATOR");
    maxFixedLoanPositions = vm.envUint("MAX_FIXED_LOAN_POSITIONS");
  }

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy LendingBroker implementation
    LendingBroker impl = new LendingBroker(moolah, interestRelayer, oracle, wbnb);
    console.log("LendingBroker implementation: ", address(impl));

    // Deploy LendingBroker proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(
        impl.initialize.selector,
        deployer,
        deployer,
        bot,
        pauser,
        rateCalculator,
        maxFixedLoanPositions
      )
    );
    console.log("LendingBroker proxy: ", address(proxy));

    // grant roles to manager and admin
    bytes32 MANAGER = keccak256("MANAGER");
    bytes32 DEFAULT_ADMIN_ROLE = 0x0000000000000000000000000000000000000000000000000000000000000000;
    LendingBroker(payable(address(proxy))).grantRole(MANAGER, manager);
    LendingBroker(payable(address(proxy))).grantRole(DEFAULT_ADMIN_ROLE, timelock);

    vm.stopBroadcast();
  }
}
