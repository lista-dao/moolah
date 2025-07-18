pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { PTLinearDiscountOracle } from "../src/oracle/PTLinearDiscountOracle.sol";

contract PTLinearDiscountOracleDeploy is Script {
  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    // Deploy implementation
    PTLinearDiscountOracle impl = new PTLinearDiscountOracle();
    console.log("PTLinearDiscountOracle implementation: ", address(impl));

    address ptToken = 0xB901c7A2D2Bc05D8B7e7eE4F7Fcf72CAaABd2F49;
    address ptOracle = 0x0f34c129EFA6436c46Ca95a1cA41f995A61d1d2b;
    address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253; // timelock
    address loanAsset = 0x55d398326f99059fF775485246999027B3197955;
    address multiOracle = 0xf3afD82A4071f272F403dC176916141f44E6c750;
    address loanTokenOracle = multiOracle;

    // Deploy OracleAdaptor proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, admin, ptToken, ptOracle, loanAsset, loanTokenOracle)
    );
    console.log("PTLinearDiscountOracle proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}
