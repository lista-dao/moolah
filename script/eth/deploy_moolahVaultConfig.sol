pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { Id, MarketParams } from "moolah/interfaces/IMoolah.sol";

contract MoolahVaultConfigDeploy is DeployBase {
  using MarketParamsLib for MarketParams;

  // todo update vault address after deployment
  MoolahVault wethVault = MoolahVault(address(0));

  uint256 fee = 0.1 ether;
  address feeRecipient = 0xd10a024602E042dcb9C19e21682c3b896c8B0d30;
  address skimRecipient = 0x1d60bBBEF79Fb9540D271Dbb01925380323A8f66;

  address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
  address wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
  address wBETH = 0xa2E3356610840701BDf5611a53974510Ae27E2e1;

  address multiOracle = 0xA64FE284EB8279B9b63946DD51813b0116099301;
  address irm = 0x8b7d334d243b74D63C4b963893267A0F5240F990;
  uint256 lltv965 = 0.965 ether;

  // todo update cap: target $100M for wstETH, $20M for wbETH, in WETH (18 decimals)
  // cap = targetUSD / ethPrice * 1e18
  uint256 wstETHCap = 0;
  uint256 wBETHCap = 0;

  address bot = 0x91fC4BA20685339781888eCA3E9E1c12d40F0e13;

  bytes32 public constant CURATOR = keccak256("CURATOR");
  bytes32 public constant ALLOCATOR = keccak256("ALLOCATOR");

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    MarketParams memory wstETHMarket = MarketParams({
      loanToken: WETH,
      collateralToken: wstETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv965
    });

    MarketParams memory wBETHMarket = MarketParams({
      loanToken: WETH,
      collateralToken: wBETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv965
    });

    vm.startBroadcast(deployerPrivateKey);

    _configVault(wethVault, wstETHMarket, wBETHMarket, deployer);

    vm.stopBroadcast();

    console.log("vault config done!");
  }

  function _configVault(
    MoolahVault vault,
    MarketParams memory market1,
    MarketParams memory market2,
    address deployer
  ) internal {
    vault.setFeeRecipient(feeRecipient);
    vault.setSkimRecipient(skimRecipient);

    vault.grantRole(CURATOR, deployer);
    vault.grantRole(ALLOCATOR, deployer);
    vault.setBotRole(bot);

    vault.setFee(fee);

    vault.setCap(market1, wstETHCap);
    vault.setCap(market2, wBETHCap);

    Id[] memory supplyQueue = new Id[](2);
    supplyQueue[0] = market1.id();
    supplyQueue[1] = market2.id();
    vault.setSupplyQueue(supplyQueue);

    // withdraw queue priority: wbETH first (smaller cap), then wstETH
    uint256[] memory withdrawQueue = new uint256[](2);
    withdrawQueue[0] = 1; // wbETH index in supplyQueue
    withdrawQueue[1] = 0; // wstETH index in supplyQueue
    vault.updateWithdrawQueue(withdrawQueue);
  }
}
