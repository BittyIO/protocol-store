// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {SunSwapUniversalTradeProtocol, ZeroFeeRecipient} from "../../src/protocols/SunSwapUniversalTradeProtocol.sol";
import {UniswapUniversalTradeProtocol, InsufficientOutput} from "../../src/protocols/UniswapUniversalTradeProtocol.sol";
import {PancakeSwapUniversalTradeProtocol} from "../../src/protocols/PancakeSwapUniversalTradeProtocol.sol";
import {UniversalRoute} from "../../src/libs/uniswap/universal/UniversalRouter.sol";
import {ASSET_STABLE_COIN} from "../../src/interfaces/IBittyV1Guard.sol";

/// TRON USDT's `transfer`: moves the tokens, then reports false.
contract TronUsdt is MockERC20("Tether USD", "USDT", 6) {
    function transfer(address to, uint256 amount) public override returns (bool) {
        super.transfer(to, amount);
        return false;
    }
}

contract SunStubGuard {
    mapping(address => uint8) public assetCategory;

    function set(address token, uint8 c) external {
        assetCategory[token] = c;
    }
}

/// Permit2's surface as the adapter and router use it: the grant is accepted, the pull is a transferFrom.
contract SunStubPermit2 {
    function approve(address, address, uint160, uint48) external {}

    function transferFrom(address from, address to, uint160 amount, address token) external {
        IERC20(token).transferFrom(from, to, amount);
    }
}

/// A filled route: pulls `spend` of `tokenIn` through Permit2, then mints `amountOut` of `out` to the caller.
contract SunStubRouter {
    SunStubPermit2 immutable permit2;
    address public tokenIn;
    uint256 public spend;
    address public out;
    uint256 public amountOut;

    constructor(SunStubPermit2 permit2_) {
        permit2 = permit2_;
    }

    function set(address tokenIn_, uint256 spend_, address out_, uint256 amountOut_) external {
        (tokenIn, spend, out, amountOut) = (tokenIn_, spend_, out_, amountOut_);
    }

    function execute(bytes calldata, bytes[] calldata, uint256) external payable {
        if (spend > 0) permit2.transferFrom(msg.sender, address(this), uint160(spend), tokenIn);
        MockERC20(out).mint(msg.sender, amountOut);
    }
}

/**
 * The SunSwap adapter is the Uniswap trade code with three TRON differences: its own lineage, a fee
 * recipient chosen at deployment, and payouts that accept TRON USDT's false-on-success `transfer`.
 * These tests pin those three; the shared trade logic is covered by the Uniswap tests.
 */
