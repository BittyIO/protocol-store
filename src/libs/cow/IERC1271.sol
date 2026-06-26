// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

interface IERC1271 {
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4 magicValue);
}
