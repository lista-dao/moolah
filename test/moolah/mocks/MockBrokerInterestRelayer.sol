// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface ILoanTokenView {
  function LOAN_TOKEN() external view returns (address);
}

/// @dev Mirrors the checks BrokerInterestRelayer.addBroker enforces: MANAGER-gated, no duplicates,
///      and a matching LOAN_TOKEN (which pins registration to run after setMarketId).
contract MockBrokerInterestRelayer {
  address public token;
  mapping(address => bool) public isManager;
  address[] private brokers;

  constructor(address _token) {
    token = _token;
  }

  function setManager(address account, bool allowed) external {
    isManager[account] = allowed;
  }

  function addBroker(address broker) external {
    require(isManager[msg.sender], "relayer/not-manager");
    require(!_contains(broker), "broker/same-value-provided");
    require(ILoanTokenView(broker).LOAN_TOKEN() == token, "relayer/invalid-loan-token");
    brokers.push(broker);
  }

  function getBrokers() external view returns (address[] memory) {
    return brokers;
  }

  function _contains(address broker) private view returns (bool) {
    for (uint256 i = 0; i < brokers.length; i++) {
      if (brokers[i] == broker) return true;
    }
    return false;
  }
}
