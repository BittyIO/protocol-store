// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {YieldFeeTracker} from "protocol-contracts/src/libs/YieldFeeTracker.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract YieldFeeTrackerHarness is YieldFeeTracker {
    function recordDeposit(address asset, uint256 amount) external {
        _recordDeposit(asset, amount);
    }

    function deliver(address asset, address token, uint256 grossAmount, address recipient)
        external
        returns (uint256 netDelivered)
    {
        return _deliverWithEarningFee(asset, IERC20(token), grossAmount, recipient);
    }
}

contract TestYieldFeeTracker is Test {
    YieldFeeTrackerHarness internal tracker;
    MockERC20 internal token;
    address internal constant RECIPIENT = address(0xBEEF);
    address internal constant FEE_RECIPIENT = 0x12EE2de7BF086388B1D560eb95e7191Edfab9823;

    function setUp() public {
        tracker = new YieldFeeTrackerHarness();
        token = new MockERC20();
    }

    function test_NoFeeWhenWithdrawWithinPrincipal() public {
        address asset = address(token);
        tracker.recordDeposit(asset, 100 ether);
        token.mint(address(tracker), 50 ether);

        uint256 feeBefore = token.balanceOf(FEE_RECIPIENT);
        uint256 recipientBefore = token.balanceOf(RECIPIENT);

        uint256 net = tracker.deliver(asset, asset, 50 ether, RECIPIENT);

        assertEq(net, 50 ether);
        assertEq(token.balanceOf(FEE_RECIPIENT), feeBefore);
        assertEq(token.balanceOf(RECIPIENT), recipientBefore + 50 ether);
        (, uint256 totalWithdrawn) = tracker.assetLedger(asset);
        assertEq(totalWithdrawn, 50 ether);
    }

    function test_FeeOnEarningsOnly() public {
        address asset = address(token);
        tracker.recordDeposit(asset, 100 ether);
        token.mint(address(tracker), 120 ether);

        uint256 feeBefore = token.balanceOf(FEE_RECIPIENT);
        uint256 recipientBefore = token.balanceOf(RECIPIENT);

        uint256 net = tracker.deliver(asset, asset, 120 ether, RECIPIENT);

        assertEq(net, 118 ether);
        assertEq(token.balanceOf(FEE_RECIPIENT), feeBefore + 2 ether);
        assertEq(token.balanceOf(RECIPIENT), recipientBefore + 118 ether);
    }

    function test_FeeOnPartialEarningsAcrossWithdrawals() public {
        address asset = address(token);
        tracker.recordDeposit(asset, 100 ether);
        token.mint(address(tracker), 130 ether);

        uint256 net1 = tracker.deliver(asset, asset, 80 ether, RECIPIENT);
        assertEq(net1, 80 ether);

        uint256 feeBefore = token.balanceOf(FEE_RECIPIENT);
        uint256 recipientBefore = token.balanceOf(RECIPIENT);

        uint256 net2 = tracker.deliver(asset, asset, 50 ether, RECIPIENT);

        assertEq(net2, 47 ether);
        assertEq(token.balanceOf(FEE_RECIPIENT), feeBefore + 3 ether);
        assertEq(token.balanceOf(RECIPIENT), recipientBefore + 47 ether);
    }
}
