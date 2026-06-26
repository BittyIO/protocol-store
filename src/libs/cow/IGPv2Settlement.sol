// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

interface IGPv2Settlement {
    function domainSeparator() external view returns (bytes32);

    /// @param orderUid 56-byte UID: digest (32) || owner (20) || validTo (4)
    /// @param signed true to enable for trading, false to revoke
    function setPreSignature(bytes calldata orderUid, bool signed) external;
}
