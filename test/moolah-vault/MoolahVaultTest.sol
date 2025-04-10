// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { MoolahVault } from "moolah-vault/MoolahVault.sol";
import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";

contract MoolahVaultTest is Test {
  MoolahVault vault = MoolahVault(0x57134a64B7cD9F9eb72F8255A671F5Bf2fe3E2d0);
  address curator = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  address allocator = 0x85CE862C5BB61938FFcc97DA4A80C8aaE43C6A27;

  function setUp() public {
    vm.createSelectFork("bsc");
  }

  function test_removeMarket() public {
    MarketParams memory marketParams = MarketParams({
      loanToken: 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c,
      collateralToken: 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B,
      oracle: 0x21650E416dC6C89486B2E654c86cC2c36c597b58,
      irm: 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c,
      lltv: 800000000000000000
    });


    Id[] memory supplyQueue = new Id[](3);
    supplyQueue[0] = Id.wrap(0x9A7D48F4D5A39353FF9D34C4CEFC2DC933BCC11E8BE1A503DB0910678763C394);
    supplyQueue[1] = Id.wrap(0xF7526E97D814E325D3133A30C934F4943DCE1D05D060319BF320C2BB02CE1138);
    supplyQueue[2] = Id.wrap(0x24EF5F94DEF28B34F08E192A810AECD393EA4969EEC031EC268DE008E8A3BC70);

    uint256[] memory indexes = new uint256[](3);
    indexes[0] = 0;
    indexes[1] = 1;
    indexes[2] = 3;

    vm.startPrank(curator);
    vault.setCap(marketParams, 0);
    vault.setMarketRemoval(marketParams);
    vm.stopPrank();
    vm.startPrank(allocator);
    vault.setSupplyQueue(supplyQueue);
    vault.updateWithdrawQueue(indexes);
    vm.stopPrank();
  }
}

