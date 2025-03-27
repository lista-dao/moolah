// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { OracleAdaptor } from "../../src/oracle/OracleAdaptor.sol";
import { ERC20Mock } from "../../src/moolah/mocks/ERC20Mock.sol";
import { IStakeManager } from "../../src/oracle/interfaces/IStakeManager.sol";
import { IOracle } from "../../src/moolah/interfaces/IOracle.sol";

contract OracleAdaptorTest is Test {
  OracleAdaptor oracleAdaptor;
  ERC20Mock ptClisBnb;
  address wBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

  function setUp() public {
    vm.createSelectFork("https://bsc-dataseed.bnbchain.org");
    address[] memory srcAsset = new address[](1);
    address[] memory targetAsset = new address[](1);
    ptClisBnb = new ERC20Mock();
    srcAsset[0] = address(ptClisBnb);
    targetAsset[0] = wBNB;

    OracleAdaptor impl = new OracleAdaptor();
    ERC1967Proxy proxy_ = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(OracleAdaptor.initialize.selector, address(this), srcAsset, targetAsset)
    );
    oracleAdaptor = OracleAdaptor(address(proxy_));

    assertEq(oracleAdaptor.assetMap(address(ptClisBnb)), wBNB);
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
      abi.encodeWithSelector(IOracle.peek.selector, wBNB),
      abi.encode(uint256(62377900546)) // returns $623.77900546
    );
    uint256 price = oracleAdaptor.peek(wBNB);
    assertEq(price, 62377900546);

    price = oracleAdaptor.peek(address(ptClisBnb));
    assertEq(price, 62377900546);
  }
}
