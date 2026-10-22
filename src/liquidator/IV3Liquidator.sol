// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice The subset of {V3Liquidator} the MarketFactory reads and configures for V3 LP share markets.
interface IV3Liquidator {
  function MOOLAH() external view returns (address);

  function fundSource() external view returns (address);

  function tokenWhitelist(address token) external view returns (bool);

  function v3Providers(address provider) external view returns (bool);

  function reflowBlacklist(address token) external view returns (bool);

  function setTokenWhitelist(address token, bool status) external;

  function setMarketWhitelist(bytes32 id, bool status) external;

  function setV3ProviderWhitelist(address provider, bool status) external;

  function setReflowBlacklist(address token, bool status) external;
}
