// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import { ILiquidator } from "../../src/liquidator/ILiquidator.sol";
import { IBroker } from "../../src/broker/interfaces/IBroker.sol";

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { MarketParamsLib } from "../../src/moolah/libraries/MarketParamsLib.sol";
import { Id, MarketParams, IMoolah } from "../../src/moolah/interfaces/IMoolah.sol";

contract MockLiquidator is UUPSUpgradeable, AccessControlUpgradeable {
  using MarketParamsLib for MarketParams;

  /// @dev Thrown when passing the zero address.
  string internal constant ZERO_ADDRESS = "zero address";
  error NoProfit();
  error OnlyMoolahOrBroker();
  error ExceedAmount();
  error WhitelistSameStatus();
  error NotWhitelisted();
  error SwapFailed();

  address public immutable MOOLAH;

  bytes32 public constant MANAGER = keccak256("MANAGER"); // manager role
  bytes32 public constant BOT = keccak256("BOT"); // bot role

  mapping(bytes32 => address) public idTobrokers;
  mapping(address => bool) public brokers;

  /// @custom:oz-upgrades-unsafe-allow constructor
  /// @param moolah The address of the Moolah contract.
  constructor(address moolah) {
    require(moolah != address(0), ZERO_ADDRESS);
    _disableInitializers();
    MOOLAH = moolah;
  }

  /// @dev initializes the contract.
  /// @param admin The address of the admin.
  /// @param manager The address of the manager.
  /// @param bot The address of the bot.
  function initialize(address admin, address manager, address bot) public initializer {
    require(admin != address(0), ZERO_ADDRESS);
    require(manager != address(0), ZERO_ADDRESS);
    require(bot != address(0), ZERO_ADDRESS);
    __AccessControl_init();
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MANAGER, manager);
    _grantRole(BOT, bot);
  }

  function setBroker(bytes32 marketId, address broker, bool whitelisted) external onlyRole(MANAGER) {
    require(broker != address(0), ZERO_ADDRESS);
    if (whitelisted) {
      if (idTobrokers[marketId] == broker) revert WhitelistSameStatus();
      idTobrokers[marketId] = broker;
      brokers[broker] = true;
    } else {
      if (idTobrokers[marketId] != broker) revert NotWhitelisted();
      delete idTobrokers[marketId];
      delete brokers[broker];
    }
  }

  /// @dev liquidates a position.
  /// @param id The id of the market.
  /// @param borrower The address of the borrower.
  /// @param seizedAssets The amount of assets to seize.
  function liquidate(
    bytes32 id,
    address borrower,
    uint256 seizedAssets,
    uint256 repaidShares
  ) external payable onlyRole(BOT) {
    address broker = idTobrokers[id];
    MarketParams memory params = IMoolah(MOOLAH).idToMarketParams(Id.wrap(id));
    if (broker != address(0)) {
      console.log("[MockLiquidator] liquidate via broker: ", broker);
      IBroker(broker).liquidate(
        params,
        borrower,
        seizedAssets,
        repaidShares,
        abi.encode(
          ILiquidator.MoolahLiquidateData(params.collateralToken, params.loanToken, seizedAssets, address(0), "", false)
        )
      );
    } else {
      console.log("[MockLiquidator] liquidate directly via Moolah");
      IMoolah(MOOLAH).liquidate(
        params,
        borrower,
        seizedAssets,
        repaidShares,
        abi.encode(
          ILiquidator.MoolahLiquidateData(params.collateralToken, params.loanToken, seizedAssets, address(0), "", false)
        )
      );
    }
  }

  /// @dev the function will be called by the Moolah contract when liquidate.
  /// @param repaidAssets The amount of assets repaid.
  /// @param data The callback data.
  function onMoolahLiquidate(uint256 repaidAssets, bytes calldata data) external {
    require(msg.sender == MOOLAH || brokers[msg.sender], OnlyMoolahOrBroker());
    console.log("[MockLiquidator] onMoolahLiquidate called. repaidAssets: ", repaidAssets);
    ILiquidator.MoolahLiquidateData memory arb = abi.decode(data, (ILiquidator.MoolahLiquidateData));
    if (arb.swap) {
      uint256 before = SafeTransferLib.balanceOf(arb.loanToken, address(this));

      SafeTransferLib.safeApprove(arb.collateralToken, arb.pair, arb.seized);
      (bool success, ) = arb.pair.call(arb.swapData);
      require(success, SwapFailed());

      uint256 out = SafeTransferLib.balanceOf(arb.loanToken, address(this)) - before;

      if (out < repaidAssets) revert NoProfit();

      SafeTransferLib.safeApprove(arb.collateralToken, arb.pair, 0);
    }

    SafeTransferLib.safeApprove(arb.loanToken, msg.sender, repaidAssets);
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
