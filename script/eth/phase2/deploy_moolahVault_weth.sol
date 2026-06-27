pragma solidity 0.8.34;

import "forge-std/Script.sol";
import { DeployBase } from "../../DeployBase.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";

/// @notice Step 3: Deploy WETH Savings Vault (for Market #1 wstETH and Market #2 wbETH)
contract MoolahVaultWETHDeploy is DeployBase {
  address moolah;
  address WETH;

  function setUp() public {
    if (block.chainid == 1) {
      // ──── ETH mainnet ────
      moolah = 0xf820fB4680712CD7263a0D3D024D5b5aEA82Fd70;
      WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    } else if (block.chainid == 11155111) {
      // ──── Sepolia testnet ────
      moolah = 0x29c53B75b4CD3CeC0B58F935dC642fF47B708d65;
      WETH = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;
    } else {
      revert("MoolahVaultWETHDeploy: unsupported chain");
    }
  }

  function run() public {
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    vm.startBroadcast(deployerPrivateKey);

    MoolahVault impl = new MoolahVault(moolah, WETH);
    console.log("  implementation:", address(impl));

    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(
        impl.initialize.selector,
        deployer,
        deployer,
        WETH,
        "Lista WETH Savings Vault",
        "ListaSafeWETH"
      )
    );
    console.log("  MoolahVault(WETH) proxy:", address(proxy));

    vm.stopBroadcast();
  }
}
