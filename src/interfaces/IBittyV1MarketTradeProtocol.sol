// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1Protocol} from "./IBittyV1Protocol.sol";

/**
 * @title IBittyV1MarketTradeProtocol
 * @notice Immediate (market) swaps: exact-in and exact-out, routed by the adapter. Stateless — the
 *         adapter holds no position between calls, so a single router adapter can serve every pool
 *         version at once. The stateful, per-version side of an AMM (concentrated liquidity) lives in
 *         {IBittyV1MarketMakerProtocol}; the split is what lets one trade adapter and many maker
 *         adapters be curated independently.
 */
interface IBittyV1MarketTradeProtocol is IBittyV1Protocol {
    /**
     * @notice Exact-input swap (market sell): sell exactly `sellAmount`, receive ≥ `buyAmountMin`,
     *         delivered to `recipient`. Pass the vault itself as `recipient` for a normal swap, or a
     *         receiver to swap and pay it in one step.
     * @dev data = abi.encode(sellToken, sellAmount, buyToken, buyAmountMin, path). Gated by the host.
     */
    function swap(bytes memory data, address recipient) external payable;

    /**
     * @notice Exact-output swap (market buy): receive exactly `buyAmount`, spend ≤ `sellAmountMax`,
     *         delivered to `recipient`.
     * @dev data = abi.encode(sellToken, sellAmountMax, buyToken, buyAmount, reversedPath). The path
     *      must be reversed (buyToken → … → sellToken) per Uniswap V3 exactOutput. Gated by the host.
     */
    function swapExactOut(bytes memory data, address recipient) external;
}
