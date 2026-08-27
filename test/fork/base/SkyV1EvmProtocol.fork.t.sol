// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {SkyV1EvmProtocol, PsmAssetMismatch} from "protocol-contracts/src/protocols/SkyV1EvmProtocol.sol";
import {IPsm3} from "protocol-contracts/src/libs/sky/Psm3.sol";
import {base} from "../../../script/addresses.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {InvalidAsset, ClaimUnstakedNotSupported} from "protocol-contracts/src/interfaces/IBittyV1StakingProtocol.sol";

contract TestSkyV1EvmProtocolFork is Test {
    using SafeERC20 for IERC20;

    uint256 internal constant STAKE_AMOUNT = 1000e6;

    SkyV1EvmProtocol public sky;
    IERC20 public usdc;
    IERC20 public sUsds;
    IPsm3 public psm;

    function setUp() public {
        vm.createSelectFork("base");

        usdc = IERC20(base.USDC);
        sUsds = IERC20(base.S_USDS);
        psm = IPsm3(base.SKY_PSM3);

        sky = new SkyV1EvmProtocol(base.USDC, base.S_USDS, base.SKY_PSM3);
        sky.initialize(address(this));
    }

    function test_Initialize() public view {
        assertEq(sky.owner(), address(this));
        assertEq(address(sky.usdc()), base.USDC);
        assertEq(address(sky.sUsds()), base.S_USDS);
        assertEq(address(sky.psm()), base.SKY_PSM3);
    }

    /// @dev The constructor asks the module to confirm its own assets, so a wrong pairing cannot be
    ///      deployed at all rather than failing mid-swap with the vault's USDC already gone.
    function test_Constructor_RevertsOnAssetMismatch() public {
        vm.expectRevert(PsmAssetMismatch.selector);
        new SkyV1EvmProtocol(base.USDT, base.S_USDS, base.SKY_PSM3);
    }

    /// @dev sUSDS on Base is a plain ERC-20 — this is why the mainnet adapter cannot serve it.
    function test_BaseSUsdsIsNotAnErc4626Vault() public {
        (bool ok,) = base.S_USDS.staticcall(abi.encodeWithSignature("convertToAssets(uint256)", 1e18));
        assertFalse(ok, "Base sUSDS unexpectedly answers convertToAssets");
        (ok,) = base.S_USDS.staticcall(abi.encodeWithSignature("asset()"));
        assertFalse(ok, "Base sUSDS unexpectedly answers asset()");
    }

    function test_Stake() public {
        deal(base.USDC, address(this), STAKE_AMOUNT);
        usdc.forceApprove(address(sky), STAKE_AMOUNT);

        uint256 expected = psm.previewSwapExactIn(base.USDC, base.S_USDS, STAKE_AMOUNT);
        sky.stake(base.USDC, STAKE_AMOUNT);

        // The receipt token lands with the CALLER (the vault), never with the adapter.
        assertEq(sUsds.balanceOf(address(this)), expected, "vault did not receive sUSDS");
        assertEq(sUsds.balanceOf(address(sky)), 0, "adapter retained sUSDS");
        assertEq(usdc.balanceOf(address(this)), 0, "USDC not spent");
        assertEq(sky.receiptTokenOf(base.USDC), base.S_USDS);
    }

    function test_StakedBalance_IsWorthAboutWhatWentIn() public {
        deal(base.USDC, address(this), STAKE_AMOUNT);
        usdc.forceApprove(address(sky), STAKE_AMOUNT);
        sky.stake(base.USDC, STAKE_AMOUNT);

        uint256 valued = sky.getStakedBalance(base.USDC);
        // A conversion, not a trade: the round trip must return the stake bar integer rounding.
        assertApproxEqAbs(valued, STAKE_AMOUNT, 2, "round trip lost value");
    }

    function test_Unstake_ExactAmount_DeliversToRecipient() public {
        deal(base.USDC, address(this), STAKE_AMOUNT);
        usdc.forceApprove(address(sky), STAKE_AMOUNT);
        sky.stake(base.USDC, STAKE_AMOUNT);

        address recipient = makeAddr("recipient");
        uint256 want = 400e6;
        sUsds.forceApprove(address(sky), type(uint256).max);

        uint256 delivered = sky.withdraw(base.USDC, want, recipient);

        assertEq(delivered, want, "reported delivery differs from request");
        assertEq(usdc.balanceOf(recipient), want, "recipient did not receive exactly the request");
        assertEq(sUsds.balanceOf(address(sky)), 0, "adapter kept sUSDS dust");
        assertEq(usdc.balanceOf(address(sky)), 0, "adapter kept USDC");
    }

    function test_Unstake_Max_DrainsThePosition() public {
        deal(base.USDC, address(this), STAKE_AMOUNT);
        usdc.forceApprove(address(sky), STAKE_AMOUNT);
        sky.stake(base.USDC, STAKE_AMOUNT);

        address recipient = makeAddr("recipient");
        sUsds.forceApprove(address(sky), type(uint256).max);

        uint256 delivered = sky.withdraw(base.USDC, type(uint256).max, recipient);

        assertApproxEqAbs(delivered, STAKE_AMOUNT, 2, "max unstake did not return the stake");
        assertEq(usdc.balanceOf(recipient), delivered);
        assertEq(sUsds.balanceOf(address(this)), 0, "position not fully drained");
        assertEq(sUsds.balanceOf(address(sky)), 0, "adapter kept sUSDS");
    }

    function test_Unstake_Max_OnEmptyPositionIsZero() public {
        assertEq(sky.withdraw(base.USDC, type(uint256).max, makeAddr("r")), 0);
    }

    function test_RevertsOnWrongAsset() public {
        vm.expectRevert(InvalidAsset.selector);
        sky.getStakedBalance(base.USDT);

        vm.expectRevert(InvalidAsset.selector);
        sky.stake(base.USDT, 1e6);

        vm.expectRevert(InvalidAsset.selector);
        sky.withdraw(base.USDT, 1e6, address(this));
    }

    function test_NoWithdrawalQueue() public {
        assertEq(sky.getUnstakeRequestIds().length, 0);
        vm.expectRevert(ClaimUnstakedNotSupported.selector);
        sky.claimUnstaked(new uint256[](0));
    }
}
