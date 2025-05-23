// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./BaseTest.sol";

contract InvariantTest is BaseTest {
  using MathLib for uint256;
  using SharesMathLib for uint256;
  using MoolahBalancesLib for IMoolah;
  using MarketParamsLib for MarketParams;

  bytes4[] internal selectors;

  function setUp() public virtual override {
    super.setUp();

    _targetSenders();

    targetContract(address(this));
    targetSelector(FuzzSelector({ addr: address(this), selectors: selectors }));
  }

  modifier logCall(string memory name) {
    console2.log(msg.sender, "->", name);

    _;
  }

  function _targetSenders() internal virtual {
    _targetSender(makeAddr("Sender1"));
    _targetSender(makeAddr("Sender2"));
    _targetSender(makeAddr("Sender3"));
    _targetSender(makeAddr("Sender4"));
    _targetSender(makeAddr("Sender5"));
    _targetSender(makeAddr("Sender6"));
    _targetSender(makeAddr("Sender7"));
    _targetSender(makeAddr("Sender8"));
  }

  function _targetSender(address sender) internal {
    targetSender(sender);

    vm.startPrank(sender);
    loanToken.approve(address(moolah), type(uint256).max);
    collateralToken.approve(address(moolah), type(uint256).max);
    vm.stopPrank();
  }

  /* HANDLERS */

  function mine(uint256 blocks) external {
    blocks = bound(blocks, 1, 1 days / BLOCK_TIME);

    _forward(blocks);
  }

  /* UTILS */

  function _randomSupplier(
    address[] memory users,
    MarketParams memory _marketParams,
    uint256 seed
  ) internal view returns (address) {
    Id _id = _marketParams.id();
    address[] memory candidates = new address[](users.length);

    for (uint256 i; i < users.length; ++i) {
      address user = users[i];

      if (moolah.position(_id, user).supplyShares != 0) {
        candidates[i] = user;
      }
    }

    return _randomNonZero(candidates, seed);
  }

  function _randomBorrower(
    address[] memory users,
    MarketParams memory _marketParams,
    uint256 seed
  ) internal view returns (address) {
    Id _id = _marketParams.id();
    address[] memory candidates = new address[](users.length);

    for (uint256 i; i < users.length; ++i) {
      address user = users[i];

      if (moolah.position(_id, user).borrowShares != 0) {
        candidates[i] = user;
      }
    }

    return _randomNonZero(candidates, seed);
  }

  function _randomHealthyCollateralSupplier(
    address[] memory users,
    MarketParams memory _marketParams,
    uint256 seed
  ) internal view returns (address) {
    Id _id = _marketParams.id();
    address[] memory candidates = new address[](users.length);

    for (uint256 i; i < users.length; ++i) {
      address user = users[i];

      if (moolah.position(_id, user).collateral != 0 && _isHealthy(_marketParams, user)) {
        candidates[i] = user;
      }
    }

    return _randomNonZero(candidates, seed);
  }

  function _randomUnhealthyBorrower(
    address[] memory users,
    MarketParams memory _marketParams,
    uint256 seed
  ) internal view returns (address randomSenderToLiquidate) {
    address[] memory candidates = new address[](users.length);

    for (uint256 i; i < users.length; ++i) {
      address user = users[i];

      if (!_isHealthy(_marketParams, user)) {
        candidates[i] = user;
      }
    }

    return _randomNonZero(candidates, seed);
  }
}
