// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {SkyV1Provider} from "provider-contracts/src/providers/SkyV1Provider.sol";
import {IDssPsm, ISUsds} from "provider-contracts/src/libs/sky/Sky.sol";
import {mainnet} from "../../../script/addresses.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {InvalidAsset, ClaimUnstakedNotSupported} from "provider-contracts/src/interfaces/IStakingProvider.sol";

contract TestSkyV1ProviderFork is Test {
    using SafeERC20 for IERC20;

    uint256 internal constant STAKE_AMOUNT = 1000e6;

    SkyV1Provider public skyProvider;
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

        skyProvider = new SkyV1Provider(mainnet.USDC, mainnet.USDS, mainnet.S_USDS, mainnet.SKY_PSM);
        skyProvider.initialize(address(this));
    }

    function test_Initialize() public view {
        assertEq(skyProvider.owner(), address(this));
        assertEq(address(skyProvider.usdc()), mainnet.USDC);
        assertEq(address(skyProvider.usds()), mainnet.USDS);
        assertEq(address(skyProvider.sUsds()), mainnet.S_USDS);
        assertEq(address(skyProvider.psm()), mainnet.SKY_PSM);
    }

    function test_Initialize_RevertWhenCalledTwice() public {
        SkyV1Provider fresh = new SkyV1Provider(mainnet.USDC, mainnet.USDS, mainnet.S_USDS, mainnet.SKY_PSM);
        fresh.initialize(address(this));
        vm.expectRevert();
        fresh.initialize(address(1));
    }

    function test_Stake() public {
        deal(mainnet.USDC, address(this), STAKE_AMOUNT);
        usdc.safeApprove(address(skyProvider), STAKE_AMOUNT);

        uint256 usdcBefore = usdc.balanceOf(address(this));
        uint256 sharesBefore = sUsds.balanceOf(address(skyProvider));

        skyProvider.stake(mainnet.USDC, STAKE_AMOUNT);

        assertEq(usdc.balanceOf(address(this)), usdcBefore - STAKE_AMOUNT);
        assertEq(usdc.balanceOf(address(skyProvider)), 0);
        assertEq(usds.balanceOf(address(skyProvider)), 0);
        assertGt(sUsds.balanceOf(address(skyProvider)), sharesBefore);
    }

    function test_Stake_ResetsApprovals() public {
        deal(mainnet.USDC, address(this), STAKE_AMOUNT);
        usdc.safeApprove(address(skyProvider), STAKE_AMOUNT);
        skyProvider.stake(mainnet.USDC, STAKE_AMOUNT);

        assertEq(usdc.allowance(address(skyProvider), mainnet.SKY_PSM), 0);
        assertEq(usds.allowance(address(skyProvider), mainnet.S_USDS), 0);
    }

    function test_Stake_RevertOnWrongAsset() public {
        deal(mainnet.WETH, address(this), 1 ether);
        IERC20(mainnet.WETH).safeApprove(address(skyProvider), 1 ether);
        vm.expectRevert(InvalidAsset.selector);
        skyProvider.stake(mainnet.WETH, 1 ether);
    }

    function test_GetStakedBalance_ZeroBeforeStake() public view {
        assertEq(skyProvider.getStakedBalance(mainnet.USDC), 0);
    }

    function test_GetStakedBalance_AfterStake() public {
        deal(mainnet.USDC, address(this), STAKE_AMOUNT);
        usdc.safeApprove(address(skyProvider), STAKE_AMOUNT);
        skyProvider.stake(mainnet.USDC, STAKE_AMOUNT);
        uint256 balance = skyProvider.getStakedBalance(mainnet.USDC);
        assertGt(balance, 0);
        assertApproxEqAbs(balance, STAKE_AMOUNT, STAKE_AMOUNT / 100);
    }

    function test_GetStakedBalance_RevertOnWrongAsset() public {
        vm.expectRevert(InvalidAsset.selector);
        skyProvider.getStakedBalance(mainnet.WETH);
    }

    function test_Unstake() public {
        deal(mainnet.USDC, address(this), STAKE_AMOUNT);
        usdc.safeApprove(address(skyProvider), STAKE_AMOUNT);
        skyProvider.stake(mainnet.USDC, STAKE_AMOUNT);

        uint256 stakedBalance = skyProvider.getStakedBalance(mainnet.USDC);
        uint256 usdcBefore = usdc.balanceOf(address(this));

        skyProvider.unstake(mainnet.USDC, stakedBalance);

        assertGt(usdc.balanceOf(address(this)), usdcBefore);
        assertApproxEqAbs(usdc.balanceOf(address(this)) - usdcBefore, stakedBalance, stakedBalance / 100);
        assertEq(usds.balanceOf(address(skyProvider)), 0);
    }

    function test_Unstake_ResetsApprovals() public {
        deal(mainnet.USDC, address(this), STAKE_AMOUNT);
        usdc.safeApprove(address(skyProvider), STAKE_AMOUNT);
        skyProvider.stake(mainnet.USDC, STAKE_AMOUNT);

        uint256 stakedBalance = skyProvider.getStakedBalance(mainnet.USDC);
        skyProvider.unstake(mainnet.USDC, stakedBalance);

        assertEq(usds.allowance(address(skyProvider), mainnet.SKY_PSM), 0);
    }

    function test_Unstake_RevertOnWrongAsset() public {
        vm.expectRevert(InvalidAsset.selector);
        skyProvider.unstake(mainnet.WETH, 1 ether);
    }

    function test_GetUnstakeRequestIds_AlwaysEmpty() public view {
        assertEq(skyProvider.getUnstakeRequestIds().length, 0);
    }

    function test_ClaimUnstaked_Revert() public {
        vm.expectRevert(ClaimUnstakedNotSupported.selector);
        skyProvider.claimUnstaked(new uint256[](3));
    }

    function test_StakeUnstakeRoundTrip_YieldAccrues() public {
        deal(mainnet.USDC, address(this), STAKE_AMOUNT);
        usdc.safeApprove(address(skyProvider), STAKE_AMOUNT);
        skyProvider.stake(mainnet.USDC, STAKE_AMOUNT);

        vm.warp(block.timestamp + 365 days);

        uint256 balanceAfterYield = skyProvider.getStakedBalance(mainnet.USDC);
        assertGe(balanceAfterYield, STAKE_AMOUNT);
    }
}
