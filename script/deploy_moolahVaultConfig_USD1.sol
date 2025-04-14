pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { Id, MarketParams } from "moolah/interfaces/IMoolah.sol";

contract MoolahVaultConfigDeploy is Script {
  using MarketParamsLib for MarketParams;
  MoolahVault vault = MoolahVault(0xfa27f172e0b6ebcEF9c51ABf817E2cb142FbE627);
  uint256 fee = 10 * 1e16;
  address feeRecipient = 0x2E2Eed557FAb1d2E11fEA1E1a23FF8f1b23551f3;
  address skimRecipient = 0x1d60bBBEF79Fb9540D271Dbb01925380323A8f66;

  address USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
  address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
  address BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
  address multiOracle = 0xf3afD82A4071f272F403dC176916141f44E6c750;
  address irm = 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c;

  uint256 lltv70 = 70 * 1e16;

  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant CURATOR = keccak256("CURATOR"); // manager role
  bytes32 public constant ALLOCATOR = keccak256("ALLOCATOR"); // manager role

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    MarketParams memory BTCBParams = MarketParams({
      loanToken: USD1,
      collateralToken: BTCB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv70
    });
    MarketParams memory WBNBParams = MarketParams({
      loanToken: USD1,
      collateralToken: WBNB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv70
    });

    vm.startBroadcast(deployerPrivateKey);
    vault.setFeeRecipient(feeRecipient);
    vault.setSkimRecipient(skimRecipient);

    vault.grantRole(CURATOR, deployer);
    vault.grantRole(ALLOCATOR, deployer);

    // config vault
    vault.setFee(fee);

    vault.setCap(BTCBParams, 75000000 ether);
    vault.setCap(WBNBParams, 75000000 ether);

    Id BTCBId = BTCBParams.id();
    Id WBNBId = WBNBParams.id();
    Id[] memory supplyQueue = new Id[](2);
    supplyQueue[0] = BTCBId;
    supplyQueue[1] = WBNBId;

    vault.setSupplyQueue(supplyQueue);

    uint256[] memory withdrawQueue = new uint256[](2);
    withdrawQueue[0] = 1;
    withdrawQueue[1] = 0;
    vault.updateWithdrawQueue(withdrawQueue);

    vm.stopBroadcast();

    console.log("vault config done!");
  }
}
