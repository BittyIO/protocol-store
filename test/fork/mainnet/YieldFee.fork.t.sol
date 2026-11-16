// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {TestProxy} from "../../helpers/Proxy.sol";
import {Test} from "forge-std/Test.sol";
import {AaveV3Protocol} from "protocol-contracts/src/protocols/AaveV3Protocol.sol";
import {SkyV1Protocol} from "protocol-contracts/src/protocols/SkyV1Protocol.sol";
import {LidoV2Protocol} from "protocol-contracts/src/protocols/LidoV2Protocol.sol";
import {BittyV1YieldFee} from "protocol-contracts/src/BittyV1YieldFee.sol";
import {IUnstETH} from "protocol-contracts/src/libs/lido/v2/Lido.sol";
import {mainnet} from "../../../script/addresses.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import {WETH} from "solmate/tokens/WETH.sol";

/// Lido's queue, cut down: takes the stETH, and pays out `payout` per request when claimed.
contract MockUnstETH {
    IERC20 public immutable stETH;
    uint256 public payout;
    uint256 public nextId = 1;

    constructor(address stETH_) payable {
        stETH = IERC20(stETH_);
    }

    function setPayout(uint256 p) external {
        payout = p;
    }

    function requestWithdrawals(uint256[] calldata amounts, address) external returns (uint256[] memory ids) {
        stETH.transferFrom(msg.sender, address(this), amounts[0]);
        ids = new uint256[](1);
        ids[0] = nextId++;
    }

    function getWithdrawalStatus(uint256[] calldata ids)
        external
        view
        returns (IUnstETH.WithdrawalRequestStatus[] memory s)
    {
        s = new IUnstETH.WithdrawalRequestStatus[](ids.length);
        for (uint256 i; i < ids.length; i++) {
            s[i] = IUnstETH.WithdrawalRequestStatus(payout, 0, address(this), block.timestamp, true, false);
        }
    }

    function claimWithdrawal(uint256) external {
        (bool ok,) = msg.sender.call{value: payout}("");
        require(ok);
    }

    receive() external payable {}
}

abstract contract YieldFeeHelpers is Test {
    address constant COLLECTOR = 0xF0E7f6998B362BD15CF819C7EBfcaCe8865FECA0;
    address payee = makeAddr("payee");

    function _fee(uint256 gain) internal pure returns (uint256) {
        return gain * 500 / 10_000;
    }
}

