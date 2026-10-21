// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {TestProxy} from "../../helpers/Proxy.sol";
import {Test} from "forge-std/Test.sol";
import {CoWSwapV1Protocol} from "protocol-contracts/src/protocols/cowswap/CoWSwapV1Protocol.sol";
import {GPv2Order} from "protocol-contracts/src/libs/cow/GPv2Order.sol";
import {IGPv2Settlement} from "protocol-contracts/src/libs/cow/IGPv2Settlement.sol";
import {mainnet} from "../../../script/addresses.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {MockVaultAuth} from "./CoWSwapV1ProtocolOffchain.fork.t.sol";

interface ISafe {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function VERSION() external view returns (string memory);
    function removeOwner(address prevOwner, address owner, uint256 threshold) external;
    function changeThreshold(uint256 threshold) external;
}

interface ISafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

interface ICompatibilityFallbackHandler {
    function getMessageHashForSafe(address safe, bytes memory message) external view returns (bytes32);
}

/**
 * @dev A vault owned by a REAL Safe, deployed on a mainnet fork from the canonical Safe singleton,
 *      proxy factory and CompatibilityFallbackHandler, validating CoW orders against mainnet's REAL
 *      GPv2Settlement domain.
 *
 *      The local suite proves the clone's logic against a stand-in wallet; this proves the parts a
 *      stand-in cannot: that a Safe's `isValidSignature(bytes32,bytes)` — reached through its fallback
 *      handler, inside the staticcall CoW makes at settlement — accepts what its owners produce for the
 *      exact digests the clone asks about, under the Safe versions vaults are actually owned by.
 *
 *      Owners sign the Safe's SafeMessage hash of the CoW digest (what Safe{Wallet} signs for an
 *      off-chain message); the Safe's signature is their 65-byte signatures sorted by owner address
 *      and concatenated, and the clone receives it wrapped as abi.encode(safe, signature).
 */
