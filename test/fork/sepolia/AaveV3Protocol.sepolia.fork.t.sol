// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {AaveV3Protocol} from "protocol-contracts/src/protocols/AaveV3Protocol.sol";
import {sepolia} from "../../../script/addresses.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IAaveV3, IAavePool, IPoolDataProvider} from "protocol-contracts/src/libs/aave/v3/Aave.sol";

contract TestAaveV3ProtocolSepoliaFork is Test {
    using SafeERC20 for IERC20;

    AaveV3Protocol public aaveProtocol;
    IPoolDataProvider public poolDataProvider;

    function setUp() public {
        vm.createSelectFork("sepolia");
        aaveProtocol = new AaveV3Protocol(sepolia.AAVE_V3, sepolia.POOL_DATA_PROVIDER);
        aaveProtocol.initialize(address(this));
        poolDataProvider = IPoolDataProvider(sepolia.POOL_DATA_PROVIDER);
    }

    function test_Supply() public {
        deal(sepolia.AAVE_WETH, address(this), 1 ether);
        IERC20(sepolia.AAVE_WETH).forceApprove(address(aaveProtocol), 1 ether);
        uint256 balanceBefore = IERC20(sepolia.AAVE_WETH).balanceOf(address(this));

        aaveProtocol.supply(sepolia.AAVE_WETH, 1 ether);

        assertEq(IERC20(sepolia.AAVE_WETH).balanceOf(address(this)), balanceBefore - 1 ether);
        (uint256 currentATokenBalance,,,,,,,,) = poolDataProvider.getUserReserveData(sepolia.AAVE_WETH, address(this));
        assertApproxEqAbs(currentATokenBalance, 1 ether, 10);
    }

    function test_Withdraw() public {
        deal(sepolia.AAVE_WETH, address(this), 1 ether);
        IERC20(sepolia.AAVE_WETH).forceApprove(address(aaveProtocol), 1 ether);
        uint256 balanceBeforeSupply = IERC20(sepolia.AAVE_WETH).balanceOf(address(this));
        aaveProtocol.supply(sepolia.AAVE_WETH, 1 ether);

        (uint256 aTokenBalance,,,,,,,,) = poolDataProvider.getUserReserveData(sepolia.AAVE_WETH, address(this));

        assertEq(IERC20(sepolia.AAVE_WETH).balanceOf(address(aaveProtocol)), 0);

        address aToken = aaveProtocol.receiptTokenOf(sepolia.AAVE_WETH);
        IERC20(aToken).forceApprove(address(aaveProtocol), aTokenBalance);
        aaveProtocol.withdraw(sepolia.AAVE_WETH, aTokenBalance, address(this));

        assertEq(IERC20(sepolia.AAVE_WETH).balanceOf(address(aaveProtocol)), 0);
        assertApproxEqAbs(IERC20(sepolia.AAVE_WETH).balanceOf(address(this)), balanceBeforeSupply, 5);

        (uint256 currentATokenBalance,,,,,,,,) = poolDataProvider.getUserReserveData(sepolia.AAVE_WETH, address(this));
        assertEq(currentATokenBalance, 0);
    }

    function test_GetBalance() public {
        assertEq(aaveProtocol.getSuppliedBalance(sepolia.AAVE_WETH), 0);

        deal(sepolia.AAVE_WETH, address(this), 1 ether);
        IERC20(sepolia.AAVE_WETH).forceApprove(address(aaveProtocol), 1 ether);
        aaveProtocol.supply(sepolia.AAVE_WETH, 1 ether);

        uint256 balanceAfter = aaveProtocol.getSuppliedBalance(sepolia.AAVE_WETH);
        assertApproxEqAbs(balanceAfter, 1 ether, 10);

        (uint256 currentATokenBalance,,,,,,,,) = poolDataProvider.getUserReserveData(sepolia.AAVE_WETH, address(this));
        assertEq(balanceAfter, currentATokenBalance);
    }

    function test_Supply_UsesMaxApproval() public {
        deal(sepolia.AAVE_WETH, address(this), 1 ether);
        IERC20(sepolia.AAVE_WETH).forceApprove(address(aaveProtocol), 1 ether);
        aaveProtocol.supply(sepolia.AAVE_WETH, 1 ether);

        address pool = address(IAaveV3(sepolia.AAVE_V3).getPool());
        uint256 remaining = IERC20(sepolia.AAVE_WETH).allowance(address(aaveProtocol), pool);
        assertGe(remaining, type(uint256).max / 2, "pool must keep a standing max approval after supply");
    }
}
