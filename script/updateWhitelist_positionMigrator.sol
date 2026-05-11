// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Script.sol";

import { PositionMigrator } from "../src/utils/PositionMigrator.sol";

/// @notice Whitelists CDP user addresses on PositionMigrator.
/// @dev    Reads addresses from script/data/cdp_whitelist.txt (one per line) and
///         submits them in batches via PositionMigrator.updateWhitelist.
///
///         Required env:
///           PRIVATE_KEY        - signer holding the MANAGER role on the migrator
///           POSITION_MIGRATOR  - deployed PositionMigrator proxy address
///
///         Optional env:
///           WHITELIST_FILE     - override path to the address list (default: script/data/cdp_whitelist.txt)
///           WHITELIST_BATCH    - addresses per tx (default: 100)
///           WHITELIST_ENABLE   - "true" to add, "false" to remove (default: true)
contract PositionMigratorUpdateWhitelist is Script {
  string constant DEFAULT_WHITELIST_FILE = "script/data/cdp_whitelist.txt";
  uint256 constant DEFAULT_BATCH_SIZE = 100;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    PositionMigrator migrator = PositionMigrator(0x2B3E5b695722756130A553E9Bb5A45E16d21D0A4);

    string memory path = vm.envOr("WHITELIST_FILE", DEFAULT_WHITELIST_FILE);
    uint256 batchSize = vm.envOr("WHITELIST_BATCH", DEFAULT_BATCH_SIZE);
    bool enable = vm.envOr("WHITELIST_ENABLE", true);
    require(batchSize > 0, "batch size must be > 0");

    address[] memory all = _readAddresses(path);
    require(all.length > 0, "no addresses to process");

    // Filter out accounts whose on-chain status already matches the target.
    address[] memory pending = new address[](all.length);
    uint256 pendingLen = 0;
    for (uint256 i = 0; i < all.length; i++) {
      if (migrator.isWhitelisted(all[i]) == enable) continue;
      pending[pendingLen++] = all[i];
    }

    console.log("Deployer:           ", deployer);
    console.log("PositionMigrator:   ", address(migrator));
    console.log("Whitelist file:     ", path);
    console.log("Total addresses:    ", all.length);
    console.log("Already in target:  ", all.length - pendingLen);
    console.log("To submit:          ", pendingLen);
    console.log("Batch size:         ", batchSize);
    console.log("Enable (add=true):  ", enable);

    if (pendingLen == 0) {
      console.log("Nothing to do; all addresses already match target status.");
      return;
    }

    vm.startBroadcast(deployerPrivateKey);

    for (uint256 start = 0; start < pendingLen; start += batchSize) {
      uint256 end = start + batchSize;
      if (end > pendingLen) {
        end = pendingLen;
      }
      uint256 len = end - start;

      address[] memory batch = new address[](len);
      for (uint256 i = 0; i < len; i++) {
        batch[i] = pending[start + i];
      }

      console.log("Submitting batch [%s, %s)", start, end);
      migrator.updateWhitelist(batch, enable);
    }

    vm.stopBroadcast();
  }

  /// @dev Reads non-empty, comment-free lines from `path` and parses them as addresses.
  function _readAddresses(string memory path) internal returns (address[] memory) {
    // First pass: count valid lines so we can size the array exactly.
    uint256 count = 0;
    while (true) {
      string memory line = vm.readLine(path);
      if (bytes(line).length == 0) break;
      if (_isAddressLine(line)) count++;
    }
    vm.closeFile(path);

    // Second pass: parse.
    address[] memory out = new address[](count);
    uint256 idx = 0;
    while (true) {
      string memory line = vm.readLine(path);
      if (bytes(line).length == 0) break;
      if (!_isAddressLine(line)) continue;
      out[idx++] = vm.parseAddress(line);
    }
    vm.closeFile(path);

    return out;
  }

  /// @dev Treats blank lines and lines starting with '#' as non-address content.
  function _isAddressLine(string memory line) internal pure returns (bool) {
    bytes memory b = bytes(line);
    if (b.length == 0) return false;
    if (b[0] == 0x23) return false; // '#'
    return true;
  }
}
