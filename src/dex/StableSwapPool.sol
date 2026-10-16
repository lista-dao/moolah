// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IStableSwapLP } from "./interfaces/IStableSwapLP.sol";
import { IOracle } from "../moolah/interfaces/IOracle.sol";
import "./interfaces/IStableSwap.sol";

/**
 * @title StableSwapPool
 * @author Lista DAO
 * @notice Two-asset reserve pool. Liquidity may only be added or removed pro rata, so the ratio between
 *         the two reserves never changes and the LP token is a claim on a fixed basket. There is no
 *         swap, no imbalanced or single-coin withdrawal, and no price curve.
 *
 * @dev Deposits name the share amount and the pool derives what each leg owes, so the amount taken is
 *      exact and nothing is ever returned to the caller.
 */
contract StableSwapPool is
  UUPSUpgradeable,
  AccessControlEnumerableUpgradeable,
  ReentrancyGuardUpgradeable,
  PausableUpgradeable,
  IStableSwap
{
  using SafeERC20 for IERC20;

  uint256 public constant N_COINS = 2;

  uint256 public constant MAX_DECIMAL = 18;
  uint256 public constant PRECISION = 1e18;
  uint256[N_COINS] public PRECISION_MUL;
  uint256[N_COINS] public RATES;

  uint256 public constant MIN_BNB_GAS = 2300;
  uint256 public constant MAX_BNB_GAS = 23000;

  address[N_COINS] public coins;
  uint256[N_COINS] public balances;
  /// @dev Unused: there is no swap, so no fee can accrue.
  uint256 public fee;
  /// @dev Unused; still carried in {AddLiquidity} so the event signature stays stable.
  uint256 public admin_fee;
  /// @dev gas stipend forwarded when paying out the native coin
  uint256 public bnb_gas;

  address public token;

  address constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  bool public support_BNB;

  /// @dev Unused.
  uint256 public initial_A;
  /// @dev Unused.
  uint256 public future_A;
  /// @dev Unused.
  uint256 public initial_A_time;
  /// @dev Unused.
  uint256 public future_A_time;

  /// @dev Unused.
  uint256 public admin_actions_deadline;
  /// @dev Unused.
  uint256 public future_fee;
  /// @dev Unused.
  uint256 public future_admin_fee;

  /// @dev Price oracle, 1e8 precision.
  address public oracle;
  /// @dev Unused.
  uint256 public price0DiffThreshold;
  /// @dev Unused.
  uint256 public price1DiffThreshold;
  /// @dev Unused.
  bool public skipPriceDiff;

  /// @dev Only this address may call {initialize}.
  address public immutable STABLESWAP_FACTORY;
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant PAUSER = keccak256("PAUSER");

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(address _factory) {
    _disableInitializers();
    STABLESWAP_FACTORY = _factory;
  }

  /**
   * @notice Initialize a freshly deployed pool proxy.
   * @param _coins Addresses of the two coins.
   * @param _A Unused; accepted so the factory ABI stays stable.
   * @param _fee Unused; accepted so the factory ABI stays stable.
   * @param _admin_fee Unused; accepted so the factory ABI stays stable.
   * @param _owner Default admin.
   * @param _manager Manager.
   * @param _pauser Pauser.
   * @param _LP LP token address.
   * @param _oracle Price oracle address.
   */
  function initialize(
    address[N_COINS] memory _coins,
    uint256 _A,
    uint256 _fee,
    uint256 _admin_fee,
    address _owner,
    address _manager,
    address _pauser,
    address _LP,
    address _oracle
  ) public initializer {
    require(msg.sender == STABLESWAP_FACTORY, "Operations: Not factory");
    require(_owner != address(0), "ZERO Address");
    require(_manager != address(0), "ZERO Address");
    require(_pauser != address(0), "ZERO Address");
    require(_LP != address(0), "ZERO Address");
    require(_oracle != address(0), "ZERO Address for oracle");

    __AccessControlEnumerable_init();
    __Pausable_init();
    __ReentrancyGuard_init();

    for (uint256 i = 0; i < N_COINS; i++) {
      require(_coins[i] != address(0), "ZERO Address");
      uint256 coinDecimal;
      if (_coins[i] == BNB_ADDRESS) {
        coinDecimal = 18;
        support_BNB = true;
      } else {
        coinDecimal = IERC20Metadata(_coins[i]).decimals();
      }
      require(coinDecimal <= MAX_DECIMAL, "The maximum decimal cannot exceed 18");
      PRECISION_MUL[i] = 10 ** (MAX_DECIMAL - coinDecimal);
      RATES[i] = PRECISION * PRECISION_MUL[i];
    }
    coins = _coins;
    token = _LP;

    oracle = _oracle;
    IOracle(oracle).peek(_coins[0]); // check the oracle is working
    IOracle(oracle).peek(_coins[1]);
    bnb_gas = 4029;

    _grantRole(DEFAULT_ADMIN_ROLE, _owner);
    _grantRole(MANAGER, _manager);
    _grantRole(PAUSER, _pauser);

    emit ChangeOracle(_oracle);
  }

  /// @notice LP intrinsic value, 1e18 — the normalised reserve sum over the supply.
  /// @dev Reverts if called while another pool operation is in flight, so callers can use it to assert
  ///      the pool is not mid-operation. Returns 0 on an empty pool rather than reverting.
  function get_virtual_price() external view returns (uint256) {
    require(_reentrancyGuardEntered() == false, "Reentrant call");

    uint256 supply = IStableSwapLP(token).totalSupply();
    if (supply == 0) return 0;

    uint256 total;
    for (uint256 i = 0; i < N_COINS; i++) {
      total += (balances[i] * RATES[i]) / PRECISION;
    }
    return (total * PRECISION) / supply;
  }

  /// @notice First deposit into an empty pool, establishing its reserve ratio.
  /// @dev Only reachable while the LP supply is zero, so it cannot alter an established ratio.
  function seed(uint256[N_COINS] calldata amounts) external payable onlyRole(MANAGER) nonReentrant {
    require(IStableSwapLP(token).totalSupply() == 0, "already seeded");
    if (!support_BNB) {
      require(msg.value == 0, "Inconsistent quantity");
    }

    uint256 minted;
    for (uint256 i = 0; i < N_COINS; i++) {
      require(amounts[i] > 0, "seed requires both coins");
      address coin = coins[i];
      if (coin == BNB_ADDRESS) {
        require(msg.value == amounts[i], "exact native amount required");
      } else {
        IERC20(coin).safeTransferFrom(msg.sender, address(this), amounts[i]);
      }
      balances[i] += amounts[i];
      minted += (amounts[i] * RATES[i]) / PRECISION;
    }

    IStableSwapLP(token).mint(msg.sender, minted);

    emit AddLiquidity(msg.sender, amounts, [uint256(0), uint256(0)], 0, minted, admin_fee);
  }

  /// @notice Reserves required to mint `lpAmount` shares. Shares its formula with {add_liquidity}, so a
  ///         quote can never disagree with execution.
  function calc_add_liquidity(uint256 lpAmount) external view returns (uint256[N_COINS] memory) {
    uint256 supply = IStableSwapLP(token).totalSupply();
    if (supply == 0) return [uint256(0), uint256(0)];
    return _amountsForShares(lpAmount, supply);
  }

  /// @notice Mint `lpAmount` shares, pulling exactly the reserves they are worth.
  /// @dev Share-in, not amount-in: deriving shares from amounts needs a second, non-invertible rounding
  ///      step that would reject reasonable inputs. Naming the shares makes the deposit exact, so
  ///      nothing is ever returned to the caller and the deposit path has no re-entrancy window.
  /// @param lpAmount Shares to mint.
  /// @param maxAmounts Per-leg spend ceiling.
  function add_liquidity(uint256 lpAmount, uint256[N_COINS] calldata maxAmounts) external payable nonReentrant {
    require(lpAmount > 0, "zero mint");
    uint256 supply = IStableSwapLP(token).totalSupply();
    require(supply > 0, "not seeded");
    if (!support_BNB) {
      require(msg.value == 0, "Inconsistent quantity");
    }

    uint256[N_COINS] memory need = _amountsForShares(lpAmount, supply);

    // Validate every leg before moving any funds.
    for (uint256 i = 0; i < N_COINS; i++) {
      require(need[i] <= maxAmounts[i], "exceeds max");
    }

    for (uint256 i = 0; i < N_COINS; i++) {
      address coin = coins[i];
      if (coin == BNB_ADDRESS) {
        // msg.value arrives whole and there is no refund path, so it must match exactly.
        require(msg.value == need[i], "exact native amount required");
      } else {
        IERC20(coin).safeTransferFrom(msg.sender, address(this), need[i]);
      }
      balances[i] += need[i];
    }

    IStableSwapLP(token).mint(msg.sender, lpAmount);

    emit AddLiquidity(msg.sender, need, [uint256(0), uint256(0)], 0, supply + lpAmount, admin_fee);
  }

  /// @notice Burn `lpAmount` shares for a pro-rata slice of both reserves.
  /// @dev Payouts derive from `balances`, so they can never exceed what the pool holds.
  function remove_liquidity(uint256 lpAmount, uint256[N_COINS] calldata minAmounts) external nonReentrant {
    uint256 supply = IStableSwapLP(token).totalSupply();
    require(lpAmount > 0 && supply > 0, "nothing to redeem");

    uint256[N_COINS] memory payout;
    for (uint256 i = 0; i < N_COINS; i++) {
      // Round down: the remainder stays with the holders that are left.
      uint256 share = (balances[i] * lpAmount) / supply;
      require(share >= minAmounts[i], "below min amount");
      payout[i] = share;
      balances[i] -= share;
    }

    IStableSwapLP(token).burnFrom(msg.sender, lpAmount); // burn before paying out

    for (uint256 i = 0; i < N_COINS; i++) {
      if (payout[i] > 0) transfer_out(coins[i], payout[i]);
    }

    emit RemoveLiquidity(msg.sender, payout, [uint256(0), uint256(0)], supply - lpAmount);
  }

  /// @dev Rounds up so the pool always receives at least what the minted shares are entitled to.
  function _amountsForShares(uint256 lpAmount, uint256 supply) internal view returns (uint256[N_COINS] memory need) {
    for (uint256 i = 0; i < N_COINS; i++) {
      need[i] = (lpAmount * balances[i] + supply - 1) / supply;
    }
  }

  function transfer_out(address coin_address, uint256 value) internal {
    if (coin_address == BNB_ADDRESS) {
      _safeTransferBNB(msg.sender, value);
    } else {
      IERC20(coin_address).safeTransfer(msg.sender, value);
    }
  }

  function _safeTransferBNB(address to, uint256 value) internal {
    (bool success, ) = to.call{ gas: bnb_gas, value: value }("");
    require(success, "BNB transfer failed");
  }

  function set_bnb_gas(uint256 _bnb_gas) external onlyRole(MANAGER) {
    require(_bnb_gas >= MIN_BNB_GAS && _bnb_gas <= MAX_BNB_GAS, "Illegal gas");
    bnb_gas = _bnb_gas;
    emit SetBNBGas(_bnb_gas);
  }

  /// @notice Tokens held beyond the LP-owned reserves, i.e. anything transferred in directly.
  function admin_balances(uint256 i) external view returns (uint256) {
    if (coins[i] == BNB_ADDRESS) {
      return address(this).balance - balances[i];
    } else {
      return IERC20(coins[i]).balanceOf(address(this)) - balances[i];
    }
  }

  function withdraw_admin_fees() external onlyRole(MANAGER) {
    for (uint256 i = 0; i < N_COINS; i++) {
      uint256 value;
      if (coins[i] == BNB_ADDRESS) {
        value = address(this).balance - balances[i];
      } else {
        value = IERC20(coins[i]).balanceOf(address(this)) - balances[i];
      }
      if (value > 0) {
        transfer_out(coins[i], value);
      }
    }
  }

  /// @notice Oracle prices for both coins, 1e18 precision.
  function fetchOraclePrice() public view returns (uint256[N_COINS] memory oraclePrices) {
    require(oracle != address(0), "Oracle not set");

    oraclePrices[0] = IOracle(oracle).peek(coins[0]) * 1e10;
    oraclePrices[1] = IOracle(oracle).peek(coins[1]) * 1e10;
  }

  function changeOracle(address _oracle) external onlyRole(MANAGER) {
    require(_oracle != address(0), "ZERO Address for oracle");
    require(_oracle != oracle, "No change in oracle");

    IOracle(_oracle).peek(coins[0]);
    IOracle(_oracle).peek(coins[1]);
    oracle = _oracle;

    emit ChangeOracle(_oracle);
  }

  /// @dev Pause the contract. Only `remove_liquidity` stays available.
  function pause() external onlyRole(PAUSER) {
    _pause();
  }

  function unpause() external onlyRole(MANAGER) {
    _unpause();
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
