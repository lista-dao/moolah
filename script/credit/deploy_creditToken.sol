pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { CreditToken } from "src/utils/CreditToken.sol";

contract CreditTokenDeploy is Script {
  address moolah_testnet = 0x4c26397D4ef9EEae55735a1631e69Da965eBC41A;
  address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
  address bot = 0x6dD696c8DBa8764D0e5fD914A470FD5e780D0D12;

  bytes32 public constant BOT = keccak256("BOT");

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_TESTNET");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy CreditToken implementation
    CreditToken impl = new CreditToken();
    console.log("CreditToken implementation: ", address(impl));

    address[] memory transferers = new address[](1);
    transferers[0] = moolah;

    // Deploy Moolah proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(
        impl.initialize.selector,
        deployer,
        deployer,
        deployer,
        transferers,
        "Lista Credit Token",
        "lisCredit"
      )
    );
    console.log("CreditToken proxy: ", address(proxy));

    // grant BOT role to bot address
    CreditToken(address(proxy)).grantRole(BOT, bot);

    vm.stopBroadcast();
  }
}
