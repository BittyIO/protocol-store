// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

error ClaimNotSupported();

/// @dev The protocol can only return an asset to its owner, so it cannot pay a third party straight
///      out of a position. Asynchronous exits are the usual case: at the point of the request there
///      is nothing yet to deliver.
error WithdrawToNotSupported();

/**
 * @title IBittyV1Withdrawable
 * @notice Taking an asset back out of a protocol.
 * @dev Deliberately says nothing about WHAT KIND of protocol it is. Lending and staking are different
 *      types - and there will be more - but a vault exiting a position asks the same things of all of
 *      them, so the type belongs in the guard's category, which is curation, and not in this
 *      interface, which is capability. Anything the vault needs in order to exit lives here, so the
 *      vault never has to ask what it is talking to.
 */
interface IBittyV1Withdrawable {
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
     *      withdrawable protocol rather than only of the asynchronous ones. A caller walks the ids and
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
