//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import { IOracle } from "../moolah/interfaces/IOracle.sol";
import { ILinearDiscountOracle } from "./interfaces/ILinearDiscountOracle.sol";

contract PTLinearDiscountMarketOracle is UUPSUpgradeable, AccessControlEnumerableUpgradeable {
  /// @dev PT token address
  address public asset;

  /// @dev Linear discount oracle address
  address public discountOracle;

  /// @dev Base token address
  address public baseToken;

  /// @dev Base token oracle address which implements `peek` function
  IOracle public baseTokenOracle;

  /// @dev Loan asset address
  address public loanAsset;

  /// @dev Loan token oracle address
  IOracle public loanTokenOracle;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /// @notice Initializes the contract
  /// @param admin The address of the admin
  /// @param _asset The address of the PT asset
  /// @param linearDiscount The address of the linear discount oracle for the PT asset
  /// @param _baseToken The address of the base token; WBNB for pt-clisBnb
  /// @param _baseTokenOracle The address of the base token oracle, for example: Lista ResilientOracle
  /// @param _loanAsset The address of the loan asset
  /// @param _loanTokenOracle The address of the loan token oracle, for example: Lista ResilientOracle or OracleAdapter
  function initialize(
    address admin,
    address _asset,
    address linearDiscount,
    address _baseToken,
    address _baseTokenOracle,
    address _loanAsset,
    address _loanTokenOracle
  ) external initializer {
    require(admin != address(0), "Invalid admin address");
    require(_asset != address(0), "Invalid asset address");
    require(linearDiscount != address(0), "Invalid linear discount oracle address");
    require(_baseToken != address(0), "Invalid base token address");
    require(_baseTokenOracle != address(0), "Invalid base token oracle address");
    require(_loanAsset != address(0), "Invalid loan asset address");
    require(_loanTokenOracle != address(0), "Invalid loan token oracle address");

    require(_asset == ILinearDiscountOracle(linearDiscount).PT(), "Asset mismatch");
    require(ILinearDiscountOracle(linearDiscount).decimals() == 18, "Invalid discount oracle");

    uint256 basePrice = IOracle(_baseTokenOracle).peek(_baseToken);
    require(basePrice > 0, "Invalid base token price");
    baseToken = _baseToken;
    baseTokenOracle = IOracle(_baseTokenOracle);

    uint256 loanPrice = IOracle(_loanTokenOracle).peek(_loanAsset);
    require(loanPrice > 0, "Invalid loan asset price");
    loanAsset = _loanAsset;
    loanTokenOracle = IOracle(_loanTokenOracle);

    asset = _asset;
    discountOracle = linearDiscount;
    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
  }

  /// @notice Returns the price of the PT asset or the loan asset
  /// @param _asset The address of the PT asset or the loan asset; must be either asset or loanAsset
  function peek(address _asset) public view returns (uint256) {
    require(_asset == asset || _asset == loanAsset, "PTLinearDiscountOracle: Invalid asset");

    if (_asset == asset) {
      (, int256 answer, , , ) = ILinearDiscountOracle(discountOracle).latestRoundData();
      uint256 basePrice = baseTokenOracle.peek(baseToken);
      uint256 price = (basePrice * uint256(answer)) / 1e18;

      require(price > 0, "PTLinearDiscountOracle: Invalid pt asset price");
      return price;
    }

    if (_asset == loanAsset) {
      uint256 price = loanTokenOracle.peek(loanAsset);
      require(price > 0, "PTLinearDiscountOracle: Invalid loan asset price");
      return price;
    }

    revert("PTLinearDiscountOracle: Invalid asset");
  }

  function decimals() external pure returns (uint8) {
    return 8;
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
