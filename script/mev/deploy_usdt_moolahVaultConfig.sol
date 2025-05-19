pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { Id, MarketParams } from "moolah/interfaces/IMoolah.sol";

contract MoolahVaultConfigDeploy is Script {
  using MarketParamsLib for MarketParams;
  // todo update vault
  MoolahVault vault = MoolahVault(0x6d6783C146F2B0B2774C1725297f1845dc502525);
  uint256 fee = 10 * 1e16;
  address feeRecipient = 0x50dE2Fb5cd259c1b99DBD3Bb4E7Aac76BE7288fC;
  address skimRecipient = 0x6293e97900aA987Cf3Cbd419e0D5Ba43ebfA91c1;

  address USDT = 0x55d398326f99059fF775485246999027B3197955;
  address BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
  address solvBTC = 0x4aae823a6a0b376De6A78e74eCC5b079d38cBCf7;
  address USDF = 0x5A110fC00474038f6c02E89C707D638602EA44B5;
  address asUSDF = 0x917AF46B3C3c6e1Bb7286B9F59637Fb7C65851Fb;
  address USDe = 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34;
  address ptSUSDe = 0xb84cEC1Ab2af11b530ae0d8594B1493556be49Cd;

  address multiOracle = 0xf3afD82A4071f272F403dC176916141f44E6c750;
  address ptOracle = 0x1a438f71bc56514F47142c96A8f580AB5767aC17;

  address irm = 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c;

  uint256 lltv85 = 85 * 1e16;
  uint256 lltv915 = 915 * 1e15;

  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant CURATOR = keccak256("CURATOR"); // manager role
  bytes32 public constant ALLOCATOR = keccak256("ALLOCATOR"); // manager role

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    MarketParams memory BTCBParams = MarketParams({
      loanToken: USDT,
      collateralToken: BTCB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv85
    });

    MarketParams memory solvBTCParams = MarketParams({
      loanToken: USDT,
      collateralToken: solvBTC,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv85
    });

    MarketParams memory USDFParams = MarketParams({
      loanToken: USDT,
      collateralToken: USDF,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });

    MarketParams memory asUSDFParams = MarketParams({
      loanToken: USDT,
      collateralToken: asUSDF,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });

    MarketParams memory USDeParams = MarketParams({
      loanToken: USDT,
      collateralToken: USDe,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });

    MarketParams memory ptSUSDeParams = MarketParams({
      loanToken: USDT,
      collateralToken: ptSUSDe,
      oracle: ptOracle,
      irm: irm,
      lltv: lltv915
    });

    vm.startBroadcast(deployerPrivateKey);
    vault.setFeeRecipient(feeRecipient);
    vault.setSkimRecipient(skimRecipient);

    vault.grantRole(CURATOR, deployer);
    vault.grantRole(ALLOCATOR, deployer);

    // config vault
    vault.setFee(fee);

    vault.setCap(BTCBParams, 10_000_000 ether);
    vault.setCap(solvBTCParams, 10_000_000 ether);
    vault.setCap(USDFParams, 10_000_000 ether);
    vault.setCap(asUSDFParams, 10_000_000 ether);
    vault.setCap(USDeParams, 10_000_000 ether);
    vault.setCap(ptSUSDeParams, 10_000_000 ether);

    Id BTCBId = BTCBParams.id();
    Id solvBTCId = solvBTCParams.id();
    Id USDFId = USDFParams.id();
    Id asUSDFId = asUSDFParams.id();
    Id USDeId = USDeParams.id();
    Id ptSUSDeId = ptSUSDeParams.id();
    Id[] memory supplyQueue = new Id[](6);
    supplyQueue[0] = BTCBId;
    supplyQueue[1] = solvBTCId;
    supplyQueue[2] = USDFId;
    supplyQueue[3] = asUSDFId;
    supplyQueue[4] = USDeId;
    supplyQueue[5] = ptSUSDeId;

    vault.setSupplyQueue(supplyQueue);

    uint256[] memory withdrawQueue = new uint256[](6);
    withdrawQueue[0] = 5;
    withdrawQueue[1] = 4;
    withdrawQueue[2] = 3;
    withdrawQueue[3] = 2;
    withdrawQueue[4] = 1;
    withdrawQueue[5] = 0;
    vault.updateWithdrawQueue(withdrawQueue);

    vm.stopBroadcast();

    console.log("vault config done!");
  }
}
