pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { Moolah } from "moolah/Moolah.sol";
import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";

contract CreateMarketDeploy is Script {
  using MarketParamsLib for MarketParams;

  Moolah moolah = Moolah(0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C);
  address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
  address BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
  address solvBTC = 0x4aae823a6a0b376De6A78e74eCC5b079d38cBCf7;
  address ptClisBNB30Otc = 0xb84cEC1Ab2af11b530ae0d8594B1493556be49Cd;
  address USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
  address slisBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
  address ETH = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;
  address USDT = 0x55d398326f99059fF775485246999027B3197955;
  address ptSUSDe26JUN2025 = 0xDD809435ba6c9d6903730f923038801781cA66ce;
  address USDF = 0x5A110fC00474038f6c02E89C707D638602EA44B5;
  address asUSDF = 0x917AF46B3C3c6e1Bb7286B9F59637Fb7C65851Fb;
  address wstETH = 0x26c5e01524d2E6280A48F2c50fF6De7e52E9611C;
  address wBETH = 0xa2E3356610840701BDf5611a53974510Ae27E2e1;
  address USDe = 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34;
  address sUSDe = 0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2;
  address STONE = 0x80137510979822322193FC997d400D5A6C747bf7;
  address Puffer = 0x87d00066cf131ff54B72B134a217D5401E5392b6;
  address USDX = 0xf3527ef8dE265eAa3716FB312c12847bFBA66Cef;
  address sUSDX = 0x7788A3538C5fc7F9c7C8A74EAC4c898fC8d87d92;
  address USR = 0x2492D0006411Af6C8bbb1c8afc1B0197350a79e9;
  address ptUSDe7AUG2025 = 0x37fbFfE3a305E342c2cd00929A904e971c65Bafd;
  address lisUSD = 0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5;
  address puffETH = 0x64274835D88F5c0215da8AADd9A5f2D2A2569381;
  address AB = 0x95034f653D5D161890836Ad2B6b8cc49D14e029a;
  address B = 0x6bdcCe4A559076e37755a78Ce0c06214E59e4444;
  address B2 = 0x783c3f003f172c6Ac5AC700218a357d2D66Ee2a2;
  address xsolvBTC = 0x1346b618dC92810EC74163e4c27004c921D446a5;
  address ptSatUSD11SEP2025 = 0xB901c7A2D2Bc05D8B7e7eE4F7Fcf72CAaABd2F49;
  address ANKR = 0xf307910A4c7bbc79691fD374889b36d8531B08e3;
  address ptUSDe30OTC2025 = 0x607C834cfb7FCBbb341Cbe23f77A6E83bCf3F55c;
  address SPA = 0x1A9Fd6eC3144Da3Dd6Ea13Ec1C25C58423a379b1;
  address solvBTC_DLP = 0x647A50540F5a1058B206f5a3eB17f56f29127F53;
  address OIK = 0xB035723D62e0e2ea7499D76355c9D560f13ba404;
  address EGL1 = 0xf4B385849f2e817E92bffBfB9AEb48F950Ff4444;
  address ptSigmaLP25Sep2025 = 0xd76Ec0A96eAffe1cCa33313352dEdA1CD3Cfa7EE;
  address wstUSR = 0x4254813524695def4163A169e901f3d7a1a55429;
  address yUSD = 0x4772D2e014F9fC3a820C444e3313968e9a5C8121;
  address uniBTC = 0x6B2a01A5f79dEb4c2f3c0eDa7b01DF456FbD726a;
  address ptUSR27NOV2025 = 0x4a3846d069B800343D53e72B80a644Bb496D9aB2;
  address ptSatUSD18DEC2025 = 0x31E88bF4AC49EEf6711756D141F1A63E78F9F665;
  address WLFI = 0x47474747477b199288bF72a1D702f7Fe0Fb1DEeA;

  address multiOracle = 0xf3afD82A4071f272F403dC176916141f44E6c750;
  address oracleAdapter = 0x21650E416dC6C89486B2E654c86cC2c36c597b58;
  address ptOracle = 0x1a438f71bc56514F47142c96A8f580AB5767aC17;
  address ptSUSDeUSDTOracle = 0x89852C82e4a7aa41c7691b374d5D5Ef8487eC370;
  address ptSUSDeUSD1Oracle = 0xFd31ADF830Fd68d3E646792917e4dDB1d9AB5665;
  address ptUSDe7AUG2025USD1Oracle = 0x2311F923Ca3FdCfF03522700b482644A929dDE70;
  address ptUSDe7AUG2025USDTOracle = 0x1CCEfa30385d5Fd7c6259362eC110e403974d7A2;
  address ptSatUSD11SEP2025OUSDTracle = 0xbEf5DfecC869AAC441F58DB1042479562D170491;
  address ptUSDe30OTC2025USD1Oracle = 0x7CA108862bE7A4331A1Ae1c8DC6ed8d6D770110C;
  address ptUSDe30OTC2025USDTOracle = 0x13eA689fBDAaDa843F536Ef9C5a479C31D6960d1;
  address ptSigmaLP25Sep2025USD1Oracle = 0x68A892d8bC5A41503534C86F7F20a72322A2CDB1;
  address ptSigmaLP25Sep2025USDTOracle = 0x39D5348B0363AC9D0d4168Bac9A5B8A1E9DBd511;
  address ptUSR27NOV2025USD1Oracle = 0xC36a8F8Ad34A68942979bb50B7792862eFb59cF3;
  address ptUSR27NOV2025USDTOracle = 0x01ccc0f0ae8907bD3EFA947B2Ce841082Bcce29f;
  address ptSatUSD18DEC2025USD1Oracle = 0x0Ed93c1BF6F81cEd3d5D83b884Fe403A8cb9072E;
  address ptSatUSD18DEC2025USDTOracle = 0xe98E6D103347fcCB97861DA5071fDAc408fD991A;

  address irm = 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c;
  address alphaIrm = 0x5F9f9173B405C6CEAfa7f98d09e4B8447e9797E6;

  uint256 lltv33 = 33 * 1e16;
  uint256 lltv50 = 50 * 1e16;
  uint256 lltv60 = 60 * 1e16;
  uint256 lltv70 = 70 * 1e16;
  uint256 lltv75 = 75 * 1e16;
  uint256 lltv80 = 80 * 1e16;
  uint256 lltv85 = 85 * 1e16;
  uint256 lltv86 = 86 * 1e16;
  uint256 lltv865 = 865 * 1e15;
  uint256 lltv90 = 90 * 1e16;
  uint256 lltv915 = 915 * 1e15;
  uint256 lltv965 = 965 * 1e15;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    MarketParams[] memory params = new MarketParams[](4);
    params[0] = MarketParams({ loanToken: USD1, collateralToken: WLFI, oracle: multiOracle, irm: irm, lltv: lltv50 });
    params[1] = MarketParams({ loanToken: USDT, collateralToken: WLFI, oracle: multiOracle, irm: irm, lltv: lltv50 });
    params[2] = MarketParams({
      loanToken: USD1,
      collateralToken: ptSatUSD18DEC2025,
      oracle: ptSatUSD18DEC2025USD1Oracle,
      irm: irm,
      lltv: lltv915
    });
    params[3] = MarketParams({
      loanToken: USDT,
      collateralToken: ptSatUSD18DEC2025,
      oracle: ptSatUSD18DEC2025USDTOracle,
      irm: irm,
      lltv: lltv915
    });
    //
    vm.startBroadcast(deployerPrivateKey);
    for (uint256 i = 0; i < 4; i++) {
      Id id = params[i].id();
      console.log("market id:");
      console.logBytes32(Id.unwrap(id));
      // check if market already exists
      (, , , , uint128 lastUpdate, ) = moolah.market(id);
      if (lastUpdate != 0) {
        console.log("market already exists");
        continue;
      }
      // create market
      moolah.createMarket(params[i]);
      console.log("market created");
    }
    vm.stopBroadcast();
  }
}