contract SunSwapUniversalTradeProtocolTest is Test {
    uint256 constant FEE_BPS = 20;

    address feeTo = makeAddr("tron fee collector");
    MockERC20 sun;
    TronUsdt usdt;
    SunStubGuard guard;
    SunStubPermit2 permit2;
    SunStubRouter router;
    SunSwapUniversalTradeProtocol adapter;

    function setUp() public {
        sun = new MockERC20("SUN", "SUN", 18);
        usdt = new TronUsdt();
        guard = new SunStubGuard();
        guard.set(address(usdt), ASSET_STABLE_COIN);
        permit2 = new SunStubPermit2();
        router = new SunStubRouter(permit2);

        SunSwapUniversalTradeProtocol impl =
            new SunSwapUniversalTradeProtocol(address(router), address(permit2), address(guard), feeTo);
        adapter = SunSwapUniversalTradeProtocol(
            payable(new ERC1967Proxy(address(impl), abi.encodeCall(impl.initialize, (address(this)))))
        );

        sun.mint(address(this), 1_000e18);
        usdt.mint(address(this), 1_000_000e6);
        sun.approve(address(adapter), type(uint256).max);
        usdt.approve(address(adapter), type(uint256).max);
    }

    function _route() internal view returns (bytes memory) {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = "";
        return UniversalRoute.encode(hex"00", inputs, block.timestamp + 60);
    }

    function test_hasItsOwnLineage() public {
        bytes32 lineage = adapter.protocolLineage();
        assertEq(lineage, keccak256("bitty.adapter.sunswap.universal"));
        UniswapUniversalTradeProtocol uni = new UniswapUniversalTradeProtocol(address(1), address(1), address(1));
        PancakeSwapUniversalTradeProtocol cake =
            new PancakeSwapUniversalTradeProtocol(address(1), address(1), address(1));
        assertTrue(lineage != uni.protocolLineage() && lineage != cake.protocolLineage());
    }

    function test_feeRecipientIsTheDeploymentsNotTheEvmSafe() public {
        assertEq(adapter.feeRecipient(), feeTo);
        assertTrue(adapter.feeRecipient() != adapter.FEE_RECIPIENT());
    }

    function test_refusesAZeroFeeRecipient() public {
        vm.expectRevert(ZeroFeeRecipient.selector);
        new SunSwapUniversalTradeProtocol(address(router), address(permit2), address(guard), address(0));
    }

    /// Buying USDT: the fee comes from the USDT output and both payouts use USDT's false-returning transfer.
    function test_buyingTronUsdtPaysTheNetAndTheFee() public {
        uint256 gross = 1_000e6;
        router.set(address(sun), 10e18, address(usdt), gross);
        uint256 fee = gross * FEE_BPS / 10_000;

        uint256 before = usdt.balanceOf(address(this));
        adapter.swap(abi.encode(address(sun), 10e18, address(usdt), gross - fee, _route()), address(this));

        assertEq(usdt.balanceOf(address(this)) - before, gross - fee, "vault gets the net");
        assertEq(usdt.balanceOf(feeTo), fee, "fee goes to the TRON recipient");
        assertEq(usdt.balanceOf(adapter.FEE_RECIPIENT()), 0, "never to the EVM fee Safe");
        assertEq(usdt.balanceOf(address(adapter)), 0);
    }

    function test_theMinimumIsStillTheNetPayout() public {
        uint256 gross = 1_000e6;
        router.set(address(sun), 10e18, address(usdt), gross);
        uint256 fee = gross * FEE_BPS / 10_000;
        vm.expectRevert(InsufficientOutput.selector);
        adapter.swap(abi.encode(address(sun), 10e18, address(usdt), gross - fee + 1, _route()), address(this));
    }

    /// Selling USDT (a stable coin): the fee is taken from the input, and unspent USDT comes back
    /// through the false-returning transfer.
    function test_sellingTronUsdtRefundsTheUnspentInput() public {
        uint256 amountIn = 1_000e6;
        uint256 fee = amountIn * FEE_BPS / 10_000;
        uint256 spent = 900e6; // the route used less than it was granted
        router.set(address(usdt), spent, address(sun), 5e18);

        uint256 before = usdt.balanceOf(address(this));
        adapter.swap(abi.encode(address(usdt), amountIn, address(sun), 5e18, _route()), address(this));

        assertEq(usdt.balanceOf(feeTo), fee, "fee from the input");
        assertEq(before - usdt.balanceOf(address(this)), fee + spent, "only the fee and what the route spent");
        assertEq(sun.balanceOf(address(this)), 1_000e18 + 5e18, "the whole output: no output fee on a stable sale");
        assertEq(usdt.balanceOf(address(adapter)), 0);
    }

    /// Exact-out paying in USDT: the fee is on the input spent and the rest of the maximum is refunded.
    function test_exactOutInTronUsdtChargesTheSpentInput() public {
        uint256 maxIn = 1_002e6;
        uint256 spent = 800e6;
        router.set(address(usdt), spent, address(sun), 4e18);

        uint256 before = usdt.balanceOf(address(this));
        adapter.swapExactOut(abi.encode(address(usdt), maxIn, address(sun), 4e18, _route()), address(this));

        uint256 fee = spent * FEE_BPS / 10_000;
        assertEq(usdt.balanceOf(feeTo), fee);
        assertEq(before - usdt.balanceOf(address(this)), spent + fee);
        assertEq(usdt.balanceOf(address(adapter)), 0);
    }
}
