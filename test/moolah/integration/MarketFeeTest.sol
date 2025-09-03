// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseTest.sol";
import { ErrorsLib } from "moolah/libraries/ErrorsLib.sol";
import { BatchManagementUtils } from "src/utils/BatchManagementUtils.sol";
import { Id } from "moolah/interfaces/IMoolah.sol";

contract MarketFeeTest is BaseTest {
  using MathLib for uint256;
  using SharesMathLib for uint256;
  using MarketParamsLib for MarketParams;

  BatchManagementUtils batchUtils;

  function setUp() public override {
    super.setUp();
    batchUtils = newBatchUtils();

    vm.startPrank(OWNER);
    moolah.enableLltv(0.1 ether);
    moolah.grantRole(MANAGER, address(batchUtils));
    vm.stopPrank();
  }

  function test_setDefaultMarketFee() public {
    vm.startPrank(OWNER);
    moolah.setDefaultMarketFee(0.1 ether);
    vm.stopPrank();

    assertEq(moolah.defaultMarketFee(), 0.1 ether, "defaultMarketFee error");

    MarketParams memory marketParams = MarketParams({
      loanToken: address(loanToken),
      collateralToken: address(collateralToken),
      oracle: address(oracle),
      irm: address(irm),
      lltv: 0.1 ether
    });
    moolah.createMarket(marketParams);

    Market memory market = moolah.market(marketParams.id());
    assertEq(market.fee, 0.1 ether, "market fee error");
  }

  function test_setDefaultMarketFeeUpperLimit() public {
    vm.startPrank(OWNER);
    vm.expectRevert(bytes(ErrorsLib.MAX_FEE_EXCEEDED));
    moolah.setDefaultMarketFee(0.26 ether);
    vm.stopPrank();
  }

  function test_batchSetMarketFee() public {
    Id id1 = marketParams.id();

    MarketParams memory marketParams2 = MarketParams({
      loanToken: address(loanToken),
      collateralToken: address(collateralToken),
      oracle: address(oracle),
      irm: address(irm),
      lltv: 0.1 ether
    });

    Id id2 = marketParams2.id();

    Id[] memory ids = new Id[](2);
    ids[0] = id1;
    ids[1] = id2;

    uint256[] memory fees = new uint256[](2);
    fees[0] = 0.1 ether;
    fees[1] = 0.15 ether;

    vm.expectRevert(bytes("Not manager of moolah"));
    batchUtils.batchSetMarketFee(ids, fees);

    vm.startPrank(OWNER);
    vm.expectRevert(bytes("Market not created"));
    batchUtils.batchSetMarketFee(ids, fees);
    vm.stopPrank();

    vm.startPrank(OWNER);
    moolah.createMarket(marketParams2);
    batchUtils.batchSetMarketFee(ids, fees);
    vm.stopPrank();

    Market memory market1 = moolah.market(id1);
    Market memory market2 = moolah.market(id2);
    assertEq(market1.fee, 0.1 ether, "market1 fee error");
    assertEq(market2.fee, 0.15 ether, "market2 fee error");
  }

  function newBatchUtils() internal returns (BatchManagementUtils) {
    BatchManagementUtils _batchUtils = new BatchManagementUtils(address(moolah));
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(_batchUtils),
      abi.encodeWithSelector(_batchUtils.initialize.selector, OWNER, OWNER)
    );
    return BatchManagementUtils(address(proxy));
  }
}
