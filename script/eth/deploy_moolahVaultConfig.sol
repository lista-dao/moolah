pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { Id, MarketParams } from "moolah/interfaces/IMoolah.sol";

contract MoolahVaultConfigDeploy is Script {
  using MarketParamsLib for MarketParams;
  // todo update vault
  MoolahVault vault = MoolahVault(0x1A9BeE2F5c85F6b4a0221fB1C733246AF5306Ae3);
  uint256 fee = 0.1 ether;
  address feeRecipient = 0xd10a024602E042dcb9C19e21682c3b896c8B0d30;
  address skimRecipient = 0x1d60bBBEF79Fb9540D271Dbb01925380323A8f66;

  address USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
  address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
  address WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
  address wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
  address wBETH = 0xa2E3356610840701BDf5611a53974510Ae27E2e1;
  address PTUSDe27NOV2025 = 0x62C6E813b9589C3631Ba0Cdb013acdB8544038B7;
  address cbBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

  address multiOracle = 0xA64FE284EB8279B9b63946DD51813b0116099301;
  address PTUSDe27NOV2025USD1Oracle = 0xb169d2459F51d02d7fC8A39498ec2801652b594c;

  address irm = 0x8b7d334d243b74D63C4b963893267A0F5240F990;
  address fixedRateIRM = 0x9A7cA2CfB886132B6024789163e770979E4222e1;

  uint256 lltv86 = 0.86 ether;
  uint256 lltv915 = 0.915 ether;

  address bot = 0x91fC4BA20685339781888eCA3E9E1c12d40F0e13;

  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant CURATOR = keccak256("CURATOR"); // manager role
  bytes32 public constant ALLOCATOR = keccak256("ALLOCATOR"); // manager role

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    MarketParams memory WETHParams = MarketParams({
      loanToken: USD1,
      collateralToken: WETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    MarketParams memory WBTCParams = MarketParams({
      loanToken: USD1,
      collateralToken: WBTC,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    MarketParams memory wstETHParams = MarketParams({
      loanToken: USD1,
      collateralToken: wstETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    MarketParams memory wBETHParams = MarketParams({
      loanToken: USD1,
      collateralToken: wBETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    MarketParams memory ptUSDe27NOV2025params = MarketParams({
      loanToken: USD1,
      collateralToken: PTUSDe27NOV2025,
      oracle: PTUSDe27NOV2025USD1Oracle,
      irm: irm,
      lltv: lltv915
    });
    MarketParams memory cbBTCParams = MarketParams({
      loanToken: USD1,
      collateralToken: cbBTC,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });

    vm.startBroadcast(deployerPrivateKey);

    vault.setFeeRecipient(feeRecipient);
    vault.setSkimRecipient(skimRecipient);

    vault.grantRole(CURATOR, deployer);
    vault.grantRole(ALLOCATOR, deployer);
    vault.setBotRole(bot);

    // config vault

    vault.setFee(fee);

    vault.setCap(WETHParams, 200_000_000 ether);
    vault.setCap(WBTCParams, 200_000_000 ether);
    vault.setCap(wstETHParams, 100_000_000 ether);
    vault.setCap(wBETHParams, 100_000_000 ether);
    vault.setCap(ptUSDe27NOV2025params, 500_000_000 ether);
    vault.setCap(cbBTCParams, 200_000_000 ether);

    Id WETHId = WETHParams.id();
    Id WBTCId = WBTCParams.id();
    Id wstETHId = wstETHParams.id();
    Id wBETHId = wBETHParams.id();
    Id ptUSDe27NOV2025Id = ptUSDe27NOV2025params.id();
    Id cbBTCId = cbBTCParams.id();
    Id[] memory supplyQueue = new Id[](6);
    supplyQueue[0] = WETHId;
    supplyQueue[1] = WBTCId;
    supplyQueue[2] = wstETHId;
    supplyQueue[3] = wBETHId;
    supplyQueue[4] = ptUSDe27NOV2025Id;
    supplyQueue[5] = cbBTCId;

    vault.setSupplyQueue(supplyQueue);

    vm.stopBroadcast();

    console.log("vault config done!");
  }
}
