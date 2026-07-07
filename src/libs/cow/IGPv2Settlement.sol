// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

interface IGPv2Settlement {
    function domainSeparator() external view returns (bytes32);

    /// @param orderUid 56-byte UID: digest (32) || owner (20) || validTo (4)
    /// @param signed true to enable for trading, false to revoke
    function setPreSignature(bytes calldata orderUid, bool signed) external;

    /// @notice Marks an order as fully filled so it can never settle. Emits OrderInvalidated,
    ///         which CoW's orderbook indexes to mark the order cancelled. Caller must be the
    ///         owner encoded in the UID.
    function invalidateOrder(bytes calldata orderUid) external;

    /// @notice Amount of an order already filled (or type(uint256).max once invalidated).
    function filledAmount(bytes calldata orderUid) external view returns (uint256);
}
