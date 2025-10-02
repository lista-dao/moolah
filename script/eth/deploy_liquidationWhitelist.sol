pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { Moolah } from "moolah/Moolah.sol";
import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";

contract LiquidatorConfigDeploy is Script {
  using MarketParamsLib for MarketParams;
  Moolah moolah = Moolah(0xf820fB4680712CD7263a0D3D024D5b5aEA82Fd70);

  address liquidator = 0x5Bf5c3B5f5c29dBC647d2557Cc22B00ED29f301C;
  address bot = 0x08E83A96F4dA5DecC0e6E9084dDe049A3E84ca04;
  address publicLiquidator = 0x796302e041d1715a8b1f16Fd7d7CBA38bb031DE5;

  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant CURATOR = keccak256("CURATOR"); // manager role
  bytes32 public constant ALLOCATOR = keccak256("ALLOCATOR"); // manager role

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    vm.startBroadcast(deployerPrivateKey);

    Id[] memory ids = new Id[](6);
    ids[0] = Id.wrap(0xed7856d2ed4fb7f2e8e989065024bdd16af4f33390be824430ce723846531c9a);
    ids[1] = Id.wrap(0x0257ba287015a4f000e29d5a1f9d2bb3b760bee37ceff3be1d975f1d66ef4a7d);
    ids[2] = Id.wrap(0x79b9bd5366b4d509067e4ea493b3e3d1e710675b6ceb99741afd327404690639);
    ids[3] = Id.wrap(0x628c644de87ac4029a48b1b2d5c6e19b9daae2042eaceace6048a6c2d82b050a);
    ids[4] = Id.wrap(0x739864c203036d02a8a7479486578ac312d8e4cf18c66f0ca463375e8560edf0);
    ids[5] = Id.wrap(0x3cb7ba8dbe4862720205123e8af686a746e4230eca1c63f13db7acdb96801b7d);

    address[][] memory accountInfo = new address[][](6);
    address[] memory liquidators = new address[](3);
    liquidators[0] = liquidator;
    liquidators[1] = bot;
    liquidators[2] = publicLiquidator;

    accountInfo[0] = liquidators;
    accountInfo[1] = liquidators;
    accountInfo[2] = liquidators;
    accountInfo[3] = liquidators;
    accountInfo[4] = liquidators;
    accountInfo[5] = liquidators;
    // set market whitelist
    moolah.batchToggleLiquidationWhitelist(ids, accountInfo, true);

    vm.stopBroadcast();

    console.log("vault config done!");
  }
}
