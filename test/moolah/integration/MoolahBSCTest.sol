// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import { Moolah } from "moolah/Moolah.sol";
import { Position, MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MoolahVault } from "moolah-vault/MoolahVault.sol";

contract MoolahBSCTest is Test {
  address feeRecipient = 0x34B504A5CF0fF41F8A480580533b6Dda687fa3Da;
  address vaultRecipient = 0xea55952a51ddd771d6eBc45Bd0B512276dd0b866;
  Moolah moolah = Moolah(0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C);
  MoolahVault wbnbVault = MoolahVault(0x57134a64B7cD9F9eb72F8255A671F5Bf2fe3E2d0);

  bytes32 btcbId = 0x9A7D48F4D5A39353FF9D34C4CEFC2DC933BCC11E8BE1A503DB0910678763C394;
  bytes32 ptId = 0xF7526E97D814E325D3133A30C934F4943DCE1D05D060319BF320C2BB02CE1138;
  address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
  address BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
  address ptClisBNB25apr = 0xE8F1C9804770e11Ab73395bE54686Ad656601E9e;
  address multiOracle = 0xf3afD82A4071f272F403dC176916141f44E6c750;
  address oracleAdapter = 0x21650E416dC6C89486B2E654c86cC2c36c597b58;
  address irm = 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c;
  uint256 lltv80 = 80 * 1e16;
  uint256 lltv90 = 90 * 1e16;

  MarketParams btcbParams;
  MarketParams ptParams;

  function setUp() public {
    vm.createSelectFork("bsc");
    btcbParams = MarketParams({
      loanToken: WBNB,
      collateralToken: BTCB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv80
    });

    ptParams = MarketParams({
      loanToken: WBNB,
      collateralToken: ptClisBNB25apr,
      oracle: oracleAdapter,
      irm: irm,
      lltv: lltv90
    });
  }

  function test_claim() public {
    uint256 beforeBalance = IERC20(WBNB).balanceOf(feeRecipient);
    console.log("1", beforeBalance);

    vm.startPrank(feeRecipient);
      (uint256 supplyShares,, ) = moolah.position(Id.wrap(btcbId), feeRecipient);
      moolah.withdraw(btcbParams, 0, supplyShares, feeRecipient, feeRecipient);
      (supplyShares,, ) = moolah.position(Id.wrap(ptId), feeRecipient);
      console.log('---', supplyShares);
      moolah.withdraw(ptParams, 0, supplyShares, feeRecipient, feeRecipient);

    vm.stopPrank();
    uint256 afterBalance = IERC20(WBNB).balanceOf(feeRecipient);
    console.log("2", afterBalance - beforeBalance);
  }

  function test_claimVault() public {
    uint256 beforeBalance = IERC20(WBNB).balanceOf(vaultRecipient);
    console.log("1", beforeBalance);

    vm.startPrank(vaultRecipient);
    uint256 shares = wbnbVault.balanceOf(vaultRecipient);
    console.log('---', shares);
    wbnbVault.redeem(shares, vaultRecipient, vaultRecipient);

    vm.stopPrank();

    uint256 afterBalance = IERC20(WBNB).balanceOf(vaultRecipient);
    console.log("2", afterBalance - beforeBalance);
  }
}
