pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { LendingFeeRecipient } from "revenue/LendingFeeRecipient.sol";

contract LendingFeeRecipientDeploy is Script {
  LendingFeeRecipient lendingFeeRecipient = LendingFeeRecipient(0xd10a024602E042dcb9C19e21682c3b896c8B0d30);
  address vault = 0x1A9BeE2F5c85F6b4a0221fB1C733246AF5306Ae3;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    lendingFeeRecipient.addVault(vault);
    lendingFeeRecipient.setMarketFeeRecipient(address(lendingFeeRecipient));
    lendingFeeRecipient.setVaultFeeRecipient(address(lendingFeeRecipient));

    vm.stopBroadcast();
  }
}
