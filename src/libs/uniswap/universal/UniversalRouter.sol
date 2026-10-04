// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BytesLib} from "../v3/Uniswap.sol";

/**
 * @dev Uniswap's Universal Router: one call that runs a command list across v2, v3 and v4 pools,
 *      which is how a route that splits between v3 and v4 liquidity executes atomically.
 */
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/**
 * @dev Permit2's allowance-transfer surface. The Universal Router never pulls tokens through a plain
 *      ERC-20 allowance; it asks Permit2, and Permit2 needs its own per-(token, spender) allowance
 *      with an expiry. The adapter grants exactly the amount of one swap for exactly one block.
 */
interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/**
 * @title UniversalRoute
 * @notice How a Universal Router route travels inside the adapter's `path` argument.
 *
 * @dev The vault hands the adapter `abi.encode(sellToken, amount, buyToken, minOut, path)` and never
 *      looks inside `path`, so a route for the Universal Router rides in the same slot as a Uniswap
 *      v3 path: TAG ‖ abi.encode(commands, inputs, deadline). A v3 path begins with a token address,
 *      so the four-byte tag is what tells the two apart; a v3 path whose first token happened to
 *      start with these bytes would need a 1-in-4-billion address, and would also have to be a
 *      length no v3 path has.
 */
library UniversalRoute {
    using BytesLib for bytes;

    bytes4 internal constant TAG = bytes4(keccak256("bitty.uniswap.universal-route"));

    function isUniversal(bytes memory path) internal pure returns (bool) {
        if (path.length < 4) return false;
        bytes32 head;
        assembly {
            head := mload(add(path, 32))
        }
        return bytes4(head) == TAG;
    }

    function decode(bytes memory path)
        internal
        pure
        returns (bytes memory commands, bytes[] memory inputs, uint256 deadline)
    {
        return abi.decode(path.slice(4, path.length - 4), (bytes, bytes[], uint256));
    }

    function encode(bytes memory commands, bytes[] memory inputs, uint256 deadline)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(TAG, abi.encode(commands, inputs, deadline));
    }
}
