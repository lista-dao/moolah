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
    assertEq(creditToken.waitingPeriod(), 1 days);
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

  function test_syncCreditScore() public {
    test_acceptMerkleRoot();

    // check user's initial data
    assertEq(creditToken.balanceOf(user1), 0);
    assertEq(_getUserScore(user1), 0);
    assertEq(_getUserScoreId(user1), 0);
    assertEq(creditToken.userAmounts(user1), 0);
    assertEq(creditToken.userBadDebts(user1), 0);

    uint256 score = 300 ether; // Example credit score = 300
    // Sync credit score
    creditToken.syncCreditScore(user1, score, proof);

    // Check credit balance
    assertEq(creditToken.balanceOf(user1), score);

    // Check stored credit score
    assertEq(_getUserScore(user1), score);
    assertEq(_getUserScoreId(user1), creditToken.versionId());
    assertEq(creditToken.userAmounts(user1), score);
    assertEq(creditToken.userBadDebts(user1), 0);
  }

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
    assertEq(creditToken.userBadDebts(user1), 0);
  }

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
    assertEq(creditToken.userBadDebts(user1), 0);

    // Now decrease credit score to 100, which should create bad debt of 200
    uint256 decreasedScore = 100 ether;
    _generateTree(user1, decreasedScore, creditToken.versionId() + 1);

    test_acceptMerkleRoot();

    creditToken.syncCreditScore(user1, decreasedScore, proof);

    // Check credit balance after decrease
    assertEq(creditToken.balanceOf(user1), 0); // still 0
    // Check last synced score (should reflect bad debt of 200)
    assertEq(_getUserScore(user1), 100 ether);
    assertEq(creditToken.userAmounts(user1), 100 ether);
    assertEq(creditToken.userBadDebts(user1), 200 ether);
  }

  // Now increase credit score to 250, (300 -> 100 -> 250) which should cover parially bad debt of 200 by 150
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
    assertEq(creditToken.userAmounts(user1), 250 ether);
    assertEq(creditToken.userBadDebts(user1), 50 ether);
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
    assertEq(creditToken.userBadDebts(user1), 0); // bad debt cleared
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
    assertEq(creditToken.userBadDebts(user1), 0); // bad debt cleared
  }

  // user1 somehow got 80 credit tokens, no score change but has bad debt of 200; should burn 80 tokens and reduce bad debt to 120
  function test_hasBadDebt_sameScore_burnBalance() public {
    test_decreaseCreditScoreWithBadDebt();

    vm.prank(broker1);
    creditToken.transfer(user1, 80 ether);

    assertEq(creditToken.balanceOf(user1), 80 ether);
    uint256 lastScore = _getUserScore(user1);

    creditToken.syncCreditScore(user1, lastScore, proof);

    // Check credit balance after increase
    assertEq(creditToken.balanceOf(user1), 0); // all 80 tokens burned

    // Check last synced score
    assertEq(_getUserScore(user1), lastScore);
    assertEq(_getUserScoreId(user1), creditToken.versionId());
    assertEq(creditToken.userAmounts(user1), lastScore);
    assertEq(creditToken.userBadDebts(user1), 120 ether); // bad debt reduced to 120
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
