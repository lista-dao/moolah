pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { Id, MarketParams } from "moolah/interfaces/IMoolah.sol";

contract MoolahVaultConfigDeploy is Script {
  using MarketParamsLib for MarketParams;
  // todo update vault feeRecipient oracleAdapter irm
  MoolahVault vault = MoolahVault(0xE46b8E65006e6450bdd8cb7D3274AB4F76f4C705);
  uint256 fee = 10 * 1e16;
  address feeRecipient = 0xea55952a51ddd771d6eBc45Bd0B512276dd0b866;
  address skimRecipient = 0x1d60bBBEF79Fb9540D271Dbb01925380323A8f66;

  address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
  address BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
  address solvBTC = 0x4aae823a6a0b376De6A78e74eCC5b079d38cBCf7;
  address USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
  address multiOracle = 0xf3afD82A4071f272F403dC176916141f44E6c750;
  address oracleAdapter = 0x21650E416dC6C89486B2E654c86cC2c36c597b58;
  address irm = 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c;
  address bot = 0x91fC4BA20685339781888eCA3E9E1c12d40F0e13;

  uint256 lltv70 = 70 * 1e16;
  uint256 lltv80 = 80 * 1e16;
  uint256 lltv90 = 90 * 1e16;
  uint256 lltv965 = 965 * 1e15;

  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant CURATOR = keccak256("CURATOR"); // manager role
  bytes32 public constant ALLOCATOR = keccak256("ALLOCATOR"); // manager role

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    // collateral-WBNB loan-BTCB lltv-80%
    MarketParams memory WBNBParams = MarketParams({
      loanToken: BTCB,
      collateralToken: WBNB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv80
    });
    // collateral-USD1 loan-BTCB lltv-80%
    MarketParams memory USD1Params = MarketParams({
      loanToken: BTCB,
      collateralToken: USD1,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv80
    });
    // collateral-solvBTC loan-BTCB lltv-70%
    MarketParams memory solvBTCParams = MarketParams({
      loanToken: BTCB,
      collateralToken: solvBTC,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv70
    });

    vm.startBroadcast(deployerPrivateKey);
    vault.setFeeRecipient(feeRecipient);
    vault.setSkimRecipient(skimRecipient);

    vault.grantRole(CURATOR, deployer);
    vault.grantRole(ALLOCATOR, deployer);
    vault.setBotRole(bot);

    // config vault
    vault.setFee(fee);

    // WBNB cap 500 BTCB
    vault.setCap(WBNBParams, 500 ether);
    // USD1 cap 300 BTCB
    vault.setCap(USD1Params, 300 ether);
    // solvBTC cap 200 BTCB
    vault.setCap(solvBTCParams, 200 ether);

    Id WBNBId = WBNBParams.id();
    Id USD1Id = USD1Params.id();
    Id solvBTCId = solvBTCParams.id();
    Id[] memory supplyQueue = new Id[](3);
    supplyQueue[0] = WBNBId;
    supplyQueue[1] = USD1Id;
    supplyQueue[2] = solvBTCId;

    vault.setSupplyQueue(supplyQueue);

    uint256[] memory withdrawQueue = new uint256[](3);
    withdrawQueue[0] = 2;
    withdrawQueue[1] = 1;
    withdrawQueue[2] = 0;
    vault.updateWithdrawQueue(withdrawQueue);

    vm.stopBroadcast();

    console.log("vault config done!");
  }
}