/// The test contract plays the vault: it owns the clone and holds the position.
contract YieldFeeAaveFork is YieldFeeHelpers {
    AaveV3Protocol aave;
    IERC20 usdc = IERC20(mainnet.USDC);
    IERC20 aUsdc;

    function setUp() public {
        vm.createSelectFork("mainnet");
        aave = AaveV3Protocol(
            TestProxy.deploy(address(new AaveV3Protocol(mainnet.AAVE_V3, mainnet.POOL_DATA_PROVIDER)), address(this))
        );
        deal(address(usdc), address(this), 1_000_000e6);
        usdc.approve(address(aave), type(uint256).max);
        aave.deposit(address(usdc), 100_000e6);
        aUsdc = IERC20(aave.receiptTokenOf(address(usdc)));
        aUsdc.approve(address(aave), type(uint256).max);
    }

    function _earn() internal returns (uint256 gain) {
        uint256 before = aUsdc.balanceOf(address(this));
        vm.warp(block.timestamp + 365 days);
        gain = aUsdc.balanceOf(address(this)) - before;
        assertGt(gain, 1_000e6, "a year on Aave earns something");
    }

    function test_freshDepositOwesNothing() public view {
        assertEq(aave.feeOwed(address(usdc)), 0);
        assertApproxEqAbs(aave.principalOf(address(usdc)), 100_000e6, 2);
        assertApproxEqAbs(aave.getBalance(address(usdc)), 100_000e6, 2);
    }

    function test_feeIsFivePercentOfTheGainAndGetBalanceIsNet() public {
        uint256 gain = _earn();
        uint256 gross = aUsdc.balanceOf(address(this));
        assertApproxEqAbs(aave.feeOwed(address(usdc)), _fee(gain), 2);
        assertEq(aave.getBalance(address(usdc)), gross - aave.feeOwed(address(usdc)));
    }

    function test_withdrawPaysRecipientExactlyAndTheCollectorTheFee() public {
        _earn();
        uint256 owed = aave.feeOwed(address(usdc));
        uint256 c0 = usdc.balanceOf(COLLECTOR);

        uint256 delivered = aave.withdraw(address(usdc), 10_000e6, payee);

        assertEq(delivered, 10_000e6);
        assertEq(usdc.balanceOf(payee), 10_000e6, "recipient gets exactly the amount");
        assertEq(usdc.balanceOf(COLLECTOR) - c0, owed, "collector gets the fee");
        assertEq(aave.feeOwed(address(usdc)), 0, "gain settled");
        assertApproxEqAbs(aave.principalOf(address(usdc)), aUsdc.balanceOf(address(this)), 2);
        assertEq(usdc.balanceOf(address(aave)), 0, "nothing left in the clone");
    }

    function test_withdrawMaxPaysTheFeeOutOfTheProceeds() public {
        _earn();
        uint256 gross = aUsdc.balanceOf(address(this));
        uint256 owed = aave.feeOwed(address(usdc));
        uint256 c0 = usdc.balanceOf(COLLECTOR);

        uint256 delivered = aave.withdraw(address(usdc), type(uint256).max, payee);

        assertEq(usdc.balanceOf(COLLECTOR) - c0, owed);
        assertEq(usdc.balanceOf(payee), delivered);
        assertApproxEqAbs(delivered, gross - owed, 2);
        assertEq(aUsdc.balanceOf(address(this)), 0);
        assertEq(aave.principalOf(address(usdc)), 0);
    }

    function test_withdrawingWhatGetBalanceSaysWorks() public {
        _earn();
        uint256 net = aave.getBalance(address(usdc));
        aave.withdraw(address(usdc), net, payee);
        assertEq(usdc.balanceOf(payee), net);
        assertLe(aUsdc.balanceOf(address(this)), 2, "at most rounding left");
    }

    /**
     * A deposit pays nothing: all of it is supplied, it adds to the principal, and the gain stays owed.
     */
    function test_depositPaysNothingAndTheGainStaysOwed() public {
        _earn();
        uint256 owed = aave.feeOwed(address(usdc));
        uint256 gross = aUsdc.balanceOf(address(this));
        uint256 p0 = aave.principalOf(address(usdc));
        uint256 c0 = usdc.balanceOf(COLLECTOR);

        aave.deposit(address(usdc), 50_000e6);

        assertEq(usdc.balanceOf(COLLECTOR), c0, "nothing paid on a deposit");
        assertApproxEqAbs(aUsdc.balanceOf(address(this)), gross + 50_000e6, 2, "all of it supplied");
        assertApproxEqAbs(aave.principalOf(address(usdc)), p0 + 50_000e6, 2, "the deposit adds to the principal");
        assertApproxEqAbs(aave.feeOwed(address(usdc)), owed, 2, "the gain is still owed");

        // ...and is paid at the next withdrawal.
        aave.withdraw(address(usdc), 1_000e6, payee);
        assertApproxEqAbs(usdc.balanceOf(COLLECTOR) - c0, owed, 2);
        assertEq(usdc.balanceOf(payee), 1_000e6);
    }

    function test_receiptTokensLeavingElsewhereDoNotShieldLaterEarnings() public {
        _earn();
        address elsewhere = makeAddr("elsewhere");
        aUsdc.transfer(elsewhere, aUsdc.balanceOf(address(this)) * 9 / 10);
        assertEq(aave.feeOwed(address(usdc)), 0, "below the principal: nothing owed");
        assertApproxEqAbs(
            aave.principalOf(address(usdc)), aUsdc.balanceOf(address(this)), 2, "principal shown as the position"
        );

        aave.deposit(address(usdc), 1e6); // touching it re-books the principal at the position
        assertApproxEqAbs(aave.principalOf(address(usdc)), aUsdc.balanceOf(address(this)), 2);

        uint256 before = aUsdc.balanceOf(address(this));
        vm.warp(block.timestamp + 365 days);
        uint256 gain = aUsdc.balanceOf(address(this)) - before;
        assertApproxEqAbs(aave.feeOwed(address(usdc)), _fee(gain), 2, "later earnings pay the fee");
    }

    /**
     * Settling first (a tiny withdrawal) pays the fee; then the whole balance is the vault's to spend.
     */
    function test_settlingFirstPaysTheFeeThenAllOfItIsTheVaults() public {
        _earn();
        uint256 owed = aave.feeOwed(address(usdc));
        uint256 c0 = usdc.balanceOf(COLLECTOR);
        aave.withdraw(address(usdc), 1, payee);
        assertEq(usdc.balanceOf(COLLECTOR) - c0, owed, "fee paid");
        assertEq(aave.feeOwed(address(usdc)), 0);
        assertApproxEqAbs(aave.getBalance(address(usdc)), aUsdc.balanceOf(address(this)), 1, "all of it is the vault's");
    }

    /**
     * The audit's cross-cycle case (H-1 on the old YieldFeeTracker): after a full exit with earnings,
     * fresh principal is not taxed. Cycle 1 earns and exits; cycle 2 deposits and withdraws it all
     * with no time passing, so it owes nothing and gets back exactly what it put in.
     */
    function test_aFullExitLeavesNothingToTaxTheNextCycle() public {
        // Cycle 1: 100k earns for a year, then everything comes out, paying the fee on the gain.
        _earn();
        uint256 c0 = usdc.balanceOf(COLLECTOR);
        uint256 owed = aave.feeOwed(address(usdc));
        aave.withdraw(address(usdc), type(uint256).max, payee);
        assertEq(usdc.balanceOf(COLLECTOR) - c0, owed);
        assertEq(aave.principalOf(address(usdc)), 0, "nothing carried into the next cycle");

        // Cycle 2: fresh principal, no yield.
        aave.deposit(address(usdc), 100_000e6);
        assertApproxEqAbs(aave.principalOf(address(usdc)), 100_000e6, 2);
        assertEq(aave.feeOwed(address(usdc)), 0, "fresh principal owes nothing");
        // Aave mints a unit under what is supplied, so all of it is getBalance, not the 100k itself.
        uint256 all = aave.getBalance(address(usdc));
        assertApproxEqAbs(all, 100_000e6, 2);
        uint256 c1 = usdc.balanceOf(COLLECTOR);
        address payee2 = makeAddr("payee2");
        uint256 delivered = aave.withdraw(address(usdc), all, payee2);
        assertEq(usdc.balanceOf(COLLECTOR), c1, "no fee on principal");
        assertEq(delivered, all);
        assertEq(usdc.balanceOf(payee2), all, "all the principal back");
    }

    /**
     * The same across partial cycles: after a withdrawal settles the gain, only new earnings pay.
     */
    function test_partialCyclesChargeOnlyNewEarnings() public {
        _earn();
        aave.withdraw(address(usdc), 30_000e6, payee); // settles year one's gain
        aave.deposit(address(usdc), 50_000e6);
        assertEq(aave.feeOwed(address(usdc)), 0, "settled, and the deposit is principal");

        uint256 p = aave.principalOf(address(usdc));
        vm.warp(block.timestamp + 365 days);
        uint256 gain = aUsdc.balanceOf(address(this)) - p;
        uint256 c0 = usdc.balanceOf(COLLECTOR);
        aave.withdraw(address(usdc), 10_000e6, payee);
        assertApproxEqAbs(usdc.balanceOf(COLLECTOR) - c0, _fee(gain), 2, "5% of year two's gain only");
    }

    /**
     * Under 100 USDC owed, a partial withdrawal leaves the fee owed: the recipient is paid straight
     * from Aave, nothing goes to the collector, and the principal falls by what left.
     */
    function test_underTheMinimumAPartialWithdrawalLeavesTheFeeOwed() public {
        vm.warp(block.timestamp + 12 hours);
        uint256 owed = aave.feeOwed(address(usdc));
        assertGt(owed, 0);
        assertLt(owed, 100e6, "under 100 USDC after half a day");
        uint256 p0 = aave.principalOf(address(usdc));
        uint256 c0 = usdc.balanceOf(COLLECTOR);

        assertEq(aave.withdraw(address(usdc), 10_000e6, payee), 10_000e6);

        assertEq(usdc.balanceOf(payee), 10_000e6);
        assertEq(usdc.balanceOf(COLLECTOR), c0, "nothing paid");
        assertApproxEqAbs(aave.principalOf(address(usdc)), p0 - 10_000e6, 2, "taken from the principal");
        assertApproxEqAbs(aave.feeOwed(address(usdc)), owed, 2, "the fee is still owed");
    }

    /**
     * Withdrawing everything pays even a fee under the minimum.
     */
    function test_aFullWithdrawalPaysEvenASmallFee() public {
        vm.warp(block.timestamp + 12 hours);
        uint256 owed = aave.feeOwed(address(usdc));
        assertLt(owed, 100e6);
        aave.withdraw(address(usdc), 10_000e6, payee); // deferred
        uint256 c0 = usdc.balanceOf(COLLECTOR);
        aave.withdraw(address(usdc), type(uint256).max, payee);
        assertApproxEqAbs(usdc.balanceOf(COLLECTOR) - c0, owed, 2, "paid on the way out");
    }

    /**
     * Withdrawing what getBalance says - into the gain itself - pays even a fee under the minimum.
     */
    function test_aWithdrawalReachingIntoTheGainPaysEvenASmallFee() public {
        vm.warp(block.timestamp + 12 hours);
        uint256 owed = aave.feeOwed(address(usdc));
        assertLt(owed, 100e6);
        uint256 net = aave.getBalance(address(usdc));
        uint256 c0 = usdc.balanceOf(COLLECTOR);
        aave.withdraw(address(usdc), net, payee);
        assertEq(usdc.balanceOf(COLLECTOR) - c0, owed);
        assertEq(usdc.balanceOf(payee), net);
    }

    function test_onlyThePositionsOwnerCanMoveIt() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        aave.withdraw(address(usdc), 1e6, payee);
    }
}

