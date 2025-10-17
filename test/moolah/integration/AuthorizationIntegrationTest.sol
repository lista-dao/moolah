// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseTest.sol";

contract AuthorizationIntegrationTest is BaseTest {
  function testSetAuthorization(address addressFuzz) public {
    vm.assume(addressFuzz != address(this));

    moolah.setAuthorization(addressFuzz, true);

    assertTrue(moolah.isAuthorized(address(this), addressFuzz));

    moolah.setAuthorization(addressFuzz, false);

    assertFalse(moolah.isAuthorized(address(this), addressFuzz));
  }

  function testAlreadySet(address addressFuzz) public {
    vm.expectRevert(bytes(ErrorsLib.ALREADY_SET));
    moolah.setAuthorization(addressFuzz, false);

    moolah.setAuthorization(addressFuzz, true);

    vm.expectRevert(bytes(ErrorsLib.ALREADY_SET));
    moolah.setAuthorization(addressFuzz, true);
  }

  function testSetAuthorizationWithSignatureDeadlineOutdated(
    Authorization memory authorization,
    uint256 privateKey,
    uint256 blocks
  ) public {
    authorization.isAuthorized = true;
    blocks = _boundBlocks(blocks);
    authorization.deadline = block.timestamp - 1;

    // Private key must be less than the secp256k1 curve order.
    privateKey = bound(privateKey, 1, type(uint32).max);
    authorization.nonce = 0;
    authorization.authorizer = vm.addr(privateKey);

    Signature memory sig;
    bytes32 digest = SigUtils.getTypedDataHash(moolah.domainSeparator(), authorization);
    (sig.v, sig.r, sig.s) = vm.sign(privateKey, digest);

    _forward(blocks);

    vm.expectRevert(bytes(ErrorsLib.SIGNATURE_EXPIRED));
    moolah.setAuthorizationWithSig(authorization, sig);
  }

  function testAuthorizationWithSigWrongPK(Authorization memory authorization, uint256 privateKey) public {
    authorization.isAuthorized = true;
    authorization.deadline = bound(authorization.deadline, block.timestamp, type(uint256).max);

    // Private key must be less than the secp256k1 curve order.
    privateKey = bound(privateKey, 1, type(uint32).max);
    authorization.nonce = 0;

    Signature memory sig;
    bytes32 digest = SigUtils.getTypedDataHash(moolah.domainSeparator(), authorization);
    (sig.v, sig.r, sig.s) = vm.sign(privateKey, digest);

    vm.expectRevert(bytes(ErrorsLib.INVALID_SIGNATURE));
    moolah.setAuthorizationWithSig(authorization, sig);
  }

  function testAuthorizationWithSigWrongNonce(Authorization memory authorization, uint256 privateKey) public {
    authorization.isAuthorized = true;
    authorization.deadline = bound(authorization.deadline, block.timestamp, type(uint256).max);
    authorization.nonce = bound(authorization.nonce, 1, type(uint256).max);

    // Private key must be less than the secp256k1 curve order.
    privateKey = bound(privateKey, 1, type(uint32).max);
    authorization.authorizer = vm.addr(privateKey);

    Signature memory sig;
    bytes32 digest = SigUtils.getTypedDataHash(moolah.domainSeparator(), authorization);
    (sig.v, sig.r, sig.s) = vm.sign(privateKey, digest);

    vm.expectRevert(bytes(ErrorsLib.INVALID_NONCE));
    moolah.setAuthorizationWithSig(authorization, sig);
  }

  function testAuthorizationWithSig(Authorization memory authorization, uint256 privateKey) public {
    authorization.isAuthorized = true;
    authorization.deadline = bound(authorization.deadline, block.timestamp, type(uint256).max);

    // Private key must be less than the secp256k1 curve order.
    privateKey = bound(privateKey, 1, type(uint32).max);
    authorization.nonce = 0;
    authorization.authorizer = vm.addr(privateKey);

    Signature memory sig;
    bytes32 digest = SigUtils.getTypedDataHash(moolah.domainSeparator(), authorization);
    (sig.v, sig.r, sig.s) = vm.sign(privateKey, digest);

    moolah.setAuthorizationWithSig(authorization, sig);

    assertEq(moolah.isAuthorized(authorization.authorizer, authorization.authorized), true);
    assertEq(moolah.nonce(authorization.authorizer), 1);
  }

  function testAuthorizationFailsWithReusedSig(Authorization memory authorization, uint256 privateKey) public {
    authorization.isAuthorized = true;
    authorization.deadline = bound(authorization.deadline, block.timestamp, type(uint256).max);

    // Private key must be less than the secp256k1 curve order.
    privateKey = bound(privateKey, 1, type(uint32).max);
    authorization.nonce = 0;
    authorization.authorizer = vm.addr(privateKey);

    Signature memory sig;
    bytes32 digest = SigUtils.getTypedDataHash(moolah.domainSeparator(), authorization);
    (sig.v, sig.r, sig.s) = vm.sign(privateKey, digest);

    moolah.setAuthorizationWithSig(authorization, sig);

    authorization.isAuthorized = false;
    vm.expectRevert(bytes(ErrorsLib.INVALID_NONCE));
    moolah.setAuthorizationWithSig(authorization, sig);
  }
}
