pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { SlisBNBProvider } from "../src/provider/SlisBNBProvider.sol";

contract InterestRateModelDeploy is Script {
  address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
  address slisBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
  address stakeManager = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;
  address clisBNB = 0x4b30fcAA7945fE9fDEFD2895aae539ba102Ed6F6;

  address mpc = 0xD57E5321e67607Fab38347D96394e0E58509C506;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy SlisBNBProvider implementation
    SlisBNBProvider impl = new SlisBNBProvider(moolah, slisBNB, stakeManager, clisBNB);
    console.log("SlisBNBProvider implementation: ", address(impl));

    // Deploy InterestRateModel proxy
    ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeWithSelector(impl.initialize.selector, deployer, deployer, 0.97 ether));
    console.log("SlisBNBProvider proxy: ", address(proxy));

    SlisBNBProvider(address(proxy)).addMPCWallet(mpc, type(uint256).max);

    vm.stopBroadcast();
  }
}
