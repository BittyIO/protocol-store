// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {TestProxy} from "../helpers/Proxy.sol";
import {
    MockTronLedger,
    MockTronStakeOps,
    MockDelegatablePrecompile,
    MockChainParameterPrecompile
} from "../helpers/TronStakeMocks.sol";
import {
    TronStakeProtocol,
    ITronStakeOps,
    BelowMinimumStake,
    InsufficientStake,
    UnstakeFailed,
    TronStakeOpFailed
} from "../../src/protocols/TronStakeProtocol.sol";
import {InvalidAsset} from "../../src/interfaces/IBittyV1Protocol.sol";
import {WithdrawToNotSupported} from "../../src/interfaces/IBittyV1Yield.sol";

/// @dev The vault side of the adapter: owns the clone, holds WTRX, has an owner() the energy goes to.
contract MockVault {
    address public owner;
    TronStakeProtocol public adapter;

    constructor(address owner_) {
        owner = owner_;
    }

    function setOwner(address owner_) external {
        owner = owner_;
    }

    function setAdapter(TronStakeProtocol adapter_, IERC20 wtrx) external {
        adapter = adapter_;
        wtrx.approve(address(adapter_), type(uint256).max);
    }

    function deposit(address asset, uint256 amount) external {
        adapter.deposit(asset, amount);
    }

    function withdraw(address asset, uint256 amount) external returns (uint256) {
        return adapter.withdraw(asset, amount, address(this));
    }

    function withdrawTo(address asset, uint256 amount, address to) external returns (uint256) {
        return adapter.withdraw(asset, amount, to);
    }

    function claim() external {
        adapter.claimWithdrawals(adapter.getPendingWithdrawalIds());
    }
}

