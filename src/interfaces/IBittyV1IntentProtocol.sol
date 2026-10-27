// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1Protocol} from "./IBittyV1Protocol.sol";

error InvalidOrderId();

/**
 * @title IBittyV1IntentProtocol
 * @notice Generic interface for vault-custodian intent protocols (CoW Swap, etc.). Intent
 *         orders are gasless and off-chain: a host-authorised signer signs an order off-chain and posts it
 *         to the protocol's orderbook. The vault is the ERC-1271 signer and token custodian; it holds no
 *         on-chain order registry.
 *
 *         At settlement the protocol calls the vault's isValidSignature(), which iterates the registered
 *         protocol clones and delegates to each clone's isValidSignature() until one returns the EIP-1271
 *         magic value. The clone validates the off-chain-signed order and defers the allow/auth decision
 *         to the vault.
 *
 * @dev Everything the vault needs from an intent protocol lives here, so the vault never has to know
 *      which one it is talking to - the same rule {IBittyV1Yield} follows for yield. Two things an
 *      intent protocol would otherwise need the VAULT to do against protocol-specific contracts are
 *      reshaped so the vault only ever calls its own clone:
 *
 *      - Approval: the vault approves its sell token to {spender}, whatever that is for the protocol
 *        (CoW's vault relayer, for one).
 *      - Cancellation: {cancelOrders} records the cancel in the clone, and {isValidSignature} refuses a
 *        cancelled order from then on. Every settlement of every intent protocol reaches the order
 *        through the vault's isValidSignature and therefore through this clone, so this is a hard cancel
 *        for all of them without the vault calling a settlement contract. A protocol's own off-chain
 *        soft-cancel (CoW's orderbook) may still be used alongside it to drop the order from the book.
 */
interface IBittyV1IntentProtocol is IBittyV1Protocol {
    /// @notice Orders cancelled by the vault. `orderIds` are as the protocol names its orders.
    event OrdersCancelled(bytes[] orderIds);

    /**
     * @notice EIP-1271 — validate an off-chain-signed order for the vault that owns this protocol clone.
     * @dev Returns the invalid value, never the magic value, for an order cancelled with {cancelOrders}.
     * @param hash The hash of the order.
     * @param signature The signature of the order.
     * @return The magic value if the order is valid, otherwise the invalid value.
     */
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4);

    /**
     * @notice The address the vault approves its sell tokens to, so the protocol can pull them at
     *         settlement.
     */
    function spender() external view returns (address);

    /**
     * @notice Cancel orders. Owner (the vault) only; the vault decides who may ask it to.
     * @dev Permanent: a cancelled order id is never valid again. Reverts with {InvalidOrderId} for an id
     *      the protocol could not have issued.
     * @param orderIds The protocol's own order ids (CoW: the order UID).
     */
    function cancelOrders(bytes[] calldata orderIds) external;

    /// @notice Whether `orderId` was cancelled with {cancelOrders}.
    function isOrderCancelled(bytes calldata orderId) external view returns (bool);
}
