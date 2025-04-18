// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { OracleAdaptor } from "../../src/oracle/OracleAdaptor.sol";
import { ERC20Mock } from "../../src/moolah/mocks/ERC20Mock.sol";
import { IStakeManager } from "../../src/oracle/interfaces/IStakeManager.sol";
import { PTOracleType, PTOracleConfig, ILinearDiscountOracle } from "../../src/oracle/interfaces/IPTOracle.sol";
import { IOracle, TokenConfig } from "../../src/moolah/interfaces/IOracle.sol";

interface IPTExpiry {
  function expiry() external view returns (uint256);
}

contract OracleAdaptorTest is Test {
  bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

  OracleAdaptor oracleAdaptor;

  address proxyAddress = 0x21650E416dC6C89486B2E654c86cC2c36c597b58; // Mainnet OracleAdaptor
  address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
  address slisBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
  address ptClisBNB25apr = 0xE8F1C9804770e11Ab73395bE54686Ad656601E9e;
  address ptSusde26Jun2025 = 0xDD809435ba6c9d6903730f923038801781cA66ce;
  address ptSusde26Jun2025Oracle = 0x2AD358a2972aD56937A18b5D90A4F087C007D08d;

  address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253; // timelock
  address manager = address(0x01);

  function setUp() public {
    vm.createSelectFork("https://bsc-dataseed.bnbchain.org");

    // Test upgrade
    OracleAdaptor impl = new OracleAdaptor();
    address newImlp = address(impl);
    address oldImpl = 0x274Cf42caf813537A81708E5a26B7c5760eDB517;
    vm.startPrank(admin);
    UUPSUpgradeable proxy = UUPSUpgradeable(proxyAddress);
    assertEq(getImplementation(proxyAddress), oldImpl);
    proxy.upgradeToAndCall(newImlp, bytes(""));
    assertEq(getImplementation(proxyAddress), newImlp);
    vm.stopPrank();

    oracleAdaptor = OracleAdaptor(proxyAddress);

    assertEq(oracleAdaptor.assetMap(address(ptClisBNB25apr)), WBNB);
    assertEq(oracleAdaptor.assetMap(address(ptSusde26Jun2025)), address(0));
    (PTOracleType type_, address oracle_) = oracleAdaptor.ptOracles(ptSusde26Jun2025);
    assertEq(uint256(type_), 0); // NONE
    assertEq(oracle_, address(0));

    // Add manager
    vm.prank(admin);
    oracleAdaptor.grantRole(keccak256("MANAGER"), manager);
    assertTrue(oracleAdaptor.hasRole(keccak256("MANAGER"), manager));
  }

  function test_peek_slisBnb() public {
    vm.mockCall(
      address(oracleAdaptor.RESILIENT_ORACLE()),
      abi.encodeWithSelector(IOracle.peek.selector, oracleAdaptor.WBNB()),
      abi.encode(uint256(62377900546)) // returns $623.77900546
    );
    vm.mockCall(
      address(oracleAdaptor.STAKE_MANAGER()),
      abi.encodeWithSelector(IStakeManager.convertSnBnbToBnb.selector, uint256(1e10)),
      abi.encode(uint256(10270000000)) // 1.027
    );
    uint256 price = oracleAdaptor.peek(oracleAdaptor.SLISBNB());
    uint256 expected = uint256(62377900546 * 10270000000) / 1e10;
    assertEq(price, expected);
  }

  function test_peek_ptClisBnb() public {
    vm.mockCall(
      address(oracleAdaptor.RESILIENT_ORACLE()),
      abi.encodeWithSelector(IOracle.peek.selector, WBNB),
      abi.encode(uint256(62377900546)) // returns $623.77900546
    );
    uint256 price = oracleAdaptor.peek(WBNB);
    assertEq(price, 62377900546);

    price = oracleAdaptor.peek(address(ptClisBNB25apr));
    assertEq(price, 62377900546);
  }

  function test_config_ptOracle() public {
    vm.expectRevert();
    oracleAdaptor.configPtOracle(ptSusde26Jun2025, PTOracleType.LINEAR_DISCOUNT, ptSusde26Jun2025Oracle);
    vm.prank(manager);
    oracleAdaptor.configPtOracle(ptSusde26Jun2025, PTOracleType.LINEAR_DISCOUNT, ptSusde26Jun2025Oracle);

    (PTOracleType type_, address oracle_) = oracleAdaptor.ptOracles(ptSusde26Jun2025);
    assertEq(uint256(type_), 1); // LINEAR_DISCOUNT
    assertEq(oracle_, ptSusde26Jun2025Oracle);
  }

  function test_peek_ptSusde26Jun2025() public {
    test_config_ptOracle();

    uint256 price = oracleAdaptor.peek(ptSusde26Jun2025);
    uint256 maturity = IPTExpiry(ptSusde26Jun2025).expiry();
    uint256 timeLeft = (maturity > block.timestamp) ? maturity - block.timestamp : 0;
    uint256 expected = 1e18 - ILinearDiscountOracle(ptSusde26Jun2025Oracle).getDiscount(timeLeft);

    assertEq(price, expected / 1e10); // 1e8 is the decimal of the oracle
  }

  function test_remove_ptOracle() public {
    vm.expectRevert();
    oracleAdaptor.removePtOracle(ptSusde26Jun2025);
    test_config_ptOracle();

    vm.prank(manager);
    oracleAdaptor.removePtOracle(ptSusde26Jun2025);

    (PTOracleType type_, address oracle_) = oracleAdaptor.ptOracles(ptSusde26Jun2025);
    assertEq(uint256(type_), 0); // NONE
    assertEq(oracle_, address(0));
  }

  function test_updateAssetMap() public {
    address newAsset = address(new ERC20Mock());
    vm.expectRevert();
    oracleAdaptor.updateAssetMap(address(ptClisBNB25apr), newAsset);
    vm.prank(manager);
    oracleAdaptor.updateAssetMap(address(ptClisBNB25apr), newAsset);
    assertEq(oracleAdaptor.assetMap(address(ptClisBNB25apr)), newAsset);
  }

  function test_getTokenConfig() public {
    TokenConfig memory config = oracleAdaptor.getTokenConfig(address(ptClisBNB25apr));
    TokenConfig memory wBNBConfig = oracleAdaptor.getTokenConfig(WBNB);
    assertEq(config.asset, address(ptClisBNB25apr));
    assertEq(config.oracles[0], wBNBConfig.oracles[0]);
    assertEq(config.oracles[1], wBNBConfig.oracles[1]);
    assertEq(config.oracles[2], wBNBConfig.oracles[2]);
    assertEq(config.enableFlagsForOracles[0], wBNBConfig.enableFlagsForOracles[0]);
    assertEq(config.enableFlagsForOracles[1], wBNBConfig.enableFlagsForOracles[1]);
    assertEq(config.enableFlagsForOracles[2], wBNBConfig.enableFlagsForOracles[2]);
    assertEq(config.timeDeltaTolerance, wBNBConfig.timeDeltaTolerance);

    TokenConfig memory slisBnbConfig = oracleAdaptor.getTokenConfig(oracleAdaptor.SLISBNB());
    assertEq(slisBnbConfig.asset, oracleAdaptor.SLISBNB());
    assertEq(slisBnbConfig.oracles[0], address(oracleAdaptor));
    assertEq(slisBnbConfig.oracles[1], address(0));
    assertEq(slisBnbConfig.oracles[2], address(0));
    assertEq(slisBnbConfig.enableFlagsForOracles[0], true);
    assertEq(slisBnbConfig.enableFlagsForOracles[1], false);
    assertEq(slisBnbConfig.enableFlagsForOracles[2], false);
    assertEq(slisBnbConfig.timeDeltaTolerance, wBNBConfig.timeDeltaTolerance);

    test_config_ptOracle();
    TokenConfig memory ptConfig = oracleAdaptor.getTokenConfig(address(ptSusde26Jun2025));
    assertEq(ptConfig.asset, address(ptSusde26Jun2025));
    assertEq(ptConfig.oracles[0], address(oracleAdaptor));
    assertEq(ptConfig.oracles[1], address(0));
    assertEq(ptConfig.oracles[2], address(0));
    assertEq(ptConfig.enableFlagsForOracles[0], true);
    assertEq(ptConfig.enableFlagsForOracles[1], false);
    assertEq(ptConfig.enableFlagsForOracles[2], false);
    assertEq(ptConfig.timeDeltaTolerance, 0);
  }

  function getImplementation(address _proxyAddress) public view returns (address) {
    bytes32 implSlot = vm.load(_proxyAddress, IMPLEMENTATION_SLOT);
    return address(uint160(uint256(implSlot)));
  }
}
