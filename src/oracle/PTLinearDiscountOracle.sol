//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import { ILinearDiscountOracle } from "./interfaces/ILinearDiscountOracle.sol";

contract PTLinearDiscountOracle is UUPSUpgradeable, AccessControlEnumerableUpgradeable {
  /// @dev PT token address
  address asset;
  /// @dev Linear discount oracle address
  address discountOracle;

  bytes32 public constant MANAGER = keccak256("MANAGER");

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize(address admin, address manager, address _asset, address linearDiscount) external initializer {
    require(admin != address(0), "Invalid admin address");
    require(manager != address(0), "Invalid manager address");
    require(_asset != address(0), "Invalid asset address");
    require(asset == ILinearDiscountOracle(linearDiscount).PT(), "Asset mismatch");
    require(ILinearDiscountOracle(linearDiscount).decimals() == 18, "Invalid discount oracle");

    asset = _asset;
    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MANAGER, admin);
  }

  function peek(address _asset) public view returns (uint256) {
    require(_asset == asset, "PTLinearDiscountOracle: Invalid asset");
    (, int256 answer, , , ) = ILinearDiscountOracle(discountOracle).latestRoundData();
    uint256 price = uint256(answer) / 1e10;
    require(price > 0, "PTLinearDiscountOracle: Invalid price");
    return price;
  }

  function decimals() external pure returns (uint8) {
    return 8;
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
