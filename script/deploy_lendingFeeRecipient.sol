pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { LendingFeeRecipient } from "revenue/LendingFeeRecipient.sol";

contract LendingFeeRecipientDeploy is Script {
  address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
  address vault = 0x57134a64B7cD9F9eb72F8255A671F5Bf2fe3E2d0;
  address marketFeeRecipient = 0x34B504A5CF0fF41F8A480580533b6Dda687fa3Da;
  address vaultFeeRecipient = 0xea55952a51ddd771d6eBc45Bd0B512276dd0b866;
  address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
  address manager = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
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
      abi.encodeWithSelector(
        impl.initialize.selector,
        moolah,
        deployer,
        deployer,
        bot,
        marketFeeRecipient,
        vaultFeeRecipient
      )
    );
    console.log("LendingFeeRecipient proxy: ", address(proxy));

    LendingFeeRecipient lendingFeeRecipient = LendingFeeRecipient(address(proxy));
    lendingFeeRecipient.addVault(vault);

    lendingFeeRecipient.grantRole(lendingFeeRecipient.DEFAULT_ADMIN_ROLE(), admin);
    lendingFeeRecipient.grantRole(lendingFeeRecipient.MANAGER(), manager);

    lendingFeeRecipient.revokeRole(lendingFeeRecipient.MANAGER(), deployer);
    lendingFeeRecipient.revokeRole(lendingFeeRecipient.DEFAULT_ADMIN_ROLE(), deployer);

    console.log("setup role done!");

    vm.stopBroadcast();
  }
}
