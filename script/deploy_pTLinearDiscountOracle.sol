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

    address ptSusde26Jun2025 = 0xDD809435ba6c9d6903730f923038801781cA66ce;
    address ptSusde26Jun2025Oracle = 0x2AD358a2972aD56937A18b5D90A4F087C007D08d;
    address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253; // timelock
    address loanAsset = 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34; // USDe CA
    address multiOracle = 0xf3afD82A4071f272F403dC176916141f44E6c750;
    address loanTokenOracle = multiOracle;

    // Deploy OracleAdaptor proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(
        impl.initialize.selector,
        admin,
        ptSusde26Jun2025,
        ptSusde26Jun2025Oracle,
        loanAsset,
        loanTokenOracle
      )
    );
    console.log("PTLinearDiscountOracle proxy: ", address(proxy));

    vm.stopBroadcast();
  }
}
