// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {CoWSwapV1Protocol} from "protocol-contracts/src/protocols/cowswap/CoWSwapV1Protocol.sol";
import {IBittyV1IntentProtocol} from "protocol-contracts/src/interfaces/IBittyV1IntentProtocol.sol";
import {GPv2Order} from "protocol-contracts/src/libs/cow/GPv2Order.sol";
import {IGPv2Settlement} from "protocol-contracts/src/libs/cow/IGPv2Settlement.sol";
import {mainnet} from "../../../script/addresses.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract TestCoWSwapV1ProtocolFork is Test {
    CoWSwapV1Protocol public protocol;

    address constant VAULT = address(0x1234567890123456789012345678901234567890);

    function setUp() public {
        vm.createSelectFork("mainnet");
        protocol = new CoWSwapV1Protocol(mainnet.COW_SETTLEMENT, mainnet.COW_VAULT_RELAYER);
        protocol.initialize(VAULT);
    }

    function test_Initialize() public view {
        assertEq(protocol.owner(), VAULT);
        assertEq(address(protocol.settlement()), mainnet.COW_SETTLEMENT);
        assertEq(protocol.vaultRelayer(), mainnet.COW_VAULT_RELAYER);
    }

    function test_BuildLimitOrderInstructions_SellOrder() public view {
        uint256 sellAmount = 1000e6;
        uint32 validTo = uint32(block.timestamp + 3600);
        bytes memory data = abi.encode(address(mainnet.USDC), sellAmount, address(mainnet.WETH), 1e15, validTo, true);

        IBittyV1IntentProtocol.OrderInstructions memory instr = protocol.buildLimitOrderInstructions(data);

        assertEq(instr.sellToken, address(mainnet.USDC));
        assertEq(instr.sellAmount, sellAmount);
        assertEq(instr.approveTarget, mainnet.COW_VAULT_RELAYER);
        assertEq(instr.registerTarget, address(protocol));
        assertTrue(instr.orderId != bytes32(0));
        assertTrue(instr.registerCalldata.length > 0);
    }

    function test_BuildLimitOrderInstructions_BuyOrder() public view {
        uint256 buyAmount = 1e18;
        uint256 sellAmountMax = 5000e6;
        uint32 validTo = uint32(block.timestamp + 3600);
        bytes memory data =
            abi.encode(address(mainnet.USDC), sellAmountMax, address(mainnet.WETH), buyAmount, validTo, false);

        IBittyV1IntentProtocol.OrderInstructions memory instr = protocol.buildLimitOrderInstructions(data);

        assertEq(instr.sellToken, address(mainnet.USDC));
        assertEq(instr.sellAmount, sellAmountMax);
        assertEq(instr.approveTarget, mainnet.COW_VAULT_RELAYER);
        assertEq(instr.registerTarget, address(protocol));
    }

    function test_BuildCancelInstructions_ReturnsDeregisterOrder() public view {
        bytes32 orderId = keccak256("test-order");
        IBittyV1IntentProtocol.CancelInstructions memory instr = protocol.buildCancelInstructions(orderId);

        assertEq(instr.cancelTarget, address(protocol));
        bytes memory expected = abi.encodeWithSignature("deregisterOrder(bytes32)", orderId);
        assertEq(instr.cancelCalldata, expected);
    }

    function test_IsOrderActive_TrueAfterRegister_FalseAfterDeregister() public {
        uint256 sellAmount = 1000e6;
        uint32 validTo = uint32(block.timestamp + 3600);
        bytes memory data = abi.encode(address(mainnet.USDC), sellAmount, address(mainnet.WETH), 1e15, validTo, true);

        IBittyV1IntentProtocol.OrderInstructions memory instr = protocol.buildLimitOrderInstructions(data);

        // Simulate vault registering the order via registerCalldata
        vm.prank(VAULT);
        (bool ok,) = address(protocol).call(instr.registerCalldata);
        assertTrue(ok);

        assertTrue(protocol.isOrderActive(instr.orderId), "order must be active after register");

        // Simulate vault cancelling
        IBittyV1IntentProtocol.CancelInstructions memory cancel = protocol.buildCancelInstructions(instr.orderId);
        vm.prank(VAULT);
        (ok,) = address(protocol).call(cancel.cancelCalldata);
        assertTrue(ok);

        assertFalse(protocol.isOrderActive(instr.orderId), "order must be inactive after deregister");
    }

    function test_IsOrderActive_FalseAfterExpiry() public {
        uint256 sellAmount = 1000e6;
        uint32 validTo = uint32(block.timestamp + 3600);
        bytes memory data = abi.encode(address(mainnet.USDC), sellAmount, address(mainnet.WETH), 1e15, validTo, true);

        IBittyV1IntentProtocol.OrderInstructions memory instr = protocol.buildLimitOrderInstructions(data);

        vm.prank(VAULT);
        (bool ok,) = address(protocol).call(instr.registerCalldata);
        assertTrue(ok);

        vm.warp(block.timestamp + 3601);
        assertFalse(protocol.isOrderActive(instr.orderId), "order must be inactive after expiry");
    }

    function test_IsValidSignature_ValidOrder_ReturnsMagic() public {
        uint256 sellAmount = 1000e6;
        uint32 validTo = uint32(block.timestamp + 3600);
        bytes memory data = abi.encode(address(mainnet.USDC), sellAmount, address(mainnet.WETH), 1e15, validTo, true);

        IBittyV1IntentProtocol.OrderInstructions memory instr = protocol.buildLimitOrderInstructions(data);

        vm.prank(VAULT);
        (bool ok,) = address(protocol).call(instr.registerCalldata);
        assertTrue(ok);

        bytes4 result = protocol.isValidSignature(instr.orderId, "");
        assertEq(result, bytes4(0x1626ba7e), "must return ERC-1271 magic value");
    }

    function test_IsValidSignature_WrongHash_ReturnsInvalid() public {
        uint256 sellAmount = 1000e6;
        uint32 validTo = uint32(block.timestamp + 3600);
        bytes memory data = abi.encode(address(mainnet.USDC), sellAmount, address(mainnet.WETH), 1e15, validTo, true);

        IBittyV1IntentProtocol.OrderInstructions memory instr = protocol.buildLimitOrderInstructions(data);

        vm.prank(VAULT);
        (bool ok,) = address(protocol).call(instr.registerCalldata);
        assertTrue(ok);

        bytes4 result = protocol.isValidSignature(keccak256("wrong hash"), "");
        assertEq(result, bytes4(0xffffffff), "must return invalid for wrong hash");
    }

    function test_IsValidSignature_UnregisteredOrder_ReturnsInvalid() public {
        uint256 sellAmount = 1000e6;
        uint32 validTo = uint32(block.timestamp + 3600);
        bytes memory data = abi.encode(address(mainnet.USDC), sellAmount, address(mainnet.WETH), 1e15, validTo, true);

        IBittyV1IntentProtocol.OrderInstructions memory instr = protocol.buildLimitOrderInstructions(data);
        // Do NOT register the order

        bytes4 result = protocol.isValidSignature(instr.orderId, "");
        assertEq(result, bytes4(0xffffffff), "must return invalid for unregistered order");
    }

    function test_IsValidSignature_ExpiredOrder_ReturnsInvalid() public {
        uint256 sellAmount = 1000e6;
        uint32 validTo = uint32(block.timestamp + 3600);
        bytes memory data = abi.encode(address(mainnet.USDC), sellAmount, address(mainnet.WETH), 1e15, validTo, true);

        IBittyV1IntentProtocol.OrderInstructions memory instr = protocol.buildLimitOrderInstructions(data);

        vm.prank(VAULT);
        (bool ok,) = address(protocol).call(instr.registerCalldata);
        assertTrue(ok);

        vm.warp(block.timestamp + 3601);
        bytes4 result = protocol.isValidSignature(instr.orderId, "");
        assertEq(result, bytes4(0xffffffff), "must return invalid for expired order");
    }

    // ============ TWAP tests ============

    function _buildTwapData(uint256 n, uint256 partDuration, uint256 span) internal view returns (bytes memory) {
        return abi.encode(
            address(mainnet.USDC), // sellToken
            uint256(1000e6) * n, // totalSellAmount
            address(mainnet.WETH), // buyToken
            uint256(1e14), // minPartLimit
            n,
            partDuration,
            span
        );
    }

    function test_BuildTwapInstructions_StoresParams() public {
        bytes memory data = _buildTwapData(4, 3600, 0);
        (IBittyV1IntentProtocol.OrderInstructions memory instr, uint256 expiresAt) =
            protocol.buildTwapInstructions(data);

        assertEq(instr.sellToken, address(mainnet.USDC));
        assertEq(instr.sellAmount, 4000e6);
        assertEq(instr.approveTarget, mainnet.COW_VAULT_RELAYER);
        assertEq(instr.registerTarget, address(protocol));
        assertTrue(instr.orderId != bytes32(0));
        assertApproxEqAbs(expiresAt, block.timestamp + 4 * 3600, 5);

        // Register and verify stored
        vm.prank(VAULT);
        (bool ok,) = address(protocol).call(instr.registerCalldata);
        assertTrue(ok);

        assertTrue(protocol.isTwapActive(instr.orderId));
    }

    function test_TwapIsValidSignature_InWindow_ReturnsMagic() public {
        uint256 partDuration = 3600;
        bytes memory data = _buildTwapData(3, partDuration, 0);
        (IBittyV1IntentProtocol.OrderInstructions memory instr,) = protocol.buildTwapInstructions(data);

        vm.prank(VAULT);
        (bool ok,) = address(protocol).call(instr.registerCalldata);
        assertTrue(ok);

        // Get the current part hash
        bytes32 partHash = protocol.getCurrentTwapPartHash(instr.orderId);
        assertTrue(partHash != bytes32(0), "should have a valid part hash");

        bytes4 result = protocol.isValidSignature(partHash, "");
        assertEq(result, bytes4(0x1626ba7e), "must return magic for current TWAP part");
    }

    function test_TwapIsValidSignature_BetweenWindows_ReturnsInvalid() public {
        uint256 partDuration = 3600;
        uint256 span = 1800; // half the slot is the execution window
        bytes memory data = _buildTwapData(3, partDuration, span);
        (IBittyV1IntentProtocol.OrderInstructions memory instr,) = protocol.buildTwapInstructions(data);

        vm.prank(VAULT);
        (bool ok,) = address(protocol).call(instr.registerCalldata);
        assertTrue(ok);

        bytes32 partHash = protocol.getCurrentTwapPartHash(instr.orderId);

        // Warp past the span (still within partDuration, but outside execution window)
        vm.warp(block.timestamp + span + 1);

        bytes4 result = protocol.isValidSignature(partHash, "");
        assertEq(result, bytes4(0xffffffff), "must return invalid between execution windows");
    }

    function test_TwapIsValidSignature_NextWindow_NewHash() public {
        uint256 partDuration = 3600;
        bytes memory data = _buildTwapData(3, partDuration, 0);
        (IBittyV1IntentProtocol.OrderInstructions memory instr,) = protocol.buildTwapInstructions(data);

        vm.prank(VAULT);
        (bool ok,) = address(protocol).call(instr.registerCalldata);
        assertTrue(ok);

        bytes32 part0Hash = protocol.getCurrentTwapPartHash(instr.orderId);

        // Advance to part 1
        vm.warp(block.timestamp + partDuration + 1);
        bytes32 part1Hash = protocol.getCurrentTwapPartHash(instr.orderId);

        assertFalse(part0Hash == part1Hash, "parts must have different hashes");
        assertEq(protocol.isValidSignature(part0Hash, ""), bytes4(0xffffffff), "part 0 invalid in window 1");
        assertEq(protocol.isValidSignature(part1Hash, ""), bytes4(0x1626ba7e), "part 1 valid in window 1");
    }

    function test_TwapIsValidSignature_AfterAllParts_ReturnsInvalid() public {
        uint256 n = 2;
        uint256 partDuration = 3600;
        bytes memory data = _buildTwapData(n, partDuration, 0);
        (IBittyV1IntentProtocol.OrderInstructions memory instr,) = protocol.buildTwapInstructions(data);

        vm.prank(VAULT);
        (bool ok,) = address(protocol).call(instr.registerCalldata);
        assertTrue(ok);

        bytes32 partHash = protocol.getCurrentTwapPartHash(instr.orderId);

        // Warp past all parts
        vm.warp(block.timestamp + n * partDuration + 1);

        assertFalse(protocol.isTwapActive(instr.orderId));
        assertEq(protocol.isValidSignature(partHash, ""), bytes4(0xffffffff));
    }

    function test_BuildCancelInstructions_TwapRoutesToDeregisterTwap() public {
        bytes memory data = _buildTwapData(3, 3600, 0);
        (IBittyV1IntentProtocol.OrderInstructions memory instr,) = protocol.buildTwapInstructions(data);

        vm.prank(VAULT);
        (bool ok,) = address(protocol).call(instr.registerCalldata);
        assertTrue(ok);

        IBittyV1IntentProtocol.CancelInstructions memory cancel = protocol.buildCancelInstructions(instr.orderId);

        assertEq(cancel.cancelTarget, address(protocol));
        bytes memory expected = abi.encodeWithSignature("deregisterTwap(bytes32)", instr.orderId);
        assertEq(cancel.cancelCalldata, expected);

        // Execute cancel
        vm.prank(VAULT);
        (ok,) = address(protocol).call(cancel.cancelCalldata);
        assertTrue(ok);

        assertFalse(protocol.isTwapActive(instr.orderId));
        assertEq(protocol.activeTwapIds().length, 0);
    }
}
