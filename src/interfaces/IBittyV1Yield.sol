// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

error ClaimNotSupported();
error WithdrawToNotSupported();

/**
 * @title IBittyV1Yield
 * @notice Putting an asset to work in a protocol and taking it back out again.
 * @dev Deliberately says nothing about WHAT KIND of protocol it is. Lending and staking are different
 *      types - and there will be more - but a vault entering or exiting a position asks the same
 *      things of all of them, so the type belongs in the guard's category, which is curation, and not
 *      in this interface, which is capability. Everything the vault needs lives here, so it never has
 *      to ask what it is talking to.
 * @dev Entering and exiting are ONE capability, not two. No adapter has ever taken an asset in
 *      without also handing it back - a one-way adapter would be a trap, not a protocol - so
 *      splitting the two only forced every caller to name which half it meant before it could ask.
 */
interface IBittyV1Yield {
    /**
     * @notice Deposit the asset into the protocol.
     * @dev Not payable. Assets reach an adapter as ERC-20 transfers - native ETH is wrapped by the
     *      vault before it gets here - so no adapter has ever read msg.value and the vault has never
     *      attached any. Accepting value would only create a way for ETH to strand in an adapter with
     *      no path back out.
     * @param asset The address of the asset to deposit.
     * @param amount The amount of the asset to deposit.
     */
    function deposit(address asset, uint256 amount) external;

    /**
     * @notice Withdraw the asset from the protocol, delivered to `recipient`.
     * @dev Pass the vault as `recipient` for a normal withdrawal, or a receiver to pay it straight out
     *      of a position in a single step. Protocols that settle asynchronously support only the vault
     *      itself and revert otherwise, since there is nothing to deliver yet.
     * @param asset The address of the asset.
     * @param amount The amount of the asset to withdraw.
     * @param recipient The address that receives the withdrawn asset.
     * @return delivered The amount of `asset` delivered to `recipient`, 0 when settlement is deferred.
     */
    function withdraw(address asset, uint256 amount, address recipient) external returns (uint256 delivered);

    /**
     * @notice What this vault holds in the protocol, valued in `asset`.
     * @dev One name for what lending called a supplied balance and staking called a staked balance.
     *      They were always the same question, and two names forced every caller to know which kind
     *      of protocol it held before it could ask.
     * @param asset The address of the asset.
     * @return uint256 The balance, in `asset` terms.
     */
    function getBalance(address asset) external view returns (uint256);

    /**
     * @notice Withdrawals requested but not yet claimed.
     * @dev EMPTY for a protocol that settles synchronously, which is what makes this askable of any
     *      yield protocol rather than only of the asynchronous ones. A caller walks the ids and
     *      claims what has finalised; getting nothing back means there is nothing outstanding.
     * @return uint256[] The outstanding withdrawal ids.
     */
    function getPendingWithdrawalIds() external view returns (uint256[] memory);

    /**
     * @notice Claim withdrawals that have finalised.
     * @dev Reverts with {ClaimNotSupported} on a protocol that settles synchronously - reachable only
     *      by calling it with ids that protocol could never have issued.
     * @param ids The withdrawal ids to claim.
     */
    function claimWithdrawals(uint256[] memory ids) external;
}
