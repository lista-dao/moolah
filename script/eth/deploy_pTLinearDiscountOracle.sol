pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { PTLinearDiscountOracle } from "../../src/oracle/PTLinearDiscountOracle.sol";

contract PTLinearDiscountOracleDeploy is Script {
  address ptToken = 0x62C6E813b9589C3631Ba0Cdb013acdB8544038B7;
  address USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
  address multiOracle = 0xA64FE284EB8279B9b63946DD51813b0116099301;
  address admin = 0xa18ae79AEDA3e711E0CD64cfe1Cd06402d400D61; // timelock
  address ptOracle = 0xd386A68d9EB8d4E6E7D18886634b30D807B6cc9b;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    deploy_PTOracle(deployer, ptToken, USD1, ptOracle, multiOracle);

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
