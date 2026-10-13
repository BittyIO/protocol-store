// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {UniswapUniversalTradeProtocol, InsufficientOutput} from "../../src/protocols/UniswapUniversalTradeProtocol.sol";

import {UniversalRoute} from "../../src/libs/uniswap/universal/UniversalRouter.sol";

/// Answers `assetCategory` only; 0 means "not a stable coin", which is the fee-from-OUTPUT path.
contract StubGuard {
    mapping(address => uint8) public category;

    function setCategory(address token, uint8 c) external {
        category[token] = c;
    }

    function assetCategory(address token) external view returns (uint8) {
        return category[token];
    }
}

/// Permit2's surface as the adapter uses it: one approve, which need do nothing here.
contract StubPermit2 {
    function approve(address, address, uint160, uint48) external {}
}

/// Delivers a fixed amount of `out` to whoever calls `execute`, standing in for a filled route.
contract StubRouter {
    address public immutable out;
    uint256 public immutable amount;

    constructor(address out_, uint256 amount_) {
        out = out_;
        amount = amount_;
    }

    function execute(bytes calldata, bytes[] calldata, uint256) external payable {
        MockERC20(out).mint(msg.sender, amount);
    }
}

/**
 * THE MINIMUM IS WHAT THE VAULT RECEIVES, NOT WHAT THE ROUTER PRODUCED.
 *
 * Audit L-01. Selling a NON-stable token takes the adapter's 0.2% fee out of the OUTPUT, and the
 * adapter the finding was written against handed `amountOutMinimum` straight to the router as
 * `ExactInputParams.amountOutMinimum`. The router therefore checked the minimum against the GROSS
 * output and the adapter then sent `amountOut - fee` onward, so a caller with a tight minimum could
 * be filled 0.2% under it — a searcher who sandwiched the sell down to exactly the minimum left the
 * vault with `0.998 * buyAmountMin`.
 *
 * The current adapter does not delegate the check at all: it measures its own balance delta, takes
 * the fee, and compares the NET payout. These tests pin that, because the fork tests cannot — they
 * set a minimum at 90% of spot, which is loose enough that the old behaviour would pass too.
 */
contract UniswapUniversalTradeFeeTest is Test {
    uint256 constant FEE_BPS = 20; // 0.2%, as the adapter charges
    uint256 constant GROSS = 300_000e6; // what the route produces

    MockERC20 weth;
    MockERC20 usdc;
    StubGuard guard;
    UniswapUniversalTradeProtocol adapter;

    function setUp() public {
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        guard = new StubGuard(); // WETH deliberately uncategorised: fee comes from the output

        address router = address(new StubRouter(address(usdc), GROSS));
        UniswapUniversalTradeProtocol impl =
            new UniswapUniversalTradeProtocol(router, address(new StubPermit2()), address(guard));
        adapter = UniswapUniversalTradeProtocol(
            payable(new ERC1967Proxy(address(impl), abi.encodeCall(impl.initialize, (address(this)))))
        );

        weth.mint(address(this), 100 ether);
        IERC20(address(weth)).approve(address(adapter), type(uint256).max);
    }

    function _route() internal view returns (bytes memory) {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = "";
        return UniversalRoute.encode(hex"00", inputs, block.timestamp + 60);
    }

    function _sell(uint256 amountIn, uint256 minOut) internal {
        adapter.swap(abi.encode(address(weth), amountIn, address(usdc), minOut, _route()), address(this));
    }

    function _net(uint256 gross) internal pure returns (uint256) {
        return gross - gross * FEE_BPS / 10_000;
    }

    /// The exact shape of L-01: a minimum the GROSS output meets and the net does not.
    function test_aMinimumTheGrossMeetsButTheNetDoesNotIsRefused() public {
        vm.expectRevert(InsufficientOutput.selector);
        _sell(1 ether, GROSS);
    }

    /// One wei above the net is still refused — the boundary is where it should be.
    function test_theBoundaryIsTheNetAmountNotTheGross() public {
        vm.expectRevert(InsufficientOutput.selector);
        _sell(1 ether, _net(GROSS) + 1);
    }

    /// And asking for exactly the net succeeds, delivering exactly that.
    function test_exactlyTheNetIsHonouredAndDelivered() public {
        uint256 before = usdc.balanceOf(address(this));
        _sell(1 ether, _net(GROSS));
        assertEq(usdc.balanceOf(address(this)) - before, _net(GROSS), "the vault receives the net, in full");
        assertEq(usdc.balanceOf(adapter.FEE_RECIPIENT()), GROSS * FEE_BPS / 10_000, "and the fee is 0.2% of the gross");
    }

    /// What the finding costs if the check is ever moved back onto the gross.
    function test_theShortfallTheFindingDescribes() public {
        assertEq(GROSS - _net(GROSS), 600e6, "0.2% of 300,000 USDC is 600 USDC");
    }
}
