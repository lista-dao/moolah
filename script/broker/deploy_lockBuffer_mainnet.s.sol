// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { console } from "forge-std/console.sol";
import { DeployBase } from "../DeployBase.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { BrokerInterestLockBuffer } from "../../src/utils/BrokerInterestLockBuffer.sol";

interface IAccessControlLike {
  function grantRole(bytes32 role, address account) external;
}

/// @notice Deploy the shared BrokerInterestLockBuffer implementation plus one UUPS proxy per
/// loan-asset vault on BSC mainnet, and grant each proxy's RELAYER role to that vault's relayer.
///
/// The deployer is set as DEFAULT_ADMIN and MANAGER so it can grant RELAYER in this same run.
/// Hand both roles to governance afterwards, then attach each buffer via the vault MANAGER
/// (see the wiring runbook). Buffers are NOT attached here; vaults still see lockBuffer() == 0
/// until the vault MANAGER calls setLockBuffer.
///
/// Run (PRIVATE_KEY is picked by DeployBase per chain id):
///   PRIVATE_KEY=0x... forge script script/broker/deploy_lockBuffer_mainnet.s.sol \
///     --rpc-url $BSC_RPC --broadcast --verify --via-ir -vvv
contract DeployLockBuffer is DeployBase {
  // ERC-1967 implementation slot = keccak256("eip1967.proxy.implementation") - 1 (bytes32, not an address).
  bytes32 internal constant ERC1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
  bytes32 internal constant RELAYER = keccak256("RELAYER");

  // Smoothing window applied to each brokered-interest flush. Must be in [MIN_DURATION, MAX_DURATION]
  // = [1 hours, 3 days] per BrokerInterestLockBuffer.
  uint64 internal constant DURATION = 8 hours;

  function run() public {
    require(block.chainid == 56, "not BSC mainnet");
    uint256 deployerPrivateKey = _deployerKey();
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    // Per loan asset: (vault, asset, relayer). Order: lisUSD, USD1, U, USDT, WBNB.
    address[5] memory vaults = [
      0xE03D86e5Baa3509AC4A059A41737bAa8169B6529,
      0xfa27f172e0b6ebcEF9c51ABf817E2cb142FbE627,
      0x9A17Fd5Cb8EFc25d11567e713aE795A89775a759,
      0x6d6783C146F2B0B2774C1725297f1845dc502525,
      0x57134a64B7cD9F9eb72F8255A671F5Bf2fe3E2d0
    ];
    address[5] memory assets = [
      0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5, // lisUSD
      0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d, // USD1
      0xcE24439F2D9C6a2289F741120FE202248B666666, // U
      0x55d398326f99059fF775485246999027B3197955, // USDT
      0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c // WBNB
    ];
    address[5] memory relayers = [
      0xcb2590F10728e3ffc725d7ECf88EcFd0d92c9d6a,
      0x35720fcA79F33E3817479E0c6abFaD38ea1a9DaC,
      0x9348923C2f0AD218A8736Ab28cfAe7D93027E73f,
      0x2A119f506ce71cF427D5ae88540fAec580840587,
      0xF2D18e9201d1fE752e3115c029F0f5Ef2Ec2bdbe
    ];

    vm.startBroadcast(deployerPrivateKey);

    BrokerInterestLockBuffer impl = new BrokerInterestLockBuffer();
    require(impl.proxiableUUID() == ERC1967_IMPL_SLOT, "impl: not UUPS / wrong proxiableUUID");
    console.log("LockBuffer impl:", address(impl));

    for (uint256 i = 0; i < vaults.length; i++) {
      bytes memory initData = abi.encodeCall(
        BrokerInterestLockBuffer.initialize,
        (deployer, deployer, vaults[i], assets[i], DURATION)
      );
      BrokerInterestLockBuffer buf = BrokerInterestLockBuffer(address(new ERC1967Proxy(address(impl), initData)));

      // grant RELAYER to this vault's relayer (deployer is DEFAULT_ADMIN) — must precede setLockBuffer
      IAccessControlLike(address(buf)).grantRole(RELAYER, relayers[i]);

      require(buf.vault() == vaults[i] && buf.asset() == assets[i], "buffer init mismatch");
      require(buf.currentLocked() == 0, "buffer not empty");
      console.log("buffer:", address(buf));
      console.log("   vault:", vaults[i]);
      console.log("   asset:", assets[i]);
      console.log("   relayer (RELAYER granted):", relayers[i]);
    }

    vm.stopBroadcast();
  }
}
