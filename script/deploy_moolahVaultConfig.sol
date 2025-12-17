pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { Id, MarketParams } from "moolah/interfaces/IMoolah.sol";

contract MoolahVaultConfigDeploy is Script {
  using MarketParamsLib for MarketParams;
  // todo update vault
  MoolahVault vault = MoolahVault(0x384729E442b7636709896e9a3bEf63EF70C22FB0);
  uint256 fee = 10 * 1e16;
  address feeRecipient = 0x2E2Eed557FAb1d2E11fEA1E1a23FF8f1b23551f3;
  address skimRecipient = 0x1d60bBBEF79Fb9540D271Dbb01925380323A8f66;
  address whiteList = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;

  address ETH = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;
  address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
  address BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
  address solvBTC = 0x4aae823a6a0b376De6A78e74eCC5b079d38cBCf7;
  address USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
  address USDT = 0x55d398326f99059fF775485246999027B3197955;
  address slisBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
  address Puffer = 0x87d00066cf131ff54B72B134a217D5401E5392b6;
  address SPA = 0x1A9Fd6eC3144Da3Dd6Ea13Ec1C25C58423a379b1;
  address Aster = 0x000Ae314E2A2172a039B26378814C252734f556A;
  address CDL = 0x84575b87395c970F1F48E87d87a8dB36Ed653716;
  address AT = 0x9be61A38725b265BC3eb7Bfdf17AfDFc9d26C130;
  address lisUSD = 0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5;
  address $U = 0xcE24439F2D9C6a2289F741120FE202248B666666;
  address $UUSDT = 0xbBD3e74E69e6BDDDA8e5AAdC1460611A8f7cd05a;

  address multiOracle = 0xf3afD82A4071f272F403dC176916141f44E6c750;
  address oracleAdapter = 0x21650E416dC6C89486B2E654c86cC2c36c597b58;
  address irm = 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c;
  address alphaIrm = 0x5F9f9173B405C6CEAfa7f98d09e4B8447e9797E6;
  address bot = 0x91fC4BA20685339781888eCA3E9E1c12d40F0e13;
  address $UUSDTSmartProvider = 0x9994D77E5cdcAD9f9055b13402A7BF8C24d4C841;

  uint256 lltv50 = 50 * 1e16;
  uint256 lltv70 = 70 * 1e16;
  uint256 lltv75 = 75 * 1e16;
  uint256 lltv80 = 80 * 1e16;
  uint256 lltv86 = 86 * 1e16;
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

    MarketParams memory WBNBParams = MarketParams({
      loanToken: $U,
      collateralToken: WBNB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    MarketParams memory slisBNBParams = MarketParams({
      loanToken: $U,
      collateralToken: slisBNB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    MarketParams memory BTCBParams = MarketParams({
      loanToken: $U,
      collateralToken: BTCB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv86
    });
    MarketParams memory USDTParams = MarketParams({
      loanToken: $U,
      collateralToken: USDT,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv965
    });
    MarketParams memory USD1Params = MarketParams({
      loanToken: $U,
      collateralToken: USD1,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv965
    });
    MarketParams memory USD1Params = MarketParams({
      loanToken: $U,
      collateralToken: USD1,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv965
    });
    MarketParams memory UUSDTParams = MarketParams({
      loanToken: $U,
      collateralToken: $UUSDT,
      oracle: $UUSDTSmartProvider,
      irm: irm,
      lltv: lltv965
    });

    vm.startBroadcast(deployerPrivateKey);
    vault.setFeeRecipient(feeRecipient);
    vault.setSkimRecipient(skimRecipient);

    vault.grantRole(CURATOR, deployer);
    vault.grantRole(ALLOCATOR, deployer);
    vault.setBotRole(bot);

    // config vault

    vault.setFee(fee);

    vault.setCap(WBNBParams, 50_000_000 ether);
    vault.setCap(slisBNBParams, 50_000_000 ether);
    vault.setCap(BTCBParams, 50_000_000 ether);
    vault.setCap(USDTParams, 50_000_000 ether);
    vault.setCap(USD1Params, 50_000_000 ether);
    vault.setCap(UUSDTParams, 50_000_000 ether);

    Id WBNBId = WBNBParams.id();
    Id slisBNBId = slisBNBParams.id();
    Id BTCBId = BTCBParams.id();
    Id USDTId = USDTParams.id();
    Id USD1Id = USD1Params.id();
    Id UUSDTId = UUSDTParams.id();
    Id[] memory supplyQueue = new Id[](6);
    supplyQueue[0] = WBNBId;
    supplyQueue[1] = slisBNBId;
    supplyQueue[2] = BTCBId;
    supplyQueue[3] = USDTId;
    supplyQueue[4] = USD1Id;
    supplyQueue[5] = UUSDTId;

    vault.setSupplyQueue(supplyQueue);
    vm.stopBroadcast();

    console.log("vault config done!");
  }
}
