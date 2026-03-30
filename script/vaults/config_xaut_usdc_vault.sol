pragma solidity 0.8.34;

import "forge-std/Script.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { Id, MarketParams } from "moolah/interfaces/IMoolah.sol";

contract ConfigXautUsdcVault is Script {
  using MarketParamsLib for MarketParams;

  // todo update vault addresses after deployment
  MoolahVault xautVault = MoolahVault(address(0));
  MoolahVault usdcVault = MoolahVault(address(0));

  uint256 fee = 10 * 1e16;
  address feeRecipient = 0x2E2Eed557FAb1d2E11fEA1E1a23FF8f1b23551f3;
  address skimRecipient = 0x1d60bBBEF79Fb9540D271Dbb01925380323A8f66;
  address whiteList = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
  address bot = 0x91fC4BA20685339781888eCA3E9E1c12d40F0e13;

  // tokens
  address XAUT = 0x21cAef8A43163Eea865baeE23b9C2E327696A3bf;
  address USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
  address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
  address slisBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
  address BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
  address ETH = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;
  address wBETH = 0xa2E3356610840701BDf5611a53974510Ae27E2e1;
  address USDT = 0x55d398326f99059fF775485246999027B3197955;
  address $U = 0xcE24439F2D9C6a2289F741120FE202248B666666;
  address USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
  address USDT_USDC_LP = 0x23BC296d67619eA11C9a8B49B8C396B798AF3330;
  address BNB_slisBNB_LP = 0x719f6445cdAC08B84611D0F19d733F57214bcfee;

  // oracles
  address multiOracle = 0xf3afD82A4071f272F403dC176916141f44E6c750;
  address smartProviderUsdcUsdt = 0x5fD3971104cF3bAB1dC89EF904Da26F54f75C06B;
  address smartProviderBnbSlisBnb = 0xC3be83DE4b19aFC4F6021Ea5011B75a3542024dE;

  // irm
  address irm = 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c;

  // lltv values
  uint256 lltv70 = 70 * 1e16;
  uint256 lltv72 = 72 * 1e16;
  uint256 lltv75 = 75 * 1e16;
  uint256 lltv80 = 80 * 1e16;
  uint256 lltv965 = 965 * 1e15;

  bytes32 public constant CURATOR = keccak256("CURATOR");
  bytes32 public constant ALLOCATOR = keccak256("ALLOCATOR");

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    vm.startBroadcast(deployerPrivateKey);

    _configXautVault(deployer);
    _configUsdcVault(deployer);

    vm.stopBroadcast();

    console.log("vault config done!");
  }

  function _configXautVault(address deployer) internal {
    xautVault.setFeeRecipient(feeRecipient);
    xautVault.setSkimRecipient(skimRecipient);
    xautVault.grantRole(CURATOR, deployer);
    xautVault.grantRole(ALLOCATOR, deployer);
    xautVault.setBotRole(bot);
    xautVault.setFee(fee);

    // XAUT vault markets (loanToken = XAUT)
    MarketParams memory xautWbnb = MarketParams({
      loanToken: XAUT,
      collateralToken: WBNB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv72
    });
    MarketParams memory xautSlisBnb = MarketParams({
      loanToken: XAUT,
      collateralToken: slisBNB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv72
    });
    MarketParams memory xautBtcb = MarketParams({
      loanToken: XAUT,
      collateralToken: BTCB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv75
    });
    MarketParams memory xautEth = MarketParams({
      loanToken: XAUT,
      collateralToken: ETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv70
    });
    MarketParams memory xautWbeth = MarketParams({
      loanToken: XAUT,
      collateralToken: wBETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv70
    });
    MarketParams memory xautUsdt = MarketParams({
      loanToken: XAUT,
      collateralToken: USDT,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv80
    });
    MarketParams memory xautU = MarketParams({
      loanToken: XAUT,
      collateralToken: $U,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv80
    });
    MarketParams memory xautUsd1 = MarketParams({
      loanToken: XAUT,
      collateralToken: USD1,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv80
    });
    MarketParams memory xautUsdtUsdcLp = MarketParams({
      loanToken: XAUT,
      collateralToken: USDT_USDC_LP,
      oracle: smartProviderUsdcUsdt,
      irm: irm,
      lltv: lltv80
    });
    MarketParams memory xautBnbSlisBnbLp = MarketParams({
      loanToken: XAUT,
      collateralToken: BNB_slisBNB_LP,
      oracle: smartProviderBnbSlisBnb,
      irm: irm,
      lltv: lltv72
    });

    xautVault.setCap(xautWbnb, 50_000 ether);
    xautVault.setCap(xautSlisBnb, 50_000 ether);
    xautVault.setCap(xautBtcb, 50_000 ether);
    xautVault.setCap(xautEth, 50_000 ether);
    xautVault.setCap(xautWbeth, 50_000 ether);
    xautVault.setCap(xautUsdt, 50_000 ether);
    xautVault.setCap(xautU, 50_000 ether);
    xautVault.setCap(xautUsd1, 50_000 ether);
    xautVault.setCap(xautUsdtUsdcLp, 50_000 ether);
    xautVault.setCap(xautBnbSlisBnbLp, 50_000 ether);

    Id[] memory xautSupplyQueue = new Id[](10);
    xautSupplyQueue[0] = xautWbnb.id();
    xautSupplyQueue[1] = xautSlisBnb.id();
    xautSupplyQueue[2] = xautBtcb.id();
    xautSupplyQueue[3] = xautEth.id();
    xautSupplyQueue[4] = xautWbeth.id();
    xautSupplyQueue[5] = xautUsdt.id();
    xautSupplyQueue[6] = xautU.id();
    xautSupplyQueue[7] = xautUsd1.id();
    xautSupplyQueue[8] = xautUsdtUsdcLp.id();
    xautSupplyQueue[9] = xautBnbSlisBnbLp.id();

    xautVault.setSupplyQueue(xautSupplyQueue);
  }

  function _configUsdcVault(address deployer) internal {
    usdcVault.setFeeRecipient(feeRecipient);
    usdcVault.setSkimRecipient(skimRecipient);
    usdcVault.grantRole(CURATOR, deployer);
    usdcVault.grantRole(ALLOCATOR, deployer);
    usdcVault.setBotRole(bot);
    usdcVault.setFee(fee);

    // USDC vault markets (loanToken = USDC)
    MarketParams memory usdcBtcb = MarketParams({
      loanToken: USDC,
      collateralToken: BTCB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv80
    });
    MarketParams memory usdcWbnb = MarketParams({
      loanToken: USDC,
      collateralToken: WBNB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv80
    });
    MarketParams memory usdcSlisBnb = MarketParams({
      loanToken: USDC,
      collateralToken: slisBNB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv80
    });
    MarketParams memory usdcEth = MarketParams({
      loanToken: USDC,
      collateralToken: ETH,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv70
    });
    MarketParams memory usdcUsdtUsdcLp = MarketParams({
      loanToken: USDC,
      collateralToken: USDT_USDC_LP,
      oracle: smartProviderUsdcUsdt,
      irm: irm,
      lltv: lltv965
    });
    MarketParams memory usdcBnbSlisBnbLp = MarketParams({
      loanToken: USDC,
      collateralToken: BNB_slisBNB_LP,
      oracle: smartProviderBnbSlisBnb,
      irm: irm,
      lltv: lltv80
    });
    MarketParams memory usdcUsdt = MarketParams({
      loanToken: USDC,
      collateralToken: USDT,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv965
    });
    MarketParams memory usdcU = MarketParams({
      loanToken: USDC,
      collateralToken: $U,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv965
    });
    MarketParams memory usdcUsd1 = MarketParams({
      loanToken: USDC,
      collateralToken: USD1,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv965
    });

    usdcVault.setCap(usdcBtcb, 50_000_000 ether);
    usdcVault.setCap(usdcWbnb, 50_000_000 ether);
    usdcVault.setCap(usdcSlisBnb, 50_000_000 ether);
    usdcVault.setCap(usdcEth, 50_000_000 ether);
    usdcVault.setCap(usdcUsdtUsdcLp, 50_000_000 ether);
    usdcVault.setCap(usdcBnbSlisBnbLp, 50_000_000 ether);
    usdcVault.setCap(usdcUsdt, 50_000_000 ether);
    usdcVault.setCap(usdcU, 50_000_000 ether);
    usdcVault.setCap(usdcUsd1, 50_000_000 ether);

    Id[] memory usdcSupplyQueue = new Id[](9);
    usdcSupplyQueue[0] = usdcBtcb.id();
    usdcSupplyQueue[1] = usdcWbnb.id();
    usdcSupplyQueue[2] = usdcSlisBnb.id();
    usdcSupplyQueue[3] = usdcEth.id();
    usdcSupplyQueue[4] = usdcUsdtUsdcLp.id();
    usdcSupplyQueue[5] = usdcBnbSlisBnbLp.id();
    usdcSupplyQueue[6] = usdcUsdt.id();
    usdcSupplyQueue[7] = usdcU.id();
    usdcSupplyQueue[8] = usdcUsd1.id();

    usdcVault.setSupplyQueue(usdcSupplyQueue);
  }
}
