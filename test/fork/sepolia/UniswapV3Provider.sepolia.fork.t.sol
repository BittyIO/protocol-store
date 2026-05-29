// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {console2} from "forge-std/console2.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {UniswapV3Provider} from "provider-contracts/src/providers/UniswapV3Provider.sol";
import {sepolia} from "../../../script/addresses.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {
    Path,
    IUniswapV3Factory,
    IUniswapV3Pool,
    IUniswapV3Router
} from "provider-contracts/src/libs/uniswap/v3/Uniswap.sol";
import {INonfungiblePositionManager} from "provider-contracts/src/libs/uniswap/v3/Uniswap.sol";

/// @dev Sepolia Uniswap V3: use WETH9 + USDT at 0.05% fee (pool `0x614dED...`); WETH/USDC pools are not deployed.
contract TestUniswapProviderSepoliaFork is Test {
    using SafeERC20 for IERC20;
    using Address for address;
    using Path for bytes;

    uint24 internal constant WETH_USDT_FEE = 500;
    int24 internal constant WETH_USDT_TICK_SPACING = 10;

    UniswapV3Provider public v3Provider;

    function setUp() public {
        vm.createSelectFork("sepolia");

        v3Provider = new UniswapV3Provider(sepolia.UNISWAP_V3_ROUTER, sepolia.UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER);
        v3Provider.initialize(address(this));
        vm.deal(address(v3Provider), 0);
    }

    function _getV3PoolPrice(address tokenIn, address tokenOut, uint24 fee) internal view returns (uint256) {
        address token0 = tokenIn < tokenOut ? tokenIn : tokenOut;
        address token1 = tokenIn < tokenOut ? tokenOut : tokenIn;

        address pool =
            IUniswapV3Factory(IUniswapV3Router(sepolia.UNISWAP_V3_ROUTER).factory()).getPool(token0, token1, fee);
        require(pool != address(0), "pool does not exist");
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();

        uint256 q192 = 2 ** 192;
        uint256 priceToken1PerToken0 =
            Math.mulDiv(Math.mulDiv(uint256(sqrtPriceX96), 1e18, 1), uint256(sqrtPriceX96), q192);

        if (tokenIn == token0) {
            return priceToken1PerToken0;
        } else {
            return Math.mulDiv(q192, 1e18, Math.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1));
        }
    }

    function test_Sepolia_V3_SwapWETHToUSDT() public {
        address[] memory path = new address[](2);
        path[0] = address(sepolia.WETH9);
        path[1] = address(sepolia.USDT);

        uint24[] memory fees = new uint24[](1);
        fees[0] = WETH_USDT_FEE;

        bytes memory encodedPath = Path.encodePath(path, fees);

        uint256 price = _getV3PoolPrice(path[0], path[1], fees[0]);
        uint256 sellAmount = 0.01 ether;
        uint256 expectedUsdtOutput = Math.mulDiv(sellAmount, price, 1e18);
        uint256 buyAmountMin = Math.mulDiv(expectedUsdtOutput, 95, 100);

        console2.log("buyAmountMin for sepolia");
        console2.log(buyAmountMin);

        bytes memory swapData = abi.encode(path[0], sellAmount, path[1], buyAmountMin, encodedPath);

        uint256 usdtBalanceBefore = IERC20(address(sepolia.USDT)).balanceOf(address(this));
        deal(address(sepolia.WETH9), address(this), sellAmount);
        IERC20(address(sepolia.WETH9)).safeApprove(address(v3Provider), sellAmount);

        console2.logBytes(swapData);

        v3Provider.swap(swapData);

        uint256 usdtBalanceAfter = IERC20(address(sepolia.USDT)).balanceOf(address(this));
        assertGt(usdtBalanceAfter, usdtBalanceBefore);
        assertGe(usdtBalanceAfter - usdtBalanceBefore, buyAmountMin);
    }

    function test_Sepolia_V3_SwapUSDTToWETH() public {
        address[] memory path = new address[](2);
        path[0] = address(sepolia.USDT);
        path[1] = address(sepolia.WETH9);

        uint24[] memory fees = new uint24[](1);
        fees[0] = WETH_USDT_FEE;

        bytes memory encodedPath = Path.encodePath(path, fees);

        uint256 price = _getV3PoolPrice(path[0], path[1], fees[0]);
        uint256 sellAmount = 20 * 1e6;
        uint256 expectedEthOutput = Math.mulDiv(sellAmount, 1e18, price);
        uint256 buyAmountMin = Math.mulDiv(expectedEthOutput, 95, 100);

        bytes memory swapData = abi.encode(path[0], sellAmount, path[1], buyAmountMin, encodedPath);

        uint256 wethBalanceBefore = IERC20(address(sepolia.WETH9)).balanceOf(address(this));
        deal(address(sepolia.USDT), address(this), sellAmount);
        IERC20(address(sepolia.USDT)).safeApprove(address(v3Provider), sellAmount);
        v3Provider.swap(swapData);

        uint256 wethBalanceAfter = IERC20(address(sepolia.WETH9)).balanceOf(address(this));
        assertGt(wethBalanceAfter, wethBalanceBefore);
        assertGe(wethBalanceAfter - wethBalanceBefore, buyAmountMin);
    }

    bytes32 constant ERC721_TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");

    function _mintV3PositionAndGetTokenId() internal returns (uint256 tokenId) {
        address token0 = sepolia.USDT < sepolia.WETH9 ? sepolia.USDT : sepolia.WETH9;
        address token1 = sepolia.USDT < sepolia.WETH9 ? sepolia.WETH9 : sepolia.USDT;
        uint24 fee = WETH_USDT_FEE;

        address pool =
            IUniswapV3Factory(IUniswapV3Router(sepolia.UNISWAP_V3_ROUTER).factory()).getPool(token0, token1, fee);
        require(pool != address(0), "pool does not exist");
        (, int24 currentTick,,,,,) = IUniswapV3Pool(pool).slot0();
        int24 tickLower = (currentTick / WETH_USDT_TICK_SPACING) * WETH_USDT_TICK_SPACING - WETH_USDT_TICK_SPACING * 10;
        int24 tickUpper = (currentTick / WETH_USDT_TICK_SPACING) * WETH_USDT_TICK_SPACING + WETH_USDT_TICK_SPACING * 10;

        uint256 amount0Desired = token0 == sepolia.WETH9 ? 0.01 ether : 20 * 1e6;
        uint256 amount1Desired = token1 == sepolia.WETH9 ? 0.01 ether : 20 * 1e6;

        deal(token0, address(this), amount0Desired);
        deal(token1, address(this), amount1Desired);
        IERC20(token0).safeApprove(address(v3Provider), amount0Desired);
        IERC20(token1).safeApprove(address(v3Provider), amount1Desired);

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: fee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(0),
            deadline: block.timestamp
        });
        bytes memory addData = abi.encode(true, abi.encode(mintParams));

        vm.recordLogs();
        v3Provider.addLiquidity(addData);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        address npm = sepolia.UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER;
        bytes32 toTopic = bytes32(uint256(uint160(address(v3Provider))));
        for (uint256 i = 0; i < entries.length; i++) {
            if (
                entries[i].emitter == npm && entries[i].topics[0] == ERC721_TRANSFER_TOPIC
                    && entries[i].topics[1] == bytes32(uint256(0)) && entries[i].topics[2] == toTopic
                    && entries[i].topics.length > 3
            ) {
                tokenId = uint256(entries[i].topics[3]);
                break;
            }
        }
        require(tokenId > 0, "tokenId from mint");
        return tokenId;
    }

    function test_Sepolia_V3_AddLiquidity_Mint() public {
        uint256 tokenId = _mintV3PositionAndGetTokenId();
        assertGt(tokenId, 0, "tokenId from mint");

        uint256 liquidity = v3Provider.getLiquidity(abi.encode(tokenId));
        assertGt(liquidity, 0, "liquidity after mint");
    }

    function test_Sepolia_V3_RemoveLiquidity() public {
        uint256 tokenId = _mintV3PositionAndGetTokenId();

        uint256 liquidityAfterMint = v3Provider.getLiquidity(abi.encode(tokenId));
        assertGt(liquidityAfterMint, 0, "liquidity after mint");

        uint128 liquidityToDecrease =
            liquidityAfterMint >= 2 ? uint128(liquidityAfterMint / 2) : uint128(liquidityAfterMint);
        INonfungiblePositionManager.DecreaseLiquidityParams memory decreaseParams =
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidityToDecrease,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            });
        v3Provider.removeLiquidity(abi.encode(decreaseParams));

        uint256 liquidityAfterDecrease = v3Provider.getLiquidity(abi.encode(tokenId));
        assertEq(liquidityAfterDecrease, liquidityAfterMint - liquidityToDecrease, "liquidity after decrease");
    }

    function test_Sepolia_V3_ClaimAMMFees() public {
        uint256 tokenId = _mintV3PositionAndGetTokenId();
        assertGt(v3Provider.getLiquidity(abi.encode(tokenId)), 0, "liquidity after mint");

        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: tokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
        });
        v3Provider.claimAMMFees(abi.encode(collectParams));
    }

    receive() external payable {}
}
