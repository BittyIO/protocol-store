// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    AcrossBridgeProtocol,
    BridgeDestinationUnsupported,
    BridgeOriginOwnerNeeded,
    BridgeOriginOwnerWrong,
    BridgeOutputTooLow
} from "../../src/protocols/AcrossBridgeProtocol.sol";
import {TronAcrossBridgeProtocol} from "../../src/protocols/TronAcrossBridgeProtocol.sol";
import {ZeroFeeRecipient} from "../../src/protocols/SunSwapUniversalTradeProtocol.sol";
import {TestProxy} from "../helpers/Proxy.sol";
import {StubSpokePool, StubGuard, StubVault} from "./AcrossBridgeProtocol.t.sol";
import {TronUsdtLike, RefusingToken} from "./TRC20Transfer.t.sol";

contract TronAcrossBridgeProtocolTest is Test {
    uint256 constant BASE = 8453;
    uint256 constant TRON = 728126428;

    // The Nile vault factory, its TVM proxy init-code hash, and an owner whose vault it activated:
    // the factory's own vaultAddress(owner) answers 0x9a74…8f56 on Nile.
    address constant NILE_FACTORY = 0x311D087Ca9528801ab0d85E8bb92C9C611235834;
    bytes32 constant TRON_INITCODE_HASH = 0x521894190e6b5a5cb1a1448751c8cd310390f565a3453d203b5577e99e6b4fbd;
    address constant NILE_OWNER = 0x27839CBFd71212970cF9C41BEF6B6c7d10E81976;
    address constant NILE_VAULT = 0x9a7449097bd8be30FEb489B7f0C3e70B6ce08F56;

    StubSpokePool spoke;
    StubGuard guard;
    TronAcrossBridgeProtocol adapter;
    StubVault vault;
    TronUsdtLike usdt;
    MockERC20 wtrx;
    address usdtOnBase = makeAddr("usdtOnBase");
    address owner = NILE_OWNER;
    address feeTo = makeAddr("tronFeeCollector");

    function setUp() public {
        wtrx = new MockERC20("Wrapped TRX", "WTRX", 6);
        usdt = new TronUsdtLike();
        spoke = new StubSpokePool(address(wtrx));
        guard = new StubGuard();
        deployCodeTo("AcrossBridgeProtocol.t.sol:StubVault", abi.encode(owner), NILE_VAULT);
        vault = StubVault(payable(NILE_VAULT));
        TronAcrossBridgeProtocol impl =
            new TronAcrossBridgeProtocol(address(spoke), address(guard), feeTo, NILE_FACTORY, TRON_INITCODE_HASH);
        adapter = TronAcrossBridgeProtocol(payable(TestProxy.deploy(address(impl), address(vault))));

        _route(address(usdt), BASE, usdtOnBase, 6, 100);
        usdt.mint(address(vault), 1_000_000e6);
        vault.approve(MockERC20(address(usdt)), address(adapter));
        vm.deal(address(vault), 1_000e6);
    }

    function _route(address input, uint256 chainId, address output, uint8 decimals, uint16 maxCost) internal {
        guard.setUint(adapter.routeKey(input, chainId), adapter.packRoute(output, decimals, maxCost));
    }

    /// Out of TRON every request names the vault's creation owner.
    function _quote(uint256 chainId, address output, uint256 outputAmount) internal view returns (bytes memory) {
        return abi.encode(_q(chainId, output, outputAmount), owner);
    }

    function _q(uint256 chainId, address output, uint256 outputAmount)
        internal
        view
        returns (AcrossBridgeProtocol.AcrossQuote memory)
    {
        return AcrossBridgeProtocol.AcrossQuote({
            destinationChainId: chainId,
            outputToken: output,
            outputAmount: outputAmount,
            exclusiveRelayer: address(0),
            quoteTimestamp: uint32(block.timestamp),
            fillDeadline: uint32(block.timestamp + 6 hours),
            exclusivityParameter: 0
        });
    }

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function test_usdtFeeReachesTheTronRecipientDespiteFalseReturn() public {
        vm.prank(address(vault));
        uint256 received = adapter.bridge(address(usdt), 1_000e6, 2e6, _quote(BASE, usdtOnBase, 990e6));

        assertEq(received, 990e6);
        assertEq(usdt.balanceOf(feeTo), 2e6);
        assertEq(usdt.balanceOf(adapter.FEE_RECIPIENT()), 0);
        assertEq(usdt.balanceOf(address(spoke)), 998e6);
        assertEq(spoke.inputAmount(), 998e6);
        assertEq(spoke.depositor(), _b32(address(vault)));
        assertEq(usdt.balanceOf(address(adapter)), 0);
        assertEq(usdt.allowance(address(adapter), address(spoke)), 0);
    }

    /// The TRON vault's counterpart is its creation owner's EVM vault, the one at that owner's EVM address.
    function test_recipientIsTheCreationOwnersEvmVault() public {
        vm.prank(address(vault));
        adapter.bridge(address(usdt), 1_000e6, 0, _quote(BASE, usdtOnBase, 990e6));
        assertEq(spoke.recipient(), _b32(adapter.vaultOn(BASE, owner)));
        // The same address the EVM adapter computes, so the same key's vault on every EVM chain.
        assertEq(adapter.vaultOn(BASE, address(0xdEaD)), 0xcE80b5aD441e0bCd1D0D616B063aB6B6680d6589);
        // And this vault is that owner's on TRON.
        assertEq(adapter.vaultOn(TRON, owner), address(vault));
    }

    /// A handover on TRON does not move the destination.
    function test_recipientStaysAfterAHandover() public {
        vm.prank(owner);
        vault.transferOwnership(makeAddr("next"));
        vm.prank(address(vault));
        adapter.bridge(address(usdt), 1_000e6, 0, _quote(BASE, usdtOnBase, 990e6));
        assertEq(spoke.recipient(), _b32(adapter.vaultOn(BASE, owner)));
    }

    /// Without the creation owner the TRON address means nothing on an EVM chain, so it is refused.
    function test_creationOwnerIsNeeded() public {
        bytes memory q = abi.encode(_q(BASE, usdtOnBase, 990e6));
        vm.prank(address(vault));
        vm.expectRevert(BridgeOriginOwnerNeeded.selector);
        adapter.bridge(address(usdt), 1_000e6, 0, q);
    }

    function test_anotherCreationOwnerIsRefused() public {
        bytes memory q = abi.encode(_q(BASE, usdtOnBase, 990e6), makeAddr("someoneElse"));
        vm.prank(address(vault));
        vm.expectRevert(BridgeOriginOwnerWrong.selector);
        adapter.bridge(address(usdt), 1_000e6, 0, q);
    }

    /// TRON to TRON is no bridge.
    function test_tronIsNeverADestination() public {
        vm.chainId(TRON);
        _route(address(usdt), TRON, address(usdt), 6, 100);
        vm.prank(address(vault));
        vm.expectRevert(BridgeDestinationUnsupported.selector);
        adapter.bridge(address(usdt), 1_000e6, 0, _quote(TRON, address(usdt), 990e6));
    }

    function test_trxIsSixDecimals() public {
        address wtrxOnBase = makeAddr("wtrxOnBase");
        _route(address(wtrx), BASE, wtrxOnBase, 6, 100);

        vm.prank(address(vault));
        uint256 received = adapter.bridge{value: 100e6}(address(0), 100e6, 0, _quote(BASE, wtrxOnBase, 99e6));
        assertEq(received, 99e6);
        assertEq(spoke.value(), 100e6);
        assertEq(spoke.inputToken(), _b32(address(wtrx)));

        vm.prank(address(vault));
        vm.expectRevert(BridgeOutputTooLow.selector);
        adapter.bridge{value: 100e6}(address(0), 100e6, 0, _quote(BASE, wtrxOnBase, 99e6 - 1));
    }

    function test_trxFeeGoesToTheTronRecipient() public {
        address wtrxOnBase = makeAddr("wtrxOnBase");
        _route(address(wtrx), BASE, wtrxOnBase, 6, 100);
        vm.prank(address(vault));
        adapter.bridge{value: 100e6}(address(0), 100e6, 0.2e6, _quote(BASE, wtrxOnBase, 98.9e6));
        assertEq(feeTo.balance, 0.2e6);
        assertEq(spoke.value(), 99.8e6);
    }

    function test_aTokenThatRefusesTheFeeStillReverts() public {
        RefusingToken no = new RefusingToken();
        no.mint(address(vault), 1_000e6);
        vault.approve(MockERC20(address(no)), address(adapter));
        _route(address(no), BASE, usdtOnBase, 6, 100);

        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(no)));
        adapter.bridge(address(no), 1_000e6, 2e6, _quote(BASE, usdtOnBase, 990e6));
    }

    function test_zeroFeeRecipientIsRefused() public {
        vm.expectRevert(ZeroFeeRecipient.selector);
        new TronAcrossBridgeProtocol(address(spoke), address(guard), address(0), NILE_FACTORY, TRON_INITCODE_HASH);
    }

    /// Without the TRON factory no vault here could be proven, so nothing could bridge.
    function test_missingTronFactoryIsRefused() public {
        vm.expectRevert(BridgeDestinationUnsupported.selector);
        new TronAcrossBridgeProtocol(address(spoke), address(guard), feeTo, address(0), TRON_INITCODE_HASH);
        vm.expectRevert(BridgeDestinationUnsupported.selector);
        new TronAcrossBridgeProtocol(address(spoke), address(guard), feeTo, NILE_FACTORY, bytes32(0));
    }

    function test_identity() public view {
        assertEq(adapter.feeRecipient(), feeTo);
        assertEq(adapter.spokePool(), address(spoke));
        assertEq(adapter.bittyGuard(), address(guard));
        assertEq(adapter.tronVaultFactory(), NILE_FACTORY);
        assertEq(adapter.protocolLineage(), keccak256("bitty.adapter.across.bridge"));
        assertEq(adapter.protocolVersion(), 1_001_000);
        assertEq(adapter.maxFeeBps(), 20);
    }
}
