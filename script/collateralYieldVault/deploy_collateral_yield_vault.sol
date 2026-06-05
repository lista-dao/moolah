pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { MarketParams } from "moolah/interfaces/IMoolah.sol";
import { CollateralYieldVault } from "src/moolah-vault/CollateralYieldVault.sol";

/// @notice Deploys a CollateralYieldVault (asset = slisBNB) behind a UUPS proxy and seeds a dead first deposit
///         so `totalSupply` is never 0 (first-deposit inflation + last-redeemer dust mitigation).
///
/// Prerequisites (must already be true on-chain, else the seed step reverts):
///   - The slisBNB-collateral Moolah market exists and `SLIS_BNB_PROVIDER` is its registered provider.
///   - The vault is allowed as `onBehalf` on that market (Moolah market onBehalf whitelist is open or includes it).
///   - The provider's `slisBNBxMinter` is set and has spare MPC fee-wallet capacity.
contract DeployCollateralYieldVault is DeployBase {
  // --- BSC mainnet ---
  address constant SLIS_BNB_PROVIDER = 0x33f7A980a246f9B8FEA2254E3065576E127D4D5f;
  address constant SLIS_BNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
  address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
  address constant SLISBNB_ORACLE = 0x21650E416dC6C89486B2E654c86cC2c36c597b58;
  address constant IRM = 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c;
  uint256 constant LLTV = 965000000000000000; // 0.965e18

  // roles handed over after configuration
  address constant TIMELOCK = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253; // DEFAULT_ADMIN
  address constant VAULT_MANAGER = 0x8d388136d578dCD791D081c6042284CED6d9B0c6; // MANAGER
  address constant PAUSER = 0xEEfebb1546d88EA0909435DF6f615084DD3c5Bd8; // PAUSER

  // launchpool MPC (delegate target) — must be governance-approved
  address constant MPC1 = 0xD57E5321e67607Fab38347D96394e0E58509C506;

  // dead first deposit (BNB → slisBNB), shares minted to a burn address and never redeemed
  address constant DEAD = 0x000000000000000000000000000000000000dEaD;
  uint256 constant SEED_BNB = 0.02 ether;

  string constant NAME = "Four.meme slisBNB Vault";
  string constant SYMBOL = "fmSlisBNB";

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer:", deployer);

    MarketParams memory market = MarketParams({
      loanToken: WBNB,
      collateralToken: SLIS_BNB,
      oracle: SLISBNB_ORACLE,
      irm: IRM,
      lltv: LLTV
    });

    vm.startBroadcast(deployerPrivateKey);

    // 1. deploy impl + proxy; deployer is temporary admin + manager so it can configure & seed.
    CollateralYieldVault impl = new CollateralYieldVault(SLIS_BNB_PROVIDER);
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(CollateralYieldVault.initialize.selector, deployer, deployer, PAUSER, market, NAME, SYMBOL)
    );
    CollateralYieldVault vault = CollateralYieldVault(payable(address(proxy)));
    console.log("CollateralYieldVault impl:", address(impl));
    console.log("CollateralYieldVault proxy:", address(vault));
    require(vault.asset() == SLIS_BNB, "asset mismatch");

    // 2. delegate slisBNBx to the governance-approved MPC.
    vault.setDelegateTarget(MPC1);

    // 3. dead seed deposit: keeps totalSupply > 0 forever (whitelist still empty == open here).
    uint256 seedShares = vault.depositBNB{ value: SEED_BNB }(DEAD);
    console.log("Seed shares minted to dead address:", seedShares);
    require(vault.totalSupply() == seedShares && seedShares > 0, "seed failed");

    // 4. hand over roles to governance and drop the deployer's powers.
    vault.grantRole(vault.MANAGER(), VAULT_MANAGER);
    vault.grantRole(vault.DEFAULT_ADMIN_ROLE(), TIMELOCK);
    vault.renounceRole(vault.MANAGER(), deployer);
    vault.renounceRole(vault.DEFAULT_ADMIN_ROLE(), deployer);

    vm.stopBroadcast();

    console.log("Done. Remaining steps for governance:");
    console.log(" - populate user whitelist (setWhiteList) if access is gated");
    console.log(" - deploy RewardHarvester and grant it the BOT role (grantRole BOT, harvester)");
  }
}
