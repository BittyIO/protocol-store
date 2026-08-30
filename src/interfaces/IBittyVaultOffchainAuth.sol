// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

/**
 * @title IBittyVaultOffchainAuth
 * @notice Callbacks a vault-custodian intent protocol clone uses to authorize gasless, off-chain-signed
 *         orders (and their cancellations) against the vault's live state.
 *
 *         The clone validates the protocol-specific shape (that the signed payload hashes to the digest
 *         CoW asked about, that the receiver is the vault, that the partner-fee appData is intact, etc.)
 *         and then asks the vault — which owns the clone and holds all vault state — whether the recovered
 *         signer is allowed. Both callbacks are pure views (reached via staticcall during settlement).
 */
interface IBittyVaultOffchainAuth {
    /**
     * @notice Authorize placing an order. MUST return true only when the host authorises `signer` to
     *         trade, `buyToken` is allow-listed, and the vault's raw ERC-20 balance of `sellToken` is at
     *         least `sellAmount` and stays at or above its minimal-balance floor afterward. No on-chain
     *         reservation is written, so an over-signed order simply fails this check once its backing is
     *         gone — nothing leaks.
     * @dev Authorize placing an order. MUST return true only when the host authorises `signer` to
     *         trade, `buyToken` is allow-listed, and the vault's raw ERC-20 balance of `sellToken` is at
     *         least `sellAmount` and stays at or above its minimal-balance floor afterward. No on-chain
     *         reservation is written, so an over-signed order simply fails this check once its backing is
     *         gone — nothing leaks.
     * @param signer The address of the signer.
     * @param sellToken The address of the sell token.
     * @param buyToken The address of the buy token.
     * @param sellAmount The amount of the sell token.
     * @return True if the order is authorized, false otherwise.
     */
    function isOffchainOrderAuthorized(address signer, address sellToken, address buyToken, uint256 sellAmount)
        external
        view
        returns (bool);

    /**
     * @notice Authorize cancelling order(s). No token or balance checks: cancelling never moves funds,
     *         so a host that permits `signer` to trade at all should permit them to cancel — including
     *         while trading is otherwise paused, or a paused vault could not withdraw its own orders.
     * @dev WHICH signers a host authorises is the host's business and deliberately not described here.
     *      This adapter asks a question and takes an answer; it does not know whether the host models
     *      authority as one role, several, or a sub-account, and must not have to change when that
     *      model does.
     * @param signer The address recovered from the cancellation signature.
     * @return True if the host authorises `signer` to cancel its orders.
     */
    function isOffchainCancellationAuthorized(address signer) external view returns (bool);
}
