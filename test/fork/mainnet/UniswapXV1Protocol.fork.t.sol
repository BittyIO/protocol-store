// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {UniswapXV1Protocol} from "protocol-contracts/src/protocols/uniswapx/UniswapXV1Protocol.sol";
import {IBittyV1IntentProtocol} from "protocol-contracts/src/interfaces/IBittyV1IntentProtocol.sol";
import {IPermit2} from "protocol-contracts/src/libs/uniswapx/UniswapX.sol";
import {mainnet} from "../../../script/addresses.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";

contract TestUniswapXV1ProtocolFork is Test {
    UniswapXV1Protocol public protocol;

    address constant VAULT = address(0x1234567890123456789012345678901234567890);

    function setUp() public {
        vm.createSelectFork("mainnet");
        protocol = new UniswapXV1Protocol(mainnet.PERMIT2, mainnet.UNISWAPX_REACTOR);
        protocol.initialize(VAULT);
    }

    function _limitData(bool isSell) internal view returns (bytes memory) {
        return abi.encode(
            address(mainnet.USDC),
            uint256(1000e6),
            address(mainnet.WETH),
            uint256(3e17),
            uint32(block.timestamp + 3600),
            isSell
        );
    }

    function _buildTwapData(uint256 n, uint256 partDuration, uint256 span) internal view returns (bytes memory) {
        return abi.encode(
            address(mainnet.USDC), uint256(1000e6) * n, address(mainnet.WETH), uint256(1e14), n, partDuration, span
        );
    }

    // ============ Setup / interface conformance ============

    function test_Initialize() public view {
        assertEq(protocol.owner(), VAULT);
        assertEq(address(protocol.permit2()), mainnet.PERMIT2);
        assertEq(protocol.reactor(), mainnet.UNISWAPX_REACTOR);
    }

    /**
     * @dev The whole point: the vault drives intent protocols ONLY through IBittyV1IntentProtocol.
     *      This clones the impl and calls it purely through the interface (initialize → build →
     *      execute registerCalldata → isValidSignature), exactly as AssetManagerLogic does — with no
     *      reference to the concrete UniswapXV1Protocol type. If this passes, the vault needs no change
     *      to support UniswapX.
     */
    function test_VaultAgnostic_DriveThroughInterfaceOnly() public {
        // 1. Vault clones the protocol impl and initializes it as owner (Clones + initialize()).
        address clone = Clones.clone(address(protocol));
        IBittyV1IntentProtocol(clone).initialize(VAULT);

        // 2. Vault builds instructions via the interface and executes the returned registerCalldata.
        IBittyV1IntentProtocol.OrderInstructions memory instr =
            IBittyV1IntentProtocol(clone).buildLimitOrderInstructions(_limitData(true));
        assertEq(instr.sellToken, address(mainnet.USDC));
        assertEq(instr.approveTarget, mainnet.PERMIT2);
        assertEq(instr.registerTarget, clone);

        vm.prank(VAULT);
        (bool ok,) = instr.registerTarget.call(instr.registerCalldata);
        assertTrue(ok, "vault-executed registerCalldata must succeed");

        // 3. Permit2 would call swapper.isValidSignature(digest); the clone authorizes it.
        assertEq(IBittyV1IntentProtocol(clone).isValidSignature(instr.orderId, ""), bytes4(0x1626ba7e));

        // 4. Vault cancels via the interface.
        IBittyV1IntentProtocol.CancelInstructions memory cancel =
            IBittyV1IntentProtocol(clone).buildCancelInstructions(instr.orderId);
        assertEq(cancel.cancelTarget, mainnet.PERMIT2, "limit cancel routes to Permit2 nonce invalidation");
        vm.prank(VAULT);
        (ok,) = cancel.cancelTarget.call(cancel.cancelCalldata);
        assertTrue(ok, "vault-executed cancelCalldata must succeed");

        assertEq(
            IBittyV1IntentProtocol(clone).isValidSignature(instr.orderId, ""),
            bytes4(0xffffffff),
            "signature invalid after Permit2 nonce invalidated"
        );
    }

    // ============ Limit orders ============

    function test_BuildLimitOrderInstructions_SellOrder() public view {
        IBittyV1IntentProtocol.OrderInstructions memory instr = protocol.buildLimitOrderInstructions(_limitData(true));
        assertEq(instr.sellToken, address(mainnet.USDC));
        assertEq(instr.sellAmount, 1000e6, "sell input is unchanged for a sell order");
        assertEq(instr.approveTarget, mainnet.PERMIT2);
        assertEq(instr.registerTarget, address(protocol));
        assertTrue(instr.orderId != bytes32(0));
        assertTrue(instr.registerCalldata.length > 0);
    }

    function test_BuildLimitOrderInstructions_BuyOrder_GrossesUpInput() public view {
        IBittyV1IntentProtocol.OrderInstructions memory instr = protocol.buildLimitOrderInstructions(_limitData(false));
        assertEq(instr.sellAmount, uint256(1000e6) * 10_020 / 10_000, "buy input grossed up 20bps for partner fee");
        assertEq(instr.approveTarget, mainnet.PERMIT2);
    }

    function test_IsValidSignature_ValidOrder_ReturnsMagic() public {
        IBittyV1IntentProtocol.OrderInstructions memory instr = protocol.buildLimitOrderInstructions(_limitData(true));
        vm.prank(VAULT);
        (bool ok,) = address(protocol).call(instr.registerCalldata);
        assertTrue(ok);
        assertEq(protocol.isValidSignature(instr.orderId, ""), bytes4(0x1626ba7e));
    }

    function test_IsValidSignature_WrongHash_ReturnsInvalid() public {
        IBittyV1IntentProtocol.OrderInstructions memory instr = protocol.buildLimitOrderInstructions(_limitData(true));
        vm.prank(VAULT);
        (bool ok,) = address(protocol).call(instr.registerCalldata);
        assertTrue(ok);
        assertEq(protocol.isValidSignature(keccak256("wrong"), ""), bytes4(0xffffffff));
    }

    function test_IsValidSignature_Unregistered_ReturnsInvalid() public view {
        IBittyV1IntentProtocol.OrderInstructions memory instr = protocol.buildLimitOrderInstructions(_limitData(true));
        assertEq(protocol.isValidSignature(instr.orderId, ""), bytes4(0xffffffff));
    }

    function test_IsValidSignature_Expired_ReturnsInvalid() public {
        IBittyV1IntentProtocol.OrderInstructions memory instr = protocol.buildLimitOrderInstructions(_limitData(true));
        vm.prank(VAULT);
        (bool ok,) = address(protocol).call(instr.registerCalldata);
        assertTrue(ok);
        vm.warp(block.timestamp + 3601);
        assertEq(protocol.isValidSignature(instr.orderId, ""), bytes4(0xffffffff));
    }

    function test_CancelLimit_InvalidatesPermit2NonceAndBlocksSignature() public {
        IBittyV1IntentProtocol.OrderInstructions memory instr = protocol.buildLimitOrderInstructions(_limitData(true));
        vm.prank(VAULT);
        (bool ok,) = address(protocol).call(instr.registerCalldata);
        assertTrue(ok);
        assertEq(protocol.isValidSignature(instr.orderId, ""), bytes4(0x1626ba7e));

        IBittyV1IntentProtocol.CancelInstructions memory cancel = protocol.buildCancelInstructions(instr.orderId);
        assertEq(cancel.cancelTarget, mainnet.PERMIT2, "limit cancel must target Permit2");

        // Execute the real Permit2 nonce invalidation as the swapper (vault).
        vm.prank(VAULT);
        (ok,) = cancel.cancelTarget.call(cancel.cancelCalldata);
        assertTrue(ok, "Permit2 invalidateUnorderedNonces must succeed");

        assertEq(protocol.isValidSignature(instr.orderId, ""), bytes4(0xffffffff), "invalid once nonce spent");
        assertFalse(protocol.isOrderActive(instr.orderId));
    }

    // ============ TWAP ============

    function test_BuildTwapInstructions_StoresParams() public {
        (IBittyV1IntentProtocol.OrderInstructions memory instr, uint256 expiresAt) =
            protocol.buildTwapInstructions(_buildTwapData(4, 3600, 0));
        assertEq(instr.sellToken, address(mainnet.USDC));
        assertEq(instr.sellAmount, 4000e6);
        assertEq(instr.approveTarget, mainnet.PERMIT2);
        assertEq(instr.registerTarget, address(protocol));
        assertApproxEqAbs(expiresAt, block.timestamp + 4 * 3600, 5);

        vm.prank(VAULT);
        (bool ok,) = address(protocol).call(instr.registerCalldata);
        assertTrue(ok);
        assertTrue(protocol.isTwapActive(instr.orderId));
    }

    function test_TwapIsValidSignature_InWindow_ReturnsMagic() public {
        (IBittyV1IntentProtocol.OrderInstructions memory instr,) =
            protocol.buildTwapInstructions(_buildTwapData(3, 3600, 0));
        vm.prank(VAULT);
        (bool ok,) = address(protocol).call(instr.registerCalldata);
        assertTrue(ok);

        bytes32 partDigest = protocol.getCurrentTwapPartDigest(instr.orderId);
        assertTrue(partDigest != bytes32(0), "should have a current part digest");
        assertEq(protocol.isValidSignature(partDigest, ""), bytes4(0x1626ba7e));
    }

    function test_TwapIsValidSignature_BetweenWindows_ReturnsInvalid() public {
        uint256 span = 1800;
        (IBittyV1IntentProtocol.OrderInstructions memory instr,) =
            protocol.buildTwapInstructions(_buildTwapData(3, 3600, span));
        vm.prank(VAULT);
        (bool ok,) = address(protocol).call(instr.registerCalldata);
        assertTrue(ok);

        bytes32 partDigest = protocol.getCurrentTwapPartDigest(instr.orderId);
        vm.warp(block.timestamp + span + 1);
        assertEq(protocol.isValidSignature(partDigest, ""), bytes4(0xffffffff));
    }

    function test_TwapIsValidSignature_NextWindow_NewDigest() public {
        uint256 partDuration = 3600;
        (IBittyV1IntentProtocol.OrderInstructions memory instr,) =
            protocol.buildTwapInstructions(_buildTwapData(3, partDuration, 0));
        vm.prank(VAULT);
        (bool ok,) = address(protocol).call(instr.registerCalldata);
        assertTrue(ok);

        bytes32 part0 = protocol.getCurrentTwapPartDigest(instr.orderId);
        vm.warp(block.timestamp + partDuration + 1);
        bytes32 part1 = protocol.getCurrentTwapPartDigest(instr.orderId);

        assertFalse(part0 == part1, "parts must have different digests");
        assertEq(protocol.isValidSignature(part0, ""), bytes4(0xffffffff), "part 0 invalid in window 1");
        assertEq(protocol.isValidSignature(part1, ""), bytes4(0x1626ba7e), "part 1 valid in window 1");
    }

    function test_Twap_DistinctBlocks_ProduceDistinctDigests() public {
        (IBittyV1IntentProtocol.OrderInstructions memory a,) =
            protocol.buildTwapInstructions(_buildTwapData(3, 3600, 0));
        vm.warp(block.timestamp + 1);
        (IBittyV1IntentProtocol.OrderInstructions memory b,) =
            protocol.buildTwapInstructions(_buildTwapData(3, 3600, 0));
        assertTrue(a.orderId != b.orderId, "distinct block timestamps -> distinct twap ids");

        vm.startPrank(VAULT);
        (bool ok,) = address(protocol).call(a.registerCalldata);
        assertTrue(ok);
        (ok,) = address(protocol).call(b.registerCalldata);
        assertTrue(ok);
        vm.stopPrank();

        assertEq(protocol.activeTwapIds().length, 2);
        assertTrue(
            protocol.getCurrentTwapPartDigest(a.orderId) != protocol.getCurrentTwapPartDigest(b.orderId),
            "distinct salts -> distinct part digests"
        );
    }

    function test_RegisterTwap_DuplicateInSameBlockReverts() public {
        (IBittyV1IntentProtocol.OrderInstructions memory instr,) =
            protocol.buildTwapInstructions(_buildTwapData(3, 3600, 0));
        vm.startPrank(VAULT);
        (bool ok,) = address(protocol).call(instr.registerCalldata);
        assertTrue(ok);
        (ok,) = address(protocol).call(instr.registerCalldata);
        assertFalse(ok, "duplicate twapId registration must revert");
        vm.stopPrank();
    }

    function test_BuildCancelInstructions_TwapRoutesToDeregister() public {
        (IBittyV1IntentProtocol.OrderInstructions memory instr,) =
            protocol.buildTwapInstructions(_buildTwapData(3, 3600, 0));
        vm.prank(VAULT);
        (bool ok,) = address(protocol).call(instr.registerCalldata);
        assertTrue(ok);

        IBittyV1IntentProtocol.CancelInstructions memory cancel = protocol.buildCancelInstructions(instr.orderId);
        assertEq(cancel.cancelTarget, address(protocol));
        assertEq(cancel.cancelCalldata, abi.encodeWithSignature("deregisterTwap(bytes32)", instr.orderId));

        vm.prank(VAULT);
        (ok,) = address(protocol).call(cancel.cancelCalldata);
        assertTrue(ok);
        assertFalse(protocol.isTwapActive(instr.orderId));
        assertEq(protocol.activeTwapIds().length, 0);
    }
}