/**
 * WETH on Aave: not a stablecoin, so the minimum is 0.1 WETH.
 */
contract YieldFeeAaveWethFork is YieldFeeHelpers {
    AaveV3Protocol aave;
    IERC20 weth = IERC20(mainnet.WETH);
    IERC20 aWeth;

    function setUp() public {
        vm.createSelectFork("mainnet");
        aave = AaveV3Protocol(
            TestProxy.deploy(address(new AaveV3Protocol(mainnet.AAVE_V3, mainnet.POOL_DATA_PROVIDER)), address(this))
        );
        deal(address(weth), address(this), 1_000 ether);
        weth.approve(address(aave), type(uint256).max);
        aave.deposit(address(weth), 500 ether);
        aWeth = IERC20(aave.receiptTokenOf(address(weth)));
        aWeth.approve(address(aave), type(uint256).max);
    }

    function test_theMinimumIsOneTenthOfAnEth() public {
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 10 days);
        uint256 owed = aave.feeOwed(address(weth));
        assertGt(owed, 0);
        assertLt(owed, 0.1 ether, "under 0.1 ETH");
        uint256 c0 = weth.balanceOf(COLLECTOR);
        aave.withdraw(address(weth), 1 ether, payee);
        assertEq(weth.balanceOf(COLLECTOR), c0, "deferred");

        vm.warp(t0 + 730 days);
        owed = aave.feeOwed(address(weth));
        assertGe(owed, 0.1 ether, "over 0.1 ETH after two years");
        aave.withdraw(address(weth), 1 ether, payee);
        assertEq(weth.balanceOf(COLLECTOR) - c0, owed, "paid");
        assertEq(weth.balanceOf(payee), 2 ether);
    }
}

