pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { Liquidator } from "liquidator/Liquidator.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { Id, MarketParams } from "moolah/interfaces/IMoolah.sol";

contract LiquidatorConfigDeploy is Script {
  using MarketParamsLib for MarketParams;
  Liquidator liquidator = Liquidator(payable(0x5Bf5c3B5f5c29dBC647d2557Cc22B00ED29f301C));

  address oneInch = 0x111111125421cA6dc452d289314280a0f8842A65;

  address USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
  address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
  address WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
  address wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
  address wBETH = 0xa2E3356610840701BDf5611a53974510Ae27E2e1;
  address PTUSDe27NOV2025 = 0x62C6E813b9589C3631Ba0Cdb013acdB8544038B7;
  address cbBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

  address bot = 0x08E83A96F4dA5DecC0e6E9084dDe049A3E84ca04;

  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant BOT = keccak256("BOT");
  bytes32 public constant CURATOR = keccak256("CURATOR"); // manager role
  bytes32 public constant ALLOCATOR = keccak256("ALLOCATOR"); // manager role

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    vm.startBroadcast(deployerPrivateKey);

    // set roles
    liquidator.grantRole(BOT, bot);

    // set token whitelist
    liquidator.setTokenWhitelist(USD1, true);
    liquidator.setTokenWhitelist(WETH, true);
    liquidator.setTokenWhitelist(WBTC, true);
    liquidator.setTokenWhitelist(wstETH, true);
    liquidator.setTokenWhitelist(wBETH, true);
    liquidator.setTokenWhitelist(PTUSDe27NOV2025, true);
    liquidator.setTokenWhitelist(cbBTC, true);

    bytes32[] memory ids = new bytes32[](6);
    ids[0] = 0xed7856d2ed4fb7f2e8e989065024bdd16af4f33390be824430ce723846531c9a;
    ids[1] = 0x0257ba287015a4f000e29d5a1f9d2bb3b760bee37ceff3be1d975f1d66ef4a7d;
    ids[2] = 0x79b9bd5366b4d509067e4ea493b3e3d1e710675b6ceb99741afd327404690639;
    ids[3] = 0x628c644de87ac4029a48b1b2d5c6e19b9daae2042eaceace6048a6c2d82b050a;
    ids[4] = 0x739864c203036d02a8a7479486578ac312d8e4cf18c66f0ca463375e8560edf0;
    ids[5] = 0x3cb7ba8dbe4862720205123e8af686a746e4230eca1c63f13db7acdb96801b7d;

    // set market whitelist
    liquidator.batchSetMarketWhitelist(ids, true);

    // set pair whitelist
    liquidator.setPairWhitelist(oneInch, true);

    vm.stopBroadcast();

    console.log("vault config done!");
  }
}
