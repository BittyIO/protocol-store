// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

// Asset category bits (bitmask), mirrored from the guard. Only the ones this repo reads are declared.
uint8 constant ASSET_STABLE_COIN = 1;

/**
 * @title IBittyV1Guard
 * @notice The slice of the Bitty guard this repo reads. The market-swap fee split needs to know
 *         whether the token being sold is a registered stable coin, which it reads from the asset's
 *         category bitmask.
 */
interface IBittyV1Guard {
    /**
     * @notice The category bitmask an asset was registered under (0 if never registered).
     */
    function assetCategory(address assetAddress) external view returns (uint8);
}
