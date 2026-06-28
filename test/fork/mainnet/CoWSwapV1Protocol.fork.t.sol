// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {CoWSwapV1Protocol} from "protocol-contracts/src/protocols/cowswap/CoWSwapV1Protocol.sol";
import {SingleOrderHandlerV1} from "protocol-contracts/src/protocols/cowswap/SingleOrderHandlerV1.sol";
import {IComposableCoW} from "protocol-contracts/src/libs/cow/IComposableCoW.sol";
import {OrderNotExpired} from "protocol-contracts/src/interfaces/IBittyV1IntentProtocol.sol";
import {mainnet} from "../../../script/addresses.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract MockComposableCoW {
    mapping(address => mapping(bytes32 => bool)) public singleOrders;

    function create(IComposableCoW.ConditionalOrderParams calldata params, bool) external {
        singleOrders[msg.sender][hash(params)] = true;
    }

    function remove(bytes32 orderHash) external {
        singleOrders[msg.sender][orderHash] = false;
    }

    function hash(IComposableCoW.ConditionalOrderParams calldata params) public pure returns (bytes32) {
        return keccak256(abi.encode(params));
    }

    function isValidSafeSignature(address, address, bytes32, bytes32, bytes32, bytes calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return 0x1626ba7e;
    }
}

