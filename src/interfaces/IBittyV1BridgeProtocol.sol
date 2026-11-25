// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1Protocol} from "./IBittyV1Protocol.sol";

/**
 * @title IBittyV1BridgeProtocol
 * @notice Moves an asset from the vault on this chain to its counterpart vault on another chain
 *         ({bridge}), or to someone else's address there ({bridgeTo}).
 *         Stateless: the adapter holds nothing between calls. Each adapter states what it can enforce
 *         on this chain about where the money goes and what arrives.
 */
interface IBittyV1BridgeProtocol is IBittyV1Protocol {
    /**
     * @notice Emitted once per bridge, after the deposit into the bridge.
     * @param token The asset sent, address(0) for the chain's native coin.
     * @param amount What the vault handed over, fee included.
     * @param fee The Bitty fee taken out of `amount`.
     * @param data The bridge-specific request, as passed in.
     */
    event Bridged(address indexed token, uint256 amount, uint256 fee, bytes data);

    /**
     * @notice Send `amount` of `token` across: `fee` of it to Bitty, the rest into the bridge.
     * @dev Pulls exactly `amount` from the caller for an ERC-20, or takes it as `msg.value` for the
     *      native coin (`token` = address(0)). `fee` may not exceed {maxFeeBps} of `amount`. Gated by
     *      the host vault.
     * @param token The asset to send, address(0) for the native coin.
     * @param amount What leaves the vault, fee included.
     * @param fee The Bitty fee, at most `amount * maxFeeBps / 10_000`.
     * @param data The bridge-specific request (Across: abi.encode(AcrossBridgeProtocol.AcrossQuote),
     *        followed by the vault's creation owner to or from TRON).
     * @return received What the bridge is bound to pay out on the other side, in `token`'s units
     *         (rounded down). The vault charges `amount - received` to its daily loss allowance.
     */
    function bridge(address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        payable
        returns (uint256 received);

    /**
     * @notice Emitted once per {bridgeTo}, after the deposit into the bridge.
     * @param token The asset sent.
     * @param destinationChainId The chain it is paid on.
     * @param recipient Who is paid on the other side.
     * @param amount What the vault handed over, fee included.
     * @param fee The Bitty fee taken out of `amount`.
     * @param data The bridge-specific request, as passed in.
     */
    event BridgedTo(
        address indexed token,
        uint256 destinationChainId,
        bytes32 indexed recipient,
        uint256 amount,
        uint256 fee,
        bytes data
    );

    /**
     * @notice Send `amount` of the ERC-20 `token` across to `recipient`, someone other than the
     *         vault: `fee` of it to Bitty, the rest into the bridge.
     * @dev Pulls exactly `amount` from the caller. `fee` may not exceed {maxFeeBps} of `amount`.
     *      Pays `recipient` and no one else; refuses address(0) and the vault itself, whose
     *      counterpart goes through {bridge}. The vault meters all of `amount` against its send
     *      allowance, so it charges nothing for `received`. Gated by the host vault.
     * @param destinationChainId The chain `recipient` is paid on; a request for another is refused.
     * @param recipient Who is paid on the other side, as 32 bytes: a 20-byte address (EVM, TRON)
     *        left-padded, a Solana address in full.
     * @param data The bridge-specific request (Across: abi.encode(AcrossBridgeProtocol.AcrossQuote)).
     * @return received What the bridge is bound to pay out on the other side, in `token`'s units.
     */
    function bridgeTo(
        address token,
        uint256 amount,
        uint256 fee,
        uint256 destinationChainId,
        bytes32 recipient,
        bytes calldata data
    ) external returns (uint256 received);

    /**
     * @notice The most Bitty may take on one bridge, in basis points of the amount sent.
     */
    function maxFeeBps() external view returns (uint256);
}
