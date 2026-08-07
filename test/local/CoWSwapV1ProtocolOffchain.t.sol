// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {CoWSwapV1Protocol} from "../../src/protocols/cowswap/CoWSwapV1Protocol.sol";
import {IBittyVaultOffchainAuth} from "../../src/interfaces/IBittyVaultOffchainAuth.sol";
import {GPv2Order} from "../../src/libs/cow/GPv2Order.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract MockSettlement {
    bytes32 public immutable domainSeparator = keccak256("bitty-test-cow-domain");

    function filledAmount(bytes calldata) external pure returns (uint256) {
        return 0;
    }
}

// Stands in for the vault: owns the clone and answers the off-chain auth callback. A single
// full-access manager is authorized; every other signer is rejected.
contract MockVaultAuth is IBittyVaultOffchainAuth {
    address public manager;
    address public allowedBuyToken;

    constructor(address manager_, address allowedBuyToken_) {
        manager = manager_;
        allowedBuyToken = allowedBuyToken_;
    }

    function isOffchainOrderAuthorized(address signer, address, address buyToken, uint256)
        external
        view
        returns (bool)
    {
        return signer == manager && buyToken == allowedBuyToken;
    }

    function isOffchainManager(address signer) external view returns (bool) {
        return signer == manager;
    }
}

