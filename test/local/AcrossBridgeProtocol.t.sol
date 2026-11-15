// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {
    AcrossBridgeProtocol,
    BridgeFeeTooHigh,
    BridgeAmountZero,
    BridgeValueMismatch,
    BridgeRouteUnknown,
    BridgeOutputTooLow,
    BridgeDestinationUnsupported
} from "../../src/protocols/AcrossBridgeProtocol.sol";
import {TestProxy} from "../helpers/Proxy.sol";

/// Across's SpokePool as far as a deposit goes: take the tokens (or the value) and remember the call.
contract StubSpokePool {
    address public immutable wrappedNativeToken;

    bytes32 public depositor;
    bytes32 public recipient;
    bytes32 public inputToken;
    bytes32 public outputToken;
    uint256 public inputAmount;
    uint256 public outputAmount;
    uint256 public destinationChainId;
    uint256 public value;

    constructor(address weth) {
        wrappedNativeToken = weth;
    }

    function deposit(
        bytes32 depositor_,
        bytes32 recipient_,
        bytes32 inputToken_,
        bytes32 outputToken_,
        uint256 inputAmount_,
        uint256 outputAmount_,
        uint256 destinationChainId_,
        bytes32,
        uint32,
        uint32,
        uint32,
        bytes calldata message
    ) external payable {
        require(message.length == 0, "message");
        if (msg.value == 0) {
            MockERC20(address(uint160(uint256(inputToken_)))).transferFrom(msg.sender, address(this), inputAmount_);
        } else {
            require(msg.value == inputAmount_, "value");
        }
        depositor = depositor_;
        recipient = recipient_;
        inputToken = inputToken_;
        outputToken = outputToken_;
        inputAmount = inputAmount_;
        outputAmount = outputAmount_;
        destinationChainId = destinationChainId_;
        value = msg.value;
    }
}

contract StubGuard {
    mapping(bytes32 => uint256) public getUint;

    function setUint(bytes32 key, uint256 v) external {
        getUint[key] = v;
    }

    function assetCategory(address) external pure returns (uint8) {
        return 0;
    }
}

/// A vault, as far as the adapter sees one: it owns the adapter and has an owner of its own.
contract StubVault is Ownable {
    constructor(address owner_) Ownable(owner_) {}

    function approve(MockERC20 token, address spender) external {
        token.approve(spender, type(uint256).max);
    }

    receive() external payable {}
}

