// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BittyV1ProtocolBase} from "../BittyV1ProtocolBase.sol";
import {InvalidAsset} from "../interfaces/IBittyV1Protocol.sol";
import {IBittyV1Yield, WithdrawToNotSupported} from "../interfaces/IBittyV1Yield.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @dev WTRX is WETH9's shape: deposit() wraps msg.value, withdraw(wad) sends TRX back.
interface IWTRX {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

/// @dev The ABI of src/libs/tron/TronStakeOps.yul. Only ever delegatecalled.
interface ITronStakeOps {
    function freezeBalanceV2(uint256 amount, uint256 resource) external returns (bool);
    function unfreezeBalanceV2(uint256 amount, uint256 resource) external returns (bool);
    function withdrawExpireUnfreeze() external returns (uint256);
    function delegateResource(address receiver, uint256 amount, uint256 resource) external returns (bool);
    function unDelegateResource(address receiver, uint256 amount, uint256 resource) external returns (bool);
}

error BelowMinimumStake();
error InsufficientStake();
error StakeFailed();
error UnstakeFailed();
error UndelegateFailed();
error TronStakeOpFailed();

/**
 * @title TronStakeProtocol
 * @notice Stakes a vault's TRX for energy with TRON's own Stake 2.0, and lends that energy to the
 *         vault's owner. No validator vote, no third-party token: the TRX stays frozen on this
 *         adapter instance's own account and comes back, unchanged, through TRON's unstake delay.
 *
 * @dev One instance per vault (the vault clones every adapter it uses), so each vault's stake,
 *      energy and pending unstakes live on an account of their own and never mix with another's.
 *
 *      Deposit takes WTRX, unwraps it and freezes the TRX for ENERGY. Freezing earns nothing by
 *      itself (no vote is cast); what it buys is energy, which is delegated to the vault's owner,
 *      so the owner's own transactions burn less TRX. Energy sitting on this account would be
 *      wasted: on TRON a contract's energy pays for nothing it is called with.
 *
 *      Withdraw starts an unstake and returns 0: the TRX is released only after the network's
 *      unstake delay (a chain parameter: 14 days on mainnet, 1 on Nile), and {claimWithdrawals}
 *      then wraps it back into WTRX for the vault. Same flow as Lido's withdrawal queue.
 *
 *      Delegation is best-effort. TRON refuses to delegate to a contract or to an account that does
 *      not exist yet, and lets an account delegate only the part of its stake its own past usage
 *      has not tied up; whatever cannot be delegated stays undelegated and is retried on the next
 *      deposit or withdrawal. It never blocks the stake itself.
 *
 *      Accounting. TRON keeps the truth (frozen balance, unfreezing entries); this contract mirrors
 *      what it needs and reconciles from what each instruction reports:
 *      - `staked` is the TRX frozen here. Only this account can freeze or unfreeze its own balance.
 *      - Unstake requests are a FIFO queue. TRON releases every entry whose delay has passed at
 *        once, and unfreezing ALSO releases them as a side effect, so each release is measured and
 *        matched against the queue oldest-first. Entries expire in creation order as long as the
 *        network does not shorten its unstake delay between two of them.
 *      - Released TRX sits in this account's balance until claimed, and is counted by
 *        {getBalance} until then.
 */
contract TronStakeProtocol is IBittyV1Yield, BittyV1ProtocolBase {
    using SafeERC20 for IERC20;

    struct UnstakeRequest {
        uint128 amount; // sun
        uint64 unlockAt; // estimate, from the delay when requested; the network decides
    }

    /// @dev TRON's resource codes.
    uint256 private constant ENERGY = 1;
    /// @dev TRON refuses to freeze or delegate less than 1 TRX.
    uint256 private constant MIN_TRX = 1e6;
    /// @dev Stake 2.0 query precompiles (java-tron PrecompiledContracts).
    address private constant GET_CHAIN_PARAMETER = address(0x100000b);
    address private constant DELEGATABLE_RESOURCE = address(0x100000f);
    uint256 private constant UNFREEZE_DELAY_DAYS = 5; // getChainParameter key
    uint256 private constant DEFAULT_UNFREEZE_DELAY_DAYS = 14;

    IERC20 public immutable wtrx;
    /// @dev Stateless; delegatecalled so its opcodes act on this account.
    address public immutable stakeOps;

    uint256 public staked;
    uint256 public pendingUnstake;
    address public energyReceiver;
    uint256 public delegatedEnergyStake;
    uint64 private _head;
    uint64 private _tail;
    mapping(uint256 id => UnstakeRequest) private _requests;

    event Staked(uint256 amount);
    event UnstakeRequested(uint256 indexed id, uint256 amount, uint256 unlockAt);
    event Released(uint256 amount);
    event Claimed(uint256 amount);
    event EnergyDelegated(address indexed receiver, uint256 stake);
    event EnergyUndelegated(address indexed receiver, uint256 stake);
    event EnergyDelegationSkipped(address indexed receiver, uint256 stake);

    constructor(address wtrx_, address stakeOps_) {
        wtrx = IERC20(wtrx_);
        stakeOps = stakeOps_;
    }

    function protocolLineage() external pure override returns (bytes32) {
        return keccak256("bitty.adapter.tron.stake");
    }

    function protocolVersion() external pure override returns (uint256) {
        return 1_000_000; // 1.0.0
    }

    /// @dev TRX arrives from WTRX.withdraw. Released stake is credited by the network, not sent.
    receive() external payable {}

    // ------------------------------------------------------------------ IBittyV1Yield

    function deposit(address asset, uint256 amount) external override onlyOwner {
        if (asset != address(wtrx)) revert InvalidAsset();
        if (amount < MIN_TRX) revert BelowMinimumStake();

        wtrx.safeTransferFrom(msg.sender, address(this), amount);
        IWTRX(address(wtrx)).withdraw(amount);
        if (!_freeze(amount)) revert StakeFailed();
        staked += amount;
        emit Staked(amount);

        _syncDelegation(owner());
    }

    function withdraw(address asset, uint256 amount, address recipient)
        external
        override
        onlyOwner
        returns (uint256 delivered)
    {
        if (recipient != owner()) revert WithdrawToNotSupported();
        if (asset != address(wtrx)) revert InvalidAsset();
        if (amount == type(uint256).max) amount = staked;
        if (amount == 0 || amount > staked) revert InsufficientStake();

        // Release what is due first, so the unfreeze below has nothing left to release on the side.
        _release();

        // Only the undelegated part of a stake can be unfrozen: take back what the unstake needs.
        uint256 free = staked - delegatedEnergyStake;
        if (amount > free) {
            uint256 take = amount - free;
            if (!_undelegate(energyReceiver, take)) revert UndelegateFailed();
            delegatedEnergyStake -= take;
            emit EnergyUndelegated(energyReceiver, take);
        }

        uint256 before = address(this).balance;
        if (!_unfreeze(amount)) revert UnstakeFailed();
        _matchReleased(address(this).balance - before);
        staked -= amount;

        uint64 id = _tail++;
        uint64 unlockAt = uint64(block.timestamp + _unfreezeDelayDays() * 1 days);
        _requests[id] = UnstakeRequest({amount: uint128(amount), unlockAt: unlockAt});
        pendingUnstake += amount;
        emit UnstakeRequested(id, amount, unlockAt);

        _syncDelegation(recipient);
        return 0;
    }

    /**
     * @dev TRON releases every expired unstake at once, so this claims everything that is due, not
     *      just `ids`; ids still waiting stay pending. Never reverts for want of anything to claim.
     */
    function claimWithdrawals(uint256[] memory) external override onlyOwner {
        _release();
        uint256 amount = address(this).balance;
        if (amount == 0) return;
        IWTRX(address(wtrx)).deposit{value: amount}();
        wtrx.safeTransfer(msg.sender, amount);
        emit Claimed(amount);
    }

    /// @dev Staked + unstaking + released and not yet claimed, in sun (= WTRX units).
    function getBalance(address asset) external view override returns (uint256) {
        if (asset != address(wtrx)) revert InvalidAsset();
        return staked + pendingUnstake + address(this).balance;
    }

    function getPendingWithdrawalIds() external view override returns (uint256[] memory ids) {
        ids = new uint256[](_tail - _head);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = _head + i;
        }
    }

