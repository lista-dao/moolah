pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { LiquidationVault } from "liquidator/LiquidationVault.sol";

/// @dev Step 2 of rollout — VAULT-SIDE config only, run by the deployer while it still holds the fresh
///      vault's MANAGER role (i.e. BEFORE the role-transfer script). It performs NO action on the live
///      Liquidator/BrokerLiquidator, so it cannot revert on their multisig-held MANAGER.
///
///      setFundSource on the live liquidators + reserve migration (collect*) are a SEPARATE, multisig-
///      executed step — see deploy_liquidationVaultWire.sol. Role handover — see
///      deploy_liquidationVaultTransferRole.sol.
///
/// IMPORTANT: the sell/collect whitelist MUST include every whitelisted market's LOAN token as
/// well as its collateral — the vault's job is to sell seized collateral INTO the loan token and to
/// refill the pool via provideFund. Verify each address below against the live market params before
/// running; token labels differ across registries.
contract LiquidationVaultConfigDeploy is DeployBase {
  // ---- fill the freshly-deployed vault; guarded so a half-config run reverts ----
  LiquidationVault vault = LiquidationVault(payable(address(0)));

  // Live liquidators to REGISTER on the vault. setLiquidator is a vault-side MANAGER op, so it runs
  // here (deployer still holds the fresh vault's MANAGER) — and it MUST precede each liquidator's
  // setFundSource in the multisig wire step, which reverts unless vault.liquidators(liquidator) == true.
  address liquidator = 0x6a87C15598929B2db22cF68a9a0dDE5Bf297a59a;
  address brokerLiquidator = 0x3AA647a1e902833b61E503DbBFbc58992daa4868;

  // ResilientOracle used by the sell loss guard (peek() -> 8-decimal USD).
  address resilientOracle = 0xf3afD82A4071f272F403dC176916141f44E6c750; // ResilientOracle (mainnet)
  // Revenue collector (DEX fee + liquidation profit). Enabling it ALSO requires the reciprocal
  // RevenueCollector.updateLiquidator(vault, true) on the collector side (done in the multisig wire
  // step), and it grants the collector uncapped withdraw* pull authority over the whole vault.
  address revenueCollector = 0x86E09296aeDA129D3b0b4c134B3202b84Cd8945C;

  address constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
  address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
  // Pair/router used for sells (1inch aggregation router).
  address pair = 0x111111125421cA6dc452d289314280a0f8842A65;

  /// @dev Every token any whitelisted market uses as LOAN or collateral, plus BNB_ADDRESS (for
  ///      sellBNB/collectETH). LOAN tokens (lisUSD/USDT/USD1/WBNB) are required, not optional.
  function _whitelistTokens() internal pure returns (address[] memory t) {
    // Every LOAN or COLLATERAL token across all markets served by Liquidator/BrokerLiquidator (moolah
    // markets snapshot 2026-07-10), plus BNB_ADDRESS. Smart-LP collateral (StableSwapLPCollateral) is
    // intentionally EXCLUDED — it is reflow-blacklisted on the liquidators and never sold by the vault.
    t = new address[](77);
    t[0] = BNB_ADDRESS;
    t[1] = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d; // USD1
    t[2] = 0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5; // lisUSD
    t[3] = 0xcE24439F2D9C6a2289F741120FE202248B666666; // U
    t[4] = 0x84575b87395c970F1F48E87d87a8dB36Ed653716; // CDL
    t[5] = 0x55d398326f99059fF775485246999027B3197955; // USDT
    t[6] = 0x95034f653D5D161890836Ad2B6b8cc49D14e029a; // AB
    t[7] = 0x1A9Fd6eC3144Da3Dd6Ea13Ec1C25C58423a379b1; // SPA
    t[8] = 0xB035723D62e0e2ea7499D76355c9D560f13ba404; // OIK
    t[9] = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d; // USDC
    t[10] = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c; // WBNB
    t[11] = 0x1D2F0da169ceB9fC7B3144628dB156f3F6c60dBE; // XRP
    t[12] = 0xE747E54783Ba3F77a8E5251a3cBA19EBe9C0E197; // TAKE
    t[13] = 0x6bdcCe4A559076e37755a78Ce0c06214E59e4444; // B
    t[14] = 0x87d00066cf131ff54B72B134a217D5401E5392b6; // PUFFER
    t[15] = 0x783c3f003f172c6Ac5AC700218a357d2D66Ee2a2; // B2
    t[16] = 0x9be61A38725b265BC3eb7Bfdf17AfDFc9d26C130; // AT
    t[17] = 0x000Ae314E2A2172a039B26378814C252734f556A; // ASTER
    t[18] = 0xf4B385849f2e817E92bffBfB9AEb48F950Ff4444; // EGL1
    t[19] = 0x21cAef8A43163Eea865baeE23b9C2E327696A3bf; // XAUt
    t[20] = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c; // BTCB
    t[21] = 0x77734e70b6E88b4d82fE632a168EDf6e700912b6; // asBNB
    t[22] = 0xDa182944E84092e11370CA521f10AEF488888888; // $U
    t[23] = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B; // slisBNB
    t[24] = 0x5A110fC00474038f6c02E89C707D638602EA44B5; // USDF
    t[25] = 0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2; // sUSDe
    t[26] = 0x7E318884f6f299031F4Fa88D7A324E076d460A4b; // PT-USDe-7MAY2026-(ETH)
    t[27] = 0x7788A3538C5fc7F9c7C8A74EAC4c898fC8d87d92; // sUSDX
    t[28] = 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34; // USDe
    t[29] = 0x54a8F370575fe98c305640D7D11B8aa2df451B13; // PT-reUSD-25JUN2026-(ETH)
    t[30] = 0x4aae823a6a0b376De6A78e74eCC5b079d38cBCf7; // SolvBTC
    t[31] = 0xf3527ef8dE265eAa3716FB312c12847bFBA66Cef; // USDX
    t[32] = 0x721105716Ab5419f1aAADbbC7835e3eaBd7e067d; // PT-sUSDE-7MAY2026-(ETH)
    t[33] = 0x4aa18834211Fb3E2B6cBD14b5e22B33c2C0475c2; // PT-USDG-28MAY2026-(ETH)
    t[34] = 0x917AF46B3C3c6e1Bb7286B9F59637Fb7C65851Fb; // asUSDF
    t[35] = 0xf307910A4c7bbc79691fD374889b36d8531B08e3; // ANKR
    t[36] = 0xEA5FF211eF700DccC521a1e6501C9fe1B95D8EE7; // wNLP-USDT
    t[37] = 0x7EB92A12a15E8a019A26A8b344F1e59b14cb8Ad3; // PT-sUSDE-9APR2026-(PLASMA)
    t[38] = 0xc8739fbBd54C587a2ad43b50CbcC30ae34FE9e34; // mXRP
    t[39] = 0x67e84bA0196738A59EE58df848A2c16ED2A6A6F3; // PT-USDe-9APR2026-(PLASMA)
    t[40] = 0xa2E3356610840701BDf5611a53974510Ae27E2e1; // wBETH
    t[41] = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8; // ETH
    t[42] = 0x1f9831626CE85909794eEaA5C35BF34DB3eB52d8; // lisCredit
    t[43] = 0x47474747477b199288bF72a1D702f7Fe0Fb1DEeA; // WLFI
    t[44] = 0x6254500243135573A948d7a5F90c307Cd7973f43; // PT-USDe-5FEB2026-(ETH)
    t[45] = 0x31E88bF4AC49EEf6711756D141F1A63E78F9F665; // PT-satUSD+-18DEC2025
    t[46] = 0xDD809435ba6c9d6903730f923038801781cA66ce; // PT-sUSDE-26JUN2025
    t[47] = 0xe052823b4aefc6e230FAf46231A57d0905E30AE0; // PT-clisBNB-25JUN2026
    t[48] = 0x4F2760B32720F013E900DC92F65480137391199b; // sUSD1+
    t[49] = 0x0EA46a4C257071352b57E9F6d054fC137F6E14b9; // PT-srUSDe-2APR2026-(ETH)
    t[50] = 0x647A50540F5a1058B206f5a3eB17f56f29127F53; // SolvBTC.DLP
    t[51] = 0xB901c7A2D2Bc05D8B7e7eE4F7Fcf72CAaABd2F49; // PT-satUSD+-11SEP2025
    t[52] = 0x26c5e01524d2E6280A48F2c50fF6De7e52E9611C; // wstETH
    t[53] = 0x607C834cfb7FCBbb341Cbe23f77A6E83bCf3F55c; // PT-USDe-30OCT2025
    t[54] = 0x4254813524695def4163A169e901f3d7a1a55429; // wstUSR
    t[55] = 0x4772D2e014F9fC3a820C444e3313968e9a5C8121; // yUSD
    t[56] = 0xb84cEC1Ab2af11b530ae0d8594B1493556be49Cd; // PT-clisBNB-30OCT2025
    t[57] = 0xd76Ec0A96eAffe1cCa33313352dEdA1CD3Cfa7EE; // PT-sigmaSP-25SEP2025
    t[58] = 0xE8F1C9804770e11Ab73395bE54686Ad656601E9e; // PT-clisBNB-24APR2025
    t[59] = 0x2492D0006411Af6C8bbb1c8afc1B0197350a79e9; // USR
    t[60] = 0x37fbFfE3a305E342c2cd00929A904e971c65Bafd; // PT-USDe-7AUG2025
    t[61] = 0x4a3846d069B800343D53e72B80a644Bb496D9aB2; // PT-USR-27NOV2025
    t[62] = 0x64274835D88F5c0215da8AADd9A5f2D2A2569381; // xPufETH
    t[63] = 0x6B2a01A5f79dEb4c2f3c0eDa7b01DF456FbD726a; // uniBTC
    t[64] = 0x80137510979822322193FC997d400D5A6C747bf7; // STONE
    t[65] = 0x4809010926aec940b550D34a46A52739f996D75D; // wsrUSD
    t[66] = 0x1346b618dC92810EC74163e4c27004c921D446a5; // xSolvBTC
    t[67] = 0x3d383503fc6df144a1cbf0CD588a78835f54672c; // PT-sUSDE-18JUN2026-(PLASMA)
    t[68] = 0x1e798C7fcE8B3Cdce8950f8Ff5a0C62f1Dc7d532; // PT-sUSDai-15OCT2026-(ARB)
    t[69] = 0x9E9093A12b343C0f4d519Ab093BEF989b1936F73; // PT-stcUSD-23JUL2026-(ETH)
    t[70] = 0x8E9d4cEa39299323FE8eda678cAD449718556c4e; // syrupUSDT
    t[71] = 0x5b1910eAaD6450E50f816082Aa078C41F10C292f; // TSLAB
    t[72] = 0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436; // NVDAB
    t[73] = 0x80f3D493EBCe97e343c53D29a137942416B4ffC0; // CRCLB
    t[74] = 0x3eE4dF61bd4F867E349BEaE8bFE07bc31b4850fb; // SNDKB
    t[75] = 0xcdf2f3e0fa43C47A6662a91C9E4a7C5f69762699; // MUB
    t[76] = 0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1; // SPCXB
  }

  function run() public {
    require(address(vault) != address(0), "set vault");
    require(resilientOracle != address(0) && pair != address(0), "set oracle/pair");

    uint256 deployerPrivateKey = _deployerKey();
    console.log("Deployer: ", vm.addr(deployerPrivateKey));
    address[] memory tokens = _whitelistTokens();

    vm.startBroadcast(deployerPrivateKey);

    vault.setOracle(resilientOracle);
    for (uint256 i = 0; i < tokens.length; i++) {
      require(tokens[i] != address(0), "zero token");
      if (!vault.tokenWhitelist(tokens[i])) vault.setTokenWhitelist(tokens[i], true);
    }
    vault.setPairWhitelist(pair, true);

    // register the live liquidators on the vault (allow-list for provideFund + collect*). Vault-side
    // MANAGER op; precedes the liquidators' setFundSource (multisig wire step).
    if (liquidator != address(0) && !vault.liquidators(liquidator)) vault.setLiquidator(liquidator, true);
    if (brokerLiquidator != address(0) && !vault.liquidators(brokerLiquidator)) {
      vault.setLiquidator(brokerLiquidator, true);
    }

    // maxSwapLossBp (5%) / maxDailyLossUsd ($1000) come from initialize(); set an appropriate
    // per-pool value here for mainnet via vault.setMaxDailyLossUsd(...) if desired.

    if (revenueCollector != address(0)) vault.setRevenueCollector(revenueCollector);

    vm.stopBroadcast();
    console.log("LiquidationVault vault-side config done. Next: transfer roles, then wire (multisig).");
  }
}
