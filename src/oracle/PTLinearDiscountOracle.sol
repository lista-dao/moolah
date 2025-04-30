//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import { ILinearDiscountOracle } from "./interfaces/ILinearDiscountOracle.sol";
import { IOracle, TokenConfig } from "../moolah/interfaces/IOracle.sol";

contract PTLinearDiscountOracle is UUPSUpgradeable, AccessControlEnumerableUpgradeable, IOracle {
  /// @dev PT token address
  address public asset;

  /// @dev Linear discount oracle address
  address public discountOracle;

  /// @dev loan token address
  address public loanAsset;

  /// @dev loan token oracle address
  IOracle public loanTokenOracle;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize(
    address admin,
    address _asset,
    address linearDiscount,
    address _loanAsset,
    address _loanTokenOracle
  ) external initializer {
    require(admin != address(0), "Invalid admin address");
    require(_asset != address(0), "Invalid asset address");
    require(_asset == ILinearDiscountOracle(linearDiscount).PT(), "Asset mismatch");
    require(ILinearDiscountOracle(linearDiscount).decimals() == 18, "Invalid discount oracle");
    require(_loanAsset != address(0), "Invalid loan asset address");
    require(_loanTokenOracle != address(0), "Invalid loan token oracle address");

    uint256 loanPrice = IOracle(_loanTokenOracle).peek(_loanAsset);
    require(loanPrice > 0, "Invalid loan asset price");
    loanAsset = _loanAsset;
    loanTokenOracle = IOracle(_loanTokenOracle);

    asset = _asset;
    discountOracle = linearDiscount;
    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
  }

  function peek(address _asset) public view returns (uint256) {
    if (_asset == asset) {
      (, int256 answer, , , ) = ILinearDiscountOracle(discountOracle).latestRoundData();
      uint256 price = uint256(answer) / 1e10;
      require(price > 0, "PTLinearDiscountOracle: Invalid price");
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

  function getTokenConfig(address _asset) external view override returns (TokenConfig memory) {
    if (_asset == asset) {
      return
        TokenConfig({
          asset: asset,
          oracles: [address(this), address(0), address(0)],
          enableFlagsForOracles: [true, false, false],
          timeDeltaTolerance: 0
        });
    }

    if (_asset == loanAsset) {
      TokenConfig memory config = loanTokenOracle.getTokenConfig(loanAsset);
      return config;
    }

    revert("PTLinearDiscountOracle: Invalid asset");
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
