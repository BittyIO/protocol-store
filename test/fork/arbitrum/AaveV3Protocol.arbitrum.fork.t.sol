// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {TestProxy} from "../../helpers/Proxy.sol";
import {Test} from "forge-std/Test.sol";
import {AaveV3Protocol} from "protocol-contracts/src/protocols/AaveV3Protocol.sol";
import {arbitrum} from "../../../script/addresses.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IAaveV3, IPoolDataProvider} from "protocol-contracts/src/libs/aave/v3/Aave.sol";

contract TestAaveV3ProtocolArbitrumFork is Test {
    using SafeERC20 for IERC20;

    AaveV3Protocol public aaveProtocol;
    IPoolDataProvider public poolDataProvider;

    function setUp() public {
        vm.createSelectFork("arbitrum");
        aaveProtocol = AaveV3Protocol(
            TestProxy.deploy(address(new AaveV3Protocol(arbitrum.AAVE_V3, arbitrum.POOL_DATA_PROVIDER)), address(this))
        );
        poolDataProvider = IPoolDataProvider(arbitrum.POOL_DATA_PROVIDER);
    }

    function test_Supply() public {
        deal(arbitrum.WETH, address(this), 1 ether);
        IERC20(arbitrum.WETH).forceApprove(address(aaveProtocol), 1 ether);
        uint256 balanceBefore = IERC20(arbitrum.WETH).balanceOf(address(this));

        aaveProtocol.deposit(arbitrum.WETH, 1 ether);

        assertEq(IERC20(arbitrum.WETH).balanceOf(address(this)), balanceBefore - 1 ether);
        (uint256 currentATokenBalance,,,,,,,,) = poolDataProvider.getUserReserveData(arbitrum.WETH, address(this));
        assertApproxEqAbs(currentATokenBalance, 1 ether, 10);
    }

    function test_Withdraw() public {
        deal(arbitrum.WETH, address(this), 1 ether);
        IERC20(arbitrum.WETH).forceApprove(address(aaveProtocol), 1 ether);
        uint256 balanceBeforeSupply = IERC20(arbitrum.WETH).balanceOf(address(this));
        aaveProtocol.deposit(arbitrum.WETH, 1 ether);

        (uint256 aTokenBalance,,,,,,,,) = poolDataProvider.getUserReserveData(arbitrum.WETH, address(this));

        assertEq(IERC20(arbitrum.WETH).balanceOf(address(aaveProtocol)), 0);

        address aToken = aaveProtocol.receiptTokenOf(arbitrum.WETH);
        IERC20(aToken).forceApprove(address(aaveProtocol), aTokenBalance);
        aaveProtocol.withdraw(arbitrum.WETH, aTokenBalance, address(this));

        assertEq(IERC20(arbitrum.WETH).balanceOf(address(aaveProtocol)), 0);
        assertApproxEqAbs(IERC20(arbitrum.WETH).balanceOf(address(this)), balanceBeforeSupply, 5);

        (uint256 currentATokenBalance,,,,,,,,) = poolDataProvider.getUserReserveData(arbitrum.WETH, address(this));
        assertEq(currentATokenBalance, 0);
    }

    function test_GetBalance() public {
        assertEq(aaveProtocol.getBalance(arbitrum.WETH), 0);

        deal(arbitrum.WETH, address(this), 1 ether);
        IERC20(arbitrum.WETH).forceApprove(address(aaveProtocol), 1 ether);
        aaveProtocol.deposit(arbitrum.WETH, 1 ether);

        uint256 balanceAfter = aaveProtocol.getBalance(arbitrum.WETH);
        assertApproxEqAbs(balanceAfter, 1 ether, 10);

        (uint256 currentATokenBalance,,,,,,,,) = poolDataProvider.getUserReserveData(arbitrum.WETH, address(this));
        assertEq(balanceAfter, currentATokenBalance);
    }

    function test_Supply_UsesMaxApproval() public {
        deal(arbitrum.WETH, address(this), 1 ether);
        IERC20(arbitrum.WETH).forceApprove(address(aaveProtocol), 1 ether);
        aaveProtocol.deposit(arbitrum.WETH, 1 ether);

        address pool = address(IAaveV3(arbitrum.AAVE_V3).getPool());
        uint256 remaining = IERC20(arbitrum.WETH).allowance(address(aaveProtocol), pool);
        assertGe(remaining, type(uint256).max / 2, "pool must keep a standing max approval after supply");
    }
}
