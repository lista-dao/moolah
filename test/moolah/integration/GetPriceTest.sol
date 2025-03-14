// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { MarketParams } from "moolah/interfaces/IMoolah.sol";
import "../BaseTest.sol";

contract GetPriceTest is BaseTest {
  using Math for uint256;

  address BTCB;
  address USDC;
  address USDT;
  address multiOracle;

  function setUp() public override {
    super.setUp();

    ERC20Mock BTCBMock = new ERC20Mock();
    BTCBMock.setDecimals(8);

    ERC20Mock USDCMock = new ERC20Mock();
    USDCMock.setDecimals(6);

    ERC20Mock USDTMock = new ERC20Mock();
    USDTMock.setDecimals(6);

    BTCB = address(BTCBMock);
    USDC = address(USDCMock);
    USDT = address(USDTMock);

    OracleMock oracle = new OracleMock();
    multiOracle = address(oracle);

    // Set BTCB price to $90000
    oracle.setPrice(BTCB, 90000 * 10 ** 8);
    // Set USDC price to $1
    oracle.setPrice(USDC, 1 * 10 ** 8);
    // Set USDT price to $1.0001
    oracle.setPrice(USDT, 10001 * 10 ** 4);
  }

  function testOracleBtcBUsdc() public view {
    uint256 price = moolah.getPrice(
      MarketParams({ loanToken: USDC, collateralToken: BTCB, oracle: address(multiOracle), irm: address(0), lltv: 0 })
    );

    uint256 basePrice = IOracle(multiOracle).peek(BTCB);
    uint256 quotePrice = IOracle(multiOracle).peek(USDC);
    uint8 baseDecimals = IERC20Metadata(BTCB).decimals();
    uint8 quoteDecimals = IERC20Metadata(USDC).decimals();

    assertEq(price, (uint256(basePrice) * 10 ** (36 + quoteDecimals - baseDecimals)) / uint256(quotePrice));
  }

  function testOracleUsutUsdc() public view {
    uint256 price = moolah.getPrice(
      MarketParams({ loanToken: USDC, collateralToken: USDT, oracle: address(multiOracle), irm: address(0), lltv: 0 })
    );

    uint256 basePrice = IOracle(multiOracle).peek(USDT);
    uint256 quotePrice = IOracle(multiOracle).peek(USDC);
    uint8 baseDecimals = IERC20Metadata(USDT).decimals();
    uint8 quoteDecimals = IERC20Metadata(USDC).decimals();

    assertEq(price, (uint256(basePrice) * 10 ** (36 + quoteDecimals - baseDecimals)) / uint256(quotePrice));
  }
}
