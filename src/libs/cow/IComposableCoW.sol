// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

interface IComposableCoW {
    struct ConditionalOrderParams {
        address handler;
        bytes32 salt;
        bytes staticInput;
    }

    function create(ConditionalOrderParams calldata params, bool dispatch) external;
    function remove(bytes32 singleOrderHash) external;
    function hash(ConditionalOrderParams calldata params) external pure returns (bytes32);
    function singleOrders(address owner, bytes32 orderHash) external view returns (bool);
    function isValidSafeSignature(
        address safe,
        address sender,
        bytes32 _hash,
        bytes32 _domainSeparator,
        bytes32 typeHash,
        bytes calldata encodeData,
        bytes calldata payload
    ) external view returns (bytes4 magic);
}
