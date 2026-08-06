// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

/**
 * @title IBittyVaultOffchainAuth
 * @notice Callback a vault-custodian intent protocol clone uses to authorize a gasless,
 *         off-chain-signed order against the vault's live state.
 *
 *         The clone validates the protocol-specific shape of the order (that the signed
 *         payload hashes to the digest CoW asked about, that the receiver is the vault,
 *         that the partner-fee appData is intact, etc.) and then asks the vault — which
 *         owns the clone and holds all vault state — whether the recovered signer is
 *         allowed to place this exact trade right now.
 *
 *         The vault MUST enforce, as a pure view (no state change — this is reached via
 *         staticcall during CoW settlement):
 *           - `signer` is the vault's asset manager AND that manager is full-access. A
 *             restricted manager's caps (lifetime invest cap, per-trade cap, throttle)
 *             require persistent state that a view cannot maintain, so gasless off-chain
 *             signing is offered to full-access managers only; return false otherwise.
 *           - `buyToken` is a vault-allowlisted asset.
 *           - the vault's raw ERC-20 balance of `sellToken` is at least `sellAmount` (so the
 *             settlement can pull it) AND stays at or above the token's minimal-balance floor
 *             afterward.
 *
 *         There is no on-chain reservation in this path: over-signed orders simply fail this
 *         check once the backing balance is gone, so nothing leaks and nothing needs cleanup.
 */
interface IBittyVaultOffchainAuth {
    function isOffchainOrderAuthorized(address signer, address sellToken, address buyToken, uint256 sellAmount)
        external
        view
        returns (bool);
}
