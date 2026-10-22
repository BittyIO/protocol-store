// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {CoWSwapV1Protocol} from "../../src/protocols/cowswap/CoWSwapV1Protocol.sol";
import {IBittyVaultOffchainAuth} from "../../src/interfaces/IBittyVaultOffchainAuth.sol";
import {GPv2Order} from "../../src/libs/cow/GPv2Order.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BittyV1ProtocolBase} from "../../src/BittyV1ProtocolBase.sol";
import {MockSettlement, MockVaultAuth} from "./CoWSwapV1ProtocolOffchain.t.sol";

// Behaves like a 1-of-1 Safe for ERC-1271: its single owner signs a hash WRAPPED in the wallet's own
// domain (as a Safe signs SafeMessage), so the 65-byte signature recovers the OWNER key, never the
// wallet. `setOwner` stands in for a Safe rotating owners after an order was signed.
contract MockSafe {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function setOwner(address owner_) external {
        owner = owner_;
    }

    function messageHash(bytes32 hash) public view returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", keccak256(abi.encode(address(this))), hash));
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(messageHash(hash), signature);
        return err == ECDSA.RecoverError.NoError && signer == owner ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

// A contract signer that misbehaves: reverts, so the clone must treat it as not signable, not revert.
contract RevertingWallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        revert("nope");
    }
}