abstract contract CoWSwapV1ProtocolSafeForkBase is Test {
    address internal constant SENTINEL = address(0x1);
    bytes4 internal constant MAGIC = 0x1626ba7e;
    bytes4 internal constant INVALID = 0xffffffff;

    CoWSwapV1Protocol internal cow;
    MockVaultAuth internal vault;
    ISafe internal safe;

    uint256[3] internal ownerPks = [uint256(0xA11CE), uint256(0xB0B), uint256(0xCA401)];
    uint256 internal saltNonce;

    function safeSingleton() internal pure virtual returns (address);
    function safeProxyFactory() internal pure virtual returns (address);
    function fallbackHandler() internal pure virtual returns (address);
    function expectedVersion() internal pure virtual returns (string memory);

    function setUp() public {
        vm.createSelectFork("mainnet");
        safe = _deploySafe(_owners(3), 2);
        (vault, cow) = _vaultOwnedBy(address(safe));
    }

    // ---- fixtures ----

    function _owners(uint256 n) internal view returns (address[] memory owners) {
        owners = new address[](n);
        for (uint256 i; i < n; i++) {
            owners[i] = vm.addr(ownerPks[i]);
        }
    }

    function _deploySafe(address[] memory owners, uint256 threshold) internal returns (ISafe) {
        bytes memory init = abi.encodeCall(
            ISafe.setup, (owners, threshold, address(0), "", fallbackHandler(), address(0), 0, payable(address(0)))
        );
        return ISafe(ISafeProxyFactory(safeProxyFactory()).createProxyWithNonce(safeSingleton(), init, saltNonce++));
    }

    function _vaultOwnedBy(address signer) internal returns (MockVaultAuth v, CoWSwapV1Protocol c) {
        v = new MockVaultAuth(signer, address(mainnet.WETH));
        c = CoWSwapV1Protocol(
            payable(TestProxy.deploy(
                    address(new CoWSwapV1Protocol(mainnet.COW_SETTLEMENT, mainnet.COW_VAULT_RELAYER)), address(v)
                ))
        );
    }

    function _domain() internal view returns (bytes32) {
        return IGPv2Settlement(mainnet.COW_SETTLEMENT).domainSeparator();
    }

    /// The Safe signature of `digest` by the owners at `pks`, as the Safe expects it: each owner signs
    /// the SafeMessage hash, and the 65-byte signatures go in ascending owner-address order.
    function _safeSignature(ISafe s, bytes32 digest, uint256[] memory pks) internal view returns (bytes memory sig) {
        bytes32 safeHash =
            ICompatibilityFallbackHandler(fallbackHandler()).getMessageHashForSafe(address(s), abi.encode(digest));
        _sortByAddress(pks);
        for (uint256 i; i < pks.length; i++) {
            (uint8 v, bytes32 r, bytes32 sg) = vm.sign(pks[i], safeHash);
            sig = abi.encodePacked(sig, r, sg, v);
        }
    }

    function _sortByAddress(uint256[] memory pks) internal pure {
        for (uint256 i = 1; i < pks.length; i++) {
            for (uint256 j = i; j > 0 && vm.addr(pks[j - 1]) > vm.addr(pks[j]); j--) {
                (pks[j - 1], pks[j]) = (pks[j], pks[j - 1]);
            }
        }
    }

    function _pks(uint256 a, uint256 b) internal pure returns (uint256[] memory p) {
        p = new uint256[](2);
        (p[0], p[1]) = (a, b);
    }

    function _pk(uint256 a) internal pure returns (uint256[] memory p) {
        p = new uint256[](1);
        p[0] = a;
    }

    function _wrapped(ISafe s, bytes memory sig) internal pure returns (bytes memory) {
        return abi.encode(address(s), sig);
    }

    function _order(address receiver) internal view returns (GPv2Order.Data memory) {
        return GPv2Order.Data({
            sellToken: IERC20(address(mainnet.USDC)),
            buyToken: IERC20(address(mainnet.WETH)),
            receiver: receiver,
            sellAmount: 1000e6,
            buyAmount: 1e17,
            validTo: uint32(block.timestamp + 3600),
            appData: cow.APP_DATA(),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
    }

    function _limitPayload(uint256[] memory pks) internal view returns (bytes32 hash, bytes memory payload) {
        GPv2Order.Data memory order = _order(address(vault));
        hash = GPv2Order.hash(order, _domain());
        payload = abi.encode(order, _wrapped(safe, _safeSignature(safe, hash, pks)), uint256(0));
    }

    // ---- the Safe is what the test thinks it is ----

    function test_safe_isRealAndConfigured() public view {
        assertEq(safe.VERSION(), expectedVersion());
        assertEq(safe.getThreshold(), 2);
        assertEq(safe.getOwners().length, 3);
    }

    // ---- limit orders ----

    function test_limit_twoOfThree_isSignable() public {
        (bytes32 hash, bytes memory payload) = _limitPayload(_pks(ownerPks[0], ownerPks[2]));
        uint256 before = gasleft();
        bytes4 res = cow.isValidSignature(hash, payload);
        emit log_named_uint("2-of-3 Safe limit order isValidSignature gas", before - gasleft());
        assertEq(res, MAGIC);
    }

    function test_limit_belowThreshold_rejected() public view {
        (bytes32 hash, bytes memory payload) = _limitPayload(_pk(ownerPks[0]));
        assertEq(cow.isValidSignature(hash, payload), INVALID);
    }

    function test_limit_unsortedSignatures_rejected() public view {
        GPv2Order.Data memory order = _order(address(vault));
        bytes32 hash = GPv2Order.hash(order, _domain());
        bytes memory sorted = _safeSignature(safe, hash, _pks(ownerPks[0], ownerPks[1]));
        // Swap the two 65-byte signatures: a Safe requires ascending owners.
        bytes memory swapped = new bytes(130);
        for (uint256 i; i < 65; i++) {
            swapped[i] = sorted[i + 65];
            swapped[i + 65] = sorted[i];
        }
        bytes memory payload = abi.encode(order, _wrapped(safe, swapped), uint256(0));
        assertEq(cow.isValidSignature(hash, payload), INVALID);
    }

    function test_limit_nonOwnerSignature_rejected() public view {
        (bytes32 hash, bytes memory payload) = _limitPayload(_pks(ownerPks[0], 0xDEAD));
        assertEq(cow.isValidSignature(hash, payload), INVALID);
    }

    function test_limit_unwrappedSafeSignature_rejected() public view {
        GPv2Order.Data memory order = _order(address(vault));
        bytes32 hash = GPv2Order.hash(order, _domain());
        bytes memory bare = _safeSignature(safe, hash, _pks(ownerPks[0], ownerPks[1]));
        assertEq(cow.isValidSignature(hash, abi.encode(order, bare, uint256(0))), INVALID);
    }

    function test_limit_ownerRemoved_orderStopsValidating() public {
        (bytes32 hash, bytes memory payload) = _limitPayload(_pks(ownerPks[0], ownerPks[1]));
        assertEq(cow.isValidSignature(hash, payload), MAGIC);

        address[] memory owners = safe.getOwners();
        address gone = vm.addr(ownerPks[1]);
        address prev = SENTINEL;
        for (uint256 i; owners[i] != gone; i++) {
            prev = owners[i];
        }
        vm.prank(address(safe)); // owner management is authorised by the Safe itself
        safe.removeOwner(prev, gone, 2);

        assertEq(cow.isValidSignature(hash, payload), INVALID);
    }

    function test_limit_thresholdRaised_orderStopsValidating() public {
        (bytes32 hash, bytes memory payload) = _limitPayload(_pks(ownerPks[0], ownerPks[1]));
        assertEq(cow.isValidSignature(hash, payload), MAGIC);
        vm.prank(address(safe));
        safe.changeThreshold(3);
        assertEq(cow.isValidSignature(hash, payload), INVALID);
    }

    function test_limit_oneOfOneSafe_wrappedOnly() public {
        // A 1-of-1 Safe's signature is 65 bytes like an EOA's. Bare, it recovers the owner key — not
        // the vault's signer — so only the wrapped form is accepted.
        ISafe solo = _deploySafe(_owners(1), 1);
        (MockVaultAuth soloVault, CoWSwapV1Protocol soloCow) = _vaultOwnedBy(address(solo));
        GPv2Order.Data memory order = _order(address(soloVault));
        bytes32 hash = GPv2Order.hash(order, _domain());
        bytes memory sig = _safeSignature(solo, hash, _pk(ownerPks[0]));
        assertEq(sig.length, 65);

        assertEq(soloCow.isValidSignature(hash, abi.encode(order, _wrapped(solo, sig), uint256(0))), MAGIC);
        assertEq(soloCow.isValidSignature(hash, abi.encode(order, sig, uint256(0))), INVALID);
    }

    function test_limit_signatureForAnotherSafe_rejected() public {
        // Same owners, same threshold, different Safe: the SafeMessage hash binds the Safe's address.
        ISafe twin = _deploySafe(_owners(3), 2);
        GPv2Order.Data memory order = _order(address(vault));
        bytes32 hash = GPv2Order.hash(order, _domain());
        bytes memory twinSig = _safeSignature(twin, hash, _pks(ownerPks[0], ownerPks[1]));
        assertEq(cow.isValidSignature(hash, abi.encode(order, _wrapped(safe, twinSig), uint256(0))), INVALID);
    }

    // ---- TWAP ----

    function _twap() internal view returns (CoWSwapV1Protocol.TwapOrder memory) {
        return CoWSwapV1Protocol.TwapOrder({
            sellToken: address(mainnet.USDC),
            buyToken: address(mainnet.WETH),
            sellAmountPerPart: 100e6,
            buyAmountPerPart: 1e16,
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

    function test_twap_twoOfThree_everyPartSignable() public {
        CoWSwapV1Protocol.TwapOrder memory p = _twap();
        bytes memory scheduleSig =
            _wrapped(safe, _safeSignature(safe, cow.twapDigest(p), _pks(ownerPks[1], ownerPks[2])));
        for (uint256 i; i < p.numParts; i++) {
            vm.warp(p.startTime + i * p.partDuration);
            GPv2Order.Data memory order = _twapPart(p, i, address(vault), cow);
            bytes32 hash = GPv2Order.hash(order, _domain());
            assertEq(cow.isValidSignature(hash, abi.encode(order, p, i, scheduleSig)), MAGIC);
        }
    }

    function test_twap_scheduleForOneVaultRejectedByAnother() public {
        // The same Safe owns two vaults; a schedule it signed for one must not replay on the other.
        (MockVaultAuth other, CoWSwapV1Protocol otherCow) = _vaultOwnedBy(address(safe));
        CoWSwapV1Protocol.TwapOrder memory p = _twap();
        bytes memory scheduleSig =
            _wrapped(safe, _safeSignature(safe, cow.twapDigest(p), _pks(ownerPks[0], ownerPks[1])));

        GPv2Order.Data memory order = _twapPart(p, 0, address(other), otherCow);
        bytes32 hash = GPv2Order.hash(order, _domain());
        assertEq(otherCow.isValidSignature(hash, abi.encode(order, p, uint256(0), scheduleSig)), INVALID);
    }

    // ---- cancellation ----

    function test_cancellation_twoOfThree_isSignable() public view {
        bytes[] memory uids = new bytes[](1);
        uids[0] = abi.encodePacked(keccak256("order-1"), address(vault), uint32(111));
        bytes32[] memory h = new bytes32[](1);
        h[0] = keccak256(uids[0]);
        bytes32 structHash =
            keccak256(abi.encode(keccak256("OrderCancellations(bytes[] orderUids)"), keccak256(abi.encodePacked(h))));
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", _domain(), structHash));

        bytes memory sig =
            abi.encode(uids, _wrapped(safe, _safeSignature(safe, digest, _pks(ownerPks[0], ownerPks[2]))));
        assertEq(cow.isValidSignature(digest, sig), MAGIC);
    }
}

/// Safe v1.3.0, canonical deployment (the version most existing Safes run).
contract TestCoWSwapV1ProtocolSafeV130Fork is CoWSwapV1ProtocolSafeForkBase {
    function safeSingleton() internal pure override returns (address) {
        return 0xd9Db270c1B5E3Bd161E8c8503c55cEABeE709552;
    }

    function safeProxyFactory() internal pure override returns (address) {
        return 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2;
    }

    function fallbackHandler() internal pure override returns (address) {
        return 0xf48f2B2d2a534e402487b3ee7C18c33Aec0Fe5e4;
    }

    function expectedVersion() internal pure override returns (string memory) {
        return "1.3.0";
    }
}

/// Safe v1.4.1, canonical deployment (what Safe{Wallet} creates today).
contract TestCoWSwapV1ProtocolSafeV141Fork is CoWSwapV1ProtocolSafeForkBase {
    function safeSingleton() internal pure override returns (address) {
        return 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    }

    function safeProxyFactory() internal pure override returns (address) {
        return 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    }

    function fallbackHandler() internal pure override returns (address) {
        return 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;
    }

    function expectedVersion() internal pure override returns (string memory) {
        return "1.4.1";
    }
}
