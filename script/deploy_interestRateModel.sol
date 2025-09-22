pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy, ERC1967Utils } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { InterestRateModel } from "interest-rate-model/InterestRateModel.sol";
import { Moolah } from "moolah/Moolah.sol";
//import "forge-std/console.sol";

contract InterestRateModelDeploy is Script {
  address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
  address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
  address moolah_test = 0x4c26397D4ef9EEae55735a1631e69Da965eBC41A;

  bytes32 public constant BOT = keccak256("BOT");
  bytes32 public constant MANAGER = keccak256("MANAGER");

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy InterestRateModel implementation
    InterestRateModel impl = new InterestRateModel(moolah);
    console.log("InterestRateModel implementation: ", address(impl));

    // Deploy InterestRateModel proxy
    ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeWithSelector(impl.initialize.selector, admin));
    console.log("InterestRateModel proxy: ", address(proxy));

    vm.stopBroadcast();
    // simulate_upgrade();
  }

  function simulate_upgrade() public {
    vm.startPrank(0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253);
    InterestRateModel irmProxy = InterestRateModel(0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c);

    address newImpl = 0xBdB2CFa2B6c5f79dF6660Bf1291C124CEc443D33;

    irmProxy.upgradeToAndCall(newImpl, "");
    bytes memory data = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", newImpl, "");
    console.logBytes(data);

    irmProxy.grantRole(irmProxy.BOT(), 0x3995852eb0C4E8b1aA4cB31dDAC254ff199111ff);
    data = abi.encodeWithSelector(
      irmProxy.grantRole.selector,
      irmProxy.BOT(),
      0x3995852eb0C4E8b1aA4cB31dDAC254ff199111ff
    );
    console.logBytes(data);

    irmProxy.grantRole(irmProxy.BOT(), 0x85CE862C5BB61938FFcc97DA4A80C8aaE43C6A27);
    data = abi.encodeWithSelector(
      irmProxy.grantRole.selector,
      irmProxy.BOT(),
      0x85CE862C5BB61938FFcc97DA4A80C8aaE43C6A27
    );
    console.logBytes(data);

    irmProxy.grantRole(irmProxy.MANAGER(), 0x8d388136d578dCD791D081c6042284CED6d9B0c6);
    data = abi.encodeWithSelector(
      irmProxy.grantRole.selector,
      irmProxy.MANAGER(),
      0x8d388136d578dCD791D081c6042284CED6d9B0c6
    );
    console.logBytes(data);

    vm.stopPrank();
  }
}
