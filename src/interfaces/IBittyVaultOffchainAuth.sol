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
     * @notice Authorize placing an order. MUST return true only when `signer` is the vault's asset
     *         manager, `buyToken` is allow-listed, and the vault's raw ERC-20 balance of `sellToken` is at
     *         least `sellAmount` and stays at or above its minimal-balance floor afterward. No on-chain
     *         reservation is written, so an over-signed order simply fails this check once its backing is
     *         gone — nothing leaks.
     * @dev Authorize placing an order. MUST return true only when `signer` is the vault's asset
     *         manager, `buyToken` is allow-listed, and the vault's raw ERC-20 balance of `sellToken` is at
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
     * @notice Authorize cancelling order(s). Cancellation only requires that `signer` is the vault's asset
     *         manager (no token/balance checks — cancelling never moves funds and is always allowed, even
     *         while trading is paused).
     * @dev Authorize cancelling order(s). Cancellation only requires that `signer` is the vault's asset
     *         manager (no token/balance checks — cancelling never moves funds and is always allowed, even
     *         while trading is paused).
     * @param signer The address of the signer.
     * @return True if the signer is the vault's asset manager, false otherwise.
     */
    function isOffchainManager(address signer) external view returns (bool);
}
