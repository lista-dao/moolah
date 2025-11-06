pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20, IERC4626, ERC20Upgradeable, ERC4626Upgradeable, Math, SafeERC20 } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import "./interfaces/IMoolahCallbacks.sol";
import { IMoolahBase } from "./interfaces/IMoolah.sol";
import { IPublicLiquidator } from "../liquidator/IPublicLiquidator.sol";
import { IPSM } from "../IPSM.sol";

contract MoolahFlashLoanCallbackLocal is UUPSUpgradeable, AccessControlEnumerableUpgradeable, IMoolahFlashLoanCallback {
  using SafeERC20 for IERC20;

  bytes32 public constant MANAGER = keccak256("MANAGER"); // manager role
  address public constant PUBLIC_LIQUIDATOR = address(0x882475d622c687b079f149B69a15683FCbeCC6D9);
  address public constant moolahAddress = address(0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C);
  address public constant psmAddress = address(0xaa57F36DD5Ef2aC471863ec46277f976f272eC0c);

  /* CONSTRUCTOR */
  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /// @param admin The new admin of the contract.
  function initialize(address admin) public initializer {
    require(admin != address(0), "zero admin");

    __AccessControl_init();
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MANAGER, admin);
  }

  function callMoolahFlash(
    address token,
    uint256 amount,
    uint256 min,
    address middleToken,
    address pair,
    bytes calldata swapData
  ) external onlyRole(MANAGER) {
    bytes memory data = abi.encode(token, amount, min, middleToken, pair, swapData);
    IMoolahBase(moolahAddress).flashLoan(token, amount, data);
  }

  function onMoolahFlashLoan(uint256 assets, bytes calldata data) external override {
    require(msg.sender == moolahAddress, "Only Moolah");
    // decode data
    (address token, uint256 amount, uint256 min, address middleToken, address pair, bytes memory swapData) = abi.decode(
      data,
      (address, uint256, uint256, address, address, bytes)
    );

    uint256 balanceBefore = IERC20(token).balanceOf(address(this));
    require(balanceBefore >= assets, "Invalid flash loan amount");

    IERC20(token).forceApprove(psmAddress, assets);
    IPSM(psmAddress).sell(assets);

    uint256 middleBalance = IERC20(middleToken).balanceOf(address(this));
    require(middleBalance >= assets, "PSM sell failed");

    IERC20(middleToken).forceApprove(pair, assets);
    (bool success, ) = pair.call(swapData);
    require(success, "Swap failed");

    uint256 balanceAfter = IERC20(token).balanceOf(address(this));
    require(balanceAfter > balanceBefore + min, "Swap no profit");

    IERC20(token).forceApprove(moolahAddress, assets);
  }

  function callFlashLiquidate(
    bytes32 id,
    address borrower,
    uint256 seizedAssets,
    address pair,
    bytes calldata swapData
  ) external onlyRole(MANAGER) {
    IPublicLiquidator(PUBLIC_LIQUIDATOR).flashLiquidate(id, borrower, seizedAssets, pair, swapData);
  }

  function withdrawERC20(address token, uint256 amount) external onlyRole(MANAGER) {
    IERC20(token).safeTransfer(msg.sender, amount);
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
