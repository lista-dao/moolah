// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./BaseTest.sol";

uint256 constant TIMELOCK = 1 weeks;

contract IntegrationTest is BaseTest {
  using MathLib for uint256;
  using MoolahBalancesLib for IMoolah;
  using MarketParamsLib for MarketParams;

  IMoolahVault internal vault;

  function setUp() public virtual override {
    super.setUp();

    vault = createMoolahVault(OWNER, address(moolah), address(loanToken), "Moolah Vault", "MMV");

    vm.startPrank(OWNER);
    vault.grantRole(CURATOR_ROLE, CURATOR_ADDR);
    vault.grantRole(ALLOCATOR_ROLE, ALLOCATOR_ADDR);
    vault.grantRole(CURATOR_ROLE, OWNER);
    vault.grantRole(ALLOCATOR_ROLE, OWNER);
    vault.grantRole(ALLOCATOR_ROLE, CURATOR_ADDR);
    vault.setFeeRecipient(FEE_RECIPIENT);
    vault.setSkimRecipient(SKIM_RECIPIENT);
    vm.stopPrank();

    _setCap(idleParams, type(uint184).max);

    loanToken.approve(address(vault), type(uint256).max);
    collateralToken.approve(address(vault), type(uint256).max);

    vm.startPrank(SUPPLIER);
    loanToken.approve(address(vault), type(uint256).max);
    collateralToken.approve(address(vault), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(ONBEHALF);
    loanToken.approve(address(vault), type(uint256).max);
    collateralToken.approve(address(vault), type(uint256).max);
    vm.stopPrank();
  }

  // Deploy MoolahVault from artifacts
  // Replaces using `new MoolahVault` which would force 0.8.21 on all tests
  // (since MoolahVault has pragma solidity 0.8.21)
  function createMoolahVault(
    address owner,
    address moolah,
    address asset,
    string memory name,
    string memory symbol
  ) public returns (IMoolahVault) {
    return newMoolahVault(owner, owner, moolah, asset, name, symbol);
  }

  function _idle() internal view returns (uint256) {
    return moolah.expectedSupplyAssets(idleParams, address(vault));
  }

  function _setGuardian(address newGuardian) internal {
    if (vault.hasRole(GUARDIAN_ROLE, newGuardian)) return;

    vm.prank(OWNER);
    vault.grantRole(GUARDIAN_ROLE, newGuardian);
  }

  function _setFee(uint256 newFee) internal {
    uint256 fee = vault.fee();
    if (newFee == fee) return;

    vm.prank(OWNER);
    vault.setFee(newFee);

    assertEq(vault.fee(), newFee, "_setFee");
  }

  function _setCap(MarketParams memory marketParams, uint256 newCap) internal {
    Id id = marketParams.id();
    uint256 cap = vault.config(id).cap;
    bool isEnabled = vault.config(id).enabled;
    if (newCap == cap) return;

    vm.prank(CURATOR_ADDR);
    vault.setCap(marketParams, newCap);

    if (newCap < cap) return;

    assertEq(vault.config(id).cap, newCap, "_setCap");

    if (newCap > 0) {
      if (!isEnabled) {
        Id[] memory newSupplyQueue = new Id[](vault.supplyQueueLength() + 1);
        for (uint256 k; k < vault.supplyQueueLength(); k++) {
          newSupplyQueue[k] = vault.supplyQueue(k);
        }
        newSupplyQueue[vault.supplyQueueLength()] = id;
        vm.prank(ALLOCATOR_ADDR);
        vault.setSupplyQueue(newSupplyQueue);
      }
    }
  }

  function _sortSupplyQueueIdleLast() internal {
    Id[] memory supplyQueue = new Id[](vault.supplyQueueLength());

    uint256 supplyIndex;
    for (uint256 i; i < supplyQueue.length; ++i) {
      Id id = vault.supplyQueue(i);
      if (Id.unwrap(id) == Id.unwrap(idleParams.id())) continue;

      supplyQueue[supplyIndex] = id;
      ++supplyIndex;
    }

    supplyQueue[supplyIndex] = idleParams.id();
    ++supplyIndex;

    assembly {
      mstore(supplyQueue, supplyIndex)
    }

    vm.prank(ALLOCATOR_ADDR);
    vault.setSupplyQueue(supplyQueue);
  }
}
