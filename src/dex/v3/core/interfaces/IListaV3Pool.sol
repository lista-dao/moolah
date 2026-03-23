// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import { IListaV3PoolImmutables } from "./pool/IListaV3PoolImmutables.sol";
import { IListaV3PoolState } from "./pool/IListaV3PoolState.sol";
import { IListaV3PoolDerivedState } from "./pool/IListaV3PoolDerivedState.sol";
import { IListaV3PoolActions } from "./pool/IListaV3PoolActions.sol";
import { IListaV3PoolOwnerActions } from "./pool/IListaV3PoolOwnerActions.sol";
import { IListaV3PoolErrors } from "./pool/IListaV3PoolErrors.sol";
import { IListaV3PoolEvents } from "./pool/IListaV3PoolEvents.sol";

/// @title The interface for a Lista V3 Pool
/// @notice A Lista pool facilitates swapping and automated market making between any two assets that strictly conform
/// to the ERC20 specification
/// @dev The pool interface is broken up into many smaller pieces
interface IListaV3Pool is
  IListaV3PoolImmutables,
  IListaV3PoolState,
  IListaV3PoolDerivedState,
  IListaV3PoolActions,
  IListaV3PoolOwnerActions,
  IListaV3PoolErrors,
  IListaV3PoolEvents
{}
