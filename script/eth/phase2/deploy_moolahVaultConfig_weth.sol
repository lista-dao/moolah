pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../../DeployBase.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { Id, MarketParams } from "moolah/interfaces/IMoolah.sol";

/// @notice Step 4: Configure WETH Savings Vault
///   - Set fee, feeRecipient, skimRecipient
///   - Grant roles, set bot
///   - Set caps for wstETH market (100M) and wbETH market (20M)
///   - Set supply queue
contract MoolahVaultConfigWETHDeploy is DeployBase {
  using MarketParamsLib for MarketParams;

  MoolahVault wethVault;

  uint256 fee = 0.1 ether; // 10% performance fee
  address feeRecipient;
  address skimRecipient;

  // Tokens
  address WETH;
  address wstETH;
  address wBETH;

  // Oracle & IRM
  address multiOracle;
  address irm;
  uint256 lltv965 = 0.965 ether;

  // Caps (in WETH, 18 decimals)
  // Market #1 wstETH: target $100M cap
  // Market #2 wbETH:  target $20M cap
  // Pass via env: WSTETH_CAP=40000000000000000000000 WBETH_CAP=8000000000000000000000
  // Formula: cap = targetUSD / ethPrice (in wei)
  uint256 wstETHCap;
  uint256 wBETHCap;

  address bot;

  bytes32 public constant CURATOR = keccak256("CURATOR");
  bytes32 public constant ALLOCATOR = keccak256("ALLOCATOR");

  function setUp() public {
    if (block.chainid == 1) {
      // ──── ETH mainnet ────
      feeRecipient = 0xd10a024602E042dcb9C19e21682c3b896c8B0d30;
      skimRecipient = 0x1d60bBBEF79Fb9540D271Dbb01925380323A8f66;
      WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
      wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
      wBETH = 0xa2E3356610840701BDf5611a53974510Ae27E2e1;
      multiOracle = 0xA64FE284EB8279B9b63946DD51813b0116099301;
      irm = 0x8b7d334d243b74D63C4b963893267A0F5240F990;
      bot = 0x91fC4BA20685339781888eCA3E9E1c12d40F0e13;
    } else if (block.chainid == 11155111) {
      // ──── Sepolia testnet ────
      feeRecipient = 0x6616EF47F4d997137a04C2AD7FF8e5c228dA4f06;
      skimRecipient = 0x6616EF47F4d997137a04C2AD7FF8e5c228dA4f06;
      WETH = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;
      multiOracle = 0x624C651254A3B1EA7A3347186A0B3b95A20f83E8; // MockResilientOracle
      irm = 0x987ECD52B37a7F76C5c9f590f8F6F52Cd85b82d8;
      bot = 0x6616EF47F4d997137a04C2AD7FF8e5c228dA4f06;
      // Mock tokens — deploy first, then pass via env
      wstETH = vm.envAddress("WSTETH");
      wBETH = vm.envAddress("WBETH");
    } else {
      revert("MoolahVaultConfigWETHDeploy: unsupported chain");
    }
  }

  function run() public {
    wethVault = MoolahVault(vm.envAddress("WETH_VAULT"));
    require(address(wethVault) != address(0), "WETH_VAULT env not set");

    wstETHCap = vm.envUint("WSTETH_CAP");
    wBETHCap = vm.envUint("WBETH_CAP");
    require(wstETHCap > 0 && wBETHCap > 0, "WSTETH_CAP and WBETH_CAP env not set");

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

    // set fee config
    wethVault.setFeeRecipient(feeRecipient);
    wethVault.setSkimRecipient(skimRecipient);

    // grant roles
    wethVault.grantRole(CURATOR, deployer);
    wethVault.grantRole(ALLOCATOR, deployer);
    wethVault.setBotRole(bot);

    // set fee
    wethVault.setFee(fee);

    // set caps
    wethVault.setCap(wstETHMarket, wstETHCap);
    wethVault.setCap(wBETHMarket, wBETHCap);

    // set supply queue (both wstETH and wbETH markets)
    Id[] memory supplyQueue = new Id[](2);
    supplyQueue[0] = wstETHMarket.id();
    supplyQueue[1] = wBETHMarket.id();
    wethVault.setSupplyQueue(supplyQueue);

    // set withdraw queue priority: wbETH first (smaller cap), then wstETH
    uint256[] memory withdrawQueue = new uint256[](2);
    withdrawQueue[0] = 1; // wbETH index in supplyQueue
    withdrawQueue[1] = 0; // wstETH index in supplyQueue
    wethVault.updateWithdrawQueue(withdrawQueue);

    vm.stopBroadcast();

    console.log("WETH vault config done!");
  }
}
