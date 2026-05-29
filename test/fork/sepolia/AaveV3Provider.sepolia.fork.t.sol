// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {AaveV3Provider} from "provider-contracts/src/providers/AaveV3Provider.sol";
import {sepolia} from "../../../script/addresses.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IAaveV3, IAavePool, IPoolDataProvider} from "provider-contracts/src/libs/aave/v3/Aave.sol";

contract TestAaveV3ProviderSepoliaFork is Test {
    using SafeERC20 for IERC20;

    AaveV3Provider public aaveProvider;
    IPoolDataProvider public poolDataProvider;

    function setUp() public {
        vm.createSelectFork("sepolia");
        aaveProvider = new AaveV3Provider(sepolia.AAVE_V3, sepolia.POOL_DATA_PROVIDER);
        aaveProvider.initialize(address(this));
        poolDataProvider = IPoolDataProvider(sepolia.POOL_DATA_PROVIDER);
    }

    function test_Supply() public {
        deal(sepolia.AAVE_WETH, address(this), 1 ether);
        IERC20(sepolia.AAVE_WETH).safeApprove(address(aaveProvider), 1 ether);
        uint256 balanceBefore = IERC20(sepolia.AAVE_WETH).balanceOf(address(this));

        aaveProvider.supply(sepolia.AAVE_WETH, 1 ether);

        assertEq(IERC20(sepolia.AAVE_WETH).balanceOf(address(this)), balanceBefore - 1 ether);
        (uint256 currentATokenBalance,,,,,,,,) =
            poolDataProvider.getUserReserveData(sepolia.AAVE_WETH, address(aaveProvider));
        assertApproxEqAbs(currentATokenBalance, 1 ether, 10);
    }

    function test_Withdraw() public {
        deal(sepolia.AAVE_WETH, address(this), 1 ether);
        IERC20(sepolia.AAVE_WETH).safeApprove(address(aaveProvider), 1 ether);
        uint256 balanceBeforeSupply = IERC20(sepolia.AAVE_WETH).balanceOf(address(this));
        aaveProvider.supply(sepolia.AAVE_WETH, 1 ether);

        (uint256 aTokenBalance,,,,,,,,) =
            poolDataProvider.getUserReserveData(sepolia.AAVE_WETH, address(aaveProvider));

        assertEq(IERC20(sepolia.AAVE_WETH).balanceOf(address(aaveProvider)), 0);

        aaveProvider.withdraw(sepolia.AAVE_WETH, aTokenBalance);

        assertEq(IERC20(sepolia.AAVE_WETH).balanceOf(address(aaveProvider)), 0);
        assertApproxEqAbs(IERC20(sepolia.AAVE_WETH).balanceOf(address(this)), balanceBeforeSupply, 5);

        (uint256 currentATokenBalance,,,,,,,,) =
            poolDataProvider.getUserReserveData(sepolia.AAVE_WETH, address(aaveProvider));
        assertEq(currentATokenBalance, 0);
    }

    function test_GetBalance() public {
        assertEq(aaveProvider.getSuppliedBalance(sepolia.AAVE_WETH), 0);

        deal(sepolia.AAVE_WETH, address(this), 1 ether);
        IERC20(sepolia.AAVE_WETH).safeApprove(address(aaveProvider), 1 ether);
        aaveProvider.supply(sepolia.AAVE_WETH, 1 ether);

        uint256 balanceAfter = aaveProvider.getSuppliedBalance(sepolia.AAVE_WETH);
        assertApproxEqAbs(balanceAfter, 1 ether, 10);

        (uint256 currentATokenBalance,,,,,,,,) =
            poolDataProvider.getUserReserveData(sepolia.AAVE_WETH, address(aaveProvider));
        assertEq(balanceAfter, currentATokenBalance);
    }

    function test_Supply_ResetsApprovalToZero() public {
        deal(sepolia.AAVE_WETH, address(this), 1 ether);
        IERC20(sepolia.AAVE_WETH).safeApprove(address(aaveProvider), 1 ether);
        aaveProvider.supply(sepolia.AAVE_WETH, 1 ether);

        address pool = address(IAaveV3(sepolia.AAVE_V3).getPool());
        assertEq(IERC20(sepolia.AAVE_WETH).allowance(address(aaveProvider), pool), 0);
    }
}
