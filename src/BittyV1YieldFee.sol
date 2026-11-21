// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title BittyV1YieldFee
 * @notice Bitty's fee on what a vault's position earns: {YIELD_FEE_BPS} (5%) of the gain, paid to
 *         {FEE_RECIPIENT} when the vault withdraws from the position.
 *
 *         Each adapter clone belongs to one vault, so it keeps that vault's books: per asset, the
 *         principal - what the vault has put in and not yet paid a fee on. The gain is what the
 *         position is worth above it, and the fee is 5% of that gain, never of the principal.
 *
 *          - A withdrawal pays the fee owed out of the position on top of what was asked for, so the
 *            recipient receives exactly the amount; a full withdrawal pays it out of the proceeds.
 *          - A partial withdrawal owing less than {_minFee} - 100 tokens of a stablecoin, 0.1 of
 *            anything else - leaves the fee owed instead, saving the transfers it would cost: what
 *            is withdrawn comes out of the principal, and the gain stays where it is. A full
 *            withdrawal, or one reaching into the gain, always pays.
 *          - A deposit pays nothing: all of it goes to work and adds to the principal, and the gain
 *            already earned stays owed until the next withdrawal.
 *          - Below the principal there is no gain, and the principal comes down to what the position
 *            is worth. The books see only what moves through this clone, and the vault holds the
 *            receipt token: one that leaves some other way looks like a loss, and a principal left
 *            above the position would shield later earnings from the fee. The cost is that a
 *            recovery after a real loss is charged as earnings.
 *          - {getBalance} answers what the vault can take out: the position less the fee owed.
 *
 *         An asset the clone has never booked - every asset of a clone upgraded from a release
 *         before this fee - starts at what it is worth when first touched, with nothing owed: what a
 *         position earned before the fee existed is never charged.
 *
 * @dev The books live at an ERC-7201 slot, not in the adapter's ordinary storage: a clone upgraded to
 *      this release already has its older variables laid out from slot 0, and a new variable there
 *      would land on top of them.
 */
abstract contract BittyV1YieldFee {
    using SafeERC20 for IERC20;

    /// The fee Safe's own Bitty vault, as for trades and bridges.
    address public constant FEE_RECIPIENT = 0xF0E7f6998B362BD15CF819C7EBfcaCe8865FECA0;
    /// 5% of what the position earned.
    uint256 public constant YIELD_FEE_BPS = 500;

    event YieldFeePaid(address indexed asset, uint256 fee);

    struct Position {
        uint128 principal;
        bool booked;
    }

    /// A deferred withdrawal's share of the fee, settled when it is claimed (Lido).
    struct PendingFee {
        uint128 fee;
        uint128 requested;
    }

    /// @custom:storage-location erc7201:bitty.storage.YieldFee
    struct YieldFeeStorage {
        mapping(address asset => Position) positions;
        mapping(uint256 requestId => PendingFee) pending;
    }

    // keccak256(abi.encode(uint256(keccak256("bitty.storage.YieldFee")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant YIELD_FEE_STORAGE = 0x2d4067ecfda5a448de8e348c34efdb6372d1623189c949dcadc6a9438ae44d00;

    function _yieldFee() internal pure returns (YieldFeeStorage storage $) {
        assembly {
            $.slot := YIELD_FEE_STORAGE
        }
    }

    /**
     * What the vault's position in `asset` is worth, in `asset`, before the fee.
     */
    function _gross(address asset) internal view virtual returns (uint256);

    function _owed(Position memory p, uint256 gross) private pure returns (uint256) {
        if (!p.booked || gross <= p.principal) return 0;
        return (gross - p.principal) * YIELD_FEE_BPS / 10_000;
    }

    /**
     * What the vault has in the position and has not paid a fee on; for an unbooked asset, its value.
     */
    function principalOf(address asset) external view returns (uint256) {
        Position memory p = _yieldFee().positions[asset];
        uint256 gross = _gross(asset);
        return p.booked && p.principal < gross ? p.principal : gross;
    }

    /**
     * The fee the position owes now, paid at its next withdrawal.
     */
    function feeOwed(address asset) public view returns (uint256) {
        return _owed(_yieldFee().positions[asset], _gross(asset));
    }

    /**
     * The position less the fee it owes: what the vault can take out.
     */
    function _net(address asset) internal view returns (uint256) {
        uint256 gross = _gross(asset);
        return gross - _owed(_yieldFee().positions[asset], gross);
    }

    /**
     * @dev The least fee a partial withdrawal pays, in `asset`: 100 tokens of a stablecoin, 0.1 of
     *      anything else.
     */
    function _minFee(address asset) internal view virtual returns (uint256);

    /**
     * @dev What a withdrawal of `amount` (the maximum for all of it) pays of the `owed` fee: all of it,
     *      or nothing when it is a partial withdrawal of principal owing less than {_minFee}.
     */
    function _feeDue(address asset, uint256 amount, uint256 owed) internal view returns (uint256) {
        if (owed == 0 || amount == type(uint256).max) return owed;
        if (amount >= _yieldFee().positions[asset].principal || owed >= _minFee(asset)) return owed;
        return 0;
    }

    /**
     * @dev Called before a deposit or withdrawal moves anything. Books an unbooked asset at what it is
     *      worth, owing nothing, and brings a principal above the position down to it.
     * @return gross The position's value now.
     * @return owed The fee it owes now.
     */
    function _openBooks(address asset) internal returns (uint256 gross, uint256 owed) {
        Position storage p = _yieldFee().positions[asset];
        gross = _gross(asset);
        if (!p.booked || gross < p.principal) {
            p.booked = true;
            p.principal = uint128(gross);
            return (gross, 0);
        }
        owed = _owed(p, gross);
    }

    /**
     * @dev After a deposit: what it added to the position is principal; the gain stays owed.
     */
    function _closeDeposit(address asset, uint256 grossBefore) internal {
        uint256 grossAfter = _gross(asset);
        if (grossAfter > grossBefore) _yieldFee().positions[asset].principal += uint128(grossAfter - grossBefore);
    }

    /**
     * @dev After a withdrawal. One that paid what was owed leaves all principal. One that left the fee
     *      owed (`deferred`) took only principal, so the principal falls by what left and the gain stays.
     */
    function _closeWithdrawal(address asset, uint256 grossBefore, bool deferred) internal {
        Position storage p = _yieldFee().positions[asset];
        uint256 grossAfter = _gross(asset);
        if (!deferred) {
            p.principal = uint128(grossAfter);
            return;
        }
        uint256 removed = grossBefore > grossAfter ? grossBefore - grossAfter : 0;
        p.principal = p.principal > removed ? uint128(p.principal - removed) : 0;
    }

    /**
     * Pay `fee` of `token`, which this clone holds, to {FEE_RECIPIENT}.
     */
    function _payYieldFee(address token, uint256 fee) internal {
        if (fee == 0) return;
        IERC20(token).safeTransfer(FEE_RECIPIENT, fee);
        emit YieldFeePaid(token, fee);
    }
}
