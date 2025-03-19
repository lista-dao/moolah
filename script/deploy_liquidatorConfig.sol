pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { Liquidator } from "liquidator/Liquidator.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { Id, MarketParams } from "moolah/interfaces/IMoolah.sol";

contract LiquidatorConfigDeploy is Script {
  using MarketParamsLib for MarketParams;
  // todo
  Liquidator liquidator = Liquidator(payable(0x65c559d41904a43cCf7bd9BF7B5B34896a39EBea));

  address WBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;
  address BTCB = 0x4BB2f2AA54c6663BFFD37b54eCd88eD81bC8B3ec;
  address slisBNB = 0xCc752dC4ae72386986d011c2B485be0DAd98C744;
  address ptClisBNB25apr = 0x0A9498fb5B811E1AC4369bcdce427f7a3D2816eB;
  address solvBTC = 0xB1E63330f4718772CF939128d222389b30C70cF2;
  address multiOracle = 0x002d038Ada9BEF58e23587348cBcd75075514FD2;
  address irm = 0x803da834B2Ff96D9055F1057dd8907AD776bEAA1;
  address pair = 0x111111125421cA6dc452d289314280a0f8842A65;

  uint256 lltv70 = 70 * 1e16;
  uint256 lltv80 = 80 * 1e16;
  uint256 lltv90 = 90 * 1e16;

  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant CURATOR = keccak256("CURATOR"); // manager role
  bytes32 public constant ALLOCATOR = keccak256("ALLOCATOR"); // manager role

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    // collateral-BTCB loan-WBNB lltv-80%
    MarketParams memory BTCBParams = MarketParams({
      loanToken: WBNB,
      collateralToken: BTCB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv80
    });
    // collateral-slisBNB loan-WBNB lltv-80%
    MarketParams memory slisBNBParams = MarketParams({
      loanToken: WBNB,
      collateralToken: slisBNB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv80
    });
    // collateral-ptClisBNB25apr loan-WBNB lltv-90%
    MarketParams memory ptClisBNB25aprParams = MarketParams({
      loanToken: WBNB,
      collateralToken: ptClisBNB25apr,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv90
    });
    // collateral-solvBTC loan-WBNB lltv-70%
    MarketParams memory solvBTCParams = MarketParams({
      loanToken: WBNB,
      collateralToken: solvBTC,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv70
    });

    vm.startBroadcast(deployerPrivateKey);

    // set token whitelist
    liquidator.setTokenWhitelist(WBNB, true);
    liquidator.setTokenWhitelist(BTCB, true);
    liquidator.setTokenWhitelist(slisBNB, true);
    liquidator.setTokenWhitelist(ptClisBNB25apr, true);
    liquidator.setTokenWhitelist(solvBTC, true);

    Id BTCBId = BTCBParams.id();
    Id slisBNBId = slisBNBParams.id();
    Id ptClisBNB25aprId = ptClisBNB25aprParams.id();
    Id solvBTCId = solvBTCParams.id();

    // set market whitelist
    liquidator.setMarketWhitelist(Id.unwrap(BTCBId), true);
    liquidator.setMarketWhitelist(Id.unwrap(slisBNBId), true);
    liquidator.setMarketWhitelist(Id.unwrap(ptClisBNB25aprId), true);
    liquidator.setMarketWhitelist(Id.unwrap(solvBTCId), true);

    // set pair whitelist
    liquidator.setPairWhitelist(pair, true);

    vm.stopBroadcast();

    console.log("vault config done!");
  }
}
