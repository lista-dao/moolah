// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IMoolah } from "./Interface.sol";

/// @title OEVLiquidator
/// @notice Liquidation entry for a third-party OEV searcher (Atlas). The searcher bundles the oracle
///         update and the liquidation in one tx, pays the repayment in loan token and receives the
///         seized collateral. This contract holds no funds; it only gates who may liquidate which market.
contract OEVLiquidator is ReentrancyGuardUpgradeable, UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable {
  using SafeTransferLib for address;

  /// @dev Thrown when passing the zero address.
  string internal constant ZERO_ADDRESS = "zero address";
  error OnlyMoolah();

  address public immutable MOOLAH;

  bytes32 public constant MANAGER = keccak256("MANAGER"); // manager role
  bytes32 public constant PAUSER = keccak256("PAUSER"); // pauser role
  bytes32 public constant OEV = keccak256("OEV"); // third-party OEV liquidator role, may only call liquidate

  /// @custom:oz-upgrades-unsafe-allow constructor
  /// @param moolah The address of the Moolah contract.
  constructor(address moolah) {
    require(moolah != address(0), ZERO_ADDRESS);
    _disableInitializers();
    MOOLAH = moolah;
  }

  /// @dev initializes the contract. OEV's role admin is MANAGER so rotating the searcher address is a
  ///      multisig operation rather than a TimeLock one.
  /// @param admin DEFAULT_ADMIN_ROLE (TimeLock): role management + UUPS upgrade authorization.
  /// @param manager MANAGER (multisig): withdraw, unpause, OEV role rotation.
  /// @param pauser PAUSER: emergency pause.
  /// @param oev OEV: the third-party liquidator (Atlas).
  function initialize(address admin, address manager, address pauser, address oev) public initializer {
    require(admin != address(0), ZERO_ADDRESS);
    require(manager != address(0), ZERO_ADDRESS);
    require(pauser != address(0), ZERO_ADDRESS);
    require(oev != address(0), ZERO_ADDRESS);
    __AccessControl_init();
    __Pausable_init();
    __ReentrancyGuard_init();
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MANAGER, manager);
    _grantRole(PAUSER, pauser);
    _grantRole(OEV, oev);
    _setRoleAdmin(OEV, MANAGER);
  }

  /// @dev withdraws ERC20 tokens sent here by mistake.
  /// @param token The address of the token.
  /// @param amount The amount to withdraw.
  function withdrawERC20(address token, uint256 amount) external onlyRole(MANAGER) {
    token.safeTransfer(msg.sender, amount);
  }

  /// @dev liquidates a position. The caller pays the repayment in loan token (pulled in the Moolah
  ///      callback, so it must have approved this contract) and receives the seized collateral.
  /// @param id The id of the market.
  /// @param borrower The address of the borrower.
  /// @param seizedAssets The amount of assets to seize.
  /// @param repaidShares The amount of shares to repay.
  /// @return The actual seized assets and repaid assets.
  function liquidate(
    bytes32 id,
    address borrower,
    uint256 seizedAssets,
    uint256 repaidShares
  ) external nonReentrant whenNotPaused onlyRole(OEV) returns (uint256, uint256) {
    IMoolah.MarketParams memory params = IMoolah(MOOLAH).idToMarketParams(id);
    (uint256 _seizedAssets, uint256 _repaidAssets) = IMoolah(MOOLAH).liquidate(
      params,
      borrower,
      seizedAssets,
      repaidShares,
      abi.encode(params.loanToken, msg.sender)
    );
    params.collateralToken.safeTransfer(msg.sender, _seizedAssets);
    return (_seizedAssets, _repaidAssets);
  }

  /// @dev the function will be called by the Moolah contract when liquidate. Pulls the exact
  ///      repayment from the OEV caller and approves Moolah to take it.
  /// @param repaidAssets The amount of assets repaid.
  /// @param data The callback data: (loanToken, payer).
  function onMoolahLiquidate(uint256 repaidAssets, bytes calldata data) external {
    require(msg.sender == MOOLAH, OnlyMoolah());
    (address loanToken, address payer) = abi.decode(data, (address, address));
    loanToken.safeTransferFrom(payer, address(this), repaidAssets);
    loanToken.safeApprove(MOOLAH, repaidAssets);
  }

  /// @dev Emergency pause (PAUSER). Halts liquidate.
  function pause() external onlyRole(PAUSER) {
    _pause();
  }

  function unpause() external onlyRole(MANAGER) {
    _unpause();
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
