pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../../DeployBase.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ERC20Mock } from "moolah/mocks/ERC20Mock.sol";
import { OracleMock } from "moolah/mocks/OracleMock.sol";
import { Moolah } from "moolah/Moolah.sol";
import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { StableSwapLPCollateral } from "src/dex/StableSwapLPCollateral.sol";
import { SmartProvider } from "src/provider/SmartProvider.sol";

interface IStableSwapFactory {
  function createSwapPair(
    address _tokenA,
    address _tokenB,
    string calldata _name,
    string calldata _symbol,
    uint256 _A,
    uint256 _fee,
    uint256 _admin_fee,
    address _admin,
    address _manager,
    address _pauser,
    address _oracle
  ) external returns (address lp, address swapContract);

  function grantRole(bytes32 role, address account) external;

  function hasRole(bytes32 role, address account) external view returns (bool);
}

interface IETHProvider {
  function addVault(address vault) external;
}

/// @notice Sepolia-ONLY: Deploy mock infrastructure + configure Moolah for Phase 2 testing.
///   This script handles all testnet provisioning that has no mainnet equivalent:
///     Section 1: Deploy mock tokens (wstETH, wBETH, USDC)
///     Section 2: Create WBTC/cbBTC StableSwap pool + LP Collateral + SmartProvider
///     Section 3: Configure oracle prices
///     Section 4: Enable LLTV + IRM on Moolah
///
///   Run this BEFORE the main Phase 2 deploy scripts (createMarket, vault, etc).
///   After running, use the output addresses as env vars for the main scripts.
///
///   Usage:
///     forge script script/eth/phase2/deploy_sepoliaSetup.sol --rpc-url sepolia --broadcast --via-ir
contract SepoliaSetupDeploy is DeployBase {
  using MarketParamsLib for MarketParams;

  // ─── Sepolia known addresses ────────────────────────────────────
  Moolah constant moolah = Moolah(0x29c53B75b4CD3CeC0B58F935dC642fF47B708d65);
  OracleMock constant mockOracle = OracleMock(0x624C651254A3B1EA7A3347186A0B3b95A20f83E8);
  address constant IRM = 0x987ECD52B37a7F76C5c9f590f8F6F52Cd85b82d8;
  address constant WETH = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;
  address constant USDT = 0xC5543Af4dE1a3972e8D1dBd0831dE97941ACd358;
  address constant WBTC = 0xD4151B2B7087e305f29E4032f8531Be42dFf5568;
  address constant CBBTC = 0x95188a991d9779C9B98C9c4b6b9632C59cD774ee;
  IStableSwapFactory constant SS_FACTORY = IStableSwapFactory(0x3D46B2264b1B2C5d592Fa999C92E4E2bB1154B81);
  address constant SS_INFO = 0x7238913812f70b08a217cd417A06ce4C1742017C;
  address constant ETH_PROVIDER = 0xA78Eb854f751FC1f2cd18EA176594a1303b156e4;
  address constant LIQUIDATOR = 0x875856e6B80795bD4edB6F4cCc6dD13150d21E99;
  address constant PUBLIC_LIQUIDATOR = 0x10cC9007487B62C6F83a98a1d15b55c25328010a;

  // ─── Pool parameters ────────────────────────────────────────────
  uint256 constant POOL_A = 2000; // high A for BTC/BTC pair
  uint256 constant POOL_FEE = 4000000; // 0.04%
  uint256 constant POOL_ADMIN_FEE = 5000000000; // 50% of fee

  // ─── Oracle prices (8 decimals) ─────────────────────────────────
  // Approximate testnet prices — not production critical
  uint256 constant PRICE_ETH = 2500e8; // $2500
  uint256 constant PRICE_WSTETH = 2900e8; // $2900 (~1.16 ETH)
  uint256 constant PRICE_WBETH = 2600e8; // $2600 (~1.04 ETH)
  uint256 constant PRICE_BTC = 65000e8; // $65000
  uint256 constant PRICE_USDT = 1e8; // $1
  uint256 constant PRICE_USDC = 1e8; // $1

  bytes32 constant DEPLOYER_ROLE = keccak256("DEPLOYER");
  bytes32 constant MANAGER_ROLE = keccak256("MANAGER");

  function run() public {
    require(block.chainid == 11155111, "SepoliaSetupDeploy: Sepolia only");

    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer:", deployer);

    vm.startBroadcast(deployerPrivateKey);

    // ════════════════════════════════════════════════════════════════
    // Section 1: Deploy mock tokens
    // ════════════════════════════════════════════════════════════════
    ERC20Mock wstETH = new ERC20Mock();
    wstETH.setName("Wrapped stETH (Mock)");
    wstETH.setSymbol("wstETH");
    console.log("[Section 1] wstETH mock:", address(wstETH));

    ERC20Mock wBETH = new ERC20Mock();
    wBETH.setName("Wrapped Binance ETH (Mock)");
    wBETH.setSymbol("wBETH");
    console.log("[Section 1] wBETH mock:", address(wBETH));

    ERC20Mock usdc = new ERC20Mock();
    usdc.setName("USD Coin (Mock)");
    usdc.setSymbol("USDC");
    usdc.setDecimals(6);
    console.log("[Section 1] USDC mock:", address(usdc));

    // ════════════════════════════════════════════════════════════════
    // Section 2: WBTC/cbBTC StableSwap pool + LP Collateral + SmartProvider
    // ════════════════════════════════════════════════════════════════

    // 2a. Grant DEPLOYER role on Factory if needed
    if (!SS_FACTORY.hasRole(DEPLOYER_ROLE, deployer)) {
      SS_FACTORY.grantRole(DEPLOYER_ROLE, deployer);
      console.log("[Section 2] Granted DEPLOYER role on Factory");
    }

    // 2b. Create StableSwap pool (WBTC/cbBTC)
    (address poolLP, address poolSwap) = SS_FACTORY.createSwapPair(
      WBTC,
      CBBTC,
      "WBTC/cbBTC LP",
      "WBTC-cbBTC-LP",
      POOL_A,
      POOL_FEE,
      POOL_ADMIN_FEE,
      deployer, // admin
      deployer, // manager
      deployer, // pauser
      address(mockOracle) // oracle for pool internal pricing
    );
    console.log("[Section 2] StableSwap pool:", poolSwap);
    console.log("[Section 2] StableSwap LP:", poolLP);

    // 2c. Deploy StableSwapLPCollateral (minter=deployer temporarily)
    StableSwapLPCollateral lpCollateralImpl = new StableSwapLPCollateral(address(moolah));
    ERC1967Proxy lpCollateralProxy = new ERC1967Proxy(
      address(lpCollateralImpl),
      abi.encodeWithSelector(
        StableSwapLPCollateral.initialize.selector,
        deployer, // admin
        deployer, // minter (temporary, will be replaced by SmartProvider)
        "WBTC/cbBTC LP Collateral",
        "WBTC-cbBTC-LPC"
      )
    );
    address lpCollateral = address(lpCollateralProxy);
    console.log("[Section 2] StableSwapLPCollateral:", lpCollateral);

    // 2d. Deploy SmartProvider
    SmartProvider smartProviderImpl = new SmartProvider(address(moolah), lpCollateral);
    ERC1967Proxy smartProviderProxy = new ERC1967Proxy(
      address(smartProviderImpl),
      abi.encodeWithSelector(
        SmartProvider.initialize.selector,
        deployer, // admin
        poolSwap, // dex (StableSwap pool)
        SS_INFO, // dexInfo
        address(mockOracle) // resilientOracle
      )
    );
    address smartProvider = address(smartProviderProxy);
    console.log("[Section 2] SmartProvider:", smartProvider);

    // 2e. Set SmartProvider as minter on LPCollateral
    StableSwapLPCollateral(lpCollateral).setMinter(smartProvider);
    console.log("[Section 2] LPCollateral minter set to SmartProvider");

    // ════════════════════════════════════════════════════════════════
    // Section 3: Configure oracle prices
    // ════════════════════════════════════════════════════════════════
    mockOracle.setPrice(WETH, PRICE_ETH);
    mockOracle.setPrice(address(wstETH), PRICE_WSTETH);
    mockOracle.setPrice(address(wBETH), PRICE_WBETH);
    mockOracle.setPrice(USDT, PRICE_USDT);
    mockOracle.setPrice(address(usdc), PRICE_USDC);
    mockOracle.setPrice(WBTC, PRICE_BTC);
    mockOracle.setPrice(CBBTC, PRICE_BTC);
    console.log("[Section 3] Oracle prices set for all tokens");

    // ════════════════════════════════════════════════════════════════
    // Section 4: Enable LLTV + IRM on Moolah
    // ════════════════════════════════════════════════════════════════
    // Note: These require MANAGER role on Moolah. If deployer doesn't have it,
    // these calls will revert — grant MANAGER first via cast or admin multisig.
    if (!moolah.isLltvEnabled(0.965 ether)) {
      moolah.enableLltv(0.965 ether);
      console.log("[Section 4] Enabled LLTV 96.5%");
    }
    if (!moolah.isLltvEnabled(0.80 ether)) {
      moolah.enableLltv(0.80 ether);
      console.log("[Section 4] Enabled LLTV 80%");
    }
    if (!moolah.isIrmEnabled(IRM)) {
      moolah.enableIrm(IRM);
      console.log("[Section 4] Enabled IRM");
    }

    vm.stopBroadcast();

    // ════════════════════════════════════════════════════════════════
    // Output: env vars for main deploy scripts
    // ════════════════════════════════════════════════════════════════
    console.log("");
    console.log("============ ENV VARS FOR MAIN SCRIPTS ============");
    console.log("WSTETH=", address(wstETH));
    console.log("WBETH=", address(wBETH));
    console.log("USDC=", address(usdc));
    console.log("WBTC_CBBTC_LP=", lpCollateral);
    console.log("WBTC_CBBTC_SMART_PROVIDER=", smartProvider);
    console.log("====================================================");
    console.log("");
    console.log("NEXT STEPS (after running main deploy scripts 2-4):");
    console.log("  1. setProvider on Moolah for SmartProvider markets");
    console.log("  2. ETHProvider.addVault(WETH_VAULT)");
    console.log("  3. Configure liquidation whitelist");
  }
}
