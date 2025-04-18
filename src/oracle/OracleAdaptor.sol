//SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { IOracle, TokenConfig } from "../moolah/interfaces/IOracle.sol";
import { IStakeManager } from "./interfaces/IStakeManager.sol";
import { PTOracleType, PTOracleConfig, ILinearDiscountOracle } from "./interfaces/IPTOracle.sol";

contract OracleAdaptor is AccessControlEnumerableUpgradeable, UUPSUpgradeable, IOracle {
  // @dev resilient oracle address
  address public constant RESILIENT_ORACLE = 0xf3afD82A4071f272F403dC176916141f44E6c750;
  // @dev WBNB token address
  address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
  // @dev SLISBNB token address
  address public constant SLISBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
  // @dev Stake Manager Address
  address public constant STAKE_MANAGER = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;
  // @dev asset mapping for resilient oracle
  mapping(address => address) public assetMap;
  // @dev PT asset uses this oracle for price if set
  // @dev PT asset => PT oracle address and type
  mapping(address => PTOracleConfig) public ptOracles;

  event AssetMapUpdated(address indexed srcAsset, address indexed targetAsset);
  event PTOracleUpdated(address indexed asset, PTOracleType oracleType, address oracleAddress);

  bytes32 public constant MANAGER = keccak256("MANAGER");

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize(address admin, address[] memory srcAsset, address[] memory targetAsset) external initializer {
    require(admin != address(0), "Invalid admin address");

    __AccessControl_init();
    __UUPSUpgradeable_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);

    require(srcAsset.length == targetAsset.length, "OracleAdaptor: Invalid asset length");
    for (uint256 i = 0; i < srcAsset.length; i++) {
      require(srcAsset[i] != targetAsset[i], "OracleAdaptor: Invalid asset");
      require(targetAsset[i] != address(0), "OracleAdaptor: Target asset cannot be zero address"); // Use WBNB for BNB
      assetMap[srcAsset[i]] = targetAsset[i];

      emit AssetMapUpdated(srcAsset[i], targetAsset[i]);
    }
  }

  function peek(address asset) public view returns (uint256) {
    // Check if the asset is a PT asset and use the configured oracle
    if (ptOracles[asset].oracleAddress != address(0) && ptOracles[asset].oracleType != PTOracleType.NONE) {
      return _peekPtOracle(asset);
    }

    // Handle slisBNB
    if (asset == SLISBNB) {
      uint256 price = IOracle(RESILIENT_ORACLE).peek(WBNB);
      return (price * IStakeManager(STAKE_MANAGER).convertSnBnbToBnb(1e10)) / 1e10;
    }

    address targetAsset = assetMap[asset];

    if (targetAsset == address(0)) {
      // Handle normal assets
      return IOracle(RESILIENT_ORACLE).peek(asset);
    } else {
      // Handle pt-clisBNB-25apr
      return IOracle(RESILIENT_ORACLE).peek(targetAsset);
    }
  }

  function _peekPtOracle(address asset) internal view returns (uint256) {
    PTOracleConfig memory config = ptOracles[asset];

    if (config.oracleType == PTOracleType.LINEAR_DISCOUNT) {
      (uint80 _roundId, int256 answer, , , ) = ILinearDiscountOracle(config.oracleAddress).latestRoundData();
      require(answer > 0, "OracleAdaptor: Invalid price");
      return uint256(answer) / 1e10;
    } else {
      revert("OracleAdaptor: Unsupported oracle type");
    }
  }

  function getTokenConfig(address asset) external view override returns (TokenConfig memory) {
    // If the asset is a PT asset, return the configured oracle
    if (ptOracles[asset].oracleAddress != address(0)) {
      return
        TokenConfig({
          asset: asset,
          oracles: [address(this), address(0), address(0)],
          enableFlagsForOracles: [true, false, false],
          timeDeltaTolerance: 0
        });
    }

    address targetAsset = assetMap[asset];

    // Handle slisBNB
    if (asset == SLISBNB) {
      TokenConfig memory config = IOracle(RESILIENT_ORACLE).getTokenConfig(WBNB);
      config.oracles[0] = address(this);
      config.enableFlagsForOracles[0] = true;
      return config;
    }

    if (targetAsset == address(0)) {
      return IOracle(RESILIENT_ORACLE).getTokenConfig(asset);
    } else {
      // Handle pt-clisBNB-25apr
      return IOracle(RESILIENT_ORACLE).getTokenConfig(targetAsset);
    }
  }

  /// @dev only admin can update the asset mapping
  /// @param srcAsset source asset address
  /// @param targetAsset target asset address
  function updateAssetMap(address srcAsset, address targetAsset) external onlyRole(MANAGER) {
    require(srcAsset != targetAsset, "OracleAdaptor: Invalid mapping");
    require(targetAsset != address(0), "OracleAdaptor: Target asset cannot be zero address");
    assetMap[srcAsset] = targetAsset;

    emit AssetMapUpdated(srcAsset, targetAsset);
  }

  /// @dev config PT oracle
  /// @param asset PT asset address
  /// @param oracleType oracle type: LINEAR_DISCOUNT or TWAP
  /// @param oracleAddress oracle address
  function configPtOracle(address asset, PTOracleType oracleType, address oracleAddress) external onlyRole(MANAGER) {
    require(asset != address(0), "OracleAdaptor: Invalid asset");
    require(oracleAddress != address(0), "OracleAdaptor: Invalid oracle address");
    require(oracleType != PTOracleType.NONE, "OracleAdaptor: Invalid oracle type");

    if (oracleType == PTOracleType.LINEAR_DISCOUNT) {
      require(ILinearDiscountOracle(oracleAddress).PT() == asset, "OracleAdaptor: Asset mismatch");
      require(ILinearDiscountOracle(oracleAddress).decimals() == 18, "OracleAdaptor: Invalid oracle decimals");

      ptOracles[asset] = PTOracleConfig({ oracleType: oracleType, oracleAddress: oracleAddress });

      emit PTOracleUpdated(asset, oracleType, oracleAddress);
    } else {
      revert("OracleAdaptor: Unsupported oracle type");
    }
  }

  /// @dev remove PT oracle
  /// @param asset PT asset address
  function removePtOracle(address asset) external onlyRole(MANAGER) {
    require(ptOracles[asset].oracleAddress != address(0), "OracleAdaptor: PT oracle not set");
    delete ptOracles[asset];

    emit PTOracleUpdated(asset, PTOracleType.NONE, address(0));
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
