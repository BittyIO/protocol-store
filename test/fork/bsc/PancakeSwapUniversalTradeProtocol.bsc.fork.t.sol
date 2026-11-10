// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {TestProxy} from "../../helpers/Proxy.sol";
import {
    PancakeSwapUniversalTradeProtocol
} from "protocol-contracts/src/protocols/PancakeSwapUniversalTradeProtocol.sol";
import {UniswapUniversalTradeProtocol} from "protocol-contracts/src/protocols/UniswapUniversalTradeProtocol.sol";
import {UniversalRoute} from "protocol-contracts/src/libs/uniswap/universal/UniversalRouter.sol";
import {bsc} from "../../../script/addresses.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Path} from "protocol-contracts/src/libs/uniswap/v3/Uniswap.sol";

interface IChainlinkFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/**
 * BNB Smart Chain: the trade adapter through PancakeSwap's Infinity Universal Router and PancakeSwap's
 * Permit2, with the LIVE Bitty guard (it lists USDT as a stable coin, which decides where the fee is
 * taken). v3 routes go through the 0.01% WBNB/USDT pool, the deepest; a v2 route is covered too.
 */
contract PancakeSwapUniversalTradeProtocolBscForkTest is Test {
    using SafeERC20 for IERC20;

    uint8 constant CMD_V3_SWAP_EXACT_IN = 0x00;
    uint8 constant CMD_V3_SWAP_EXACT_OUT = 0x01;
    uint8 constant CMD_V2_SWAP_EXACT_IN = 0x08;
    address constant MSG_SENDER = address(1);
    address constant FEE_RECIPIENT = 0xF0E7f6998B362BD15CF819C7EBfcaCe8865FECA0;
    uint256 constant SWAP_FEE_BPS = 20;
    uint24 constant FEE = 100;
    // Chainlink BNB / USD on BSC, 8 decimals.
    address constant BNB_USD = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;

    PancakeSwapUniversalTradeProtocol adapter;

    function setUp() public {
        vm.createSelectFork("bsc");
        adapter = PancakeSwapUniversalTradeProtocol(
            payable(TestProxy.deploy(
                    address(
                        new PancakeSwapUniversalTradeProtocol(
                            bsc.PANCAKE_UNIVERSAL_ROUTER, bsc.PANCAKE_PERMIT2, bsc.BITTY_GUARD
                        )
                    ),
                    address(this)
                ))
        );
    }

    /** USDT (18 decimals) per 1e18 WBNB. */
    function _bnbPrice() internal view returns (uint256) {
        (, int256 answer,,,) = IChainlinkFeed(BNB_USD).latestRoundData();
        return uint256(answer) * 1e10;
    }

    function _path(address a, address b) internal pure returns (bytes memory) {
        address[] memory tokens = new address[](2);
        tokens[0] = a;
        tokens[1] = b;
        uint24[] memory fees = new uint24[](1);
        fees[0] = FEE;
        return Path.encodePath(tokens, fees);
    }

    function _v3ExactIn(address tokenIn, address tokenOut, uint256 amountIn) internal view returns (bytes memory) {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(MSG_SENDER, amountIn, uint256(0), _path(tokenIn, tokenOut), true);
        return UniversalRoute.encode(abi.encodePacked(CMD_V3_SWAP_EXACT_IN), inputs, block.timestamp + 60);
    }

    /** A vault keeps one clone per lineage: PancakeSwap must not share Uniswap's. */
    function test_Bsc_OwnLineage() public {
        UniswapUniversalTradeProtocol uni =
            new UniswapUniversalTradeProtocol(bsc.PANCAKE_UNIVERSAL_ROUTER, bsc.PANCAKE_PERMIT2, bsc.BITTY_GUARD);
        assertEq(adapter.protocolLineage(), keccak256("bitty.adapter.pancakeswap.universal"));
        assertTrue(adapter.protocolLineage() != uni.protocolLineage(), "distinct from Uniswap");
        assertEq(adapter.protocolVersion(), uni.protocolVersion(), "version follows the shared trade code");
        assertEq(adapter.permit2(), bsc.PANCAKE_PERMIT2, "PancakeSwap's Permit2, not Uniswap's");
    }

    function test_Bsc_SellWbnbForUsdt_FeeFromOutput() public {
        uint256 sell = 1 ether;
        uint256 minOut = _bnbPrice() * 95 / 100;
        deal(bsc.WBNB, address(this), sell);
        IERC20(bsc.WBNB).forceApprove(address(adapter), sell);
        uint256 feeBefore = IERC20(bsc.USDT).balanceOf(FEE_RECIPIENT);
        // Differences, not balances: on a live fork this test's address can already hold USDT.
        uint256 before = IERC20(bsc.USDT).balanceOf(address(this));

        adapter.swap(abi.encode(bsc.WBNB, sell, bsc.USDT, minOut, _v3ExactIn(bsc.WBNB, bsc.USDT, sell)), address(this));

        uint256 got = IERC20(bsc.USDT).balanceOf(address(this)) - before;
        uint256 fee = IERC20(bsc.USDT).balanceOf(FEE_RECIPIENT) - feeBefore;
        assertGe(got, minOut, "at least the minimum");
        assertEq(fee, (got + fee) * SWAP_FEE_BPS / 10_000, "0.2% of the output");
        assertEq(IERC20(bsc.WBNB).balanceOf(address(adapter)), 0, "nothing stranded");
        assertEq(IERC20(bsc.USDT).balanceOf(address(adapter)), 0, "nothing stranded");
    }

    function test_Bsc_SellUsdtForWbnb_FeeFromInput() public {
        uint256 sell = 1000e18;
        uint256 fee = sell * SWAP_FEE_BPS / 10_000;
        uint256 minOut = Math.mulDiv(sell - fee, 1e18, _bnbPrice()) * 95 / 100;
        deal(bsc.USDT, address(this), sell);
        IERC20(bsc.USDT).forceApprove(address(adapter), sell);
        uint256 feeBefore = IERC20(bsc.USDT).balanceOf(FEE_RECIPIENT);
        uint256 before = IERC20(bsc.WBNB).balanceOf(address(this));

        adapter.swap(
            abi.encode(bsc.USDT, sell, bsc.WBNB, minOut, _v3ExactIn(bsc.USDT, bsc.WBNB, sell - fee)), address(this)
        );

        assertGe(IERC20(bsc.WBNB).balanceOf(address(this)) - before, minOut, "at least the minimum");
        assertEq(IERC20(bsc.USDT).balanceOf(FEE_RECIPIENT) - feeBefore, fee, "0.2% of the stable coin sold");
        assertEq(IERC20(bsc.USDT).balanceOf(address(this)), 0, "all input spent");
        assertEq(IERC20(bsc.USDT).balanceOf(address(adapter)), 0, "nothing stranded");
    }

    function test_Bsc_ExactOutBuyWbnbWithUsdt() public {
        uint256 want = 0.5 ether;
        uint256 maxIn = Math.mulDiv(want, _bnbPrice(), 1e18) * 110 / 100;
        uint256 swapMax = maxIn * 10_000 / (10_000 + SWAP_FEE_BPS);
        deal(bsc.USDT, address(this), maxIn);
        IERC20(bsc.USDT).forceApprove(address(adapter), maxIn);
        uint256 before = IERC20(bsc.WBNB).balanceOf(address(this));

        bytes[] memory inputs = new bytes[](1);
        // exact-out paths run from the token bought back to the token sold.
        inputs[0] = abi.encode(MSG_SENDER, want, swapMax, _path(bsc.WBNB, bsc.USDT), true);
        bytes memory route =
            UniversalRoute.encode(abi.encodePacked(CMD_V3_SWAP_EXACT_OUT), inputs, block.timestamp + 60);

        adapter.swapExactOut(abi.encode(bsc.USDT, maxIn, bsc.WBNB, want, route), address(this));

        assertEq(IERC20(bsc.WBNB).balanceOf(address(this)) - before, want, "exactly the amount bought");
        assertGt(IERC20(bsc.USDT).balanceOf(address(this)), 0, "unspent input refunded");
        assertEq(IERC20(bsc.USDT).balanceOf(address(adapter)), 0, "nothing stranded");
    }

    function test_Bsc_V2Route() public {
        uint256 sell = 1 ether;
        uint256 minOut = _bnbPrice() * 95 / 100;
        deal(bsc.WBNB, address(this), sell);
        IERC20(bsc.WBNB).forceApprove(address(adapter), sell);
        uint256 before = IERC20(bsc.USDT).balanceOf(address(this));

        address[] memory path = new address[](2);
        path[0] = bsc.WBNB;
        path[1] = bsc.USDT;
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(MSG_SENDER, sell, uint256(0), path, true);
        bytes memory route = UniversalRoute.encode(abi.encodePacked(CMD_V2_SWAP_EXACT_IN), inputs, block.timestamp + 60);

        adapter.swap(abi.encode(bsc.WBNB, sell, bsc.USDT, minOut, route), address(this));

        assertGe(IERC20(bsc.USDT).balanceOf(address(this)) - before, minOut, "at least the minimum");
        assertEq(IERC20(bsc.WBNB).balanceOf(address(adapter)), 0, "nothing stranded");
    }
}
