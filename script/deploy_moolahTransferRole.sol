pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { Moolah } from "moolah/Moolah.sol";
import { MoolahVault } from "moolah-vault/MoolahVault.sol";

contract MoolahTransferRoleDeploy is Script {
  // todo
  Moolah moolah = Moolah(0x32A88180f2681fABB5AFF98F6A0284aeBfa05532);
  MoolahVault vault = MoolahVault(0x32A88180f2681fABB5AFF98F6A0284aeBfa05532);
  address feeRecipient = 0x34B504A5CF0fF41F8A480580533b6Dda687fa3Da;
  address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
  address manager = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  address pauser = 0xEEfebb1546d88EA0909435DF6f615084DD3c5Bd8;

  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant PAUSER = keccak256("PAUSER");

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // setup roles
    moolah.setFeeRecipient(feeRecipient);

    moolah.grantRole(DEFAULT_ADMIN_ROLE, admin);
    moolah.grantRole(MANAGER, manager);
    moolah.grantRole(PAUSER, pauser);

    moolah.revokeRole(PAUSER, deployer);
    moolah.revokeRole(MANAGER, deployer);
    moolah.revokeRole(DEFAULT_ADMIN_ROLE, deployer);

    vm.stopBroadcast();

    console.log("setup role done!");
  }
}