    // ------------------------------------------------------------------ views

    function unstakeRequest(uint256 id) external view returns (uint256 amount, uint256 unlockAt) {
        UnstakeRequest memory r = _requests[id];
        return (r.amount, r.unlockAt);
    }

    // ------------------------------------------------------------------ internals

    function _release() private {
        if (_head == _tail) return;
        uint256 released = _op(abi.encodeCall(ITronStakeOps.withdrawExpireUnfreeze, ()));
        _matchReleased(released);
    }

    function _matchReleased(uint256 released) private {
        if (released == 0) return;
        emit Released(released);
        uint64 head = _head;
        while (head < _tail) {
            uint256 amount = _requests[head].amount;
            if (amount > released) break;
            released -= amount;
            pendingUnstake -= amount;
            delete _requests[head];
            ++head;
        }
        _head = head;
    }

    /**
     * @dev Point the stake's energy at the vault owner's account. Moves it off a previous receiver
     *      (the vault changed owner), then delegates whatever TRON says can be.
     */
    function _syncDelegation(address vault) private {
        address target = _ownerOf(vault);
        address current = energyReceiver;
        uint256 delegated = delegatedEnergyStake;

        if (delegated != 0 && current != target) {
            if (!_undelegate(current, delegated)) revert UndelegateFailed();
            emit EnergyUndelegated(current, delegated);
            delegated = 0;
            delegatedEnergyStake = 0;
        }
        if (delegated == 0) energyReceiver = address(0);
        if (target == address(0)) return;

        uint256 amount = _delegatable();
        uint256 undelegated = staked - delegated;
        if (amount > undelegated) amount = undelegated;
        if (amount < MIN_TRX) return;

        if (_op(abi.encodeCall(ITronStakeOps.delegateResource, (target, amount, ENERGY))) == 1) {
            delegatedEnergyStake = delegated + amount;
            energyReceiver = target;
            emit EnergyDelegated(target, amount);
        } else {
            emit EnergyDelegationSkipped(target, amount);
        }
    }

