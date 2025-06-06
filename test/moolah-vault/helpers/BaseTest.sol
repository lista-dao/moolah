// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20, ERC20 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import "moolah/interfaces/IMoolah.sol";

import { WAD, MathLib } from "moolah/libraries/MathLib.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { MoolahBalancesLib } from "moolah/libraries/periphery/MoolahBalancesLib.sol";

import "moolah-vault/interfaces/IMoolahVault.sol";
import { ErrorsLib } from "moolah-vault/libraries/ErrorsLib.sol";
import { EventsLib } from "moolah-vault/libraries/EventsLib.sol";
import { ORACLE_PRICE_SCALE } from "moolah/libraries/ConstantsLib.sol";
import { ConstantsLib } from "moolah-vault/libraries/ConstantsLib.sol";

import { IrmMock } from "moolah-vault/mocks/IrmMock.sol";
import { ERC20Mock } from "moolah-vault/mocks/ERC20Mock.sol";
import { OracleMock } from "moolah-vault/mocks/OracleMock.sol";

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import { MoolahVault } from "moolah-vault/MoolahVault.sol";
import { Moolah } from "moolah/Moolah.sol";

uint256 constant BLOCK_TIME = 1;
uint256 constant MIN_TEST_ASSETS = 1e8;
uint256 constant MAX_TEST_ASSETS = 1e28;
uint184 constant CAP = type(uint128).max;
uint256 constant NB_MARKETS = ConstantsLib.MAX_QUEUE_LENGTH + 1;

