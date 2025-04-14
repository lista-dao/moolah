// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { MoolahVault } from "moolah-vault/MoolahVault.sol";
import { MarketParams, Id, IMoolah, Market } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { SharesMathLib } from "moolah/libraries/SharesMathLib.sol";
import { MarketAllocation } from "moolah-vault/interfaces/IMoolahVault.sol";
import { IVaultAllocator } from "vault-allocator/interfaces/IVaultAllocator.sol";

contract MoolahVaultTest is Test {
  using MarketParamsLib for MarketParams;
  using SharesMathLib for uint256;
  IVaultAllocator vaultAllocator = IVaultAllocator(0x9ECF66f016FCaA853FdA24d223bdb4276E5b524a);
  address vault = 0x57134a64B7cD9F9eb72F8255A671F5Bf2fe3E2d0;
  address curator = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  address allocator = 0x85CE862C5BB61938FFcc97DA4A80C8aaE43C6A27;
  address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;

  address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;

  address USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
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


  address bot = 0x6dD696c8DBa8764D0e5fD914A470FD5e780D0D12;

  function setUp() public {
    vm.createSelectFork("bsc");
  }

  function test_reallocate() public {
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

    MarketParams memory solvBTCParams = MarketParams({
      loanToken: WBNB,
      collateralToken: solvBTC,
      oracle: oracleAdapter,
      irm: irm,
      lltv: lltv70
    });

    vm.startPrank(bot);

//    vaultAllocator.reallocateTo();

    vm.stopPrank();

  }
}

