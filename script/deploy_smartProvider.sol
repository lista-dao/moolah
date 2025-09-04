pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { StableSwapPoolInfo } from "src/dex/StableSwapPoolInfo.sol";
import { StableSwapLPCollateral } from "src/dex/StableSwapLPCollateral.sol";
import { SmartProvider } from "src/provider/SmartProvider.sol";

contract SmartProviderDeploy is Script {
  address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
  address lpCollateral = 0x4C20518cB2f98f02e9eB375D0f3173035723B133;
  address dex = 0x97f11B85D6B3f054f5e8Ca025C55d99F419Ad3be;
  address dexInfo = 0xEce6FF19D7b1d1de5cb11cF42F5F1463a7F73b6f;
  address oracle = 0x79e9675cDe605Ef9965AbCE185C5FD08d0DE16B1;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_TESTNET");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // deploy_dexInfo(deployer);

    // Deploy SmartProvider
    SmartProvider impl = new SmartProvider(moolah, lpCollateral);
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, deployer, dex, dexInfo, oracle)
    );

    vm.stopBroadcast();
  }

  function deploy_dexInfo(address admin) public returns (address) {
    StableSwapPoolInfo impl = new StableSwapPoolInfo();

    ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeWithSelector(impl.initialize.selector, admin));
    console.log("StableSwapPoolInfo proxy: ", address(proxy));
    return address(proxy);
  }

  function deploy_lpCollateral(
    address _admin,
    address _minter,
    string memory _name,
    string memory _symbol
  ) public returns (address) {
    StableSwapLPCollateral impl = new StableSwapLPCollateral(moolah);

    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, _admin, _minter, _name, _symbol)
    );
    console.log("StableSwapLPCollateral proxy: ", address(proxy));
    return address(proxy);
  }
}
