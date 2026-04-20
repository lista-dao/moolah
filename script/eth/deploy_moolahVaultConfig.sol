pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { Id, MarketParams } from "moolah/interfaces/IMoolah.sol";

contract MoolahVaultConfigDeploy is DeployBase {
  using MarketParamsLib for MarketParams;

  // todo update vault addresses after step 3 deployment
  MoolahVault usdtVault = MoolahVault(address(0));
  MoolahVault usdcVault = MoolahVault(address(0));

  uint256 fee = 0.1 ether;
  address feeRecipient = 0xd10a024602E042dcb9C19e21682c3b896c8B0d30;
  address skimRecipient = 0x1d60bBBEF79Fb9540D271Dbb01925380323A8f66;

  address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
  address USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
  address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

  address multiOracle = 0xA64FE284EB8279B9b63946DD51813b0116099301;
  address irm = 0x8b7d334d243b74D63C4b963893267A0F5240F990;
  uint256 lltv86 = 0.86 ether;

  uint256 cap = 300_000_000e6; // 300M in 6-decimal units (USDT/USDC)

  address bot = 0x91fC4BA20685339781888eCA3E9E1c12d40F0e13;

  bytes32 public constant CURATOR = keccak256("CURATOR");
  bytes32 public constant ALLOCATOR = keccak256("ALLOCATOR");

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    MarketParams memory usdtMarket = MarketParams({
      loanToken: USDT,
      collateralToken: WETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    MarketParams memory usdcMarket = MarketParams({
      loanToken: USDC,
      collateralToken: WETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });

    vm.startBroadcast(deployerPrivateKey);

    _configVault(usdtVault, usdtMarket, deployer);
    _configVault(usdcVault, usdcMarket, deployer);

    vm.stopBroadcast();

    console.log("vault config done!");
  }

  function _configVault(MoolahVault vault, MarketParams memory params, address deployer) internal {
    vault.setFeeRecipient(feeRecipient);
    vault.setSkimRecipient(skimRecipient);

    vault.grantRole(CURATOR, deployer);
    vault.grantRole(ALLOCATOR, deployer);
    vault.setBotRole(bot);

    vault.setFee(fee);
    vault.setCap(params, cap);

    Id[] memory supplyQueue = new Id[](1);
    supplyQueue[0] = params.id();
    vault.setSupplyQueue(supplyQueue);
  }
}
