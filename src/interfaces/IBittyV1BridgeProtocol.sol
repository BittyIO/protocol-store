// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1Protocol} from "./IBittyV1Protocol.sol";

/**
 * @title IBittyV1BridgeProtocol
 * @notice Moves an asset from the vault on this chain to the owner's vault on another chain.
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
     * @param data The bridge-specific request (Across: abi.encode(AcrossBridgeProtocol.AcrossQuote)).
     * @return received What the bridge is bound to pay out on the other side, in `token`'s units
     *         (rounded down). The vault charges `amount - received` to its daily loss allowance.
     */
    function bridge(address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        payable
        returns (uint256 received);

    /**
     * @notice The most Bitty may take on one bridge, in basis points of the amount sent.
     */
    function maxFeeBps() external view returns (uint256);
}
