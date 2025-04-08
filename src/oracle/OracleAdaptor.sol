//SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { IOracle, TokenConfig } from "../moolah/interfaces/IOracle.sol";
import { IStakeManager } from "./interfaces/IStakeManager.sol";

contract OracleAdaptor is AccessControlEnumerableUpgradeable, UUPSUpgradeable, IOracle {
  // @dev resilient oracle address
  address public constant RESILIENT_ORACLE = 0xf3afD82A4071f272F403dC176916141f44E6c750;
  // @dev WBNB token address
  address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
  // @dev SLISBNB token address
  address public constant SLISBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
  // @dev Stake Manager Address
  address public constant STAKE_MANAGER = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;
  // @dev asset mapping
  mapping(address => address) public assetMap;

  event AssetMapUpdated(address indexed srcAsset, address indexed targetAsset);

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

  function getTokenConfig(address asset) external view override returns (TokenConfig memory) {
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
  function updateAssetMap(address srcAsset, address targetAsset) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(srcAsset != targetAsset, "OracleAdaptor: Invalid mapping");
    require(targetAsset != address(0), "OracleAdaptor: Target asset cannot be zero address");
    assetMap[srcAsset] = targetAsset;

    emit AssetMapUpdated(srcAsset, targetAsset);
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
