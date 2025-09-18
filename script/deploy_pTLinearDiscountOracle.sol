pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { PTLinearDiscountOracle } from "../src/oracle/PTLinearDiscountOracle.sol";

contract PTLinearDiscountOracleDeploy is Script {
  address ptToken = 0x31E88bF4AC49EEf6711756D141F1A63E78F9F665;
  address USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
  address USDT = 0x55d398326f99059fF775485246999027B3197955;
  address multiOracle = 0xf3afD82A4071f272F403dC176916141f44E6c750;
  address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253; // timelock
  address ptOracle = 0xB75Cc06b61a0Dc726728569ab06f13ac1623d33f;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    deploy_PTOracle(admin, ptToken, USD1, ptOracle, multiOracle);
    deploy_PTOracle(admin, ptToken, USDT, ptOracle, multiOracle);

    vm.stopBroadcast();
  }

  function deploy_PTOracle(
    address admin,
    address collateral,
    address loan,
    address collateralOracle,
    address loanOracle
  ) public {
    // Deploy implementation
    PTLinearDiscountOracle impl = new PTLinearDiscountOracle();
    console.log("PTLinearDiscountOracle implementation: ", address(impl));
    // Deploy OracleAdaptor proxy
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, admin, collateral, collateralOracle, loan, loanOracle)
    );
    console.log("PTLinearDiscountOracle proxy: ", address(proxy));
  }
}