contract CoWSwapV1ProtocolOffchainTest is Test {
    CoWSwapV1Protocol internal cow;
    MockSettlement internal settlement;
    MockVaultAuth internal vault;

    uint256 internal managerPk = 0xA11CE;
    address internal manager;

    address internal constant SELL = address(0x1111);
    address internal constant BUY = address(0x2222);
    address internal constant RELAYER = address(0x3333);

    function setUp() public {
        manager = vm.addr(managerPk);
        settlement = new MockSettlement();
        vault = new MockVaultAuth(manager, BUY);
        cow = new CoWSwapV1Protocol(address(settlement), RELAYER);
        cow.initialize(address(vault)); // owner() == vault
        vm.warp(1_000_000);
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

    function _sign(uint256 pk, bytes32 hash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, hash);
        return abi.encodePacked(r, s, v);
    }

    function _payload(GPv2Order.Data memory order, uint256 pk) internal view returns (bytes32 hash, bytes memory sig) {
        hash = GPv2Order.hash(order, settlement.domainSeparator());
        sig = abi.encode(order, _sign(pk, hash), uint256(0));
    }

    function test_validOffchainOrder_isSignable() public view {
        (bytes32 hash, bytes memory sig) = _payload(_order(), managerPk);
        assertEq(cow.isValidSignature(hash, sig), bytes4(0x1626ba7e));
    }

    function test_unauthorizedSigner_rejected() public {
        (bytes32 hash, bytes memory sig) = _payload(_order(), 0xB0B); // not the manager
        assertEq(cow.isValidSignature(hash, sig), bytes4(0xffffffff));
    }

    function test_tamperedOrder_hashMismatch_rejected() public view {
        GPv2Order.Data memory order = _order();
        (bytes32 hash, bytes memory sig) = _payload(order, managerPk);
        // Re-encode the payload with a mutated order but the original (signed) hash.
        order.buyAmount = 1; // steal: accept far less
        bytes memory tampered = abi.encode(order, _sign(managerPk, hash), uint256(0));
        assertEq(cow.isValidSignature(hash, tampered), bytes4(0xffffffff));
    }

    function test_wrongAppData_rejected() public {
        GPv2Order.Data memory order = _order();
        order.appData = bytes32(uint256(1)); // fee-free doc
        (bytes32 hash, bytes memory sig) = _payload(order, managerPk);
        assertEq(cow.isValidSignature(hash, sig), bytes4(0xffffffff));
    }

    function test_wrongReceiver_rejected() public {
        GPv2Order.Data memory order = _order();
        order.receiver = manager; // proceeds to the manager, not the vault
        (bytes32 hash, bytes memory sig) = _payload(order, managerPk);
        assertEq(cow.isValidSignature(hash, sig), bytes4(0xffffffff));
    }

    function test_expiredOrder_rejected() public {
        GPv2Order.Data memory order = _order();
        (bytes32 hash, bytes memory sig) = _payload(order, managerPk);
        vm.warp(order.validTo + 1);
        assertEq(cow.isValidSignature(hash, sig), bytes4(0xffffffff));
    }

    function test_disallowedBuyToken_rejected() public {
        GPv2Order.Data memory order = _order();
        order.buyToken = IERC20(address(0x9999)); // not allow-listed by the vault
        (bytes32 hash, bytes memory sig) = _payload(order, managerPk);
        assertEq(cow.isValidSignature(hash, sig), bytes4(0xffffffff));
    }

    function test_emptySignature_notSignable() public view {
        (bytes32 hash,) = _payload(_order(), managerPk);
        assertEq(cow.isValidSignature(hash, ""), bytes4(0xffffffff));
    }

    function test_garbageSignature_doesNotRevert() public view {
        assertEq(cow.isValidSignature(keccak256("x"), hex"deadbeef"), bytes4(0xffffffff));
    }

    // ---- TWAP: ONE manager signature over the whole schedule authorizes every part ----

    function _twap() internal view returns (CoWSwapV1Protocol.TwapOrder memory p) {
        p = CoWSwapV1Protocol.TwapOrder({
            sellToken: SELL,
            buyToken: BUY,
            sellAmountPerPart: 1e17,
            buyAmountPerPart: 200e6,
            startTime: block.timestamp,
            partDuration: 600,
            numParts: 5
        });
    }

    // The order the clone must reconstruct for part `i` — every field is derived from the schedule.
    function _twapPartOrder(CoWSwapV1Protocol.TwapOrder memory p, uint256 i)
        internal
        view
        returns (GPv2Order.Data memory order)
    {
        order = GPv2Order.Data({
            sellToken: IERC20(p.sellToken),
            buyToken: IERC20(p.buyToken),
            receiver: address(vault),
            sellAmount: p.sellAmountPerPart,
            buyAmount: p.buyAmountPerPart,
            validTo: uint32(p.startTime + (i + 1) * p.partDuration),
            appData: cow.twapAppData(p.startTime),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
    }

    function _twapPayload(CoWSwapV1Protocol.TwapOrder memory p, uint256 i, uint256 pk)
        internal
        view
        returns (bytes32 hash, bytes memory sig)
    {
        GPv2Order.Data memory order = _twapPartOrder(p, i);
        hash = GPv2Order.hash(order, settlement.domainSeparator());
        sig = abi.encode(order, p, i, _sign(pk, cow.twapDigest(p)));
    }

    function test_twap_everyPartSignableFromOneSignature() public view {
        CoWSwapV1Protocol.TwapOrder memory p = _twap();
        for (uint256 i = 0; i < p.numParts; i++) {
            (bytes32 hash, bytes memory sig) = _twapPayload(p, i, managerPk);
            assertEq(cow.isValidSignature(hash, sig), bytes4(0x1626ba7e));
        }
    }

    function test_twap_wrongSigner_rejected() public {
        CoWSwapV1Protocol.TwapOrder memory p = _twap();
        (bytes32 hash, bytes memory sig) = _twapPayload(p, 1, 0xB0B);
        assertEq(cow.isValidSignature(hash, sig), bytes4(0xffffffff));
    }

    function test_twap_indexOutOfRange_rejected() public view {
        CoWSwapV1Protocol.TwapOrder memory p = _twap();
        (bytes32 hash, bytes memory sig) = _twapPayload(p, p.numParts, managerPk);
        assertEq(cow.isValidSignature(hash, sig), bytes4(0xffffffff));
    }

    function test_twap_tamperedValidTo_rejected() public view {
        CoWSwapV1Protocol.TwapOrder memory p = _twap();
        GPv2Order.Data memory order = _twapPartOrder(p, 1);
        order.validTo = uint32(p.startTime + 999); // not the slot boundary
        bytes32 hash = GPv2Order.hash(order, settlement.domainSeparator());
        bytes memory sig = abi.encode(order, p, uint256(1), _sign(managerPk, cow.twapDigest(p)));
        assertEq(cow.isValidSignature(hash, sig), bytes4(0xffffffff));
    }

    // Changing the signed schedule after signing breaks the single-signature binding.
    function test_twap_tamperedScheduleAfterSigning_rejected() public view {
        CoWSwapV1Protocol.TwapOrder memory p = _twap();
        GPv2Order.Data memory order = _twapPartOrder(p, 1);
        bytes32 hash = GPv2Order.hash(order, settlement.domainSeparator());
        bytes memory managerSig = _sign(managerPk, cow.twapDigest(p));
        p.numParts = 50; // digest of the presented params no longer matches the signature
        bytes memory sig = abi.encode(order, p, uint256(1), managerSig);
        assertEq(cow.isValidSignature(hash, sig), bytes4(0xffffffff));
    }

    // ---- cancellation ----

    function _cancellationDigest(bytes[] memory uids) internal view returns (bytes32) {
        bytes32 typeHash = keccak256("OrderCancellations(bytes[] orderUids)");
        bytes32[] memory h = new bytes32[](uids.length);
        for (uint256 i = 0; i < uids.length; i++) {
            h[i] = keccak256(uids[i]);
        }
        bytes32 structHash = keccak256(abi.encode(typeHash, keccak256(abi.encodePacked(h))));
        return keccak256(abi.encodePacked(hex"1901", settlement.domainSeparator(), structHash));
    }

    function _cancelUids() internal view returns (bytes[] memory uids) {
        uids = new bytes[](2);
        uids[0] = abi.encodePacked(keccak256("order-1"), address(vault), uint32(111));
        uids[1] = abi.encodePacked(keccak256("order-2"), address(vault), uint32(222));
    }

    function test_validCancellation_isSignable() public view {
        bytes[] memory uids = _cancelUids();
        bytes32 digest = _cancellationDigest(uids);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(managerPk, digest);
        bytes memory sig = abi.encode(uids, abi.encodePacked(r, s, v));
        assertEq(cow.isValidSignature(digest, sig), bytes4(0x1626ba7e));
    }

    function test_cancellation_wrongSigner_rejected() public view {
        bytes[] memory uids = _cancelUids();
        bytes32 digest = _cancellationDigest(uids);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xB0B, digest);
        bytes memory sig = abi.encode(uids, abi.encodePacked(r, s, v));
        assertEq(cow.isValidSignature(digest, sig), bytes4(0xffffffff));
    }

    function test_cancellation_tamperedUids_rejected() public view {
        bytes[] memory uids = _cancelUids();
        bytes32 digest = _cancellationDigest(uids);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(managerPk, digest);
        uids[0] = abi.encodePacked(keccak256("order-X"), address(vault), uint32(111)); // swap after signing
        bytes memory sig = abi.encode(uids, abi.encodePacked(r, s, v));
        assertEq(cow.isValidSignature(digest, sig), bytes4(0xffffffff));
    }
}
