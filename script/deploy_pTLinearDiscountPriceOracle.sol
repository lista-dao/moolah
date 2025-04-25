pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { PTLinearDiscountPriceOracle } from "../src/oracle/PTLinearDiscountPriceOracle.sol";

contract PTLinearDiscountPriceOracleDeploy is Script {
  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy implementation
    PTLinearDiscountPriceOracle impl = new PTLinearDiscountPriceOracle();
    console.log("PTLinearDiscountPriceOracle implementation: ", address(impl));

    address ptClisBNB30OCT2025 = 0xb84cEC1Ab2af11b530ae0d8594B1493556be49Cd;
    address discountOracle = 0xDF1dED2EA9dEa5456533A0C92f6EF7d6F2ACc1c0;
    address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address multiOracle = 0xf3afD82A4071f272F403dC176916141f44E6c750;
    address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253; // timelock

    // Deploy OracleAdaptor proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, admin, ptClisBNB30OCT2025, discountOracle, WBNB, multiOracle)
    );
    console.log("PTLinearDiscountPriceOracle proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}
