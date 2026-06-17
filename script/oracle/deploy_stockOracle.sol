pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../DeployBase.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { StockOracle } from "../../src/oracle/StockOracle.sol";
import { StockOracleSwitch } from "../../src/oracle/StockOracleSwitch.sol";

/// @notice Deploys StockOracleSwitch + StockOracle (UUPS proxies) and registers the managed bStocks.
///         admin = manager = deployer (hand off later via deploy_stockOracleTransferRole.sol);
///         BOT is a dedicated wallet. Network config (resilient oracle, bot, stock list) is resolved
///         by chain id. The market stays CLOSED after deploy (globalEnabled = false) until the BOT opens it.
contract StockOracleDeploy is DeployBase {
  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    (address resilientOracle, address bot, address pauser, address[] memory stocks) = _config(deployer);

    console.log("Deployer:          ", deployer);
    console.log("Bot:               ", bot);
    console.log("Pauser:            ", pauser);
    console.log("Resilient oracle:  ", resilientOracle);
    vm.startBroadcast(deployerPrivateKey);

    // --- StockOracleSwitch (impl + proxy): admin = manager = deployer, bot + pauser = dedicated wallets ---
    StockOracleSwitch switchImpl = new StockOracleSwitch();
    console.log("StockOracleSwitch implementation: ", address(switchImpl));
    StockOracleSwitch stockSwitch = StockOracleSwitch(
      address(
        new ERC1967Proxy(
          address(switchImpl),
          abi.encodeWithSelector(switchImpl.initialize.selector, deployer, deployer, bot, pauser)
        )
      )
    );
    console.log("StockOracleSwitch proxy: ", address(stockSwitch));

    // --- StockOracle (impl + proxy): admin = manager = deployer ---
    StockOracle oracleImpl = new StockOracle();
    console.log("StockOracle implementation: ", address(oracleImpl));
    StockOracle oracle = StockOracle(
      address(
        new ERC1967Proxy(
          address(oracleImpl),
          abi.encodeWithSelector(
            oracleImpl.initialize.selector,
            deployer,
            deployer,
            address(stockSwitch),
            resilientOracle
          )
        )
      )
    );
    console.log("StockOracle proxy: ", address(oracle));

    // --- Register managed bStocks. setStock also enables each per-stock; the market stays closed
    //     globally until the BOT calls setGlobal(true) during trading hours. ---
    for (uint256 i = 0; i < stocks.length; i++) {
      stockSwitch.setStock(stocks[i], true);
      console.log("registered stock: ", stocks[i]);
    }

    vm.stopBroadcast();
  }

  /// @dev Per-network configuration (resilient oracle, bot wallet, managed bStock list).
  function _config(
    address deployer
  ) internal view returns (address resilientOracle, address bot, address pauser, address[] memory stocks) {
    if (block.chainid == 56) {
      // ---------------- BSC mainnet ----------------
      resilientOracle = 0xf3afD82A4071f272F403dC176916141f44E6c750; // Lista resilient oracle (multiOracle)
      bot = 0x91fC4BA20685339781888eCA3E9E1c12d40F0e13;
      pauser = 0xEEfebb1546d88EA0909435DF6f615084DD3c5Bd8; // Lista pauser (same as other Moolah deploys)
      stocks = new address[](6);
      stocks[0] = 0xcdf2f3e0fa43C47A6662a91C9E4a7C5f69762699; // MUB
      stocks[1] = 0x5b1910eAaD6450E50f816082Aa078C41F10C292f; // TSLAB
      stocks[2] = 0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436; // NVDAB
      stocks[3] = 0x3eE4dF61bd4F867E349BEaE8bFE07bc31b4850fb; // SNDKB
      stocks[4] = 0x80f3D493EBCe97e343c53D29a137942416B4ffC0; // CRCLB
      stocks[5] = 0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1; // SPCXB
    } else if (block.chainid == 97) {
      // ---------------- BSC testnet ----------------
      resilientOracle = 0xb041398567ee5B01aA54A04894796c17f11cF07a;
      bot = deployer;
      pauser = deployer;
      stocks = new address[](0);
    } else {
      revert("StockOracleDeploy: unsupported chain");
    }
  }
}
