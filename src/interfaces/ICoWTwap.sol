// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

interface ICoWTwap {
    event LimitOrderCreated(bytes32 indexed conditionalOrderHash, address indexed owner);
    event TwapCreated(bytes32 indexed conditionalOrderHash, address indexed owner);
    event TwapCancelled(bytes32 indexed conditionalOrderHash, address indexed owner);

    /// @param data abi.encode(sellToken, totalSellAmount, buyToken, minPartLimit, n, partDuration, span)
    ///   totalSellAmount — total tokens to sell across all n parts
    ///   minPartLimit    — minimum buy tokens per part
    ///   n               — number of parts
    ///   partDuration    — seconds per part
    ///   span            — valid window per slot in seconds (0 = full slot)
    function createTwap(bytes memory data) external returns (bytes32 conditionalOrderHash);

    function cancelTwap(bytes32 conditionalOrderHash) external;
}
