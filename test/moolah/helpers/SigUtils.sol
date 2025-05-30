// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AUTHORIZATION_TYPEHASH } from "moolah/libraries/ConstantsLib.sol";

import { Authorization } from "moolah/interfaces/IMoolah.sol";

library SigUtils {
  /// @dev Computes the hash of the EIP-712 encoded data.
  function getTypedDataHash(bytes32 domainSeparator, Authorization memory authorization) public pure returns (bytes32) {
    return keccak256(bytes.concat("\x19\x01", domainSeparator, hashStruct(authorization)));
  }

  function hashStruct(Authorization memory authorization) internal pure returns (bytes32) {
    return
      keccak256(
        abi.encode(
          AUTHORIZATION_TYPEHASH,
          authorization.authorizer,
          authorization.authorized,
          authorization.isAuthorized,
          authorization.nonce,
          authorization.deadline
        )
      );
  }
}
