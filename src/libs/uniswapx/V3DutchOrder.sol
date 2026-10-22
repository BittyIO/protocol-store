// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

/**
 * @dev Minimal bindings for UniswapX's V3DutchOrderReactor, mirrored from Uniswap/UniswapX
 *      (src/lib/V3DutchOrderLib.sol, src/lib/OrderInfoLib.sol) and Permit2 (src/libraries/PermitHash.sol).
 *
 *      Only the part of a V3 Dutch order the SWAPPER signs is carried. The reactor's V3DutchOrder also
 *      has `cosignerData` and `cosignature`, but those are added by the cosigner after the swapper signed
 *      and are not in the order hash, so they play no part in validating the swapper's signature.
 */
struct OrderInfo {
    address reactor;
    address swapper;
    uint256 nonce;
    uint256 deadline;
    address additionalValidationContract;
    bytes additionalValidationData;
}

struct NonlinearDutchDecay {
    uint256 relativeBlocks;
    int256[] relativeAmounts;
}

struct V3DutchInput {
    address token;
    uint256 startAmount;
    NonlinearDutchDecay curve;
    uint256 maxAmount;
    uint256 adjustmentPerGweiBaseFee;
}

struct V3DutchOutput {
    address token;
    uint256 startAmount;
    NonlinearDutchDecay curve;
    address recipient;
    uint256 minAmount;
    uint256 adjustmentPerGweiBaseFee;
}

/// @dev The swapper-signed fields of UniswapX's V3DutchOrder, in the same order.
struct V3DutchOrder {
    OrderInfo info;
    address cosigner;
    uint256 startingBaseFee;
    V3DutchInput baseInput;
    V3DutchOutput[] baseOutputs;
}

interface IPermit2Domain {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

library V3DutchOrderLib {
    bytes internal constant ORDER_INFO_TYPE =
        "OrderInfo(address reactor,address swapper,uint256 nonce,uint256 deadline,address additionalValidationContract,bytes additionalValidationData)";
    bytes internal constant NON_LINEAR_DECAY_TYPE =
        "NonlinearDutchDecay(uint256 relativeBlocks,int256[] relativeAmounts)";
    bytes internal constant V3_DUTCH_INPUT_TYPE =
        "V3DutchInput(address token,uint256 startAmount,NonlinearDutchDecay curve,uint256 maxAmount,uint256 adjustmentPerGweiBaseFee)";
    bytes internal constant V3_DUTCH_OUTPUT_TYPE =
        "V3DutchOutput(address token,uint256 startAmount,NonlinearDutchDecay curve,address recipient,uint256 minAmount,uint256 adjustmentPerGweiBaseFee)";
    bytes internal constant V3_DUTCH_ORDER_TYPE =
        "V3DutchOrder(OrderInfo info,address cosigner,uint256 startingBaseFee,V3DutchInput baseInput,V3DutchOutput[] baseOutputs)";
    bytes internal constant TOKEN_PERMISSIONS_TYPE = "TokenPermissions(address token,uint256 amount)";

    bytes32 internal constant ORDER_INFO_TYPE_HASH = keccak256(ORDER_INFO_TYPE);
    bytes32 internal constant NON_LINEAR_DECAY_TYPE_HASH = keccak256(NON_LINEAR_DECAY_TYPE);
    bytes32 internal constant V3_DUTCH_INPUT_TYPE_HASH =
        keccak256(abi.encodePacked(V3_DUTCH_INPUT_TYPE, NON_LINEAR_DECAY_TYPE));
    bytes32 internal constant V3_DUTCH_OUTPUT_TYPE_HASH =
        keccak256(abi.encodePacked(V3_DUTCH_OUTPUT_TYPE, NON_LINEAR_DECAY_TYPE));
    bytes32 internal constant ORDER_TYPE_HASH = keccak256(
        abi.encodePacked(
            V3_DUTCH_ORDER_TYPE, NON_LINEAR_DECAY_TYPE, ORDER_INFO_TYPE, V3_DUTCH_INPUT_TYPE, V3_DUTCH_OUTPUT_TYPE
        )
    );
    bytes32 internal constant TOKEN_PERMISSIONS_TYPE_HASH = keccak256(TOKEN_PERMISSIONS_TYPE);

    /// @dev Permit2's PermitWitnessTransferFrom type with the reactor's witness type string appended
    ///      (sub-structs in alphabetical order, as EIP-712 requires).
    bytes32 internal constant PERMIT_WITNESS_TRANSFER_FROM_TYPE_HASH = keccak256(
        abi.encodePacked(
            "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,",
            "V3DutchOrder witness)",
            NON_LINEAR_DECAY_TYPE,
            ORDER_INFO_TYPE,
            TOKEN_PERMISSIONS_TYPE,
            V3_DUTCH_INPUT_TYPE,
            V3_DUTCH_ORDER_TYPE,
            V3_DUTCH_OUTPUT_TYPE
        )
    );

    function hash(OrderInfo memory info) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_INFO_TYPE_HASH,
                info.reactor,
                info.swapper,
                info.nonce,
                info.deadline,
                info.additionalValidationContract,
                keccak256(info.additionalValidationData)
            )
        );
    }

    function hash(NonlinearDutchDecay memory curve) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                NON_LINEAR_DECAY_TYPE_HASH, curve.relativeBlocks, keccak256(abi.encodePacked(curve.relativeAmounts))
            )
        );
    }

    function hash(V3DutchInput memory input) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                V3_DUTCH_INPUT_TYPE_HASH,
                input.token,
                input.startAmount,
                hash(input.curve),
                input.maxAmount,
                input.adjustmentPerGweiBaseFee
            )
        );
    }

    function hash(V3DutchOutput memory output) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                V3_DUTCH_OUTPUT_TYPE_HASH,
                output.token,
                output.startAmount,
                hash(output.curve),
                output.recipient,
                output.minAmount,
                output.adjustmentPerGweiBaseFee
            )
        );
    }

    function hash(V3DutchOutput[] memory outputs) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](outputs.length);
        for (uint256 i = 0; i < outputs.length; i++) {
            hashes[i] = hash(outputs[i]);
        }
        return keccak256(abi.encodePacked(hashes));
    }

    /// @dev The order hash the reactor computes and hands Permit2 as the witness.
    function hash(V3DutchOrder memory order) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TYPE_HASH,
                hash(order.info),
                order.cosigner,
                order.startingBaseFee,
                hash(order.baseInput),
                hash(order.baseOutputs)
            )
        );
    }

    /**
     * @dev The EIP-712 digest Permit2 asks the swapper's ERC-1271 isValidSignature about when the reactor
     *      fills `order`: a PermitWitnessTransferFrom of the input's maxAmount, with the reactor as spender
     *      and the order hash ({hash}, passed in as `orderHash`) as witness, under Permit2's domain.
     */
    function permit2Digest(V3DutchOrder memory order, bytes32 orderHash, bytes32 permit2DomainSeparator)
        internal
        pure
        returns (bytes32)
    {
        bytes32 tokenPermissions =
            keccak256(abi.encode(TOKEN_PERMISSIONS_TYPE_HASH, order.baseInput.token, order.baseInput.maxAmount));
        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_WITNESS_TRANSFER_FROM_TYPE_HASH,
                tokenPermissions,
                order.info.reactor,
                order.info.nonce,
                order.info.deadline,
                orderHash
            )
        );
        return keccak256(abi.encodePacked(hex"1901", permit2DomainSeparator, structHash));
    }
}
