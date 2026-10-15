// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MarketParams, Id, IMoolah } from "moolah/interfaces/IMoolah.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { IProvider } from "../../provider/interfaces/IProvider.sol";
import { IV3Provider } from "../../provider/interfaces/IV3Provider.sol";
import { IV3ProviderOracle } from "../../provider/interfaces/IV3ProviderOracle.sol";
import { IV3DexAdapter } from "../../provider/interfaces/IV3DexAdapter.sol";
import { IV3Liquidator } from "../../liquidator/IV3Liquidator.sol";
import { ILiquidationVault } from "../../liquidator/ILiquidationVault.sol";

/// @dev `params.collateralToken` is the V3Provider share, `params.oracle` its V3ProviderOracle.
struct V3MarketParams {
  MarketParams params;
  address[] extraLiquidators;
  address[] supplyWhitelist;
}

/// @dev Getters the V3 share and its oracle expose beyond their declared interfaces.
interface IV3Binding {
  function MOOLAH() external view returns (address);

  function resilientOracle() external view returns (address);
}

/**
 * @title V3MarketLib
 * @notice MarketFactory's V3 LP share market wiring, kept out of the factory for EIP-170. Linked and
 *         DELEGATECALLed, so every call runs as the factory and writes the factory's storage.
 */
library V3MarketLib {
  using MarketParamsLib for MarketParams;

  address private constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  struct Deps {
    IMoolah moolah;
    address liquidator;
    address publicLiquidator;
    address brokerLiquidator;
    ILiquidationVault liquidationVault;
    IV3Liquidator v3Liquidator;
  }

  error V3LiquidatorNotSet();
  error InvalidV3Liquidator();
  error InvalidV3Share();
  error InvalidV3Oracle();
  error V3DepositUnguarded();
  error InvalidLiquidator();

  event V3ProviderRegistered(address indexed share, address indexed oracle);

  /// @dev The V3-specific part of a V3 market: pin, per-provider wiring, the market, its provider, its
  ///      liquidation whitelist and the V3Liquidator side. The factory adds the loan-token wiring.
  function createV3Market(
    mapping(address => address) storage v3OracleOf,
    Deps memory d,
    V3MarketParams calldata m
  ) external returns (Id id) {
    IV3Liquidator v3Liq = d.v3Liquidator;
    require(address(v3Liq) != address(0), V3LiquidatorNotSet());
    // the legs are whitelisted on the factory's vault, so the liquidator must reflow into it (or nowhere)
    address fund = v3Liq.fundSource();
    require(fund == address(0) || fund == address(d.liquidationVault), InvalidV3Liquidator());

    address share = m.params.collateralToken;
    address oracle = m.params.oracle;
    address pinned = v3OracleOf[share];
    if (pinned == address(0)) {
      validate(address(d.moolah), share, oracle);
      v3OracleOf[share] = oracle;
      emit V3ProviderRegistered(share, oracle);
    } else {
      require(oracle == pinned, InvalidV3Oracle());
    }
    // set on every market, like a smart provider: a replacement liquidator or vault gets wired, and a
    // switch MANAGER turned off is turned back on
    _wireProvider(d, share);
    // deposits open with the market: require the seed or the deposit whitelist first
    require(IERC20(share).totalSupply() > 0 || IV3Provider(share).depositWhitelistEnabled(), V3DepositUnguarded());

    MarketParams memory param = m.params;
    id = param.id();
    d.moolah.createMarket(param);
    // the share is its own provider
    d.moolah.setProvider(id, share, true);

    // liquidation whitelist: V3Liquidator plus extras; the generic liquidators cannot move the share
    address[] calldata extras = m.extraLiquidators;
    address[][] memory whitelist = new address[][](1);
    whitelist[0] = new address[](extras.length + 1);
    whitelist[0][0] = address(v3Liq);
    for (uint256 i = 0; i < extras.length; i++) {
      address extra = extras[i];
      require(
        extra != address(0) &&
          extra != d.liquidator &&
          extra != d.publicLiquidator &&
          extra != d.brokerLiquidator &&
          extra != address(v3Liq),
        InvalidLiquidator()
      );
      whitelist[0][i + 1] = extra;
    }
    Id[] memory ids = new Id[](1);
    ids[0] = id;
    d.moolah.batchToggleLiquidationWhitelist(ids, whitelist, true);
    v3Liq.setMarketWhitelist(Id.unwrap(id), true);
    // the share itself is never whitelisted
    _whitelist(d, param.loanToken, false);
  }

  /// @dev Bind share, adapter and oracle. Any oracle proxy can claim a share, so the oracle
  ///      must also use the share's own resilient oracle.
  function validate(address moolah, address share, address oracle) public view {
    require(
      IProvider(share).TOKEN() == share &&
        IV3Binding(share).MOOLAH() == moolah &&
        IV3DexAdapter(IV3Provider(share).ADAPTER()).provider() == share,
      InvalidV3Share()
    );
    require(
      IV3ProviderOracle(oracle).PROVIDER_SHARE() == share &&
        IV3Binding(oracle).resilientOracle() == IV3Provider(share).resilientOracle(),
      InvalidV3Oracle()
    );
  }

  /// @dev Per-provider switches: flash-loan blacklist, V3Liquidator provider whitelist and the legs.
  function _wireProvider(Deps memory d, address share) private {
    if (!d.moolah.flashLoanTokenBlacklist(share)) {
      d.moolah.setFlashLoanTokenBlacklist(share, true);
    }
    if (!d.v3Liquidator.v3Providers(share)) {
      d.v3Liquidator.setV3ProviderWhitelist(share, true);
    }
    // redeemed legs are sold by the V3Liquidator or reflowed to the vault; the wrapped-native leg exits as native
    address token0 = IV3Provider(share).TOKEN0();
    address token1 = IV3Provider(share).TOKEN1();
    address wrappedNative = IV3Provider(share).WRAPPED_NATIVE();
    _whitelist(d, token0, true);
    _whitelist(d, token1, true);
    if (token0 == wrappedNative || token1 == wrappedNative) {
      _whitelist(d, BNB_ADDRESS, true);
    }
  }

  /// @dev Whitelist `token` on the V3Liquidator and, when `includeVault`, the LiquidationVault. Both setters
  ///      reject a no-op, so read first.
  function _whitelist(Deps memory d, address token, bool includeVault) private {
    if (!d.v3Liquidator.tokenWhitelist(token)) {
      d.v3Liquidator.setTokenWhitelist(token, true);
    }
    if (includeVault && address(d.liquidationVault) != address(0) && !d.liquidationVault.tokenWhitelist(token)) {
      d.liquidationVault.setTokenWhitelist(token, true);
    }
  }
}