/// A clone that held a position on the 1.0.0 release, upgraded to the fee release.
contract YieldFeeUpgradeFork is YieldFeeHelpers {
    /// The 1.0.0 Aave adapter live on Ethereum.
    address constant AAVE_V100 = 0xBB51E4D055f213d0E38a103B9Ba5943DE2e83287;
    IERC20 usdc = IERC20(mainnet.USDC);

    function test_upgradedPositionPaysNothingOnWhatItEarnedBefore() public {
        vm.createSelectFork("mainnet");
        uint256 t0 = block.timestamp;
        AaveV3Protocol clone = AaveV3Protocol(TestProxy.deploy(AAVE_V100, address(this)));
        assertEq(clone.versionName(), "1.0.0");
        deal(address(usdc), address(this), 100_000e6);
        usdc.approve(address(clone), type(uint256).max);
        clone.deposit(address(usdc), 100_000e6);
        IERC20 aUsdc = IERC20(clone.receiptTokenOf(address(usdc)));
        aUsdc.approve(address(clone), type(uint256).max);
        vm.warp(t0 + 365 days); // earned on 1.0.0

        UUPSUpgradeable(address(clone))
            .upgradeToAndCall(address(new AaveV3Protocol(mainnet.AAVE_V3, mainnet.POOL_DATA_PROVIDER)), "");
        assertEq(clone.versionName(), "1.1.0");
        assertEq(clone.owner(), address(this), "owner kept");
        assertEq(clone.receiptTokenOf(address(usdc)), address(aUsdc), "old storage kept");
        assertEq(clone.feeOwed(address(usdc)), 0, "nothing owed on earnings before the fee");

        uint256 c0 = usdc.balanceOf(COLLECTOR);
        uint256 gross = aUsdc.balanceOf(address(this));
        clone.withdraw(address(usdc), 1_000e6, payee);
        assertEq(usdc.balanceOf(COLLECTOR), c0, "first touch books it, no fee");
        assertApproxEqAbs(clone.principalOf(address(usdc)), gross - 1_000e6, 2);

        // From here on, earnings are charged. (A fixed time: under via-ir a second read of
        // block.timestamp after vm.warp can come back stale.)
        vm.warp(t0 + 730 days);
        assertGt(clone.feeOwed(address(usdc)), 0);
    }
}

