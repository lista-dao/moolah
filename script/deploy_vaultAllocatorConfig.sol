pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";

import { VaultAllocator, FlowCapsConfig, FlowCaps, Id, MarketParams } from "vault-allocator/VaultAllocator.sol";

contract LiquidatorDeploy is Script {
  using MarketParamsLib for MarketParams;
  VaultAllocator allocator = VaultAllocator(0x9ECF66f016FCaA853FdA24d223bdb4276E5b524a);
  address vault = 0xfa27f172e0b6ebcEF9c51ABf817E2cb142FbE627;

  address USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
  address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
  address BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;

  address multiOracle = 0xf3afD82A4071f272F403dC176916141f44E6c750;

  address irm = 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c;

  uint256 lltv70 = 70 * 1e16;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    allocator.setFee(vault, 0.01 ether);

    // collateral-BTCB loan-USD1 lltv-70%
    MarketParams memory test1 = MarketParams({
      loanToken: USD1,
      collateralToken: BTCB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv70
    });
    // collateral-WBNB loan-USD1 lltv-70%
    MarketParams memory test2 = MarketParams({
      loanToken: USD1,
      collateralToken: WBNB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv70
    });

    FlowCapsConfig memory config_btcb = FlowCapsConfig({
      id: test1.id(),
      caps: FlowCaps({ maxIn: 75000000000000000000000000, maxOut: 75000000000000000000000000 })
    });

    FlowCapsConfig memory config_wbnb = FlowCapsConfig({
      id: test2.id(),
      caps: FlowCaps({ maxIn: 75000000000000000000000000, maxOut: 75000000000000000000000000 })
    });

    FlowCapsConfig[] memory config = new FlowCapsConfig[](2);
    config[0] = config_btcb;
    config[1] = config_wbnb;

    allocator.setFlowCaps(vault, config);

    vm.stopBroadcast();
  }
}
