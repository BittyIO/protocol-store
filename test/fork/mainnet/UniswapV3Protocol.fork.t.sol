// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {UniswapV3Protocol} from "protocol-contracts/src/protocols/UniswapV3Protocol.sol";
import {mainnet} from "../../../script/addresses.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {
    Path,
    IUniswapV3Factory,
    IUniswapV3Pool,
    IUniswapV3Router
} from "protocol-contracts/src/libs/uniswap/v3/Uniswap.sol";
import {INonfungiblePositionManager} from "protocol-contracts/src/libs/uniswap/v3/Uniswap.sol";

contract TestUniswapProtocolFork is Test {
    using SafeERC20 for IERC20;
    using Address for address;
    using Path for bytes;

    UniswapV3Protocol public v3Protocol;

    address internal constant FEE_RECIPIENT = 0xc377432D0D28f3f689245D4aE7C58385bF31b590;
    uint256 internal constant SWAP_FEE_BPS = 20;
    uint256 internal constant COLLECT_FEE_BPS = 100;
    // BMNR token has no pool in Uniswap V3 now
    address internal constant NO_V3_POOL_TOKEN = 0x33483A58079b4225b10e57958Ca28ad7b9CDbAF7;

    function _assertFeeSplit(uint256 feeRecipientAmount, uint256 ownerAmount, uint256 feeBps) internal pure {
        if (feeRecipientAmount == 0 && ownerAmount == 0) {
            return;
        }
        uint256 total = feeRecipientAmount + ownerAmount;
        assertEq(feeRecipientAmount, total * feeBps / 10_000, "unexpected fee split");
    }

    function setUp() public {
        vm.createSelectFork("mainnet");

        v3Protocol = new UniswapV3Protocol(
            mainnet.UNISWAP_V3_ROUTER, mainnet.UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER, mainnet.BITTY_GUARD
        );
        v3Protocol.initialize(address(this));
        vm.deal(address(v3Protocol), 0);
        IERC721(mainnet.UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER).setApprovalForAll(address(v3Protocol), true);
    }

    function _getV3PoolPrice(address tokenIn, address tokenOut, uint24 fee) internal view returns (uint256) {
        // Ensure token0 < token1 for Uniswap V3
        address token0 = tokenIn < tokenOut ? tokenIn : tokenOut;
        address token1 = tokenIn < tokenOut ? tokenOut : tokenIn;

        address pool =
            IUniswapV3Factory(IUniswapV3Router(mainnet.UNISWAP_V3_ROUTER).factory()).getPool(token0, token1, fee);
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();

        // sqrtPriceX96 = sqrt(token1/token0) * 2^96
        // price = (sqrtPriceX96 / 2^96)^2 = token1/token0
        uint256 q192 = 2 ** 192;
        uint256 priceToken1PerToken0 =
            Math.mulDiv(Math.mulDiv(uint256(sqrtPriceX96), 1e18, 1), uint256(sqrtPriceX96), q192);

        // Return price of tokenOut per tokenIn
        // If tokenIn is token0, price = token1/token0 = tokenOut/tokenIn
        // If tokenIn is token1, price = token0/token1 = 1 / (token1/token0) = tokenOut/tokenIn
        if (tokenIn == token0) {
            return priceToken1PerToken0;
        } else {
            // Invert: price = 1 / priceToken1PerToken0
            return Math.mulDiv(q192, 1e18, Math.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1));
        }
    }

    // ============ Uniswap V3 Protocol Tests ============

    function test_V3_SwapWETHToUSDT() public {
        address[] memory path = new address[](2);
        path[0] = address(mainnet.WETH);
        path[1] = address(mainnet.USDT);

        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000; // 0.3% fee

        bytes memory encodedPath = Path.encodePath(path, fees);

        uint256 price = _getV3PoolPrice(path[0], path[1], fees[0]);
        uint256 sellAmount = 1 ether;
        uint256 buyAmountMin = Math.mulDiv(price, 95, 100);

        bytes memory swapData = abi.encode(path[0], sellAmount, path[1], buyAmountMin, encodedPath);

        uint256 usdtBalanceBefore = IERC20(address(mainnet.USDT)).balanceOf(address(this));
        deal(address(mainnet.WETH), address(this), sellAmount);
        IERC20(address(mainnet.WETH)).forceApprove(address(v3Protocol), sellAmount);

        v3Protocol.swap(swapData);

        uint256 usdtBalanceAfter = IERC20(address(mainnet.USDT)).balanceOf(address(this));
        assertGt(usdtBalanceAfter, usdtBalanceBefore);
        assertGe(usdtBalanceAfter - usdtBalanceBefore, buyAmountMin);
    }

    function test_V3_SwapUSDCToWETH() public {
        address[] memory path = new address[](2);
        path[0] = address(mainnet.USDC);
        path[1] = address(mainnet.WETH);

        uint24[] memory fees = new uint24[](1);
        fees[0] = 500; // 0.05% fee

        bytes memory encodedPath = Path.encodePath(path, fees);

        uint256 price = _getV3PoolPrice(address(mainnet.USDC), address(mainnet.WETH), 3000);
        uint256 sellAmount = 1000 * 1e6;
        uint256 expectedEthOutput = Math.mulDiv(sellAmount, 1e18, price);
        uint256 buyAmountMin = Math.mulDiv(expectedEthOutput, 95, 100);

        bytes memory swapData = abi.encode(path[0], sellAmount, path[1], buyAmountMin, encodedPath);

        uint256 wethBalanceBefore = IERC20(address(mainnet.WETH)).balanceOf(address(this));
        deal(address(mainnet.USDC), address(this), sellAmount);
        IERC20(address(mainnet.USDC)).forceApprove(address(v3Protocol), sellAmount);

        v3Protocol.swap(swapData);

        uint256 wethBalanceAfter = IERC20(address(mainnet.WETH)).balanceOf(address(this));
        assertGt(wethBalanceAfter, wethBalanceBefore);
        assertGe(wethBalanceAfter - wethBalanceBefore, buyAmountMin);
    }

    function test_V3_SwapUSDTToWETH() public {
        address[] memory path = new address[](2);
        path[0] = address(mainnet.USDT);
        path[1] = address(mainnet.WETH);

        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000; // 0.3% fee

        bytes memory encodedPath = Path.encodePath(path, fees);

        uint256 price = _getV3PoolPrice(address(mainnet.USDT), address(mainnet.WETH), 3000);
        uint256 sellAmount = 1000 * 1e6;
        uint256 expectedEthOutput = Math.mulDiv(sellAmount, 1e18, price);
        uint256 buyAmountMin = Math.mulDiv(expectedEthOutput, 95, 100);

        bytes memory swapData = abi.encode(path[0], sellAmount, path[1], buyAmountMin, encodedPath);

        uint256 wethBalanceBefore = IERC20(address(mainnet.WETH)).balanceOf(address(this));
        deal(address(mainnet.USDT), address(this), sellAmount);
        IERC20(address(mainnet.USDT)).forceApprove(address(v3Protocol), sellAmount);

        v3Protocol.swap(swapData);

        uint256 wethBalanceAfter = IERC20(address(mainnet.WETH)).balanceOf(address(this));
        assertGt(wethBalanceAfter, wethBalanceBefore);
        assertGe(wethBalanceAfter - wethBalanceBefore, buyAmountMin);
    }

    function test_V3_SwapUSDCToWETHToUSDT() public {
        address[] memory path = new address[](3);
        path[0] = address(mainnet.USDC);
        path[1] = address(mainnet.WETH);
        path[2] = address(mainnet.USDT);

        uint24[] memory fees = new uint24[](2);
        fees[0] = 500; // 0.05% fee for USDC -> WETH
        fees[1] = 3000; // 0.3% fee for WETH -> USDT

        bytes memory encodedPath = Path.encodePath(path, fees);

        uint256 sellAmount = 1000 * 1e6;

        uint256 price1 = _getV3PoolPrice(address(mainnet.USDC), address(mainnet.WETH), 500);
        uint256 expectedWethOutput = Math.mulDiv(sellAmount, 1e18, price1);

        uint256 price2 = _getV3PoolPrice(address(mainnet.WETH), address(mainnet.USDT), 3000);
        uint256 expectedUsdtOutput = Math.mulDiv(expectedWethOutput, price2, 1e18);

        uint256 buyAmountMin = Math.mulDiv(expectedUsdtOutput, 95, 100);

        bytes memory swapData = abi.encode(path[0], sellAmount, path[2], buyAmountMin, encodedPath);

        uint256 usdtBalanceBefore = IERC20(address(mainnet.USDT)).balanceOf(address(this));
        deal(address(mainnet.USDC), address(this), sellAmount);
        IERC20(address(mainnet.USDC)).forceApprove(address(v3Protocol), sellAmount);

        v3Protocol.swap(swapData);

        uint256 usdtBalanceAfter = IERC20(address(mainnet.USDT)).balanceOf(address(this));
        assertGt(usdtBalanceAfter, usdtBalanceBefore);
        assertGe(usdtBalanceAfter - usdtBalanceBefore, buyAmountMin);
    }

    function test_V3_SwapFee_ChargesStablecoinInputFee() public {
        address[] memory path = new address[](2);
        path[0] = address(mainnet.USDC);
        path[1] = address(mainnet.WETH);

        uint24[] memory fees = new uint24[](1);
        fees[0] = 500;

        bytes memory encodedPath = Path.encodePath(path, fees);

        uint256 price = _getV3PoolPrice(address(mainnet.USDC), address(mainnet.WETH), 3000);
        uint256 sellAmount = 1000 * 1e6;
        uint256 expectedEthOutput = Math.mulDiv(sellAmount, 1e18, price);
        uint256 buyAmountMin = Math.mulDiv(expectedEthOutput, 95, 100);

        bytes memory swapData = abi.encode(path[0], sellAmount, path[1], buyAmountMin, encodedPath);
        uint256 expectedFee = sellAmount * SWAP_FEE_BPS / 10_000;

        uint256 feeRecipientBefore = IERC20(address(mainnet.USDC)).balanceOf(FEE_RECIPIENT);
        deal(address(mainnet.USDC), address(this), sellAmount);
        IERC20(address(mainnet.USDC)).forceApprove(address(v3Protocol), sellAmount);

        v3Protocol.swap(swapData);

        assertEq(
            IERC20(address(mainnet.USDC)).balanceOf(FEE_RECIPIENT) - feeRecipientBefore,
            expectedFee,
            "stablecoin input swap fee"
        );
    }

    function test_V3_SwapFee_ChargesOutputFee() public {
        address[] memory path = new address[](2);
        path[0] = address(mainnet.WETH);
        path[1] = address(mainnet.USDT);

        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;

        bytes memory encodedPath = Path.encodePath(path, fees);

        uint256 price = _getV3PoolPrice(path[0], path[1], fees[0]);
        uint256 sellAmount = 1 ether;
        uint256 buyAmountMin = Math.mulDiv(price, 95, 100);

        bytes memory swapData = abi.encode(path[0], sellAmount, path[1], buyAmountMin, encodedPath);

        uint256 feeRecipientBefore = IERC20(address(mainnet.USDT)).balanceOf(FEE_RECIPIENT);
        uint256 ownerBefore = IERC20(address(mainnet.USDT)).balanceOf(address(this));
        deal(address(mainnet.WETH), address(this), sellAmount);
        IERC20(address(mainnet.WETH)).forceApprove(address(v3Protocol), sellAmount);

        v3Protocol.swap(swapData);

        _assertFeeSplit(
            IERC20(address(mainnet.USDT)).balanceOf(FEE_RECIPIENT) - feeRecipientBefore,
            IERC20(address(mainnet.USDT)).balanceOf(address(this)) - ownerBefore,
            SWAP_FEE_BPS
        );
    }

    function test_V3_Swap_RevertsWhenPoolDoesNotExist() public {
        address tokenIn = NO_V3_POOL_TOKEN;
        address tokenOut = address(mainnet.WETH);
        uint24 fee = 3000;

        address token0 = tokenIn < tokenOut ? tokenIn : tokenOut;
        address token1 = tokenIn < tokenOut ? tokenOut : tokenIn;
        address pool =
            IUniswapV3Factory(IUniswapV3Router(mainnet.UNISWAP_V3_ROUTER).factory()).getPool(token0, token1, fee);
        assertEq(pool, address(0), "pool must not exist for test token");

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        uint24[] memory fees = new uint24[](1);
        fees[0] = fee;

        bytes memory encodedPath = Path.encodePath(path, fees);
        uint256 sellAmount = 1 ether;
        bytes memory swapData = abi.encode(path[0], sellAmount, path[1], uint256(0), encodedPath);

        uint256 tokenInBalanceBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 tokenOutBalanceBefore = IERC20(tokenOut).balanceOf(address(this));
        uint256 feeRecipientBalanceBefore = IERC20(tokenOut).balanceOf(FEE_RECIPIENT);
        uint256 protocolTokenInBefore = IERC20(tokenIn).balanceOf(address(v3Protocol));

        deal(tokenIn, address(this), sellAmount);
        IERC20(tokenIn).forceApprove(address(v3Protocol), sellAmount);

        vm.expectRevert();
        v3Protocol.swap(swapData);

        assertEq(IERC20(tokenIn).balanceOf(address(this)), tokenInBalanceBefore + sellAmount, "tokenIn returned");
        assertEq(IERC20(tokenOut).balanceOf(address(this)), tokenOutBalanceBefore, "tokenOut unchanged");
        assertEq(IERC20(tokenOut).balanceOf(FEE_RECIPIENT), feeRecipientBalanceBefore, "no output fee charged");
        assertEq(IERC20(tokenIn).balanceOf(address(v3Protocol)), protocolTokenInBefore, "protocol holds no tokenIn");
    }

    // ============ Uniswap V3 AMM (addLiquidity / removeLiquidity / claimAMMFees / getLiquidity) ============

    bytes32 constant ERC721_TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");

    function _mintV3PositionAndGetTokenId() internal returns (uint256 tokenId) {
        address token0 = mainnet.WETH < mainnet.USDC ? mainnet.WETH : mainnet.USDC;
        address token1 = mainnet.WETH < mainnet.USDC ? mainnet.USDC : mainnet.WETH;
        uint24 fee = 3000;
        int24 tickSpacing = 60;

        address pool =
            IUniswapV3Factory(IUniswapV3Router(mainnet.UNISWAP_V3_ROUTER).factory()).getPool(token0, token1, fee);
        (, int24 currentTick,,,,,) = IUniswapV3Pool(pool).slot0();
        int24 tickLower = (currentTick / tickSpacing) * tickSpacing - tickSpacing * 10;
        int24 tickUpper = (currentTick / tickSpacing) * tickSpacing + tickSpacing * 10;

        uint256 amount0Desired = token0 == mainnet.WETH ? 0.01 ether : 20 * 1e6;
        uint256 amount1Desired = token1 == mainnet.WETH ? 0.01 ether : 20 * 1e6;

        deal(token0, address(this), amount0Desired);
        deal(token1, address(this), amount1Desired);
        IERC20(token0).forceApprove(address(v3Protocol), amount0Desired);
        IERC20(token1).forceApprove(address(v3Protocol), amount1Desired);

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
        v3Protocol.addLiquidity(addData);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        address npm = mainnet.UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER;
        bytes32 toTopic = bytes32(uint256(uint160(address(this))));
        for (uint256 i = 0; i < entries.length; i++) {
            if (
                entries[i].emitter == npm && entries[i].topics[0] == ERC721_TRANSFER_TOPIC
                    && entries[i].topics[2] == toTopic && entries[i].topics.length > 3
            ) {
                tokenId = uint256(entries[i].topics[3]);
                break;
            }
        }
        require(tokenId > 0, "tokenId from mint");
        return tokenId;
    }

    function test_V3_AddLiquidity_Mint() public {
        uint256 tokenId = _mintV3PositionAndGetTokenId();
        assertGt(tokenId, 0, "tokenId from mint");

        uint256 liquidity = v3Protocol.getLiquidity(abi.encode(tokenId));
        assertGt(liquidity, 0, "liquidity after mint");
    }

    function test_V3_GetLiquidity_ClaimFees() public {
        uint256 tokenId = _mintV3PositionAndGetTokenId();

        uint256 liquidity = v3Protocol.getLiquidity(abi.encode(tokenId));
        assertGt(liquidity, 0, "liquidity after mint");

        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: tokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
        });
        v3Protocol.claimAMMFees(abi.encode(collectParams));
    }

    /// @notice `CollectParams.recipient` in calldata must be ignored; fees go to the protocol owner only.
    function test_V3_ClaimFees_EncodedRecipientDoesNotReceiveTokens() public {
        uint256 tokenId = _mintV3PositionAndGetTokenId();
        assertGt(v3Protocol.getLiquidity(abi.encode(tokenId)), 0, "liquidity after mint");

        address token0 = mainnet.WETH < mainnet.USDC ? mainnet.WETH : mainnet.USDC;
        address token1 = mainnet.WETH < mainnet.USDC ? mainnet.USDC : mainnet.WETH;
        address encodedRecipient = makeAddr("encodedRecipient");

        uint256 bal0Before = IERC20(token0).balanceOf(encodedRecipient);
        uint256 bal1Before = IERC20(token1).balanceOf(encodedRecipient);

        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: tokenId, recipient: encodedRecipient, amount0Max: type(uint128).max, amount1Max: type(uint128).max
        });
        v3Protocol.claimAMMFees(abi.encode(collectParams));

        assertEq(IERC20(token0).balanceOf(encodedRecipient), bal0Before, "token0 must not go to encoded recipient");
        assertEq(IERC20(token1).balanceOf(encodedRecipient), bal1Before, "token1 must not go to encoded recipient");
    }

    function test_V3_ClaimAMMFees_DoesNotChargeCollectFeeOnPrincipalInTokensOwed() public {
        uint256 tokenId = _mintV3PositionAndGetTokenId();

        address token0 = mainnet.WETH < mainnet.USDC ? mainnet.WETH : mainnet.USDC;
        address token1 = mainnet.WETH < mainnet.USDC ? mainnet.USDC : mainnet.WETH;

        _swapOnPoolToAccruePositionFees(token0, token1);

        uint128 liquidity = uint128(v3Protocol.getLiquidity(abi.encode(tokenId)));
        vm.prank(address(v3Protocol));
        INonfungiblePositionManager(mainnet.UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER)
            .decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId, liquidity: liquidity / 2, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
                })
            );

        (,,,,,,,,,, uint128 principalOwed0Before, uint128 principalOwed1Before) =
            INonfungiblePositionManager(mainnet.UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER).positions(tokenId);

        uint256 feeRec0Before = IERC20(token0).balanceOf(FEE_RECIPIENT);
        uint256 feeRec1Before = IERC20(token1).balanceOf(FEE_RECIPIENT);
        uint256 owner0Before = IERC20(token0).balanceOf(address(this));
        uint256 owner1Before = IERC20(token1).balanceOf(address(this));

        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: tokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
        });
        v3Protocol.claimAMMFees(abi.encode(collectParams));

        uint256 feeRec0Received = IERC20(token0).balanceOf(FEE_RECIPIENT) - feeRec0Before;
        uint256 feeRec1Received = IERC20(token1).balanceOf(FEE_RECIPIENT) - feeRec1Before;
        uint256 owner0Received = IERC20(token0).balanceOf(address(this)) - owner0Before;
        uint256 owner1Received = IERC20(token1).balanceOf(address(this)) - owner1Before;

        assertTrue(owner0Received > 0 || owner1Received > 0, "owner must receive tokens");
        assertTrue(principalOwed0Before > 0 || principalOwed1Before > 0, "principal must be owed before fee claim");
        if (owner0Received > principalOwed0Before) {
            _assertFeeSplit(feeRec0Received, owner0Received - principalOwed0Before, COLLECT_FEE_BPS);
        }
        if (owner1Received > principalOwed1Before) {
            _assertFeeSplit(feeRec1Received, owner1Received - principalOwed1Before, COLLECT_FEE_BPS);
        }
    }

    function test_V3_ClaimAMMFees_SendsOnePercentToFeeRecipient() public {
        uint256 tokenId = _mintV3PositionAndGetTokenId();

        address token0 = mainnet.WETH < mainnet.USDC ? mainnet.WETH : mainnet.USDC;
        address token1 = mainnet.WETH < mainnet.USDC ? mainnet.USDC : mainnet.WETH;

        _swapOnPoolToAccruePositionFees(token0, token1);

        uint256 feeRec0Before = IERC20(token0).balanceOf(FEE_RECIPIENT);
        uint256 feeRec1Before = IERC20(token1).balanceOf(FEE_RECIPIENT);
        uint256 owner0Before = IERC20(token0).balanceOf(address(this));
        uint256 owner1Before = IERC20(token1).balanceOf(address(this));

        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: tokenId,
            recipient: makeAddr("ignoredRecipient"),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });
        v3Protocol.claimAMMFees(abi.encode(collectParams));

        _assertFeeSplit(
            IERC20(token0).balanceOf(FEE_RECIPIENT) - feeRec0Before,
            IERC20(token0).balanceOf(address(this)) - owner0Before,
            COLLECT_FEE_BPS
        );
        _assertFeeSplit(
            IERC20(token1).balanceOf(FEE_RECIPIENT) - feeRec1Before,
            IERC20(token1).balanceOf(address(this)) - owner1Before,
            COLLECT_FEE_BPS
        );
    }

    function test_V3_RemoveLiquidity() public {
        uint256 tokenId = _mintV3PositionAndGetTokenId();

        uint256 liquidityAfterMint = v3Protocol.getLiquidity(abi.encode(tokenId));
        assertGt(liquidityAfterMint, 0, "liquidity after mint");

        INonfungiblePositionManager.DecreaseLiquidityParams memory decreaseParams =
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId, liquidity: 0, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            });
        v3Protocol.removeLiquidity(abi.encode(decreaseParams));

        assertEq(v3Protocol.getLiquidity(abi.encode(tokenId)), 0, "liquidity must be zero after remove");

        address token0 = mainnet.WETH < mainnet.USDC ? mainnet.WETH : mainnet.USDC;
        address token1 = mainnet.WETH < mainnet.USDC ? mainnet.USDC : mainnet.WETH;
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        assertTrue(balance0 > 0 || balance1 > 0, "should receive tokens from decrease and collect");
    }

    function test_V3_RemoveLiquidity_CollectsTokensDirectly() public {
        uint256 tokenId = _mintV3PositionAndGetTokenId();

        address token0 = mainnet.WETH < mainnet.USDC ? mainnet.WETH : mainnet.USDC;
        address token1 = mainnet.WETH < mainnet.USDC ? mainnet.USDC : mainnet.WETH;

        uint128 liquidity = uint128(v3Protocol.getLiquidity(abi.encode(tokenId)));
        assertGt(liquidity, 0, "liquidity before remove");

        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));

        INonfungiblePositionManager.DecreaseLiquidityParams memory decreaseParams =
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId, liquidity: 0, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            });

        v3Protocol.removeLiquidity(abi.encode(decreaseParams));

        uint256 balance0After = IERC20(token0).balanceOf(address(this));
        uint256 balance1After = IERC20(token1).balanceOf(address(this));

        assertTrue(
            balance0After > balance0Before || balance1After > balance1Before, "tokens must arrive without claimAMMFees"
        );
        assertEq(IERC20(token0).balanceOf(address(v3Protocol)), 0, "protocol must hold no token0");
        assertEq(IERC20(token1).balanceOf(address(v3Protocol)), 0, "protocol must hold no token1");
        assertEq(v3Protocol.getLiquidity(abi.encode(tokenId)), 0, "liquidity must be zero after full removal");
    }

    function test_V3_RemoveLiquidity_ClaimsAccruedFeesWithCollectFeeAndRemovesAllLiquidity() public {
        uint256 tokenId = _mintV3PositionAndGetTokenId();

        address token0 = mainnet.WETH < mainnet.USDC ? mainnet.WETH : mainnet.USDC;
        address token1 = mainnet.WETH < mainnet.USDC ? mainnet.USDC : mainnet.WETH;

        _swapOnPoolToAccruePositionFees(token0, token1);

        assertGt(v3Protocol.getLiquidity(abi.encode(tokenId)), 0, "liquidity before remove");

        uint256 feeRec0Before = IERC20(token0).balanceOf(FEE_RECIPIENT);
        uint256 feeRec1Before = IERC20(token1).balanceOf(FEE_RECIPIENT);
        uint256 owner0Before = IERC20(token0).balanceOf(address(this));
        uint256 owner1Before = IERC20(token1).balanceOf(address(this));

        INonfungiblePositionManager.DecreaseLiquidityParams memory decreaseParams =
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId, liquidity: 0, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            });
        v3Protocol.removeLiquidity(abi.encode(decreaseParams));

        assertTrue(
            IERC20(token0).balanceOf(FEE_RECIPIENT) - feeRec0Before > 0
                || IERC20(token1).balanceOf(FEE_RECIPIENT) - feeRec1Before > 0,
            "fee recipient receives collect fee on accrued fees"
        );
        assertTrue(
            IERC20(token0).balanceOf(address(this)) > owner0Before
                || IERC20(token1).balanceOf(address(this)) > owner1Before,
            "owner receives principal and net fees"
        );
        assertEq(v3Protocol.getLiquidity(abi.encode(tokenId)), 0, "all liquidity removed");
    }

    function test_V3_RemoveLiquidity_DoesNotChargeCollectFeeWhenNoAccruedFees() public {
        uint256 tokenId = _mintV3PositionAndGetTokenId();

        address token0 = mainnet.WETH < mainnet.USDC ? mainnet.WETH : mainnet.USDC;
        address token1 = mainnet.WETH < mainnet.USDC ? mainnet.USDC : mainnet.WETH;

        uint128 liquidity = uint128(v3Protocol.getLiquidity(abi.encode(tokenId)));
        assertGt(liquidity, 0, "liquidity before remove");

        uint256 feeRec0Before = IERC20(token0).balanceOf(FEE_RECIPIENT);
        uint256 feeRec1Before = IERC20(token1).balanceOf(FEE_RECIPIENT);
        uint256 owner0Before = IERC20(token0).balanceOf(address(this));
        uint256 owner1Before = IERC20(token1).balanceOf(address(this));

        INonfungiblePositionManager.DecreaseLiquidityParams memory decreaseParams =
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId, liquidity: 0, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            });
        v3Protocol.removeLiquidity(abi.encode(decreaseParams));

        assertEq(IERC20(token0).balanceOf(FEE_RECIPIENT) - feeRec0Before, 0, "no collect fee on principal");
        assertEq(IERC20(token1).balanceOf(FEE_RECIPIENT) - feeRec1Before, 0, "no collect fee on principal");
        assertTrue(
            IERC20(token0).balanceOf(address(this)) > owner0Before
                || IERC20(token1).balanceOf(address(this)) > owner1Before,
            "owner must receive full principal"
        );
    }

    function _swapOnPoolToAccruePositionFees(address token0, address token1) internal {
        bool wethIsToken0 = token0 == mainnet.WETH;
        address tokenIn = wethIsToken0 ? token0 : token1;
        address tokenOut = wethIsToken0 ? token1 : token0;

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;

        bytes memory encodedPath = Path.encodePath(path, fees);
        uint256 swapAmount = tokenIn == mainnet.WETH ? 2 ether : 5000 * 1e6;

        deal(tokenIn, address(this), swapAmount);
        IERC20(tokenIn).forceApprove(mainnet.UNISWAP_V3_ROUTER, swapAmount);

        IUniswapV3Router(mainnet.UNISWAP_V3_ROUTER)
            .exactInput(
                IUniswapV3Router.ExactInputParams({
                    path: encodedPath, recipient: address(this), amountIn: swapAmount, amountOutMinimum: 0
                })
            );
    }

    function test_V3_AddLiquidity_Mint_ReturnsUnusedTokens() public {
        address token0 = mainnet.WETH < mainnet.USDC ? mainnet.WETH : mainnet.USDC;
        address token1 = mainnet.WETH < mainnet.USDC ? mainnet.USDC : mainnet.WETH;
        uint24 fee = 3000;
        int24 tickSpacing = 60;

        address pool =
            IUniswapV3Factory(IUniswapV3Router(mainnet.UNISWAP_V3_ROUTER).factory()).getPool(token0, token1, fee);
        (, int24 currentTick,,,,,) = IUniswapV3Pool(pool).slot0();
        int24 tickLower = (currentTick / tickSpacing) * tickSpacing - tickSpacing * 10;
        int24 tickUpper = (currentTick / tickSpacing) * tickSpacing + tickSpacing * 10;

        uint256 amount0Desired = token0 == mainnet.WETH ? 1 ether : 5000 * 1e6;
        uint256 amount1Desired = token1 == mainnet.WETH ? 1 ether : 5000 * 1e6;

        deal(token0, address(this), amount0Desired);
        deal(token1, address(this), amount1Desired);
        IERC20(token0).forceApprove(address(v3Protocol), amount0Desired);
        IERC20(token1).forceApprove(address(v3Protocol), amount1Desired);

        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));

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
        v3Protocol.addLiquidity(abi.encode(true, abi.encode(mintParams)));

        uint256 balance0After = IERC20(token0).balanceOf(address(this));
        uint256 balance1After = IERC20(token1).balanceOf(address(this));

        uint256 used0 = balance0Before - balance0After;
        uint256 used1 = balance1Before - balance1After;
        assertLe(used0, amount0Desired, "used0 exceeds desired");
        assertLe(used1, amount1Desired, "used1 exceeds desired");
        assertTrue(used0 < amount0Desired || used1 < amount1Desired, "at least one token should have leftover");
        assertEq(IERC20(token0).balanceOf(address(v3Protocol)), 0, "protocol clone must hold no token0");
        assertEq(IERC20(token1).balanceOf(address(v3Protocol)), 0, "protocol clone must hold no token1");
    }

    function test_V3_AddLiquidity_IncreaseLiquidity_ReturnsUnusedTokens() public {
        uint256 tokenId = _mintV3PositionAndGetTokenId();

        address token0 = mainnet.WETH < mainnet.USDC ? mainnet.WETH : mainnet.USDC;
        address token1 = mainnet.WETH < mainnet.USDC ? mainnet.USDC : mainnet.WETH;

        uint256 amount0Desired = token0 == mainnet.WETH ? 1 ether : 5000 * 1e6;
        uint256 amount1Desired = token1 == mainnet.WETH ? 1 ether : 5000 * 1e6;

        deal(token0, address(this), amount0Desired);
        deal(token1, address(this), amount1Desired);
        IERC20(token0).forceApprove(address(v3Protocol), amount0Desired);
        IERC20(token1).forceApprove(address(v3Protocol), amount1Desired);

        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));

        INonfungiblePositionManager.IncreaseLiquidityParams memory increaseParams =
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            });
        v3Protocol.addLiquidity(abi.encode(false, abi.encode(increaseParams)));

        uint256 balance0After = IERC20(token0).balanceOf(address(this));
        uint256 balance1After = IERC20(token1).balanceOf(address(this));

        uint256 used0 = balance0Before - balance0After;
        uint256 used1 = balance1Before - balance1After;
        assertLe(used0, amount0Desired, "used0 exceeds desired");
        assertLe(used1, amount1Desired, "used1 exceeds desired");
        assertTrue(used0 < amount0Desired || used1 < amount1Desired, "at least one token should have leftover");
        assertEq(IERC20(token0).balanceOf(address(v3Protocol)), 0, "protocol clone must hold no token0");
        assertEq(IERC20(token1).balanceOf(address(v3Protocol)), 0, "protocol clone must hold no token1");
    }

    function test_V3_DecreaseLiquidity_DoesNotChargeCollectFee() public {
        uint256 tokenId = _mintV3PositionAndGetTokenId();

        address token0 = mainnet.WETH < mainnet.USDC ? mainnet.WETH : mainnet.USDC;
        address token1 = mainnet.WETH < mainnet.USDC ? mainnet.USDC : mainnet.WETH;

        uint256 liquidityBefore = v3Protocol.getLiquidity(abi.encode(tokenId));
        assertGt(liquidityBefore, 0, "liquidity before decrease");

        uint128 liquidityToDecrease = uint128(liquidityBefore / 2);

        uint256 feeRec0Before = IERC20(token0).balanceOf(FEE_RECIPIENT);
        uint256 feeRec1Before = IERC20(token1).balanceOf(FEE_RECIPIENT);
        uint256 owner0Before = IERC20(token0).balanceOf(address(this));
        uint256 owner1Before = IERC20(token1).balanceOf(address(this));

        INonfungiblePositionManager.DecreaseLiquidityParams memory decreaseParams =
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidityToDecrease,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            });
        v3Protocol.decreaseLiquidity(abi.encode(decreaseParams));

        assertEq(
            v3Protocol.getLiquidity(abi.encode(tokenId)),
            liquidityBefore - liquidityToDecrease,
            "liquidity after decrease"
        );

        assertEq(IERC20(token0).balanceOf(FEE_RECIPIENT) - feeRec0Before, 0, "no collect fee on decrease");
        assertEq(IERC20(token1).balanceOf(FEE_RECIPIENT) - feeRec1Before, 0, "no collect fee on decrease");
        assertTrue(
            IERC20(token0).balanceOf(address(this)) > owner0Before
                || IERC20(token1).balanceOf(address(this)) > owner1Before,
            "owner must receive full decreased principal"
        );
    }

    function test_V3_DecreaseLiquidity_FullPositionClaimsAccruedFeesWithCollectFee() public {
        uint256 tokenId = _mintV3PositionAndGetTokenId();

        address token0 = mainnet.WETH < mainnet.USDC ? mainnet.WETH : mainnet.USDC;
        address token1 = mainnet.WETH < mainnet.USDC ? mainnet.USDC : mainnet.WETH;

        _swapOnPoolToAccruePositionFees(token0, token1);

        uint128 liquidity = uint128(v3Protocol.getLiquidity(abi.encode(tokenId)));

        uint256 feeRec0Before = IERC20(token0).balanceOf(FEE_RECIPIENT);
        uint256 feeRec1Before = IERC20(token1).balanceOf(FEE_RECIPIENT);
        uint256 owner0Before = IERC20(token0).balanceOf(address(this));
        uint256 owner1Before = IERC20(token1).balanceOf(address(this));

        INonfungiblePositionManager.DecreaseLiquidityParams memory decreaseParams =
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId, liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            });
        v3Protocol.decreaseLiquidity(abi.encode(decreaseParams));

        assertEq(v3Protocol.getLiquidity(abi.encode(tokenId)), 0, "full position liquidity removed");

        uint256 feeRec0Received = IERC20(token0).balanceOf(FEE_RECIPIENT) - feeRec0Before;
        uint256 feeRec1Received = IERC20(token1).balanceOf(FEE_RECIPIENT) - feeRec1Before;
        uint256 owner0Received = IERC20(token0).balanceOf(address(this)) - owner0Before;
        uint256 owner1Received = IERC20(token1).balanceOf(address(this)) - owner1Before;

        assertTrue(feeRec0Received > 0 || feeRec1Received > 0, "fee recipient receives collect fee on accrued fees");
        assertTrue(owner0Received > 0 || owner1Received > 0, "owner receives principal and net fees");
        assertLt(feeRec0Received, owner0Received, "collect fee must be less than total token0 received");
        assertLt(feeRec1Received, owner1Received, "collect fee must be less than total token1 received");

        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: tokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
        });
        uint256 owner0BeforeSecondClaim = IERC20(token0).balanceOf(address(this));
        uint256 owner1BeforeSecondClaim = IERC20(token1).balanceOf(address(this));
        v3Protocol.claimAMMFees(abi.encode(collectParams));
        assertEq(IERC20(token0).balanceOf(address(this)), owner0BeforeSecondClaim, "no fees left after full decrease");
        assertEq(IERC20(token1).balanceOf(address(this)), owner1BeforeSecondClaim, "no fees left after full decrease");
    }

    function test_V3_DecreaseLiquidity_PartialDoesNotCollectAccruedFees() public {
        uint256 tokenId = _mintV3PositionAndGetTokenId();

        address token0 = mainnet.WETH < mainnet.USDC ? mainnet.WETH : mainnet.USDC;
        address token1 = mainnet.WETH < mainnet.USDC ? mainnet.USDC : mainnet.WETH;

        _swapOnPoolToAccruePositionFees(token0, token1);

        uint256 liquidityBefore = v3Protocol.getLiquidity(abi.encode(tokenId));
        uint128 liquidityToDecrease = uint128(liquidityBefore / 2);

        uint256 owner0Before = IERC20(token0).balanceOf(address(this));
        uint256 owner1Before = IERC20(token1).balanceOf(address(this));

        INonfungiblePositionManager.DecreaseLiquidityParams memory decreaseParams =
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidityToDecrease,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            });
        v3Protocol.decreaseLiquidity(abi.encode(decreaseParams));

        uint256 owner0AfterDecrease = IERC20(token0).balanceOf(address(this));
        uint256 owner1AfterDecrease = IERC20(token1).balanceOf(address(this));

        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: tokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
        });
        v3Protocol.claimAMMFees(abi.encode(collectParams));

        assertTrue(
            IERC20(token0).balanceOf(address(this)) > owner0AfterDecrease
                || IERC20(token1).balanceOf(address(this)) > owner1AfterDecrease,
            "accrued fees still collectible after partial decreaseLiquidity"
        );
    }

    receive() external payable {}
}

