// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1Protocol} from "./IBittyV1Protocol.sol";

error OrderNotExpired();

/// @dev Reverts when a TWAP order is created for a sell token that already has an active TWAP.
error ActiveTwapExists(address sellToken);

/**
 * @title IBittyV1IntentProtocol
 * @notice Generic interface for vault-custodian intent protocols (CoW Swap, UniswapX, etc.).
 *
 *         The vault is the ERC-1271 signer and token custodian for all intent orders.
 *         The protocol clone is a pure instruction builder — it never holds tokens.
 *
 *         Order lifecycle:
 *           1. AssetManagerLogic calls buildLimitOrderInstructions() or buildTwapInstructions()
 *              (view call on clone — no state change).
 *           2. The vault executes OrderInstructions.registerCalldata on registerTarget
 *              (e.g. composableCow.create(), UniswapX reactor.execute()) in its own context,
 *              so the order is registered under the vault's address.
 *           3. The vault grants allowance of sellAmount to approveTarget
 *              (e.g. CoW vaultRelayer, UniswapX reactor).
 *           4. The vault's isValidSignature() iterates registered protocol clones and delegates
 *              to each clone's isValidSignature() until one returns the EIP-1271 magic value.
 *           5. On cancel, AssetManagerLogic executes CancelInstructions.cancelCalldata on
 *              cancelTarget and revokes the outstanding allowance.
 */
interface IBittyV1IntentProtocol is IBittyV1Protocol {
    struct OrderInstructions {
        bytes32 orderId;
        address sellToken;
        uint256 sellAmount;
        address approveTarget; // vault grants allowance of sellAmount to this address
        address registerTarget; // vault calls this contract to register the order (address(0) = skip)
        bytes registerCalldata; // calldata for the registration call
    }

    struct CancelInstructions {
        address cancelTarget; // vault calls this to deregister the order (address(0) = skip)
        bytes cancelCalldata;
        address approveTarget; // vault revokes allowance from this address
    }

    event OrderCreated(bytes32 indexed orderId, address indexed vault);
    event OrderCancelled(bytes32 indexed orderId, address indexed vault);
    event TwapCreated(bytes32 indexed twapId, address indexed vault);
    event TwapCancelled(bytes32 indexed twapId, address indexed vault);

    /// @notice Build registration instructions for a single limit order. View only — no state change.
    /// @param data abi.encode(sellToken, sellAmount, buyToken, buyAmountMin[, validTo[, isSellOrder]])
    function buildLimitOrderInstructions(bytes memory data)
        external
        view
        returns (OrderInstructions memory instructions);

    /// @notice Build registration instructions for a TWAP order. View only — no state change.
    /// @param data abi.encode(sellToken, totalSellAmount, buyToken, minPartLimit, n, partDuration, span)
    /// @return instructions  order registration + approval instructions
    /// @return expiresAt     timestamp after which the last slot has expired
    function buildTwapInstructions(bytes memory data)
        external
        view
        returns (OrderInstructions memory instructions, uint256 expiresAt);

    /// @notice Build cancel/deregistration instructions for a limit order or TWAP.
    function buildCancelInstructions(bytes32 orderId) external view returns (CancelInstructions memory instructions);

    /// @notice EIP-1271 — validate signatures for orders registered under the vault by this protocol.
    ///         Called by vault.isValidSignature(); owner() must return the vault address.
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4);
}
