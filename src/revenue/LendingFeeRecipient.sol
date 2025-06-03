// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import "moolah-vault/interfaces/IMoolahVault.sol";
import "moolah/interfaces/IMoolah.sol";

contract LendingFeeRecipient is
  UUPSUpgradeable,
  AccessControlEnumerableUpgradeable
{
  IMoolah public moolah;
  address[] public vaults;
  address public marketFeeRecipient;
  address public vaultFeeRecipient;

  bytes32 public constant MANAGER = keccak256("MANAGER"); // manager role
  bytes32 public constant BOT = keccak256("BOT"); // bot role

  event MarketFeeClaimed(Id id, address token, uint256 assets, uint256 shares);
  event VaultFeeClaimed(address vault, address token, uint256 assets, uint256 shares);
  event VaultAdded(address vault);
  event VaultRemoved(address vault);
  event SetMarketFeeRecipient(address feeRecipient);
  event SetVaultFeeRecipient(address feeRecipient);


  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /// @dev initialize contract
  /// @param _moolah the moolah address.
  /// @param admin the new admin role of the contract.
  /// @param manager the new manager role of the contract.
  /// @param bot the new bot role of the contract.
  /// @param _marketFeeRecipient the new market fee recipient.
  /// @param _vaultFeeRecipient the new vault fee recipient.
  function initialize(
    address _moolah,
    address admin,
    address manager,
    address bot,
    address _marketFeeRecipient,
    address _vaultFeeRecipient
  ) public initializer {
    require(_moolah != address(0), "moolah cannot be zero address");
    require(admin != address(0), "admin cannot be zero address");
    require(manager != address(0), "manager cannot be zero address");
    require(bot != address(0), "bot cannot be zero address");
    require(_marketFeeRecipient != address(0), "marketFeeRecipient cannot be zero address");
    require(_vaultFeeRecipient != address(0), "vaultFeeRecipient cannot be zero address");

    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MANAGER, manager);
    _grantRole(BOT, bot);

    moolah = IMoolah(_moolah);
    marketFeeRecipient = _marketFeeRecipient;
    vaultFeeRecipient = _vaultFeeRecipient;
  }

  /// @dev set the market fee recipient.
  /// @param _marketFeeRecipient the new market fee recipient.
  function setMarketFeeRecipient(address _marketFeeRecipient) external onlyRole(MANAGER) {
    require(_marketFeeRecipient != address(0), "marketFeeRecipient cannot be zero address");
    require(_marketFeeRecipient != marketFeeRecipient, "marketFeeRecipient already set to this address");
    marketFeeRecipient = _marketFeeRecipient;

    emit SetMarketFeeRecipient(_marketFeeRecipient);
  }

  /// @dev set the vault fee recipient.
  /// @param _vaultFeeRecipient the new vault fee recipient.
  function setVaultFeeRecipient(address _vaultFeeRecipient) external onlyRole(MANAGER) {
    require(_vaultFeeRecipient != address(0), "vaultFeeRecipient cannot be zero address");
    require(_vaultFeeRecipient != vaultFeeRecipient, "vaultFeeRecipient already set to this address");
    vaultFeeRecipient = _vaultFeeRecipient;

    emit SetVaultFeeRecipient(_vaultFeeRecipient);
  }

  /// @dev add a new vault to the list of vaults.
  /// @param _vault the address of the vault to add.
  function addVault(address _vault) external onlyRole(MANAGER) {
    require(_vault != address(0), "vault cannot be zero address");

    for (uint256 i = 0; i < vaults.length; i++) {
      require(vaults[i] != _vault, "vault already exists");
    }

    vaults.push(_vault);
    emit VaultAdded(_vault);
  }

  /// @dev remove a vault from the list of vaults.
  /// @param _vault the address of the vault to remove.
  function removeVault(address _vault) external onlyRole(MANAGER) {
    for (uint256 i = 0; i < vaults.length; i++) {
      if (vaults[i] == _vault) {
        vaults[i] = vaults[vaults.length - 1];
        vaults.pop();
        emit VaultRemoved(_vault);
        return;
      }
    }

    revert("vault not found");
  }

  /// @dev claim market fees for the given market IDs.
  /// @param marketIds the array of market IDs to claim fees for.
  function claimMarketFee(Id[] calldata marketIds) external onlyRole(BOT) {
    for (uint256 i = 0; i < marketIds.length; i++) {
      Id marketId = marketIds[i];
      Position memory position = moolah.position(marketId, address(this));
      if (position.supplyShares > 0) {
        MarketParams memory marketParams = moolah.idToMarketParams(marketId);
        (uint256 assets,) = moolah.withdraw(marketParams, 0, position.supplyShares, address(this), marketFeeRecipient);
        emit MarketFeeClaimed(marketId, marketParams.loanToken, assets, position.supplyShares);
      }
    }
  }

  /// @dev claim vault fees for all vaults.
  function claimVaultFee() external onlyRole(BOT) {
    for (uint256 i = 0; i < vaults.length; i++) {
      IMoolahVault vault = IMoolahVault(vaults[i]);
      uint256 shares = vault.balanceOf(address(this));
      if (shares > 0) {
        uint256 assets = vault.redeem(shares, vaultFeeRecipient, address(this));
        emit VaultFeeClaimed(address(vault), vault.asset(), assets, shares);
      }
    }
  }

  /// @dev claim vault fees for the given vaults.
  function claimVaultFee(address[] calldata _vaults) external onlyRole(BOT) {
    for (uint256 i = 0; i < _vaults.length; i++) {
      IMoolahVault vault = IMoolahVault(_vaults[i]);
      uint256 shares = vault.balanceOf(address(this));
      if (shares > 0) {
        uint256 assets = vault.redeem(shares, vaultFeeRecipient, address(this));
        emit VaultFeeClaimed(address(vault), vault.asset(), assets, shares);
      }
    }
  }

  /// @dev get all vaults
  function getVaults() external view returns (address[] memory) {
    address[] memory vaultsList = new address[](vaults.length);
    for (uint256 i = 0; i < vaults.length; i++) {
      vaultsList[i] = vaults[i];
    }
    return vaultsList;
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

