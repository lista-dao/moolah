pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { PTLinearDiscountOracle } from "../src/oracle/PTLinearDiscountOracle.sol";

contract PTLinearDiscountOracleDeploy is Script {
  address PTUSR27NOV2025 = 0x4a3846d069B800343D53e72B80a644Bb496D9aB2;
  address PTSIMASTABILITYPOOL2025 = 0xd76Ec0A96eAffe1cCa33313352dEdA1CD3Cfa7EE;
  address USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
  address USDT = 0x55d398326f99059fF775485246999027B3197955;
  address multiOracle = 0xf3afD82A4071f272F403dC176916141f44E6c750;
  address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253; // timelock
  address PTUSR27NOV2025Oracle = 0x17DD866F185C2e11fA1D8ee4c8fcFa9B568819A7;
  address PTSIMASTABILITYPOOL2025Oracle = 0xBD69Af22Cc3F22E3830ef956C344cebb8F090554;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);
    vm.startBroadcast(deployerPrivateKey);

    deploy_PTOracle(admin, PTUSR27NOV2025, USD1, PTUSR27NOV2025Oracle, multiOracle);
    deploy_PTOracle(admin, PTUSR27NOV2025, USDT, PTUSR27NOV2025Oracle, multiOracle);
    deploy_PTOracle(admin, PTSIMASTABILITYPOOL2025, USD1, PTSIMASTABILITYPOOL2025Oracle, multiOracle);
    deploy_PTOracle(admin, PTSIMASTABILITYPOOL2025, USDT, PTSIMASTABILITYPOOL2025Oracle, multiOracle);

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
