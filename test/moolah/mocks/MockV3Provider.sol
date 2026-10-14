// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

contract MockV3Adapter {
  address public provider;

  function setProvider(address _provider) external {
    provider = _provider;
  }
}

/// @dev The V3Provider share surface MarketFactory reads.
contract MockV3Share {
  address public MOOLAH;
  address public ADAPTER;
  address public TOKEN0;
  address public TOKEN1;
  address public WRAPPED_NATIVE;
  address public resilientOracle;
  bool public depositWhitelistEnabled;
  uint256 public totalSupply;
  address public tokenOverride;

  constructor(
    address moolah,
    address adapter,
    address token0,
    address token1,
    address wrappedNative,
    address _resilientOracle
  ) {
    MOOLAH = moolah;
    ADAPTER = adapter;
    TOKEN0 = token0;
    TOKEN1 = token1;
    WRAPPED_NATIVE = wrappedNative;
    resilientOracle = _resilientOracle;
  }

  function TOKEN() external view returns (address) {
    return tokenOverride == address(0) ? address(this) : tokenOverride;
  }

  function setDepositWhitelistEnabled(bool enabled) external {
    depositWhitelistEnabled = enabled;
  }

  function setTotalSupply(uint256 supply) external {
    totalSupply = supply;
  }

  function setTokenOverride(address token) external {
    tokenOverride = token;
  }
}

/// @dev The V3ProviderOracle surface MarketFactory and Moolah.createMarket read.
contract MockV3Oracle {
  address public PROVIDER_SHARE;
  address public resilientOracle;

  constructor(address share, address _resilientOracle) {
    PROVIDER_SHARE = share;
    resilientOracle = _resilientOracle;
  }

  function peek(address) external pure returns (uint256) {
    return 1e8;
  }
}

contract MockV3LiquidatorView {
  address public MOOLAH;
  address public fundSource;

  constructor(address moolah, address _fundSource) {
    MOOLAH = moolah;
    fundSource = _fundSource;
  }
}
