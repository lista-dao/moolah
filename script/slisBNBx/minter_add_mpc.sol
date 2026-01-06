pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { SlisBNBxMinter } from "src/utils/SlisBNBxMinter.sol";

contract StableSwapLPCollateralDeploy is Script {
  SlisBNBxMinter minter = SlisBNBxMinter(0x2959c423bfe5Cc6E41516599D982A29C0773F11a);

  address mpc1 = 0xD57E5321e67607Fab38347D96394e0E58509C506;
  uint256 cap1 = 115792089237316195423570985008687907853269984665640564039457584007913129639935;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    minter.addMPCWallet(mpc1, cap1);
    console.log("Added MPC wallet: ", mpc1);

    vm.stopBroadcast();
  }
}
