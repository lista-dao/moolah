pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import { Merkle } from "murky/src/Merkle.sol";

import { MarketParams, Id } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { ErrorsLib } from "moolah/libraries/ErrorsLib.sol";
import { MathLib } from "moolah/libraries/MathLib.sol";

import { CreditToken } from "../../src/utils/CreditToken.sol";

import { Moolah } from "../../src/moolah/Moolah.sol";
import { IOracle } from "../../src/moolah/interfaces/IOracle.sol";

contract CreditTokenTest is Test {
  CreditToken creditToken;

  address moolah = address(0x1234);
  address admin = address(0xABCD);
  address manager = address(0xDCBA);
  address bot = address(0xBEEF);
  address broker1 = address(0x1111);
  address broker2 = address(0x2222);

  address user1 = address(0xAAAA);

  bytes32 merkleRoot;
  bytes32[] proof;

  Merkle m = new Merkle();

  function setUp() public {
    creditToken = new CreditToken();
    address[] memory _transferers = new address[](3);
    _transferers[0] = broker1;
    _transferers[1] = broker2;
    _transferers[2] = moolah;
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(creditToken),
      abi.encodeWithSelector(CreditToken.initialize.selector, admin, manager, bot, _transferers, "Credit Token", "CRE")
    );

    creditToken = CreditToken(address(proxy));

    assertEq(creditToken.hasRole(creditToken.DEFAULT_ADMIN_ROLE(), admin), true);
    assertEq(creditToken.hasRole(creditToken.MANAGER(), manager), true);
    assertEq(creditToken.hasRole(creditToken.BOT(), bot), true);
    assertEq(creditToken.hasRole(creditToken.TRANSFERER(), broker1), true);
    assertEq(creditToken.hasRole(creditToken.TRANSFERER(), broker2), true);
    assertEq(creditToken.hasRole(creditToken.TRANSFERER(), moolah), true);
    assertEq(creditToken.getRoleAdmin(creditToken.TRANSFERER()), creditToken.MANAGER());

    assertEq(creditToken.name(), "Credit Token");
    assertEq(creditToken.symbol(), "CRE");

    assertEq(creditToken.pendingMerkleRoot(), bytes32(0));
    assertEq(creditToken.lastSetTime(), type(uint256).max);
    assertEq(creditToken.merkleRoot(), bytes32(0));
    assertEq(creditToken.waitingPeriod(), 6 hours);
    assertEq(creditToken.versionId(), 0);

    _generateTree(user1, 300 ether, 1);
  }

  function test_setPendingMerkleRoot() public {
    uint256 previousId = creditToken.versionId();
    vm.prank(bot);
    creditToken.setPendingMerkleRoot(merkleRoot);

    assertEq(creditToken.pendingMerkleRoot(), merkleRoot);
    assertEq(creditToken.lastSetTime(), block.timestamp);
    assertEq(creditToken.versionId(), previousId);
  }

  function test_acceptMerkleRoot() public {
    vm.prank(bot);
    creditToken.setPendingMerkleRoot(merkleRoot);

    vm.warp(block.timestamp + 1 days + 1);

    uint256 previousId = creditToken.versionId();

    vm.prank(bot);
    creditToken.acceptMerkleRoot();

    assertEq(creditToken.merkleRoot(), merkleRoot);
    assertEq(creditToken.pendingMerkleRoot(), bytes32(0));
    assertEq(creditToken.lastSetTime(), type(uint256).max);
    assertEq(creditToken.versionId(), previousId + 1);
  }

  function _getUserScoreId(address _user) public view returns (uint256) {
    (uint id, ) = creditToken.creditScores(_user);
    return id;
  }

  function _getUserScore(address _user) public view returns (uint256) {
    (, uint score) = creditToken.creditScores(_user);
    return score;
  }

  // Sync credit score: 0 -> 300
  function test_syncCreditScore() public {
    test_acceptMerkleRoot();

    // check user's initial data
    assertEq(creditToken.balanceOf(user1), 0);
    assertEq(_getUserScore(user1), 0);
    assertEq(_getUserScoreId(user1), 0);
    assertEq(creditToken.userAmounts(user1), 0);
    assertEq(creditToken.debtOf(user1), 0);

    uint256 score = 300 ether; // Example credit score = 300
    // Sync credit score
    creditToken.syncCreditScore(user1, score, proof);

    // Check credit balance
    assertEq(creditToken.balanceOf(user1), score, "Credit balance not updated correctly");

    // Check stored credit score
    assertEq(_getUserScore(user1), score, "Credit score not updated correctly");
    assertEq(_getUserScoreId(user1), creditToken.versionId(), "Credit score ID not updated correctly");
    assertEq(creditToken.userAmounts(user1), score, "User amount not updated correctly");
    assertEq(creditToken.debtOf(user1), 0, "Debt should be zero");
  }

  // Decrease credit score: 0 -> 300 -> 100, no bad debt
  function test_decreaseCreditScoreWithoutBadDebt() public {
    test_syncCreditScore();
    uint256 decreasedScore = 100 ether; // Decrease credit score to 100

    _generateTree(user1, decreasedScore, creditToken.versionId() + 1);

    test_acceptMerkleRoot();

    creditToken.syncCreditScore(user1, decreasedScore, proof);

    // Check credit balance after decrease
    assertEq(creditToken.balanceOf(user1), 100 ether); // 300 - 200 = 100

    // Check stored credit score and user amount
    assertEq(_getUserScore(user1), decreasedScore);
    assertEq(_getUserScoreId(user1), creditToken.versionId());
    assertEq(creditToken.userAmounts(user1), decreasedScore);
    assertEq(creditToken.debtOf(user1), 0);
  }

  // Decrease credit score: 0 -> 300 -> 100, with bad debt 200
  function test_decreaseCreditScoreWithBadDebt() public {
    test_syncCreditScore();

    // borker transfers all credit tokens from user1
    vm.expectRevert(); // access control: only transferer
    vm.prank(user1);
    creditToken.transfer(broker1, 300 ether);

    vm.expectRevert(); // insufficient allowance
    vm.prank(broker1);
    creditToken.transferFrom(user1, broker1, 300 ether);

    vm.prank(user1);
    creditToken.approve(broker1, 300 ether);
    vm.prank(broker1);
    creditToken.transferFrom(user1, broker1, 300 ether);

    // Now user1 has 0 balance but last synced score is 300
    assertEq(creditToken.balanceOf(user1), 0);
    assertEq(_getUserScore(user1), 300 ether);
    assertEq(creditToken.userAmounts(user1), 300 ether);
    assertEq(creditToken.debtOf(user1), 0);

    // Now decrease credit score to 100, which should create bad debt of 200
    uint256 decreasedScore = 100 ether;
    _generateTree(user1, decreasedScore, creditToken.versionId() + 1);

    test_acceptMerkleRoot();

    creditToken.syncCreditScore(user1, decreasedScore, proof);

    // Check credit balance after decrease
    assertEq(creditToken.balanceOf(user1), 0); // still 0
    // Check last synced score (should reflect bad debt of 200)
    assertEq(_getUserScore(user1), 100 ether);
    assertEq(creditToken.userAmounts(user1), 300 ether);
    assertEq(creditToken.debtOf(user1), 200 ether);
  }

  // Now increase credit score to 250, (0 -> 300 -> 100 -> 250) which should cover parially bad debt of 200 by 150
  function test_hasBadDebtThenCoverParially() public {
    test_decreaseCreditScoreWithBadDebt();

    uint256 increasedScore = 250 ether;

    _generateTree(user1, increasedScore, creditToken.versionId() + 1);

    test_acceptMerkleRoot();

    creditToken.syncCreditScore(user1, increasedScore, proof);

    // Check credit balance after increase
    assertEq(creditToken.balanceOf(user1), 0); // no tokens minted as still has bad debt

    // Check last synced score (should reflect new score of 250 and remaining bad debt of 50)
    assertEq(_getUserScore(user1), 250 ether);
    assertEq(_getUserScoreId(user1), creditToken.versionId());
    assertEq(creditToken.userAmounts(user1), 300 ether); // no change because no changes in either balance or deposits
    assertEq(creditToken.debtOf(user1), 50 ether); // bad debt reduced to 50
  }

  // Now increase credit score to 300, (300 -> 100 -> 300) which should cover bad debt of 200 exactly
  function test_hasBadDebtThenCoverExact() public {
    test_decreaseCreditScoreWithBadDebt();

    uint256 increasedScore = 300 ether;
    _generateTree(user1, increasedScore, creditToken.versionId() + 1);

    test_acceptMerkleRoot();

    creditToken.syncCreditScore(user1, increasedScore, proof);

    // Check credit balance after increase
    assertEq(creditToken.balanceOf(user1), 0); // still 0 after covering bad debt

    assertEq(_getUserScore(user1), 300 ether);
    assertEq(_getUserScoreId(user1), creditToken.versionId());
    assertEq(creditToken.userAmounts(user1), 300 ether);
    assertEq(creditToken.debtOf(user1), 0); // bad debt cleared
  }

  // 300 -> transfer out all 300 -> 100 -> 80, should have bad debt of 220
  function test_newScore_lowerThan_userAmount_noBalance() public {
    test_decreaseCreditScoreWithBadDebt();

    uint256 decreasedScore = 80 ether;
    _generateTree(user1, decreasedScore, creditToken.versionId() + 1);
    test_acceptMerkleRoot();

    assertEq(creditToken.balanceOf(user1), 0); // still 0
    assertEq(_getUserScore(user1), 100 ether);
    assertEq(creditToken.userAmounts(user1), 300 ether);
    assertEq(creditToken.debtOf(user1), 200 ether);

    creditToken.syncCreditScore(user1, decreasedScore, proof);

    // Check credit balance after decrease
    assertEq(creditToken.balanceOf(user1), 0); // still 0

    // Check last synced score (should reflect bad debt of 220)
    assertEq(_getUserScore(user1), 80 ether);
    assertEq(_getUserScoreId(user1), creditToken.versionId());
    assertEq(creditToken.userAmounts(user1), 300 ether);
    assertEq(creditToken.debtOf(user1), 220 ether);
  }

  // 300 -> transfer out all 300 -> 100 -> received 10 -> 80, should have bad debt of 210
  function test_newScore_lowerThan_userAmount_withSmallBalance() public {
    test_decreaseCreditScoreWithBadDebt();

    uint256 decreasedScore = 80 ether;
    _generateTree(user1, decreasedScore, creditToken.versionId() + 1);
    test_acceptMerkleRoot();

    assertEq(creditToken.balanceOf(user1), 0); // still 0
    assertEq(_getUserScore(user1), 100 ether);
    assertEq(creditToken.userAmounts(user1), 300 ether);
    assertEq(creditToken.debtOf(user1), 200 ether);

    // user1 somehow received 10 tokens
    vm.prank(broker1);
    creditToken.transfer(user1, 10 ether);

    assertEq(creditToken.balanceOf(user1), 10 ether);
    creditToken.syncCreditScore(user1, decreasedScore, proof);

    // Check credit balance after decrease
    assertEq(creditToken.balanceOf(user1), 0); // all 10 tokens burned to cover bad debt

    // Check last synced score (should reflect bad debt of 210)
    assertEq(_getUserScore(user1), 80 ether);
    assertEq(_getUserScoreId(user1), creditToken.versionId());
    assertEq(creditToken.userAmounts(user1), 290 ether); // user amount reduced by 10 due to burning
    assertEq(creditToken.debtOf(user1), 210 ether);
  }

  // 300 -> transfer out all 300 -> 100 -> received 199 -> 80, should have bad debt of 21
  function test_newScore_lowerThan_userAmount_withLargeBalance() public {
    test_decreaseCreditScoreWithBadDebt();

    uint256 decreasedScore = 80 ether;
    _generateTree(user1, decreasedScore, creditToken.versionId() + 1);
    test_acceptMerkleRoot();

    assertEq(creditToken.balanceOf(user1), 0); // still 0
    assertEq(_getUserScore(user1), 100 ether);
    assertEq(creditToken.userAmounts(user1), 300 ether);
    assertEq(creditToken.debtOf(user1), 200 ether);

    // user1 somehow received 199 tokens
    vm.prank(broker1);
    creditToken.transfer(user1, 199 ether);

    assertEq(creditToken.balanceOf(user1), 199 ether);
    creditToken.syncCreditScore(user1, decreasedScore, proof);

    // Check credit balance after decrease
    assertEq(creditToken.balanceOf(user1), 0); // all 199 tokens burned to cover bad debt

    // Check last synced score (should reflect bad debt of 11)
    assertEq(_getUserScore(user1), 80 ether);
    assertEq(_getUserScoreId(user1), creditToken.versionId());
    assertEq(creditToken.userAmounts(user1), 101 ether); // user amount reduced by 199 due to burning
    assertEq(creditToken.debtOf(user1), 21 ether);
  }

  // Increase credit score to 350, (300 -> 100 -> 350) which should cover bad debt of 200 and mint 50 tokens
  function test_hasBadDebtThenIncreaseWithMint() public {
    test_decreaseCreditScoreWithBadDebt();

    uint256 increasedScore = 350 ether;
    _generateTree(user1, increasedScore, creditToken.versionId() + 1);

    test_acceptMerkleRoot();

    creditToken.syncCreditScore(user1, increasedScore, proof);

    // Check credit balance after increase
    assertEq(creditToken.balanceOf(user1), 50 ether);
    // Check last synced score
    assertEq(_getUserScore(user1), 350 ether);
    assertEq(_getUserScoreId(user1), creditToken.versionId());
    assertEq(creditToken.userAmounts(user1), 350 ether);
    assertEq(creditToken.debtOf(user1), 0); // bad debt cleared
  }

  // user1 somehow got 80 credit tokens, no score change but has bad debt of 200; should burn 80 tokens and reduce bad debt to 120
  function test_hasBadDebt_sameScore_burnBalance() public {
    test_decreaseCreditScoreWithBadDebt();

    vm.prank(broker1);
    creditToken.transfer(user1, 80 ether);
    uint prevUserAmount = creditToken.userAmounts(user1);
    uint prevDebt = creditToken.debtOf(user1);

    assertEq(creditToken.balanceOf(user1), 80 ether);
    uint256 lastScore = _getUserScore(user1);

    creditToken.syncCreditScore(user1, lastScore, proof);

    // Check credit balance after increase
    assertEq(creditToken.balanceOf(user1), 0); // all 80 tokens burned

    // Check last synced score
    assertEq(_getUserScore(user1), lastScore);
    assertEq(_getUserScoreId(user1), creditToken.versionId());
    assertEq(creditToken.userAmounts(user1), prevUserAmount - 80 ether); // user amount increased by 80 due to burning
    assertEq(creditToken.debtOf(user1), prevDebt - 80 ether); // bad debt reduced by 80
  }

  // 0 -> 100 -> 80, with bad debt of 15
  function test_userAmounts() public {
    // First set score to 100
    _generateTree(user1, 100 ether, creditToken.versionId() + 1);
    test_acceptMerkleRoot();
    creditToken.syncCreditScore(user1, 100 ether, proof);

    assertEq(creditToken.balanceOf(user1), 100 ether);
    assertEq(creditToken.userAmounts(user1), 100 ether);
    assertEq(creditToken.debtOf(user1), 0);

    // Now broker takes 95 tokens, leaving user1 with 5 tokens
    vm.prank(user1);
    creditToken.approve(broker1, 100 ether);
    vm.prank(broker1);
    creditToken.transferFrom(user1, broker1, 95 ether);

    assertEq(creditToken.balanceOf(user1), 5 ether);
    assertEq(creditToken.userAmounts(user1), 100 ether);
    assertEq(creditToken.debtOf(user1), 0);

    // Now decrease score to 80
    _generateTree(user1, 80 ether, creditToken.versionId() + 1);
    test_acceptMerkleRoot();
    creditToken.syncCreditScore(user1, 80 ether, proof);

    // Check final states
    assertEq(creditToken.balanceOf(user1), 0); // all 5 tokens burned
    assertEq(creditToken.userAmounts(user1), 95 ether); // user amount reduced by 5 due to burning
    assertEq(creditToken.debtOf(user1), 15 ether); // bad debt of 15 (95 - 80)
  }

  function test_syncCreditScore_fakeProof() public {
    test_acceptMerkleRoot();

    // sync user credit score
    creditToken.syncCreditScore(user1, 300 ether, proof);

    uint256 score = 3000000 ether; // Example credit score = 300
    bytes32[] memory fakeProof = new bytes32[](2);
    fakeProof[0] = bytes32("0xdeadbeef");
    fakeProof[1] = bytes32("0xabcdef01");

    vm.expectRevert("Invalid proof");
    creditToken.syncCreditScore(user1, score, fakeProof);
  }

  function _generateTree(address _account, uint256 _score, uint256 _versionId) public {
    bytes32[] memory data = new bytes32[](4);
    data[0] = keccak256(abi.encode(block.chainid, address(creditToken), _account, _score, _versionId));
    data[1] = bytes32("0x1");
    data[2] = bytes32("0x2");
    data[3] = bytes32("0x3");
    // Get Root, Proof, and Verify
    bytes32 root = m.getRoot(data);
    bytes32[] memory _proof = m.getProof(data, 0); // will get proof for user1
    bool verified = m.verifyProof(root, _proof, data[0]);
    require(verified, "Merkle Proof not verified");

    merkleRoot = root;
    proof = _proof;
  }
}
