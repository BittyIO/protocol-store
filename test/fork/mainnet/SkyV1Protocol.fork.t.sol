// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {TestProxy} from "../../helpers/Proxy.sol";
import {Test} from "forge-std/Test.sol";
import {ClaimNotSupported} from "protocol-contracts/src/interfaces/IBittyV1Yield.sol";
import {SkyV1Protocol} from "protocol-contracts/src/protocols/SkyV1Protocol.sol";
import {IDssPsm, ISUsds} from "protocol-contracts/src/libs/sky/Sky.sol";
import {mainnet} from "../../../script/addresses.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {InvalidAsset} from "protocol-contracts/src/interfaces/IBittyV1Protocol.sol";

contract TestSkyV1ProtocolFork is Test {
    using SafeERC20 for IERC20;

    uint256 internal constant STAKE_AMOUNT = 1000e6;

    SkyV1Protocol public skyProtocol;
    IERC20 public usdc;
    IERC20 public usds;
    ISUsds public sUsds;
    IDssPsm public psm;

    function setUp() public {
        vm.createSelectFork("mainnet");

        usdc = IERC20(mainnet.USDC);
        usds = IERC20(mainnet.USDS);
        sUsds = ISUsds(mainnet.S_USDS);
        psm = IDssPsm(mainnet.SKY_PSM);

        skyProtocol = SkyV1Protocol(
            TestProxy.deploy(
                address(new SkyV1Protocol(mainnet.USDC, mainnet.USDS, mainnet.S_USDS, mainnet.SKY_PSM)), address(this)
            )
        );
    }

    function test_Initialize() public view {
        assertEq(skyProtocol.owner(), address(this));
        assertEq(address(skyProtocol.usdc()), mainnet.USDC);
        assertEq(address(skyProtocol.usds()), mainnet.USDS);
        assertEq(address(skyProtocol.sUsds()), mainnet.S_USDS);
        assertEq(address(skyProtocol.psm()), mainnet.SKY_PSM);
    }

    function test_Initialize_RevertWhenCalledTwice() public {
        SkyV1Protocol fresh = SkyV1Protocol(
            TestProxy.deploy(
                address(new SkyV1Protocol(mainnet.USDC, mainnet.USDS, mainnet.S_USDS, mainnet.SKY_PSM)), address(this)
            )
        );
        vm.expectRevert();
        fresh.initialize(address(1));
    }

    function test_Stake() public {
        deal(mainnet.USDC, address(this), STAKE_AMOUNT);
        usdc.forceApprove(address(skyProtocol), STAKE_AMOUNT);

        uint256 usdcBefore = usdc.balanceOf(address(this));
        uint256 sharesBefore = sUsds.balanceOf(address(skyProtocol));

        skyProtocol.deposit(mainnet.USDC, STAKE_AMOUNT);

        assertEq(usdc.balanceOf(address(this)), usdcBefore - STAKE_AMOUNT);
        assertEq(usdc.balanceOf(address(skyProtocol)), 0);
        assertEq(usds.balanceOf(address(skyProtocol)), 0);
        assertGt(sUsds.balanceOf(address(this)), sharesBefore);
    }

    function test_Stake_UsesMaxApproval() public {
        deal(mainnet.USDC, address(this), STAKE_AMOUNT);
        usdc.forceApprove(address(skyProtocol), STAKE_AMOUNT);
        skyProtocol.deposit(mainnet.USDC, STAKE_AMOUNT);

        assertGe(usdc.allowance(address(skyProtocol), mainnet.SKY_PSM), type(uint256).max / 2);
        assertGe(usds.allowance(address(skyProtocol), mainnet.S_USDS), type(uint256).max / 2);
    }

    function test_Stake_RevertOnWrongAsset() public {
        deal(mainnet.WETH, address(this), 1 ether);
        IERC20(mainnet.WETH).forceApprove(address(skyProtocol), 1 ether);
        vm.expectRevert(InvalidAsset.selector);
        skyProtocol.deposit(mainnet.WETH, 1 ether);
    }

    function test_GetStakedBalance_ZeroBeforeStake() public view {
        assertEq(skyProtocol.getBalance(mainnet.USDC), 0);
    }

    function test_GetStakedBalance_AfterStake() public {
        deal(mainnet.USDC, address(this), STAKE_AMOUNT);
        usdc.forceApprove(address(skyProtocol), STAKE_AMOUNT);
        skyProtocol.deposit(mainnet.USDC, STAKE_AMOUNT);
        uint256 balance = skyProtocol.getBalance(mainnet.USDC);
        assertGt(balance, 0);
        assertApproxEqAbs(balance, STAKE_AMOUNT, STAKE_AMOUNT / 100);
    }

    function test_GetStakedBalance_RevertOnWrongAsset() public {
        vm.expectRevert(InvalidAsset.selector);
        skyProtocol.getBalance(mainnet.WETH);
    }

    function test_Unstake() public {
        deal(mainnet.USDC, address(this), STAKE_AMOUNT);
        usdc.forceApprove(address(skyProtocol), STAKE_AMOUNT);
        skyProtocol.deposit(mainnet.USDC, STAKE_AMOUNT);

        IERC20(address(sUsds)).forceApprove(address(skyProtocol), type(uint256).max);
        uint256 stakedBalance = skyProtocol.getBalance(mainnet.USDC);
        uint256 usdcBefore = usdc.balanceOf(address(this));

        skyProtocol.withdraw(mainnet.USDC, stakedBalance, address(this));

        assertGt(usdc.balanceOf(address(this)), usdcBefore);
        assertApproxEqAbs(usdc.balanceOf(address(this)) - usdcBefore, stakedBalance, stakedBalance / 100);
        assertEq(usds.balanceOf(address(skyProtocol)), 0);
    }

    function test_Unstake_UsesMaxApproval() public {
        deal(mainnet.USDC, address(this), STAKE_AMOUNT);
        usdc.forceApprove(address(skyProtocol), STAKE_AMOUNT);
        skyProtocol.deposit(mainnet.USDC, STAKE_AMOUNT);

        IERC20(address(sUsds)).forceApprove(address(skyProtocol), type(uint256).max);
        uint256 stakedBalance = skyProtocol.getBalance(mainnet.USDC);
        skyProtocol.withdraw(mainnet.USDC, stakedBalance, address(this));

        assertGe(usds.allowance(address(skyProtocol), mainnet.SKY_PSM), type(uint256).max / 2);
    }

    function test_UnstakeMax_FullExit() public {
        deal(mainnet.USDC, address(this), STAKE_AMOUNT);
        usdc.forceApprove(address(skyProtocol), STAKE_AMOUNT);
        skyProtocol.deposit(mainnet.USDC, STAKE_AMOUNT);

        IERC20(address(sUsds)).forceApprove(address(skyProtocol), type(uint256).max);
        uint256 usdcBefore = usdc.balanceOf(address(this));
        skyProtocol.withdraw(mainnet.USDC, type(uint256).max, address(this));

        assertEq(sUsds.balanceOf(address(this)), 0, "all sUSDS shares redeemed");
        assertApproxEqAbs(usdc.balanceOf(address(this)) - usdcBefore, STAKE_AMOUNT, STAKE_AMOUNT / 100);
    }

    /**
     * The reported balance must be an amount {withdraw} can actually deliver (audit L-04).
     *
     * This test used to assert the opposite: with a toll set, `getBalance` reported the GROSS value
     * and `withdraw(getBalance())` reverted, because the non-max branch adds `tout` on top and rounds
     * `previewWithdraw` up — so it asked for more sUSDS than the holder had. The "withdraw everything"
     * form was the documented way round it. That made the view a promise the adapter would not keep,
     * and the host trusts it: it checks `getBalance() >= amount` and then asks for exactly that.
     *
     * `getBalance` now reports net of the toll, so the two agree.
     */
    function test_Unstake_WithTout_TheReportedBalanceIsWithdrawable() public {
        deal(mainnet.USDC, address(this), STAKE_AMOUNT);
        usdc.forceApprove(address(skyProtocol), STAKE_AMOUNT);
        skyProtocol.deposit(mainnet.USDC, STAKE_AMOUNT);

        IERC20(address(sUsds)).forceApprove(address(skyProtocol), type(uint256).max);
        vm.mockCall(mainnet.SKY_PSM, abi.encodeWithSelector(IDssPsm.tout.selector), abi.encode(uint256(1e15)));

        uint256 reported = skyProtocol.getBalance(mainnet.USDC);
        assertGt(reported, 0, "there is a position to empty");
        uint256 before = usdc.balanceOf(address(this));

        skyProtocol.withdraw(mainnet.USDC, reported, address(this));

        assertEq(usdc.balanceOf(address(this)) - before, reported, "delivered exactly what was reported");
        assertLt(skyProtocol.getBalance(mainnet.USDC), reported / 100, "and the position is emptied");
    }

    /// The "withdraw everything" form still works with a toll, and agrees with the reported balance.
    function test_UnstakeMax_FullExit_WithTout() public {
        deal(mainnet.USDC, address(this), STAKE_AMOUNT);
        usdc.forceApprove(address(skyProtocol), STAKE_AMOUNT);
        skyProtocol.deposit(mainnet.USDC, STAKE_AMOUNT);

        IERC20(address(sUsds)).forceApprove(address(skyProtocol), type(uint256).max);
        vm.mockCall(mainnet.SKY_PSM, abi.encodeWithSelector(IDssPsm.tout.selector), abi.encode(uint256(1e15)));

        uint256 reported = skyProtocol.getBalance(mainnet.USDC);
        uint256 before = usdc.balanceOf(address(this));

        skyProtocol.withdraw(mainnet.USDC, type(uint256).max, address(this));

        assertEq(sUsds.balanceOf(address(this)), 0, "full exit works with a non-zero PSM toll");
        assertApproxEqRel(
            usdc.balanceOf(address(this)) - before, reported, 1e15, "and matches what getBalance promised"
        );
    }

    function test_Unstake_RevertOnWrongAsset() public {
        vm.expectRevert(InvalidAsset.selector);
        skyProtocol.withdraw(mainnet.WETH, 1 ether, address(this));
    }

    function test_GetUnstakeRequestIds_AlwaysEmpty() public view {
        assertEq(skyProtocol.getPendingWithdrawalIds().length, 0);
    }

    function test_ClaimUnstaked_Revert() public {
        vm.expectRevert(ClaimNotSupported.selector);
        skyProtocol.claimWithdrawals(new uint256[](3));
    }

    function test_StakeUnstakeRoundTrip_YieldAccrues() public {
        deal(mainnet.USDC, address(this), STAKE_AMOUNT);
        usdc.forceApprove(address(skyProtocol), STAKE_AMOUNT);
        skyProtocol.deposit(mainnet.USDC, STAKE_AMOUNT);

        vm.warp(block.timestamp + 365 days);

        uint256 balanceAfterYield = skyProtocol.getBalance(mainnet.USDC);
        assertGe(balanceAfterYield, STAKE_AMOUNT);
    }

    function test_Unstake_DeliversFullAmountNoYieldFee() public {
        deal(mainnet.USDC, address(this), STAKE_AMOUNT);
        usdc.forceApprove(address(skyProtocol), STAKE_AMOUNT);
        skyProtocol.deposit(mainnet.USDC, STAKE_AMOUNT);

        vm.warp(block.timestamp + 365 days);

        uint256 gross = skyProtocol.getBalance(mainnet.USDC);
        assertGt(gross, STAKE_AMOUNT);

        IERC20(address(sUsds)).forceApprove(address(skyProtocol), type(uint256).max);

        address feeRecipient = 0xF0E7f6998B362BD15CF819C7EBfcaCe8865FECA0;
        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        uint256 usdcBefore = usdc.balanceOf(address(this));

        skyProtocol.withdraw(mainnet.USDC, type(uint256).max, address(this));

        // Yield fee removed: nothing goes to the old fee recipient; the caller receives the full redeemed amount.
        assertEq(usdc.balanceOf(feeRecipient), feeBefore, "no yield fee taken");
        assertApproxEqAbs(usdc.balanceOf(address(this)) - usdcBefore, gross, STAKE_AMOUNT / 100);
    }

    /// Shares are minted to the owner and the PSM pays the recipient: nothing passes through here.
    function test_DepositAndWithdraw_NothingPassesThroughTheInstance() public {
        address payee = makeAddr("payee");
        deal(mainnet.USDC, address(this), STAKE_AMOUNT);
        usdc.forceApprove(address(skyProtocol), STAKE_AMOUNT);
        skyProtocol.deposit(mainnet.USDC, STAKE_AMOUNT);
        assertEq(IERC20(address(sUsds)).balanceOf(address(skyProtocol)), 0, "no shares held here");
        assertGt(IERC20(address(sUsds)).balanceOf(address(this)), 0, "the owner holds them");

        IERC20(address(sUsds)).forceApprove(address(skyProtocol), type(uint256).max);
        uint256 delivered = skyProtocol.withdraw(mainnet.USDC, 400e6, payee);

        assertEq(delivered, 400e6);
        assertEq(usdc.balanceOf(payee), 400e6, "the payee was paid exactly");
        assertEq(usdc.balanceOf(address(skyProtocol)), 0, "no USDC stuck here");
        assertEq(usds.balanceOf(address(skyProtocol)), 0, "no USDS stuck here");
    }
}