contract TronStakeProtocolTest is Test {
    uint256 constant TRX = 1e6;

    WETH wtrx;
    MockTronLedger ledger;
    MockVault vault;
    TronStakeProtocol adapter;
    address user = makeAddr("vault owner");

    function setUp() public {
        wtrx = new WETH();
        ledger = new MockTronLedger();
        vm.etch(address(0x100000f), address(new MockDelegatablePrecompile(ledger)).code);
        vm.etch(address(0x100000b), address(new MockChainParameterPrecompile(ledger)).code);

        TronStakeProtocol impl = new TronStakeProtocol(address(wtrx), address(new MockTronStakeOps(ledger)));
        vault = new MockVault(user);
        adapter = TronStakeProtocol(payable(TestProxy.deploy(address(impl), address(vault))));
        vault.setAdapter(adapter, IERC20(address(wtrx)));

        vm.deal(address(this), 1_000_000 * TRX);
        wtrx.deposit{value: 1_000_000 * TRX}();
        wtrx.transfer(address(vault), 1_000_000 * TRX);
    }

    // ---------------------------------------------------------------- deposit

    function test_depositStakesAndDelegatesToOwner() public {
        vault.deposit(address(wtrx), 1_000 * TRX);

        assertEq(adapter.staked(), 1_000 * TRX);
        assertEq(ledger.frozen(address(adapter)), 1_000 * TRX);
        assertEq(ledger.delegation(address(adapter), user), 1_000 * TRX);
        assertEq(adapter.energyReceiver(), user);
        assertEq(adapter.delegatedEnergyStake(), 1_000 * TRX);
        assertEq(adapter.getBalance(address(wtrx)), 1_000 * TRX);
        assertEq(wtrx.balanceOf(address(vault)), 999_000 * TRX);
        assertEq(address(adapter).balance, 0);
    }

    function test_depositsAddUpOnTheSameReceiver() public {
        vault.deposit(address(wtrx), 100 * TRX);
        vault.deposit(address(wtrx), 50 * TRX);
        assertEq(ledger.delegation(address(adapter), user), 150 * TRX);
        assertEq(adapter.delegatedEnergyStake(), 150 * TRX);
    }

    function test_depositRefusesWrongAssetAndDust() public {
        vm.expectRevert(InvalidAsset.selector);
        vault.deposit(address(0xdead), 10 * TRX);
        vm.expectRevert(BelowMinimumStake.selector);
        vault.deposit(address(wtrx), TRX - 1);
    }

    function test_onlyTheVault() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        adapter.deposit(address(wtrx), 10 * TRX);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        adapter.withdraw(address(wtrx), 10 * TRX, address(vault));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        adapter.claimWithdrawals(new uint256[](0));
    }

    function test_contractOwnerStakesWithoutDelegating() public {
        vault.setOwner(address(new MockVault(user))); // a smart-account owner: TRON refuses it energy
        vault.deposit(address(wtrx), 100 * TRX);
        assertEq(adapter.staked(), 100 * TRX);
        assertEq(adapter.delegatedEnergyStake(), 0);
        assertEq(adapter.energyReceiver(), address(0));
    }

    function test_partialDelegationWhenUsageTiesUpStake() public {
        ledger.setUsageLocked(address(adapter), 30 * TRX);
        vault.deposit(address(wtrx), 100 * TRX);
        assertEq(adapter.delegatedEnergyStake(), 70 * TRX);

        ledger.setUsageLocked(address(adapter), 0);
        vault.deposit(address(wtrx), 10 * TRX); // the next deposit delegates the rest
        assertEq(adapter.delegatedEnergyStake(), 110 * TRX);
        assertEq(ledger.delegation(address(adapter), user), 110 * TRX);
    }

    function test_delegationSkippedIsNotAFailure() public {
        ledger.setUsageLocked(address(adapter), type(uint128).max);
        vault.deposit(address(wtrx), 100 * TRX);
        assertEq(adapter.staked(), 100 * TRX);
        assertEq(adapter.delegatedEnergyStake(), 0);
    }

    function test_ownerChangeMovesTheEnergy() public {
        vault.deposit(address(wtrx), 100 * TRX);
        address next = makeAddr("next owner");
        vault.setOwner(next);
        vault.deposit(address(wtrx), 10 * TRX);

        assertEq(ledger.delegation(address(adapter), user), 0);
        assertEq(ledger.delegation(address(adapter), next), 110 * TRX);
        assertEq(adapter.energyReceiver(), next);
    }

    // ---------------------------------------------------------------- withdraw / claim

    function test_withdrawQueuesThenClaimsAfterTheDelay() public {
        vault.deposit(address(wtrx), 1_000 * TRX);
        assertEq(vault.withdraw(address(wtrx), 400 * TRX), 0);

        assertEq(adapter.staked(), 600 * TRX);
        assertEq(adapter.pendingUnstake(), 400 * TRX);
        assertEq(adapter.getBalance(address(wtrx)), 1_000 * TRX);
        assertEq(ledger.delegation(address(adapter), user), 600 * TRX); // took back only what it needed
        uint256[] memory ids = adapter.getPendingWithdrawalIds();
        assertEq(ids.length, 1);
        (uint256 amount, uint256 unlockAt) = adapter.unstakeRequest(ids[0]);
        assertEq(amount, 400 * TRX);
        assertEq(unlockAt, block.timestamp + 14 days);

        vault.claim(); // too early: nothing moves
        assertEq(wtrx.balanceOf(address(vault)), 999_000 * TRX);
        assertEq(adapter.getPendingWithdrawalIds().length, 1);

        vm.warp(block.timestamp + 14 days);
        vault.claim();
        assertEq(wtrx.balanceOf(address(vault)), 999_400 * TRX);
        assertEq(adapter.getPendingWithdrawalIds().length, 0);
        assertEq(adapter.pendingUnstake(), 0);
        assertEq(adapter.getBalance(address(wtrx)), 600 * TRX);
    }

    function test_unlockFollowsTheChainsDelay() public {
        ledger.setDelayDays(1); // Nile
        vault.deposit(address(wtrx), 100 * TRX);
        vault.withdraw(address(wtrx), 100 * TRX);
        (, uint256 unlockAt) = adapter.unstakeRequest(0);
        assertEq(unlockAt, block.timestamp + 1 days);
        vm.warp(block.timestamp + 1 days);
        vault.claim();
        assertEq(wtrx.balanceOf(address(vault)), 1_000_000 * TRX);
    }

    function test_withdrawAllTakesBackAllEnergy() public {
        vault.deposit(address(wtrx), 500 * TRX);
        vault.withdraw(address(wtrx), type(uint256).max);
        assertEq(adapter.staked(), 0);
        assertEq(adapter.delegatedEnergyStake(), 0);
        assertEq(ledger.delegation(address(adapter), user), 0);
        assertEq(adapter.pendingUnstake(), 500 * TRX);
    }

    function test_withdrawUsesUndelegatedStakeFirst() public {
        ledger.setUsageLocked(address(adapter), 30 * TRX);
        vault.deposit(address(wtrx), 100 * TRX); // 70 delegated, 30 not
        vault.withdraw(address(wtrx), 20 * TRX);
        assertEq(ledger.delegation(address(adapter), user), 70 * TRX);
        assertEq(adapter.delegatedEnergyStake(), 70 * TRX);
        assertEq(adapter.staked(), 80 * TRX);
    }

    /// TRON's unfreeze releases every expired unstake as a side effect; the queue must not count it twice.
    function test_laterUnstakeReleasesEarlierOnesWithoutDoubleCounting() public {
        vault.deposit(address(wtrx), 1_000 * TRX);
        vault.withdraw(address(wtrx), 100 * TRX);
        vm.warp(block.timestamp + 15 days);
        vault.withdraw(address(wtrx), 200 * TRX);

        uint256[] memory ids = adapter.getPendingWithdrawalIds();
        assertEq(ids.length, 1);
        assertEq(ids[0], 1);
        assertEq(adapter.pendingUnstake(), 200 * TRX);
        assertEq(address(adapter).balance, 100 * TRX); // released, not yet claimed
        assertEq(adapter.getBalance(address(wtrx)), 1_000 * TRX);

        vault.claim();
        assertEq(wtrx.balanceOf(address(vault)), 999_100 * TRX);
        assertEq(adapter.getBalance(address(wtrx)), 900 * TRX);
    }

    function test_claimReleasesEverythingDueAtOnce() public {
        vault.deposit(address(wtrx), 1_000 * TRX);
        vault.withdraw(address(wtrx), 100 * TRX);
        vault.withdraw(address(wtrx), 200 * TRX);
        vm.warp(block.timestamp + 14 days);
        vault.withdraw(address(wtrx), 300 * TRX); // not due yet

        uint256[] memory onlyFirst = new uint256[](1);
        vm.prank(address(vault));
        adapter.claimWithdrawals(onlyFirst);

        assertEq(wtrx.balanceOf(address(vault)), 999_300 * TRX);
        uint256[] memory ids = adapter.getPendingWithdrawalIds();
        assertEq(ids.length, 1);
        assertEq(ids[0], 2);
        assertEq(adapter.getBalance(address(wtrx)), 700 * TRX);
    }

    function test_withdrawRefusesOtherRecipientsAndOverdraw() public {
        vault.deposit(address(wtrx), 100 * TRX);
        vm.expectRevert(WithdrawToNotSupported.selector);
        vault.withdrawTo(address(wtrx), 10 * TRX, user);
        vm.expectRevert(InsufficientStake.selector);
        vault.withdraw(address(wtrx), 101 * TRX);
        vm.expectRevert(InsufficientStake.selector);
        vault.withdraw(address(wtrx), 0);
    }

    function test_unstakeLimitSurfacesAsUnstakeFailed() public {
        vault.deposit(address(wtrx), 100 * TRX);
        for (uint256 i; i < 32; ++i) {
            vault.withdraw(address(wtrx), 1 * TRX);
        }
        vm.expectRevert(UnstakeFailed.selector);
        vault.withdraw(address(wtrx), 1 * TRX);
    }

    // ---------------------------------------------------------------- the real opcodes

    /// The Yul helper is TRON-only: on the EVM its staking instructions are invalid, so it must revert,
    /// and the adapter must turn that into a revert rather than read it as "not staked".
    function test_realStakeOpsRevertOffTron() public {
        // Yul artifacts carry no ABI (vm.getCode refuses them), so load the bytecode by path from this profile's output.
        string memory out =
            keccak256(bytes(vm.envOr("FOUNDRY_PROFILE", string("default")))) == keccak256("tron") ? "out-tron" : "out";
        string memory json = vm.readFile(string.concat(out, "/TronStakeOps.yul/TronStakeOps.json"));
        bytes memory initCode = vm.parseJsonBytes(json, ".bytecode.object");
        address ops;
        assembly {
            ops := create(0, add(initCode, 0x20), mload(initCode))
        }
        assertTrue(ops != address(0), "deploy");
        bytes memory code = ops.code;
        for (uint8 op = 0xda; op <= 0xdf; ++op) {
            if (op == 0xdc) continue; // CANCELALLUNFREEZEV2: not used
            assertTrue(_contains(code, op), "opcode missing");
        }
        (bool ok,) = ops.call{gas: 1_000_000}(abi.encodeCall(ITronStakeOps.freezeBalanceV2, (TRX, 1)));
        assertFalse(ok);

        TronStakeProtocol impl = new TronStakeProtocol(address(wtrx), ops);
        MockVault v = new MockVault(user);
        TronStakeProtocol a = TronStakeProtocol(payable(TestProxy.deploy(address(impl), address(v))));
        v.setAdapter(a, IERC20(address(wtrx)));
        vm.prank(address(vault));
        wtrx.transfer(address(v), 10 * TRX);
        vm.expectRevert(TronStakeOpFailed.selector);
        v.deposit(address(wtrx), 10 * TRX);
    }

    function _contains(bytes memory code, uint8 op) private pure returns (bool) {
        for (uint256 i; i < code.length; ++i) {
            if (uint8(code[i]) == op) return true;
        }
        return false;
    }

    receive() external payable {}
}
