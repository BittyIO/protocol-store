// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1Protocol} from "./IBittyV1Protocol.sol";

/**
 * @title IBittyV1IntentProtocol
 * @notice Generic interface for vault-custodian intent protocols (CoW Swap, etc.). Intent orders are
 *         gasless and off-chain: the asset manager signs an order off-chain and posts it to the
 *         protocol's orderbook. The vault is the ERC-1271 signer and token custodian; it holds no
 *         on-chain order registry.
 *
 *         At settlement the protocol calls the vault's isValidSignature(), which iterates the registered
 *         protocol clones and delegates to each clone's isValidSignature() until one returns the EIP-1271
 *         magic value. The clone validates the off-chain-signed order and defers the allow/auth decision
 *         to the vault. Cancellation is off-chain (orderbook soft-cancel / order expiry).
 */
interface IBittyV1IntentProtocol is IBittyV1Protocol {
    /// @notice EIP-1271 — validate an off-chain-signed order for the vault that owns this protocol clone.
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4);
}
