pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { InterestRateModel } from "interest-rate-model/InterestRateModel.sol";

contract IrmTransferRoleDeploy is Script {
  InterestRateModel irm = InterestRateModel(0x8b7d334d243b74D63C4b963893267A0F5240F990);
  address admin = 0xa18ae79AEDA3e711E0CD64cfe1Cd06402d400D61;
  address manager = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  address allocator = 0x85CE862C5BB61938FFcc97DA4A80C8aaE43C6A27;
  address bot = 0xEEfebb1546d88EA0909435DF6f615084DD3c5Bd8;

  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant BOT = keccak256("BOT");

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // setup roles
    irm.grantRole(DEFAULT_ADMIN_ROLE, admin);
    irm.grantRole(MANAGER, manager);
    irm.grantRole(BOT, bot);
    irm.grantRole(BOT, allocator);

    irm.revokeRole(DEFAULT_ADMIN_ROLE, deployer);

    vm.stopBroadcast();

    console.log("setup role done!");
  }
}
