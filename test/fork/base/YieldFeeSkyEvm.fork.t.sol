// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {TestProxy} from "../../helpers/Proxy.sol";
import {Test} from "forge-std/Test.sol";
import {SkyV1EvmProtocol} from "protocol-contracts/src/protocols/SkyV1EvmProtocol.sol";
import {base} from "../../../script/addresses.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// The yield fee on Sky's PSM3 adapter (Base; Arbitrum runs the same code). The test plays the vault.
contract YieldFeeSkyEvmFork is Test {
    address constant COLLECTOR = 0xF0E7f6998B362BD15CF819C7EBfcaCe8865FECA0;
    address payee = makeAddr("payee");
    SkyV1EvmProtocol sky;
    IERC20 usdc = IERC20(base.USDC);

    function setUp() public {
        vm.createSelectFork("base");
        uint256 t0 = block.timestamp;
        sky = SkyV1EvmProtocol(
            TestProxy.deploy(address(new SkyV1EvmProtocol(base.USDC, base.S_USDS, base.SKY_PSM3)), address(this))
        );
        deal(address(usdc), address(this), 1_000_000e6);
        usdc.approve(address(sky), type(uint256).max);
        sky.deposit(address(usdc), 100_000e6);
        IERC20(base.S_USDS).approve(address(sky), type(uint256).max);
        vm.warp(t0 + 365 days);
    }

    function test_feeIsFivePercentOfTheGain() public view {
        uint256 gain = (sky.getBalance(address(usdc)) + sky.feeOwed(address(usdc))) - sky.principalOf(address(usdc));
        assertGt(gain, 0, "sUSDS earned over the year");
        assertApproxEqAbs(sky.feeOwed(address(usdc)), gain * 500 / 10_000, 1);
    }

    function test_withdrawPaysRecipientExactlyAndTheCollectorTheFee() public {
        uint256 owed = sky.feeOwed(address(usdc));
        uint256 c0 = usdc.balanceOf(COLLECTOR);
        assertEq(sky.withdraw(address(usdc), 10_000e6, payee), 10_000e6);
        assertEq(usdc.balanceOf(payee), 10_000e6);
        assertEq(usdc.balanceOf(COLLECTOR) - c0, owed);
        assertEq(sky.feeOwed(address(usdc)), 0);
        assertEq(usdc.balanceOf(address(sky)), 0, "nothing left in the clone");
    }

    function test_withdrawMax() public {
        uint256 owed = sky.feeOwed(address(usdc));
        uint256 net = sky.getBalance(address(usdc));
        uint256 c0 = usdc.balanceOf(COLLECTOR);
        uint256 delivered = sky.withdraw(address(usdc), type(uint256).max, payee);
        assertEq(usdc.balanceOf(COLLECTOR) - c0, owed);
        assertEq(usdc.balanceOf(payee), delivered);
        assertApproxEqAbs(delivered, net, 1);
        assertEq(IERC20(base.S_USDS).balanceOf(address(this)), 0);
    }

    function test_depositPaysNothingAndTheGainStaysOwed() public {
        uint256 owed = sky.feeOwed(address(usdc));
        uint256 c0 = usdc.balanceOf(COLLECTOR);
        sky.deposit(address(usdc), 50_000e6);
        assertEq(usdc.balanceOf(COLLECTOR), c0, "nothing paid on a deposit");
        assertApproxEqAbs(sky.feeOwed(address(usdc)), owed, 1, "the gain is still owed");
    }
}
