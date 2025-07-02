pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";

contract MoolahVaultDeploy is Script {
  address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;

  address AB = 0x95034f653D5D161890836Ad2B6b8cc49D14e029a;
  address B = 0x6bdcCe4A559076e37755a78Ce0c06214E59e4444;
  address B2 = 0x783c3f003f172c6Ac5AC700218a357d2D66Ee2a2;

  MoolahVault impl = MoolahVault(0xAaB62068D44C3b4D4214fb1d4645c071D978a777);

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    address abProxy = deployVault(deployer, AB, "AB Vault", "AB");
    address bProxy = deployVault(deployer, B, "B Vault", "B");
    address b2Proxy = deployVault(deployer, B2, "B2 Vault", "B2");

    console.log("AB Vault proxy: ", abProxy);
    console.log("B Vault proxy: ", bProxy);
    console.log("B2 Vault proxy: ", b2Proxy);
    vm.stopBroadcast();
  }

  function deployVault(
    address deployer,
    address asset,
    string memory name,
    string memory symbol
  ) internal returns (address) {
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, deployer, asset, name, symbol)
    );
    return address(proxy);
  }
}
