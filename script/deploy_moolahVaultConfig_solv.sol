pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { Id, MarketParams } from "moolah/interfaces/IMoolah.sol";

contract MoolahVaultConfigDeploy is Script {
  using MarketParamsLib for MarketParams;
  // todo update vault
  MoolahVault WBNBVault = MoolahVault(0x6d6783C146F2B0B2774C1725297f1845dc502525);
  MoolahVault USD1Vault = MoolahVault(0x6d6783C146F2B0B2774C1725297f1845dc502525);

  uint256 fee = 10 * 1e16;
  address feeRecipient = 0x2E2Eed557FAb1d2E11fEA1E1a23FF8f1b23551f3;
  address skimRecipient = 0x1d60bBBEF79Fb9540D271Dbb01925380323A8f66;

  address ETH = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;
  address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
  address BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
  address solvBTC = 0x4aae823a6a0b376De6A78e74eCC5b079d38cBCf7;
  address USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
  address USDT = 0x55d398326f99059fF775485246999027B3197955;
  address slisBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
  address Puffer = 0x87d00066cf131ff54B72B134a217D5401E5392b6;
  address AB = 0x95034f653D5D161890836Ad2B6b8cc49D14e029a;
  address B = 0x6bdcCe4A559076e37755a78Ce0c06214E59e4444;
  address B2 = 0x783c3f003f172c6Ac5AC700218a357d2D66Ee2a2;
  address xsolvBTC = 0x1346b618dC92810EC74163e4c27004c921D446a5;

  address multiOracle = 0xf3afD82A4071f272F403dC176916141f44E6c750;
  address oracleAdapter = 0x21650E416dC6C89486B2E654c86cC2c36c597b58;
  address irm = 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c;
  address alphaIrm = 0x5F9f9173B405C6CEAfa7f98d09e4B8447e9797E6;
  address bot = 0x91fC4BA20685339781888eCA3E9E1c12d40F0e13;

  address bnbProvider = 0x367384C54756a25340c63057D87eA22d47Fd5701;

  uint256 lltv50 = 50 * 1e16;
  uint256 lltv70 = 70 * 1e16;
  uint256 lltv75 = 75 * 1e16;
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

    vm.startBroadcast(deployerPrivateKey);

    configWBNB(deployer, WBNBVault);
    configUSD1(deployer, USD1Vault);

    vm.stopBroadcast();

    console.log("vault config done!");
  }

  function configWBNB(address deployer, MoolahVault vault) internal {
    MarketParams memory solvBTCParams = MarketParams({
      loanToken: WBNB,
      collateralToken: solvBTC,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv80
    });

    MarketParams memory xsolvBTCParams = MarketParams({
      loanToken: WBNB,
      collateralToken: xsolvBTC,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv75
    });
    vault.setFeeRecipient(feeRecipient);
    vault.setSkimRecipient(skimRecipient);

    vault.grantRole(CURATOR, deployer);
    vault.grantRole(ALLOCATOR, deployer);
    vault.setBotRole(bot);

    vault.setFee(fee);

    vault.setCap(solvBTCParams, 2_000_000 ether);
    vault.setCap(xsolvBTCParams, 1_000_000 ether);

    Id solvBTCId = solvBTCParams.id();
    Id xsolvBTCTId = xsolvBTCParams.id();
    Id[] memory supplyQueue = new Id[](2);
    supplyQueue[0] = solvBTCId;
    supplyQueue[1] = xsolvBTCTId;

    vault.setSupplyQueue(supplyQueue);

    uint256[] memory withdrawQueue = new uint256[](2);
    withdrawQueue[0] = 1;
    withdrawQueue[1] = 0;
    vault.updateWithdrawQueue(withdrawQueue);

    vault.setProvider(bnbProvider);
  }

  function configUSD1(address deployer, MoolahVault vault) internal {
    MarketParams memory solvBTCParams = MarketParams({
      loanToken: USD1,
      collateralToken: solvBTC,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv80
    });

    MarketParams memory xsolvBTCParams = MarketParams({
      loanToken: USD1,
      collateralToken: xsolvBTC,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv75
    });
    vault.setFeeRecipient(feeRecipient);
    vault.setSkimRecipient(skimRecipient);

    vault.grantRole(CURATOR, deployer);
    vault.grantRole(ALLOCATOR, deployer);
    vault.setBotRole(bot);

    vault.setFee(fee);

    vault.setCap(solvBTCParams, 50_000_000 ether);
    vault.setCap(xsolvBTCParams, 25_000_000 ether);

    Id solvBTCId = solvBTCParams.id();
    Id xsolvBTCTId = xsolvBTCParams.id();
    Id[] memory supplyQueue = new Id[](2);
    supplyQueue[0] = solvBTCId;
    supplyQueue[1] = xsolvBTCTId;

    vault.setSupplyQueue(supplyQueue);

    uint256[] memory withdrawQueue = new uint256[](2);
    withdrawQueue[0] = 1;
    withdrawQueue[1] = 0;
    vault.updateWithdrawQueue(withdrawQueue);
  }
}
