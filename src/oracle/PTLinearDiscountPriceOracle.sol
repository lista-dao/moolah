//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import { IOracle } from "../moolah/interfaces/IOracle.sol";
import { ILinearDiscountOracle } from "./interfaces/ILinearDiscountOracle.sol";

contract PTLinearDiscountPriceOracle is UUPSUpgradeable, AccessControlEnumerableUpgradeable {
  /// @dev PT token address
  address public asset;

  /// @dev Linear discount oracle address
  address public discountOracle;

  /// @dev Base token address
  address public baseToken;

  /// @dev Base token oracle address which implements `peek` function
  IOracle public baseTokenOracle;

  bytes32 public constant MANAGER = keccak256("MANAGER");

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /// @notice Initializes the contract
  /// @param admin The address of the admin
  /// @param manager The address of the manager
  /// @param _asset The address of the PT asset
  /// @param linearDiscount The address of the linear discount oracle for the PT asset
  /// @param _baseToken The address of the base token; WBNB for pt-clisBnb
  /// @param _baseTokenOracle The address of the base token oracle, for example: Lista ResilientOracle
  function initialize(
    address admin,
    address manager,
    address _asset,
    address linearDiscount,
    address _baseToken,
    address _baseTokenOracle
  ) external initializer {
    require(admin != address(0), "Invalid admin address");
    require(manager != address(0), "Invalid manager address");
    require(_asset != address(0), "Invalid asset address");
    require(linearDiscount != address(0), "Invalid linear discount oracle address");
    require(_baseToken != address(0), "Invalid base token address");
    require(_baseTokenOracle != address(0), "Invalid base token oracle address");

    require(_asset == ILinearDiscountOracle(linearDiscount).PT(), "Asset mismatch");
    require(ILinearDiscountOracle(linearDiscount).decimals() == 18, "Invalid discount oracle");

    IOracle(_baseTokenOracle).peek(_baseToken);
    baseToken = _baseToken;
    baseTokenOracle = IOracle(_baseTokenOracle);

    asset = _asset;
    discountOracle = linearDiscount;
    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MANAGER, manager);
  }

  function peek(address _asset) public view returns (uint256) {
    require(_asset == asset, "PTLinearDiscountOracle: Invalid asset");
    (, int256 answer, , , ) = ILinearDiscountOracle(discountOracle).latestRoundData();
    uint256 basePrice = baseTokenOracle.peek(baseToken);
    uint256 price = basePrice * uint256(answer) / 1e18;

    require(price > 0, "PTLinearDiscountOracle: Invalid price");
    return price;
  }

  function decimals() external pure returns (uint8) {
    return 8;
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
