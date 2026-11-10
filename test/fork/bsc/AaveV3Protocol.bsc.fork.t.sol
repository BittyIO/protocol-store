// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {TestProxy} from "../../helpers/Proxy.sol";
import {Test} from "forge-std/Test.sol";
import {AaveV3Protocol} from "protocol-contracts/src/protocols/AaveV3Protocol.sol";
import {bsc} from "../../../script/addresses.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IAaveV3, IPoolDataProvider} from "protocol-contracts/src/libs/aave/v3/Aave.sol";

/**
 * Aave V3 BNB Market: the same adapter as every other chain, against BSC's pool. Run for WBNB (the
 * gas token's wrapper) and for USDT, an 18-decimal stable coin here.
 */
contract TestAaveV3ProtocolBscFork is Test {
    using SafeERC20 for IERC20;

    AaveV3Protocol public aaveProtocol;
    IPoolDataProvider public poolDataProvider;

    function setUp() public {
        vm.createSelectFork("bsc");
        aaveProtocol = AaveV3Protocol(
            TestProxy.deploy(address(new AaveV3Protocol(bsc.AAVE_V3, bsc.POOL_DATA_PROVIDER)), address(this))
        );
        poolDataProvider = IPoolDataProvider(bsc.POOL_DATA_PROVIDER);
    }

    function _supplyAndWithdraw(address asset, uint256 amount) internal {
        deal(asset, address(this), amount);
        IERC20(asset).forceApprove(address(aaveProtocol), amount);
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));

        aaveProtocol.deposit(asset, amount);

        assertEq(IERC20(asset).balanceOf(address(this)), balanceBefore - amount);
        (uint256 aTokenBalance,,,,,,,,) = poolDataProvider.getUserReserveData(asset, address(this));
        assertApproxEqAbs(aTokenBalance, amount, 10);
        assertEq(aaveProtocol.getBalance(asset), aTokenBalance);

        address aToken = aaveProtocol.receiptTokenOf(asset);
        IERC20(aToken).forceApprove(address(aaveProtocol), aTokenBalance);
        aaveProtocol.withdraw(asset, aTokenBalance, address(this));

        assertEq(IERC20(asset).balanceOf(address(aaveProtocol)), 0);
        assertApproxEqAbs(IERC20(asset).balanceOf(address(this)), balanceBefore, 5);
        (uint256 after_,,,,,,,,) = poolDataProvider.getUserReserveData(asset, address(this));
        assertEq(after_, 0);
    }

    function test_SupplyWithdraw_WBNB() public {
        _supplyAndWithdraw(bsc.WBNB, 1 ether);
    }

    function test_SupplyWithdraw_USDT() public {
        _supplyAndWithdraw(bsc.USDT, 1000e18);
    }

    function test_Supply_UsesMaxApproval() public {
        deal(bsc.WBNB, address(this), 1 ether);
        IERC20(bsc.WBNB).forceApprove(address(aaveProtocol), 1 ether);
        aaveProtocol.deposit(bsc.WBNB, 1 ether);

        address pool = address(IAaveV3(bsc.AAVE_V3).getPool());
        uint256 remaining = IERC20(bsc.WBNB).allowance(address(aaveProtocol), pool);
        assertGe(remaining, type(uint256).max / 2, "pool must keep a standing max approval after supply");
    }
}