contract AcrossBridgeProtocolTest is Test {
    uint256 constant BASE = 8453;
    uint256 constant TRON = 728126428;

    // The Nile vault factory, its TVM proxy init-code hash, and an owner whose vault is activated
    // there: the factory's own vaultAddress(owner) answers 0x9a74…8f56 on Nile.
    address constant NILE_FACTORY = 0x311D087Ca9528801ab0d85E8bb92C9C611235834;
    bytes32 constant TRON_INITCODE_HASH = 0x521894190e6b5a5cb1a1448751c8cd310390f565a3453d203b5577e99e6b4fbd;
    address constant NILE_OWNER = 0x27839CBFd71212970cF9C41BEF6B6c7d10E81976;
    address constant NILE_VAULT = 0x9a7449097bd8be30FEb489B7f0C3e70B6ce08F56;

    StubSpokePool spoke;
    StubGuard guard;
    AcrossBridgeProtocol adapter;
    StubVault vault;
    MockERC20 usdc;
    MockERC20 weth;
    address usdcOnBase = makeAddr("usdcOnBase");
    address wethOnBase = makeAddr("wethOnBase");
    address owner = makeAddr("owner");
    address feeRecipient;

    function setUp() public {
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        spoke = new StubSpokePool(address(weth));
        guard = new StubGuard();
        adapter = _adapter(address(0), bytes32(0));
        feeRecipient = adapter.FEE_RECIPIENT();

        _route(address(usdc), BASE, usdcOnBase, 6, 100);
        _route(address(weth), BASE, wethOnBase, 18, 100);

        usdc.mint(address(vault), 1_000_000e6);
        vault.approve(usdc, address(adapter));
        vm.deal(address(vault), 100 ether);
    }

    function _adapter(address tronFactory, bytes32 tronHash) internal returns (AcrossBridgeProtocol a) {
        if (address(vault) == address(0)) vault = new StubVault(owner);
        AcrossBridgeProtocol impl = new AcrossBridgeProtocol(address(spoke), address(guard), tronFactory, tronHash);
        a = AcrossBridgeProtocol(payable(TestProxy.deploy(address(impl), address(vault))));
    }

    function _route(address input, uint256 chainId, address output, uint8 decimals, uint16 maxCost) internal {
        guard.setUint(adapter.routeKey(input, chainId), adapter.packRoute(output, decimals, maxCost));
    }

    function _quote(uint256 chainId, address output, uint256 outputAmount) internal view returns (bytes memory) {
        return abi.encode(
            AcrossBridgeProtocol.AcrossQuote({
                destinationChainId: chainId,
                outputToken: output,
                outputAmount: outputAmount,
                exclusiveRelayer: address(0),
                quoteTimestamp: uint32(block.timestamp),
                fillDeadline: uint32(block.timestamp + 6 hours),
                exclusivityParameter: 0
            })
        );
    }

    function _bridge(AcrossBridgeProtocol a, address token, uint256 amount, uint256 fee, uint256 value, bytes memory q)
        internal
    {
        vm.prank(address(vault));
        a.bridge{value: value}(token, amount, fee, q);
    }

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    // ── where the money goes ────────────────────────────────────────────────────────────────────

    /// The live factory on every EVM chain answers vaultAddress(0x…dEaD) = 0xcE80…6589.
    function test_evmVaultMatchesTheLiveFactory() public view {
        assertEq(adapter.vaultOn(BASE, address(0xdEaD)), 0xcE80b5aD441e0bCd1D0D616B063aB6B6680d6589);
        assertEq(adapter.vaultOn(1, address(0xdEaD)), 0xcE80b5aD441e0bCd1D0D616B063aB6B6680d6589);
    }

    function test_tronVaultMatchesTheNileFactory() public {
        AcrossBridgeProtocol a = _adapter(NILE_FACTORY, TRON_INITCODE_HASH);
        assertEq(a.vaultOn(TRON, NILE_OWNER), NILE_VAULT);
    }

    function test_tronIsUnsupportedUntilConfigured() public {
        vm.expectRevert(BridgeDestinationUnsupported.selector);
        adapter.vaultOn(TRON, owner);
    }

    function test_recipientIsTheOwnersVaultThere() public {
        _bridge(adapter, address(usdc), 1_000e6, 0, 0, _quote(BASE, usdcOnBase, 999e6));
        assertEq(spoke.recipient(), _b32(adapter.vaultOn(BASE, owner)));
        assertEq(spoke.depositor(), _b32(address(vault)));
        assertEq(spoke.destinationChainId(), BASE);
    }

    /// After an ownership transfer the money follows the NEW owner, not the old owner's address.
    function test_recipientFollowsTheCurrentOwner() public {
        address next = makeAddr("next");
        vm.prank(owner);
        vault.transferOwnership(next);
        _bridge(adapter, address(usdc), 1_000e6, 0, 0, _quote(BASE, usdcOnBase, 999e6));
        assertEq(spoke.recipient(), _b32(adapter.vaultOn(BASE, next)));
        assertTrue(spoke.recipient() != _b32(adapter.vaultOn(BASE, owner)));
    }

    function test_toTronPaysTheTronVault() public {
        AcrossBridgeProtocol a = _adapter(NILE_FACTORY, TRON_INITCODE_HASH);
        vault.approve(usdc, address(a));
        address usdtOnTron = makeAddr("usdtOnTron");
        guard.setUint(a.routeKey(address(usdc), TRON), a.packRoute(usdtOnTron, 6, 100));
        _bridge(a, address(usdc), 1_000e6, 0, 0, _quote(TRON, usdtOnTron, 999e6));
        assertEq(spoke.recipient(), _b32(a.vaultOn(TRON, owner)));
    }

    function test_sameChainIsRefused() public {
        _route(address(usdc), block.chainid, address(usdc), 6, 100);
        vm.expectRevert(BridgeDestinationUnsupported.selector);
        _bridge(adapter, address(usdc), 1_000e6, 0, 0, _quote(block.chainid, address(usdc), 999e6));
    }

    // ── what arrives ────────────────────────────────────────────────────────────────────────────

    function test_unknownRouteIsRefused() public {
        vm.expectRevert(BridgeRouteUnknown.selector);
        _bridge(adapter, address(usdc), 1_000e6, 0, 0, _quote(42161, usdcOnBase, 999e6));
    }

    function test_wrongOutputTokenIsRefused() public {
        vm.expectRevert(BridgeRouteUnknown.selector);
        _bridge(adapter, address(usdc), 1_000e6, 0, 0, _quote(BASE, makeAddr("junk"), 999e6));
    }

    function test_outputAtTheRoutesCostPasses() public {
        // 1% route cost: 1,000 in, 990 out is the floor.
        _bridge(adapter, address(usdc), 1_000e6, 0, 0, _quote(BASE, usdcOnBase, 990e6));
        assertEq(spoke.outputAmount(), 990e6);
    }

    function test_outputBelowTheRoutesCostIsRefused() public {
        vm.expectRevert(BridgeOutputTooLow.selector);
        _bridge(adapter, address(usdc), 1_000e6, 0, 0, _quote(BASE, usdcOnBase, 990e6 - 1));
    }

    /// A colluding relayer cannot be handed the deposit by a quote that pays out almost nothing.
    function test_dustOutputIsRefused() public {
        vm.expectRevert(BridgeOutputTooLow.selector);
        _bridge(adapter, address(usdc), 1_000e6, 0, 0, _quote(BASE, usdcOnBase, 1));
    }

    /// The floor is taken on what is deposited, after Bitty's fee.
    function test_floorIsOnTheDepositAfterFee() public {
        // 1,000 less a 2 fee = 998 deposited; 1% cost leaves a 988.02 floor.
        _bridge(adapter, address(usdc), 1_000e6, 2e6, 0, _quote(BASE, usdcOnBase, 988.02e6));
        vm.expectRevert(BridgeOutputTooLow.selector);
        _bridge(adapter, address(usdc), 1_000e6, 2e6, 0, _quote(BASE, usdcOnBase, 988.02e6 - 1));
    }

    function test_decimalsAreScaled() public {
        // An 18-decimal stable (BSC's USDT) arriving as a 6-decimal one.
        MockERC20 usdt18 = new MockERC20("Tether", "USDT", 18);
        usdt18.mint(address(vault), 1_000e18);
        vault.approve(usdt18, address(adapter));
        _route(address(usdt18), BASE, usdcOnBase, 6, 100);
        vm.expectRevert(BridgeOutputTooLow.selector);
        _bridge(adapter, address(usdt18), 1_000e18, 0, 0, _quote(BASE, usdcOnBase, 990e6 - 1));
        _bridge(adapter, address(usdt18), 1_000e18, 0, 0, _quote(BASE, usdcOnBase, 990e6));
    }

    /// A route configured looser than MAX_COST_BPS is held to MAX_COST_BPS.
    function test_routeCostIsCapped() public {
        _route(address(usdc), BASE, usdcOnBase, 6, 5_000);
        vm.expectRevert(BridgeOutputTooLow.selector);
        _bridge(adapter, address(usdc), 1_000e6, 0, 0, _quote(BASE, usdcOnBase, 970e6 - 1));
        _bridge(adapter, address(usdc), 1_000e6, 0, 0, _quote(BASE, usdcOnBase, 970e6));
    }

    // ── what leaves ─────────────────────────────────────────────────────────────────────────────

    function test_erc20PaysFeeAndDepositsTheRest() public {
        _bridge(adapter, address(usdc), 1_000e6, 2e6, 0, _quote(BASE, usdcOnBase, 990e6));
        assertEq(usdc.balanceOf(feeRecipient), 2e6);
        assertEq(usdc.balanceOf(address(spoke)), 998e6);
        assertEq(spoke.inputAmount(), 998e6);
        assertEq(spoke.inputToken(), _b32(address(usdc)));
        assertEq(usdc.balanceOf(address(vault)), 1_000_000e6 - 1_000e6);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(usdc.allowance(address(adapter), address(spoke)), 0);
    }

    function test_nativeGoesAsValueAgainstWrappedNative() public {
        _bridge(adapter, address(0), 1 ether, 0.002 ether, 1 ether, _quote(BASE, wethOnBase, 0.99 ether));
        assertEq(feeRecipient.balance, 0.002 ether);
        assertEq(spoke.value(), 0.998 ether);
        assertEq(spoke.inputAmount(), 0.998 ether);
        assertEq(spoke.inputToken(), _b32(address(weth)));
        assertEq(address(adapter).balance, 0);
    }

    function test_nativeValueMustMatch() public {
        bytes memory q = _quote(BASE, wethOnBase, 0.99 ether);
        vm.expectRevert(BridgeValueMismatch.selector);
        _bridge(adapter, address(0), 1 ether, 0, 0.5 ether, q);
    }

    function test_erc20TakesNoValue() public {
        bytes memory q = _quote(BASE, usdcOnBase, 999e6);
        vm.expectRevert(BridgeValueMismatch.selector);
        _bridge(adapter, address(usdc), 1_000e6, 0, 1, q);
    }

    function test_feeAboveTwentyBpsIsRefused() public {
        bytes memory q = _quote(BASE, usdcOnBase, 990e6);
        vm.expectRevert(BridgeFeeTooHigh.selector);
        _bridge(adapter, address(usdc), 1_000e6, 2e6 + 1, 0, q);
    }

    function test_zeroAmountIsRefused() public {
        bytes memory q = _quote(BASE, usdcOnBase, 1);
        vm.expectRevert(BridgeAmountZero.selector);
        _bridge(adapter, address(usdc), 0, 0, 0, q);
    }

    function test_onlyTheVaultMayBridge() public {
        bytes memory q = _quote(BASE, usdcOnBase, 999e6);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        adapter.bridge(address(usdc), 1_000e6, 0, q);
    }

    function test_identity() public view {
        assertEq(adapter.protocolLineage(), keccak256("bitty.adapter.across.bridge"));
        assertEq(adapter.versionName(), "1.0.0");
        assertEq(adapter.maxFeeBps(), 20);
    }

    // ── what it reports ─────────────────────────────────────────────────────────────────────────

    function _received(address token, uint256 amount, uint256 fee, bytes memory q) internal returns (uint256) {
        vm.prank(address(vault));
        return adapter.bridge(token, amount, fee, q);
    }

    function test_reportsWhatArrives() public {
        assertEq(_received(address(usdc), 1_000e6, 2e6, _quote(BASE, usdcOnBase, 990e6)), 990e6);
    }

    /// Reported in the SENT token's units, so the vault can price the loss with its own feed.
    function test_reportsInTheSentTokensDecimals() public {
        MockERC20 usdt18 = new MockERC20("Tether", "USDT", 18);
        usdt18.mint(address(vault), 1_000e18);
        vault.approve(usdt18, address(adapter));
        _route(address(usdt18), BASE, usdcOnBase, 6, 100);
        assertEq(_received(address(usdt18), 1_000e18, 0, _quote(BASE, usdcOnBase, 995e6)), 995e18);

        MockERC20 six = new MockERC20("Six", "SIX", 6);
        six.mint(address(vault), 1_000e6);
        vault.approve(six, address(adapter));
        address eighteen = makeAddr("eighteen");
        _route(address(six), BASE, eighteen, 18, 100);
        assertEq(_received(address(six), 1_000e6, 0, _quote(BASE, eighteen, 995.0000009e18)), 995e6);
    }
}
