// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {AaveV3Protocol} from "protocol-contracts/src/protocols/AaveV3Protocol.sol";
import {mainnet} from "../../../script/addresses.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";
import {IAaveV3, IAavePool, IPoolDataProvider} from "protocol-contracts/src/libs/aave/v3/Aave.sol";

contract TestAaveProtocolFork is Test {
    using SafeERC20 for IERC20;
    using Address for address;

    AaveV3Protocol public aaveProtocol;
    IPoolDataProvider public poolDataProvider;

    function setUp() public {
        vm.createSelectFork("mainnet");
        aaveProtocol = new AaveV3Protocol(mainnet.AAVE_V3, mainnet.POOL_DATA_PROVIDER);
        aaveProtocol.initialize(address(this));
        poolDataProvider = IPoolDataProvider(mainnet.POOL_DATA_PROVIDER);
    }

    function test_Supply() public {
        IERC20(address(mainnet.WETH)).safeApprove(address(aaveProtocol), 1 ether);
        deal(address(mainnet.WETH), address(this), 1 ether);
        uint256 balanceBefore = IERC20(address(mainnet.WETH)).balanceOf(address(this));

        aaveProtocol.supply(address(mainnet.WETH), 1 ether);

        uint256 balanceAfter = IERC20(address(mainnet.WETH)).balanceOf(address(this));
        assertEq(balanceAfter, balanceBefore - 1 ether);

        (uint256 currentATokenBalance,,,,,,,,) =
            poolDataProvider.getUserReserveData(address(mainnet.WETH), address(aaveProtocol));
        assertApproxEqAbs(currentATokenBalance, 1 ether, 10);
    }

    function test_Withdraw() public {
        IERC20(address(mainnet.WETH)).safeApprove(address(aaveProtocol), 1 ether);
        deal(address(mainnet.WETH), address(this), 1 ether);
        uint256 balanceBeforeSupply = IERC20(address(mainnet.WETH)).balanceOf(address(this));
        aaveProtocol.supply(address(mainnet.WETH), 1 ether);

        (uint256 aTokenBalance,,,,,,,,) =
            poolDataProvider.getUserReserveData(address(mainnet.WETH), address(aaveProtocol));

        uint256 aaveProtocolBalanceBefore = IERC20(address(mainnet.WETH)).balanceOf(address(aaveProtocol));
        assertEq(aaveProtocolBalanceBefore, 0);

        aaveProtocol.withdraw(address(mainnet.WETH), aTokenBalance);

        uint256 aaveProtocolBalanceAfter = IERC20(address(mainnet.WETH)).balanceOf(address(aaveProtocol));
        assertEq(aaveProtocolBalanceAfter, 0);

        uint256 balanceAfterWithdraw = IERC20(address(mainnet.WETH)).balanceOf(address(this));
        assertApproxEqAbs(balanceAfterWithdraw, balanceBeforeSupply, 5);

        (uint256 currentATokenBalance,,,,,,,,) =
            poolDataProvider.getUserReserveData(address(mainnet.WETH), address(aaveProtocol));
        assertEq(currentATokenBalance, 0);
    }

    function test_Withdraw_UsesActualReturnedAmountNotInput() public {
        address asset = address(mainnet.WETH);
        uint256 requestAmount = 1000e18;
        // Aave returns less than requested for rounding or liquidity reasons
        uint256 mockReturnedAmount = 999e18;

        IAavePool pool = IAaveV3(mainnet.AAVE_V3).getPool();

        deal(asset, address(aaveProtocol), mockReturnedAmount);

        vm.mockCall(
            address(pool),
            abi.encodeWithSelector(IAavePool.withdraw.selector, asset, requestAmount, address(aaveProtocol)),
            abi.encode(mockReturnedAmount)
        );

        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        aaveProtocol.withdraw(asset, requestAmount);
        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));

        assertEq(balanceAfter - balanceBefore, mockReturnedAmount, "Must transfer actual returned amount, not input");
    }

    function test_GetBalance() public {
        uint256 balanceBefore = aaveProtocol.getSuppliedBalance(address(mainnet.WETH));
        assertEq(balanceBefore, 0);

        IERC20(address(mainnet.WETH)).safeApprove(address(aaveProtocol), 1 ether);
        deal(address(mainnet.WETH), address(this), 1 ether);
        aaveProtocol.supply(address(mainnet.WETH), 1 ether);

        uint256 balanceAfter = aaveProtocol.getSuppliedBalance(address(mainnet.WETH));
        assertApproxEqAbs(balanceAfter, 1 ether, 10);

        (uint256 currentATokenBalance,,,,,,,,) =
            poolDataProvider.getUserReserveData(address(mainnet.WETH), address(aaveProtocol));
        assertEq(balanceAfter, currentATokenBalance);
    }

    function test_Supply_ResetsApprovalToZero() public {
        deal(address(mainnet.WETH), address(this), 1 ether);
        IERC20(address(mainnet.WETH)).safeApprove(address(aaveProtocol), 1 ether);

        aaveProtocol.supply(address(mainnet.WETH), 1 ether);

        address pool = address(IAaveV3(mainnet.AAVE_V3).getPool());
        uint256 remaining = IERC20(address(mainnet.WETH)).allowance(address(aaveProtocol), pool);
        assertEq(remaining, 0, "approval to Aave pool must be 0 after supply");
    }

    function test_SupplyMultipleAssets() public {
        IERC20(address(mainnet.WETH)).safeApprove(address(aaveProtocol), 1 ether);
        deal(address(mainnet.WETH), address(this), 1 ether);
        aaveProtocol.supply(address(mainnet.WETH), 1 ether);

        uint256 wethBalance = aaveProtocol.getSuppliedBalance(address(mainnet.WETH));
        assertApproxEqAbs(wethBalance, 1 ether, 10);

        deal(address(mainnet.USDC), address(this), 1000e6);
        IERC20(address(mainnet.USDC)).safeApprove(address(aaveProtocol), 1000e6);
        aaveProtocol.supply(address(mainnet.USDC), 1000e6);

        uint256 usdcBalance = aaveProtocol.getSuppliedBalance(address(mainnet.USDC));
        assertApproxEqAbs(usdcBalance, 1000e6, 10);
    }
}