/// A vault owned by a contract wallet (a Safe) places, schedules and cancels CoW orders through the
/// wrapped abi.encode(signer, signature) form. EOA behaviour is covered, unchanged, in
/// CoWSwapV1ProtocolOffchain.t.sol.
contract CoWSwapV1ProtocolContractSignerTest is Test {
    CoWSwapV1Protocol internal cow;
    MockSettlement internal settlement;
    MockVaultAuth internal vault;
    MockSafe internal safe;

    uint256 internal safeOwnerPk = 0x5AFE;
    uint256 internal eoaPk = 0xA11CE;

    address internal constant SELL = address(0x1111);
    address internal constant BUY = address(0x2222);
    address internal constant RELAYER = address(0x3333);

    bytes4 internal constant MAGIC = 0x1626ba7e;
    bytes4 internal constant INVALID = 0xffffffff;

    function setUp() public {
        settlement = new MockSettlement();
        safe = new MockSafe(vm.addr(safeOwnerPk));
        vault = new MockVaultAuth(address(safe), BUY); // the Safe is the vault's authorised signer
        cow = _cloneFor(address(vault));
        vm.warp(1_000_000);
    }

    function _cloneFor(address host) internal returns (CoWSwapV1Protocol) {
        return CoWSwapV1Protocol(
            payable(new ERC1967Proxy(
                    address(new CoWSwapV1Protocol(address(settlement), RELAYER)),
                    abi.encodeCall(BittyV1ProtocolBase.initialize, (host))
                ))
        );
    }

    function _sign(uint256 pk, bytes32 hash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, hash);
        return abi.encodePacked(r, s, v);
    }

    /// What the Safe's owner produces for `hash`: 65 bytes over the Safe-wrapped digest.
    function _safeSig(bytes32 hash) internal view returns (bytes memory) {
        return _sign(safeOwnerPk, safe.messageHash(hash));
    }

    function _wrapped(address signer, bytes memory sig) internal pure returns (bytes memory) {
        return abi.encode(signer, sig);
    }

    function _order() internal view returns (GPv2Order.Data memory) {
        return GPv2Order.Data({
            sellToken: IERC20(SELL),
            buyToken: IERC20(BUY),
            receiver: address(vault),
            sellAmount: 1e18,
            buyAmount: 2000e6,
            validTo: uint32(block.timestamp + 3600),
            appData: cow.APP_DATA(),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
    }

    function _orderHash() internal view returns (bytes32) {
        return GPv2Order.hash(_order(), settlement.domainSeparator());
    }

    // ---- limit orders ----

    function test_limit_safeSigner_isSignable() public view {
        bytes32 hash = _orderHash();
        bytes memory sig = abi.encode(_order(), _wrapped(address(safe), _safeSig(hash)), uint256(0));
        assertEq(cow.isValidSignature(hash, sig), MAGIC);
    }

    function test_limit_unwrappedSafeSig_rejected() public view {
        // A 1-of-1 Safe signature is itself 65 bytes: presented bare it recovers the Safe's OWNER key,
        // who is not the vault's signer.
        bytes32 hash = _orderHash();
        bytes memory sig = abi.encode(_order(), _safeSig(hash), uint256(0));
        assertEq(cow.isValidSignature(hash, sig), INVALID);
    }

    function test_limit_wrappedWrongKey_rejected() public view {
        bytes32 hash = _orderHash();
        bytes memory bad = _sign(0xB0B, safe.messageHash(hash));
        bytes memory sig = abi.encode(_order(), _wrapped(address(safe), bad), uint256(0));
        assertEq(cow.isValidSignature(hash, sig), INVALID);
    }

    function test_limit_wrappedEoa_rejected() public {
        // The wrapped form is ERC-1271 only: an EOA asserted there, even with a valid ECDSA signature
        // and even when it IS the vault's signer, is not a second encoding of the bare form.
        address eoa = vm.addr(eoaPk);
        MockVaultAuth eoaVault = new MockVaultAuth(eoa, BUY);
        CoWSwapV1Protocol eoaCow = _cloneFor(address(eoaVault));
        GPv2Order.Data memory order = _order();
        order.receiver = address(eoaVault);
        bytes32 hash = GPv2Order.hash(order, settlement.domainSeparator());

        bytes memory sig = abi.encode(order, _wrapped(eoa, _sign(eoaPk, hash)), uint256(0));
        assertEq(eoaCow.isValidSignature(hash, sig), INVALID);
        // ...while the bare form still works for it.
        assertEq(eoaCow.isValidSignature(hash, abi.encode(order, _sign(eoaPk, hash), uint256(0))), MAGIC);
    }

    function test_limit_safeRotatesOwner_orderStopsValidating() public {
        bytes32 hash = _orderHash();
        bytes memory sig = abi.encode(_order(), _wrapped(address(safe), _safeSig(hash)), uint256(0));
        assertEq(cow.isValidSignature(hash, sig), MAGIC);
        safe.setOwner(address(0xdead));
        assertEq(cow.isValidSignature(hash, sig), INVALID);
    }

    function test_limit_revertingWallet_notSignable() public {
        RevertingWallet w = new RevertingWallet();
        MockVaultAuth wVault = new MockVaultAuth(address(w), BUY);
        CoWSwapV1Protocol wCow = _cloneFor(address(wVault));
        GPv2Order.Data memory order = _order();
        order.receiver = address(wVault);
        bytes32 hash = GPv2Order.hash(order, settlement.domainSeparator());
        bytes memory sig = abi.encode(order, _wrapped(address(w), hex"1234"), uint256(0));
        assertEq(wCow.isValidSignature(hash, sig), INVALID);
    }

    function test_limit_signerWithNoCode_rejected() public view {
        bytes32 hash = _orderHash();
        bytes memory sig = abi.encode(_order(), _wrapped(address(0xC0FFEE), _safeSig(hash)), uint256(0));
        assertEq(cow.isValidSignature(hash, sig), INVALID);
    }

    // ---- TWAP ----

    function _twap() internal view returns (CoWSwapV1Protocol.TwapOrder memory) {
        return CoWSwapV1Protocol.TwapOrder({
            sellToken: SELL,
            buyToken: BUY,
            sellAmountPerPart: 1e17,
            buyAmountPerPart: 200e6,
            startTime: block.timestamp,
            partDuration: 600,
            numParts: 3
        });
    }

    function _twapPart(CoWSwapV1Protocol.TwapOrder memory p, uint256 i, address receiver, CoWSwapV1Protocol c)
        internal
        view
        returns (GPv2Order.Data memory)
    {
        return GPv2Order.Data({
            sellToken: IERC20(p.sellToken),
            buyToken: IERC20(p.buyToken),
            receiver: receiver,
            sellAmount: p.sellAmountPerPart,
            buyAmount: p.buyAmountPerPart,
            validTo: uint32(p.startTime + (i + 1) * p.partDuration),
            appData: c.twapAppData(p.startTime),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
    }

    function test_twap_safeSigner_everyPartSignable() public {
        CoWSwapV1Protocol.TwapOrder memory p = _twap();
        bytes memory scheduleSig = _wrapped(address(safe), _safeSig(cow.twapDigest(p)));
        for (uint256 i = 0; i < p.numParts; i++) {
            vm.warp(p.startTime + i * p.partDuration);
            GPv2Order.Data memory order = _twapPart(p, i, address(vault), cow);
            bytes32 hash = GPv2Order.hash(order, settlement.domainSeparator());
            assertEq(cow.isValidSignature(hash, abi.encode(order, p, i, scheduleSig)), MAGIC);
        }
    }

    function test_twap_safeScheduleForOneVaultRejectedByAnother() public {
        // The same Safe is the signer on two vaults; a schedule it signed for one must not replay on the other.
        MockVaultAuth other = new MockVaultAuth(address(safe), BUY);
        CoWSwapV1Protocol otherCow = _cloneFor(address(other));
        CoWSwapV1Protocol.TwapOrder memory p = _twap();
        bytes memory scheduleSig = _wrapped(address(safe), _safeSig(cow.twapDigest(p))); // signed for `vault`

        GPv2Order.Data memory order = _twapPart(p, 0, address(other), otherCow);
        bytes32 hash = GPv2Order.hash(order, settlement.domainSeparator());
        assertEq(otherCow.isValidSignature(hash, abi.encode(order, p, uint256(0), scheduleSig)), INVALID);
    }

    // ---- cancellation ----

    function _cancellationDigest(bytes[] memory uids) internal view returns (bytes32) {
        bytes32[] memory h = new bytes32[](uids.length);
        for (uint256 i = 0; i < uids.length; i++) {
            h[i] = keccak256(uids[i]);
        }
        bytes32 structHash =
            keccak256(abi.encode(keccak256("OrderCancellations(bytes[] orderUids)"), keccak256(abi.encodePacked(h))));
        return keccak256(abi.encodePacked(hex"1901", settlement.domainSeparator(), structHash));
    }

    function test_cancellation_safeSigner_isSignable() public view {
        bytes[] memory uids = new bytes[](1);
        uids[0] = abi.encodePacked(keccak256("order-1"), address(vault), uint32(111));
        bytes32 digest = _cancellationDigest(uids);
        bytes memory sig = abi.encode(uids, _wrapped(address(safe), _safeSig(digest)));
        assertEq(cow.isValidSignature(digest, sig), MAGIC);
    }

    function test_cancellation_unwrappedSafeSig_rejected() public view {
        bytes[] memory uids = new bytes[](1);
        uids[0] = abi.encodePacked(keccak256("order-1"), address(vault), uint32(111));
        bytes32 digest = _cancellationDigest(uids);
        assertEq(cow.isValidSignature(digest, abi.encode(uids, _safeSig(digest))), INVALID);
    }

    function test_version_is_1_0_3() public view {
        assertEq(cow.protocolVersion(), 1_000_003);
        assertEq(cow.versionName(), "1.0.3");
    }
}
