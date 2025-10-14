pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { LendingFeeRecipient } from "revenue/LendingFeeRecipient.sol";

contract LendingFeeRecipientDeploy is Script {
  address moolah = 0xf820fB4680712CD7263a0D3D024D5b5aEA82Fd70;
  address vault = 0x57134a64B7cD9F9eb72F8255A671F5Bf2fe3E2d0;
  address marketFeeRecipient = 0x34B504A5CF0fF41F8A480580533b6Dda687fa3Da;
  address vaultFeeRecipient = 0xea55952a51ddd771d6eBc45Bd0B512276dd0b866;
  address bot = 0x6F28FeC449dbd2056b76ac666350Af8773E03873;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy LendingFeeRecipient implementation
    LendingFeeRecipient impl = new LendingFeeRecipient();
    console.log("LendingFeeRecipient implementation: ", address(impl));

    // Deploy LendingFeeRecipient proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, moolah, deployer, deployer, bot, deployer, deployer)
    );
    console.log("LendingFeeRecipient proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}