contract YieldFeeSkyFork is YieldFeeHelpers {
    SkyV1Protocol sky;
    IERC20 usdc = IERC20(mainnet.USDC);

    function setUp() public {
        vm.createSelectFork("mainnet");
        sky = SkyV1Protocol(
            TestProxy.deploy(
                address(new SkyV1Protocol(mainnet.USDC, mainnet.USDS, mainnet.S_USDS, mainnet.SKY_PSM)), address(this)
            )
        );
        deal(address(usdc), address(this), 1_000_000e6);
        usdc.approve(address(sky), type(uint256).max);
        sky.deposit(address(usdc), 100_000e6);
        IERC20(mainnet.S_USDS).approve(address(sky), type(uint256).max);
        vm.warp(block.timestamp + 365 days);
    }

    function test_withdrawPaysRecipientExactlyAndTheCollectorTheFee() public {
        uint256 owed = sky.feeOwed(address(usdc));
        assertGt(owed, 0, "sUSDS earned over the year");
        uint256 c0 = usdc.balanceOf(COLLECTOR);
        sky.withdraw(address(usdc), 10_000e6, payee);
        assertEq(usdc.balanceOf(payee), 10_000e6);
        assertEq(usdc.balanceOf(COLLECTOR) - c0, owed);
        assertEq(sky.feeOwed(address(usdc)), 0);
    }

    function test_withdrawMax() public {
        uint256 owed = sky.feeOwed(address(usdc));
        uint256 net = sky.getBalance(address(usdc));
        uint256 c0 = usdc.balanceOf(COLLECTOR);
        uint256 delivered = sky.withdraw(address(usdc), type(uint256).max, payee);
        assertEq(usdc.balanceOf(COLLECTOR) - c0, owed);
        assertEq(usdc.balanceOf(payee), delivered);
        assertApproxEqAbs(delivered, net, 2);
        assertEq(IERC20(mainnet.S_USDS).balanceOf(address(this)), 0);
    }

    function test_depositPaysNothingAndTheGainStaysOwed() public {
        uint256 owed = sky.feeOwed(address(usdc));
        uint256 c0 = usdc.balanceOf(COLLECTOR);
        sky.deposit(address(usdc), 50_000e6);
        assertEq(usdc.balanceOf(COLLECTOR), c0, "nothing paid on a deposit");
        assertApproxEqAbs(sky.feeOwed(address(usdc)), owed, 2, "the gain is still owed");
    }
}