contract TestCoWSwapV1ProtocolFork is Test {
    using SafeERC20 for IERC20;

    CoWSwapV1Protocol public cowProtocol;
    SingleOrderHandlerV1 public singleHandler;
    MockComposableCoW public mockComposableCow;

    function setUp() public {
        vm.createSelectFork("mainnet");
        singleHandler = new SingleOrderHandlerV1();
        mockComposableCow = new MockComposableCoW();
        cowProtocol = new CoWSwapV1Protocol(
            mainnet.COW_SETTLEMENT,
            mainnet.COW_VAULT_RELAYER,
            address(mockComposableCow),
            mainnet.TWAP_HANDLER,
            address(singleHandler)
        );
        cowProtocol.initialize(address(this));
    }

    function test_Initialize() public view {
        assertEq(cowProtocol.owner(), address(this));
        assertEq(address(cowProtocol.settlement()), mainnet.COW_SETTLEMENT);
        assertEq(cowProtocol.vaultRelayer(), mainnet.COW_VAULT_RELAYER);
        assertEq(cowProtocol.singleOrderHandler(), address(singleHandler));
    }

    function test_Trade_RegistersConditionalOrder() public {
        uint256 sellAmount = 1000 * 1e6;
        uint32 validTo = uint32(block.timestamp + 3600);

        deal(address(mainnet.USDC), address(this), sellAmount);
        IERC20(address(mainnet.USDC)).forceApprove(address(cowProtocol), sellAmount);
        bytes32 h = _trade(sellAmount, 1e15, validTo, true);

        assertTrue(mockComposableCow.singleOrders(address(cowProtocol), h), "conditional order must be registered");
        assertEq(IERC20(address(mainnet.USDC)).balanceOf(address(cowProtocol)), sellAmount, "tokens must be in clone");
    }

    function test_Trade_VaultRelayerAllowancePersists() public {
        uint256 sellAmount = 1000 * 1e6;
        uint32 validTo = uint32(block.timestamp + 3600);

        deal(address(mainnet.USDC), address(this), sellAmount);
        IERC20(address(mainnet.USDC)).forceApprove(address(cowProtocol), sellAmount);
        _trade(sellAmount, 1e15, validTo, true);

        assertEq(
            IERC20(address(mainnet.USDC)).allowance(address(cowProtocol), cowProtocol.vaultRelayer()),
            sellAmount,
            "vault relayer allowance must persist for async settlement"
        );
    }

    function test_Trade_EmitsLimitOrderCreated() public {
        uint256 sellAmount = 1000 * 1e6;
        uint32 validTo = uint32(block.timestamp + 3600);

        deal(address(mainnet.USDC), address(this), sellAmount);
        IERC20(address(mainnet.USDC)).forceApprove(address(cowProtocol), sellAmount);

        vm.recordLogs();
        cowProtocol.trade(abi.encode(address(mainnet.USDC), sellAmount, address(mainnet.WETH), 1e15, validTo));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("LimitOrderCreated(bytes32,address)")) {
                found = true;
                break;
            }
        }
        assertTrue(found, "LimitOrderCreated event must be emitted");
    }

    function test_Trade_BuyOrder_RegistersConditionalOrder() public {
        uint256 sellAmountMax = 5000 * 1e6;
        uint256 buyAmount = 1e18;
        uint32 validTo = uint32(block.timestamp + 3600);

        deal(address(mainnet.USDC), address(this), sellAmountMax);
        IERC20(address(mainnet.USDC)).forceApprove(address(cowProtocol), sellAmountMax);

        vm.recordLogs();
        cowProtocol.trade(
            abi.encode(address(mainnet.USDC), sellAmountMax, address(mainnet.WETH), buyAmount, validTo, false)
        );
        bytes32 h = _parseLimitOrderHash();

        assertTrue(mockComposableCow.singleOrders(address(cowProtocol), h), "buy order must be registered");
    }

    function test_CancelTrade_RemovesConditionalOrderAndReturnsFunds() public {
        uint256 sellAmount = 1000 * 1e6;
        uint32 validTo = uint32(block.timestamp + 3600);

        deal(address(mainnet.USDC), address(this), sellAmount);
        IERC20(address(mainnet.USDC)).forceApprove(address(cowProtocol), sellAmount);
        bytes32 h = _trade(sellAmount, 1e15, validTo, true);

        cowProtocol.cancelTrade(abi.encode(h));

        assertFalse(mockComposableCow.singleOrders(address(cowProtocol), h), "conditional order must be removed");
        assertEq(
            IERC20(address(mainnet.USDC)).allowance(address(cowProtocol), cowProtocol.vaultRelayer()),
            0,
            "vault relayer allowance must be zero after cancel"
        );
        assertEq(IERC20(address(mainnet.USDC)).balanceOf(address(cowProtocol)), 0, "clone must hold no tokens");
        assertEq(IERC20(address(mainnet.USDC)).balanceOf(address(this)), sellAmount, "tokens returned to vault");
    }

    function test_CleanExpiredOrders_RevertsIfNotExpired() public {
        uint32 validTo = uint32(block.timestamp + 3600);
        bytes32 h = _placeTrade(1000e6, validTo);

        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = h;
        vm.expectRevert(OrderNotExpired.selector);
        cowProtocol.cleanExpiredOrders(hashes);
    }

    function test_CleanExpiredOrders_PermissionlessAfterExpiry() public {
        uint256 sellAmount = 1000e6;
        uint32 validTo = uint32(block.timestamp + 3600);
        bytes32 h = _placeTrade(sellAmount, validTo);

        vm.warp(validTo + 1);

        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = h;
        vm.prank(address(0xdead));
        cowProtocol.cleanExpiredOrders(hashes);

        assertFalse(mockComposableCow.singleOrders(address(cowProtocol), h), "order must be removed");
        assertEq(
            IERC20(address(mainnet.USDC)).allowance(address(cowProtocol), cowProtocol.vaultRelayer()),
            0,
            "allowance must be 0 after clean"
        );
        assertEq(IERC20(address(mainnet.USDC)).balanceOf(address(cowProtocol)), 0, "clone must hold no tokens");
        assertEq(IERC20(address(mainnet.USDC)).balanceOf(address(this)), sellAmount, "tokens returned to vault");
    }

    function test_IsOrderActive_TrueAfterTrade_FalseAfterCancel() public {
        uint256 sellAmount = 1000 * 1e6;
        uint32 validTo = uint32(block.timestamp + 3600);

        deal(address(mainnet.USDC), address(this), sellAmount);
        IERC20(address(mainnet.USDC)).forceApprove(address(cowProtocol), sellAmount);
        bytes32 h = _trade(sellAmount, 1e15, validTo, true);

        assertTrue(cowProtocol.isOrderActive(h));
        cowProtocol.cancelTrade(abi.encode(h));
        assertFalse(cowProtocol.isOrderActive(h));
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    function _placeTrade(uint256 sellAmount, uint32 validTo) internal returns (bytes32 h) {
        deal(address(mainnet.USDC), address(this), sellAmount);
        IERC20(address(mainnet.USDC)).forceApprove(address(cowProtocol), sellAmount);
        return _trade(sellAmount, 1e15, validTo, true);
    }

    function _trade(uint256 sellAmount, uint256 buyAmountMin, uint32 validTo, bool isSellOrder)
        internal
        returns (bytes32)
    {
        vm.recordLogs();
        cowProtocol.trade(
            abi.encode(address(mainnet.USDC), sellAmount, address(mainnet.WETH), buyAmountMin, validTo, isSellOrder)
        );
        return _parseLimitOrderHash();
    }

    function _parseLimitOrderHash() internal returns (bytes32) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("LimitOrderCreated(bytes32,address)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                return logs[i].topics[1];
            }
        }
        revert("LimitOrderCreated event not found");
    }
}
