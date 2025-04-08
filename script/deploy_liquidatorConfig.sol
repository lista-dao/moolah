pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { Liquidator } from "liquidator/Liquidator.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { Id, MarketParams } from "moolah/interfaces/IMoolah.sol";

contract LiquidatorConfigDeploy is Script {
  using MarketParamsLib for MarketParams;
  Liquidator liquidator = Liquidator(payable(0x6a87C15598929B2db22cF68a9a0dDE5Bf297a59a));

  address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
  address BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
  address slisBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
  address ptClisBNB25apr = 0xE8F1C9804770e11Ab73395bE54686Ad656601E9e;
  address solvBTC = 0x4aae823a6a0b376De6A78e74eCC5b079d38cBCf7;
  address multiOracle = 0xf3afD82A4071f272F403dC176916141f44E6c750;
  address oracleAdapter = 0x21650E416dC6C89486B2E654c86cC2c36c597b58;
  address irm = 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c;
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
      oracle: oracleAdapter,
      irm: irm,
      lltv: lltv80
    });
    // collateral-ptClisBNB25apr loan-WBNB lltv-90%
    MarketParams memory ptClisBNB25aprParams = MarketParams({
      loanToken: WBNB,
      collateralToken: ptClisBNB25apr,
      oracle: oracleAdapter,
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
