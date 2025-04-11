// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { MoolahVault } from "moolah-vault/MoolahVault.sol";
import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketAllocation } from "moolah-vault/interfaces/IMoolahVault.sol";

contract MoolahVaultTest is Test {
  MoolahVault vault = MoolahVault(0x57134a64B7cD9F9eb72F8255A671F5Bf2fe3E2d0);
  address curator = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  address allocator = 0x85CE862C5BB61938FFcc97DA4A80C8aaE43C6A27;
  address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;

  address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;

  address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
  address BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
  address slisBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
  address ptClisBNB25apr = 0xE8F1C9804770e11Ab73395bE54686Ad656601E9e;
  address solvBTC = 0x4aae823a6a0b376De6A78e74eCC5b079d38cBCf7;
  address multiOracle = 0xf3afD82A4071f272F403dC176916141f44E6c750;
  address oracleAdapter = 0x21650E416dC6C89486B2E654c86cC2c36c597b58;
  address irm = 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c;

  uint256 lltv70 = 70 * 1e16;
  uint256 lltv80 = 80 * 1e16;
  uint256 lltv90 = 90 * 1e16;

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
    for (uint256 i = 0; i < vault.withdrawQueueLength(); i++) {
      console.logBytes32(Id.unwrap(vault.withdrawQueue(i)));
    }
  }

  function test_reallocate() public {
    MoolahVault impl = new MoolahVault(moolah, WBNB);
    vm.startPrank(admin);
    vault.upgradeToAndCall(address(impl), "");
    vm.stopPrank();

    // collateral-BTCB loan-WBNB lltv-80%
    MarketParams memory BTCBParams = MarketParams({
      loanToken: WBNB,
      collateralToken: BTCB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv80
    });
    // collateral-ptClisBNB25apr loan-WBNB lltv-90%
    MarketParams memory ptClisBNB25aprParams = MarketParams({
      loanToken: WBNB,
      collateralToken: ptClisBNB25apr,
      oracle: oracleAdapter,
      irm: irm,
      lltv: lltv90
    });
    // collateral-solvBTC loan-WBNB lltv-70%
    MarketParams memory solvBTCParams = MarketParams({
      loanToken: WBNB,
      collateralToken: solvBTC,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv70
    });

    vm.startPrank(allocator);
    MarketAllocation[] memory allocations = new MarketAllocation[](3);
    allocations[0] = MarketAllocation({
      marketParams: BTCBParams,
      assets: 11700 ether
    });
    allocations[1] = MarketAllocation({
      marketParams: ptClisBNB25aprParams,
      assets: 4500 ether
    });
    allocations[2] = MarketAllocation({
      marketParams: solvBTCParams,
      assets: type(uint256).max
    });

    vault.reallocate(allocations);

    vm.stopPrank();
  }
}