    /// @dev The vault's owner, if it is an account TRON lets energy be delegated to.
    function _ownerOf(address vault) private view returns (address target) {
        (bool ok, bytes memory data) = vault.staticcall(abi.encodeWithSignature("owner()"));
        if (!ok || data.length < 32) return address(0);
        target = abi.decode(data, (address));
        if (target == address(this) || target.code.length != 0) return address(0);
    }

    function _freeze(uint256 amount) private returns (bool) {
        return _op(abi.encodeCall(ITronStakeOps.freezeBalanceV2, (amount, ENERGY))) == 1;
    }

    function _unfreeze(uint256 amount) private returns (bool) {
        return _op(abi.encodeCall(ITronStakeOps.unfreezeBalanceV2, (amount, ENERGY))) == 1;
    }

    function _undelegate(address receiver, uint256 amount) private returns (bool) {
        return _op(abi.encodeCall(ITronStakeOps.unDelegateResource, (receiver, amount, ENERGY))) == 1;
    }

    function _op(bytes memory data) private returns (uint256) {
        (bool ok, bytes memory ret) = stakeOps.delegatecall(data);
        if (!ok || ret.length != 32) revert TronStakeOpFailed();
        return abi.decode(ret, (uint256));
    }

    /// @dev How much of this account's energy stake TRON will let it delegate right now, in sun.
    function _delegatable() private view returns (uint256) {
        (bool ok, bytes memory data) = DELEGATABLE_RESOURCE.staticcall(abi.encode(address(this), ENERGY));
        if (!ok || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }

    function _unfreezeDelayDays() private view returns (uint256 days_) {
        (bool ok, bytes memory data) = GET_CHAIN_PARAMETER.staticcall(abi.encode(UNFREEZE_DELAY_DAYS));
        if (ok && data.length >= 32) days_ = abi.decode(data, (uint256));
        if (days_ == 0) days_ = DEFAULT_UNFREEZE_DELAY_DAYS;
    }
}
