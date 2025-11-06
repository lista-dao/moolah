pragma solidity 0.8.28;

import "forge-std/console.sol";
import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20, IERC4626, ERC20Upgradeable, ERC4626Upgradeable, Math, SafeERC20 } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import "./interfaces/IMoolahCallbacks.sol";
import { IMoolahBase } from "./interfaces/IMoolah.sol";
import { IPublicLiquidator } from "../liquidator/IPublicLiquidator.sol";
import { IPSM } from "../IPSM.sol";

interface IStableSwap {
  function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external payable;
}

interface IWBNB {
  function deposit() external payable;
}

contract FlashLoanSmart is UUPSUpgradeable, AccessControlEnumerableUpgradeable, IMoolahFlashLoanCallback {
  using SafeERC20 for IERC20;

  bytes32 public constant MANAGER = keccak256("MANAGER"); // manager role
  address public constant PUBLIC_LIQUIDATOR = address(0x882475d622c687b079f149B69a15683FCbeCC6D9);
  address public constant moolahAddress = address(0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C);
  address public constant psmAddress = address(0xaa57F36DD5Ef2aC471863ec46277f976f272eC0c);
  address public constant slisbnbSwapPool = address(0x3DcEA6AFBA8af84b25F1f8947058AF1ac4c06131);
  address public constant wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);

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

  function callMoolahFlashSmart(
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
    console.log("slisbnb before1: %s %s", assets, balanceBefore);

    IERC20(token).forceApprove(slisbnbSwapPool, assets);
    IStableSwap(slisbnbSwapPool).exchange(0, 1, assets, 0);

    uint256 nativeMiddle = address(this).balance;
    console.log("bnb nativeMiddle: %s", nativeMiddle);
    uint256 wbnbBefore = IERC20(wbnb).balanceOf(address(this));
    IWBNB(wbnb).deposit{ value: nativeMiddle }();

    uint256 wbnbAfter = IERC20(wbnb).balanceOf(address(this));
    console.log("wbnb wbnbAfter: %s", wbnbAfter);

    IERC20(middleToken).forceApprove(pair, wbnbAfter);
    (bool success, ) = pair.call(swapData);
    require(success, "Swap failed");

    uint256 balanceAfter = IERC20(token).balanceOf(address(this));
    console.log("slisbnb after: %s %s", assets, balanceAfter);
    require(balanceAfter > balanceBefore + min, "Swap no profit");

    IERC20(token).forceApprove(moolahAddress, assets);
  }

  function withdrawERC20(address token, uint256 amount) external onlyRole(MANAGER) {
    IERC20(token).safeTransfer(msg.sender, amount);
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

  receive() external payable {}
}
