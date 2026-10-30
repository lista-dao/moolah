// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IMoolah, IOEVLiquidateCallback } from "./Interface.sol";

/// @title OEVLiquidator
/// @notice Liquidation entry for a third-party OEV searcher (Atlas). The searcher bundles the oracle
///         update and the liquidation in one tx. Its OEV-role contract receives the seized collateral
///         inside the Moolah callback, then must send the repayment in loan token from its own
///         onOEVLiquidate. The OEV holder must be a contract implementing IOEVLiquidateCallback.
/// @dev    Plain-collateral markets only: SmartProvider LP and V3Provider share collateral cannot be
///         transferred out to the payer, so liquidating those markets reverts. Which markets can be
///         liquidated is gated by Moolah's per-market liquidation whitelist.
///         Not meant to hold funds. The repayment is not pulled from the payer (gas), so any loan token
///         left here could fund a later repayment; MANAGER sweeps stray balances via withdrawERC20.
contract OEVLiquidator is ReentrancyGuardUpgradeable, UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable {
  using SafeTransferLib for address;

  /// @dev Thrown when passing the zero address.
  string internal constant ZERO_ADDRESS = "zero address";
  error OnlyMoolah();

  address public immutable MOOLAH;

  bytes32 public constant MANAGER = keccak256("MANAGER"); // manager role
  bytes32 public constant PAUSER = keccak256("PAUSER"); // pauser role
  bytes32 public constant OEV = keccak256("OEV"); // third-party OEV liquidator role, may only call liquidate

  /// @dev Same signature as PublicLiquidator.Liquidated; `liquidator` is the OEV searcher (msg.sender).
  event Liquidated(
    bytes32 indexed id,
    address indexed borrower,
    uint256 seizedAssets,
    uint256 repaidAssets,
    uint256 repaidShares,
    address liquidator
  );

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

  /// @dev liquidates a position. The caller must be a contract implementing IOEVLiquidateCallback:
  ///      inside the Moolah callback it first receives the seized collateral, then its
  ///      onOEVLiquidate(repaidAssets, payload) is called, in which it must transfer `repaidAssets`
  ///      of loan token to this contract.
  /// @param params The market params. Moolah reverts unless they hash to an existing market.
  /// @param borrower The address of the borrower.
  /// @param seizedAssets The amount of assets to seize.
  /// @param repaidShares The amount of shares to repay.
  /// @param payload Arbitrary data passed through to the caller's onOEVLiquidate.
  /// @return _seizedAssets The actual seized assets.
  /// @return _repaidAssets The actual repaid assets.
  function liquidate(
    IMoolah.MarketParams calldata params,
    address borrower,
    uint256 seizedAssets,
    uint256 repaidShares,
    bytes calldata payload
  ) external nonReentrant whenNotPaused onlyRole(OEV) returns (uint256 _seizedAssets, uint256 _repaidAssets) {
    (_seizedAssets, _repaidAssets) = IMoolah(MOOLAH).liquidate(
      params,
      borrower,
      seizedAssets,
      repaidShares,
      abi.encode(
        params.loanToken,
        params.collateralToken,
        params.collateralToken.balanceOf(address(this)),
        msg.sender,
        payload
      )
    );
    emit Liquidated(keccak256(abi.encode(params)), borrower, _seizedAssets, _repaidAssets, repaidShares, msg.sender);
  }

  /// @dev the function will be called by the Moolah contract when liquidate. Sends the collateral
  ///      seized by this liquidation to the payer, calls the payer's onOEVLiquidate (which must send
  ///      the repayment here), then approves Moolah to take the repayment.
  /// @param repaidAssets The amount of assets repaid.
  /// @param data The callback data: (loanToken, collateralToken, collateralTokenPreBalance, payer, payload).
  function onMoolahLiquidate(uint256 repaidAssets, bytes calldata data) external {
    require(msg.sender == MOOLAH, OnlyMoolah());
    (
      address loanToken,
      address collateralToken,
      uint256 collateralTokenPreBalance,
      address payer,
      bytes memory payload
    ) = abi.decode(data, (address, address, uint256, address, bytes));
    // transfer seized collateral to payer first
    collateralToken.safeTransfer(payer, collateralToken.balanceOf(address(this)) - collateralTokenPreBalance);
    // callback payer
    IOEVLiquidateCallback(payer).onOEVLiquidate(repaidAssets, payload);
    // Note: should be reverted if payer doesn't transfer sufficient loan token here
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