contract BaseTest is Test {
  using MathLib for uint256;
  using MoolahBalancesLib for IMoolah;
  using MarketParamsLib for MarketParams;

  address internal OWNER = makeAddr("Owner");
  address internal SUPPLIER = makeAddr("Supplier");
  address internal BORROWER = makeAddr("Borrower");
  address internal REPAYER = makeAddr("Repayer");
  address internal ONBEHALF = makeAddr("OnBehalf");
  address internal RECEIVER = makeAddr("Receiver");
  address internal ALLOCATOR_ADDR = makeAddr("Allocator");
  address internal CURATOR_ADDR = makeAddr("Curator");
  address internal GUARDIAN_ADDR = makeAddr("Guardian");
  address internal FEE_RECIPIENT = makeAddr("FeeRecipient");
  address internal SKIM_RECIPIENT = makeAddr("SkimRecipient");
  address internal MOOLAH_OWNER = makeAddr("MoolahOwner");
  address internal MOOLAH_FEE_RECIPIENT = makeAddr("MoolahFeeRecipient");
  address internal BOT_ADDR = makeAddr("Bot");

  IMoolah internal moolah;
  ERC20Mock internal loanToken = new ERC20Mock("loan", "B");
  ERC20Mock internal collateralToken = new ERC20Mock("collateral", "C");
  OracleMock internal oracle = new OracleMock();
  IrmMock internal irm = new IrmMock();

  MarketParams[] internal allMarkets;
  MarketParams internal idleParams;

  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00; // default admin role
  bytes32 public constant MANAGER_ROLE = keccak256("MANAGER"); // manager role
  bytes32 public constant CURATOR_ROLE = keccak256("CURATOR"); // manager role
  bytes32 public constant ALLOCATOR_ROLE = keccak256("ALLOCATOR"); // manager role
  bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN"); // manager role

  function setUp() public virtual {
    moolah = newMoolah(MOOLAH_OWNER, MOOLAH_OWNER, MOOLAH_OWNER);

    vm.label(address(moolah), "Moolah");
    vm.label(address(loanToken), "Loan");
    vm.label(address(collateralToken), "Collateral");
    vm.label(address(oracle), "Oracle");
    vm.label(address(irm), "Irm");

    oracle.setPrice(address(collateralToken), ORACLE_PRICE_SCALE);
    oracle.setPrice(address(loanToken), ORACLE_PRICE_SCALE);

    irm.setApr(0.5 ether); // 50%.

    idleParams = MarketParams({
      loanToken: address(loanToken),
      collateralToken: address(collateralToken),
      oracle: address(oracle),
      irm: address(irm),
      lltv: 0
    });

    vm.startPrank(MOOLAH_OWNER);
    moolah.enableIrm(address(irm));
    moolah.setFeeRecipient(MOOLAH_FEE_RECIPIENT);

    moolah.enableLltv(0);
    moolah.createMarket(idleParams);
    vm.stopPrank();

    for (uint256 i; i < NB_MARKETS; ++i) {
      uint256 lltv = 0.8 ether / (i + 1);

      MarketParams memory marketParams = MarketParams({
        loanToken: address(loanToken),
        collateralToken: address(collateralToken),
        oracle: address(oracle),
        irm: address(irm),
        lltv: lltv
      });

      vm.startPrank(MOOLAH_OWNER);
      moolah.enableLltv(lltv);

      moolah.createMarket(marketParams);
      vm.stopPrank();

      allMarkets.push(marketParams);
    }

    allMarkets.push(idleParams); // Must be pushed last.

    vm.startPrank(SUPPLIER);
    loanToken.approve(address(moolah), type(uint256).max);
    collateralToken.approve(address(moolah), type(uint256).max);
    vm.stopPrank();

    vm.prank(BORROWER);
    collateralToken.approve(address(moolah), type(uint256).max);

    vm.prank(REPAYER);
    loanToken.approve(address(moolah), type(uint256).max);
  }

  /// @dev Rolls & warps the given number of blocks forward the blockchain.
  function _forward(uint256 blocks) internal {
    vm.roll(block.number + blocks);
    vm.warp(block.timestamp + blocks * BLOCK_TIME); // Block speed should depend on test network.
  }

  /// @dev Bounds the fuzzing input to a realistic number of blocks.
  function _boundBlocks(uint256 blocks) internal pure returns (uint256) {
    return bound(blocks, 2, type(uint24).max);
  }

  /// @dev Bounds the fuzzing input to a non-zero address.
  /// @dev This function should be used in place of `vm.assume` in invariant test handler functions:
  /// https://github.com/foundry-rs/foundry/issues/4190.
  function _boundAddressNotZero(address input) internal view virtual returns (address) {
    return address(uint160(bound(uint256(uint160(input)), 1, type(uint160).max)));
  }

  function _accrueInterest(MarketParams memory market) internal {
    collateralToken.setBalance(address(this), 1);
    moolah.supplyCollateral(market, 1, address(this), hex"");
    moolah.withdrawCollateral(market, 1, address(this), address(10));
  }

  /// @dev Returns a random market params from the list of markets enabled on moolah (except the idle market).
  function _randomMarketParams(uint256 seed) internal view returns (MarketParams memory) {
    return allMarkets[seed % (allMarkets.length - 1)];
  }

  function _randomCandidate(address[] memory candidates, uint256 seed) internal pure returns (address) {
    if (candidates.length == 0) return address(0);

    return candidates[seed % candidates.length];
  }

  function _removeAll(address[] memory inputs, address removed) internal pure returns (address[] memory result) {
    result = new address[](inputs.length);

    uint256 nbAddresses;
    for (uint256 i; i < inputs.length; ++i) {
      address input = inputs[i];

      if (input != removed) {
        result[nbAddresses] = input;
        ++nbAddresses;
      }
    }

    assembly {
      mstore(result, nbAddresses)
    }
  }

  function _randomNonZero(address[] memory users, uint256 seed) internal pure returns (address) {
    users = _removeAll(users, address(0));

    return _randomCandidate(users, seed);
  }

  function newMoolahVault(
    address admin,
    address manager,
    address _moolah,
    address _asset,
    string memory _name,
    string memory _symbol
  ) internal returns (IMoolahVault) {
    MoolahVault moolahVaultImpl = new MoolahVault(_moolah, _asset);
    ERC1967Proxy moolahVaultProxy = new ERC1967Proxy(
      address(moolahVaultImpl),
      abi.encodeWithSelector(moolahVaultImpl.initialize.selector, admin, manager, _asset, _name, _symbol)
    );

    return IMoolahVault(address(moolahVaultProxy));
  }

  function newMoolah(address admin, address manager, address pauser) internal returns (IMoolah) {
    Moolah moolahImpl = new Moolah();

    ERC1967Proxy moolahProxy = new ERC1967Proxy(
      address(moolahImpl),
      abi.encodeWithSelector(moolahImpl.initialize.selector, admin, manager, pauser, 0)
    );

    return IMoolah(address(moolahProxy));
  }
}