contract YieldFeeLidoFork is YieldFeeHelpers {
    LidoV2Protocol lido;
    MockUnstETH queue;
    WETH weth = WETH(payable(mainnet.WETH));
    IERC20 stETH = IERC20(mainnet.STETH);

    function setUp() public {
        vm.createSelectFork("mainnet");
        queue = new MockUnstETH(mainnet.STETH);
        lido = LidoV2Protocol(
            payable(TestProxy.deploy(
                    address(new LidoV2Protocol(mainnet.STETH, address(queue), mainnet.WETH)), address(this)
                ))
        );
        deal(address(weth), address(this), 100 ether);
        weth.approve(address(lido), type(uint256).max);
        stETH.approve(address(lido), type(uint256).max);
        lido.deposit(address(weth), 10 ether);
        // stETH rebases only on Lido's oracle report; a gift of stETH stands in for a year's rewards.
        address holder = _stEthHolder();
        vm.prank(holder);
        stETH.transfer(address(this), 4 ether);
    }

    function _stEthHolder() internal returns (address h) {
        h = makeAddr("stEthHolder");
        vm.deal(h, 5 ether);
        vm.prank(h);
        (bool ok,) = mainnet.STETH.call{value: 4.5 ether}("");
        require(ok, "stake for stETH");
    }

    function test_feeIsPaidInEthWhenTheWithdrawalIsClaimed() public {
        uint256 owed = lido.feeOwed(address(weth));
        assertApproxEqAbs(owed, _fee(4 ether), 4);

        uint256 before = weth.balanceOf(COLLECTOR);
        lido.withdraw(address(weth), 5 ether, address(this));
        assertEq(lido.feeOwed(address(weth)), 0, "the gain is settled into the request");
        assertEq(weth.balanceOf(COLLECTOR), before, "nothing paid before the claim");

        uint256 requested = stETH.balanceOf(address(queue));
        assertApproxEqAbs(requested, 5 ether + owed, 4, "the request carries the amount and the fee");

        // Lido pays out what was requested.
        vm.deal(address(queue), requested);
        queue.setPayout(requested);
        uint256 c0 = weth.balanceOf(COLLECTOR);
        uint256 w0 = weth.balanceOf(address(this));
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        lido.claimWithdrawals(ids);

        uint256 fee = weth.balanceOf(COLLECTOR) - c0;
        assertApproxEqAbs(fee, owed, 4, "collector gets the fee in WETH");
        assertApproxEqAbs(weth.balanceOf(address(this)) - w0, 5 ether, 4, "vault gets the amount");
    }

    function test_aShortPayoutSharesTheShortfall() public {
        uint256 owed = lido.feeOwed(address(weth));
        lido.withdraw(address(weth), 5 ether, address(this));
        uint256 requested = stETH.balanceOf(address(queue));
        uint256 paid = requested * 9 / 10; // Lido paid out 10% less (a slashing)
        vm.deal(address(queue), paid);
        queue.setPayout(paid);
        uint256 c0 = weth.balanceOf(COLLECTOR);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        lido.claimWithdrawals(ids);
        assertApproxEqAbs(weth.balanceOf(COLLECTOR) - c0, owed * 9 / 10, 4, "the fee shrinks with the payout");
    }

    function test_depositPaysNothingAndTheGainStaysOwed() public {
        uint256 owed = lido.feeOwed(address(weth));
        uint256 c0 = weth.balanceOf(COLLECTOR);
        lido.deposit(address(weth), 1 ether);
        assertEq(weth.balanceOf(COLLECTOR), c0, "nothing paid on a deposit");
        assertApproxEqAbs(lido.feeOwed(address(weth)), owed, 4, "the gain is still owed");
    }
}
