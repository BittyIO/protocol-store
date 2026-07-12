// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

/**
 * @title UniswapX order model + Permit2 witness hashing
 * @notice Minimal, self-contained transcription of UniswapX's ExclusiveDutchOrder EIP-712
 *         structs, type strings and hashing, plus the Permit2 `permitWitnessTransferFrom`
 *         witness digest. Kept in-repo (no external UniswapX dependency) so BittyVault's
 *         intent layer can build and register orders on-chain.
 *
 *         Order flow (parallels CoW): the swapper (the vault) authorizes an off-chain order
 *         via Permit2 with signingScheme = eip1271. A filler submits it to the reactor, which
 *         calls Permit2.permitWitnessTransferFrom to pull the input token; Permit2 verifies the
 *         swapper's signature by calling swapper.isValidSignature(permit2Digest, sig). The
 *         BittyVault intent protocol registers that exact `permit2Digest` on-chain, so only
 *         orders the vault actually built can ever be pulled.
 */
interface IPermit2 {
    /**
     * @notice EIP-712 domain separator (recomputed by Permit2 when chainId changes).
     */
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    /**
     * @notice Invalidate specific unordered nonces for msg.sender: bitmap[wordPos] |= mask.
     */
    function invalidateUnorderedNonces(uint256 wordPos, uint256 mask) external;

    /**
     * @notice Current nonce bitmap word for `owner`. A set bit means that nonce is spent.
     */
    function nonceBitmap(address owner, uint256 wordPos) external view returns (uint256);
}

interface IUniswapXReactor {
    struct SignedOrder {
        bytes order;
        bytes sig;
    }

    function execute(SignedOrder calldata order) external payable;
}

library UniswapXOrders {
    struct OrderInfo {
        address reactor;
        address swapper;
        uint256 nonce;
        uint256 deadline;
        address additionalValidationContract;
        bytes additionalValidationData;
    }

    struct DutchInput {
        address token;
        uint256 startAmount;
        uint256 endAmount;
    }

    struct DutchOutput {
        address token;
        uint256 startAmount;
        uint256 endAmount;
        address recipient;
    }

    struct ExclusiveDutchOrder {
        OrderInfo info;
        uint256 decayStartTime;
        uint256 decayEndTime;
        address exclusiveFiller;
        uint256 exclusivityOverrideBps;
        DutchInput input;
        DutchOutput[] outputs;
    }

    // --- EIP-712 type strings (byte-identical to UniswapX's on-chain libs) ---

    string internal constant ORDER_INFO_TYPE =
        "OrderInfo(address reactor,address swapper,uint256 nonce,uint256 deadline,address additionalValidationContract,bytes additionalValidationData)";

    string internal constant DUTCH_OUTPUT_TYPE =
        "DutchOutput(address token,uint256 startAmount,uint256 endAmount,address recipient)";

    string internal constant TOKEN_PERMISSIONS_TYPE = "TokenPermissions(address token,uint256 amount)";

    string internal constant EXCLUSIVE_DUTCH_ORDER_TYPE =
        "ExclusiveDutchOrder(OrderInfo info,uint256 decayStartTime,uint256 decayEndTime,address exclusiveFiller,uint256 exclusivityOverrideBps,address inputToken,uint256 inputStartAmount,uint256 inputEndAmount,DutchOutput[] outputs)";

    // ExclusiveDutchOrder(...) then its referenced sub-types, sorted per EIP-712 (Dutch before Order before nothing).
    bytes internal constant ORDER_TYPE =
        abi.encodePacked(EXCLUSIVE_DUTCH_ORDER_TYPE, DUTCH_OUTPUT_TYPE, ORDER_INFO_TYPE);

    bytes32 internal constant ORDER_INFO_TYPE_HASH = keccak256(bytes(ORDER_INFO_TYPE));
    bytes32 internal constant DUTCH_OUTPUT_TYPE_HASH = keccak256(bytes(DUTCH_OUTPUT_TYPE));
    bytes32 internal constant TOKEN_PERMISSIONS_TYPE_HASH = keccak256(bytes(TOKEN_PERMISSIONS_TYPE));

    // Permit2 witness stub + the witness type string (referenced sub-types sorted alphabetically:
    // DutchOutput, ExclusiveDutchOrder, OrderInfo, TokenPermissions).
    string internal constant PERMIT2_WITNESS_STUB =
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";
    bytes internal constant PERMIT2_WITNESS_TYPE = abi.encodePacked(
        "ExclusiveDutchOrder witness)",
        DUTCH_OUTPUT_TYPE,
        EXCLUSIVE_DUTCH_ORDER_TYPE,
        ORDER_INFO_TYPE,
        TOKEN_PERMISSIONS_TYPE
    );

    /**
     * @dev The witnessTypeString the reactor passes to Permit2.permitWitnessTransferFrom.
     */
    function permit2WitnessTypeString() internal pure returns (string memory) {
        return string(PERMIT2_WITNESS_TYPE);
    }

    function hashOrderInfo(OrderInfo memory info) internal pure returns (bytes32) {
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

    function hashOutputs(DutchOutput[] memory outputs) internal pure returns (bytes32) {
        bytes memory packed;
        for (uint256 i = 0; i < outputs.length; i++) {
            DutchOutput memory o = outputs[i];
            packed = abi.encodePacked(
                packed, keccak256(abi.encode(DUTCH_OUTPUT_TYPE_HASH, o.token, o.startAmount, o.endAmount, o.recipient))
            );
        }
        return keccak256(packed);
    }

    /**
     * @notice EIP-712 struct hash of the order — the `witness` bound into the Permit2 transfer.
     */
    function hash(ExclusiveDutchOrder memory order) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(ORDER_TYPE),
                hashOrderInfo(order.info),
                order.decayStartTime,
                order.decayEndTime,
                order.exclusiveFiller,
                order.exclusivityOverrideBps,
                order.input.token,
                order.input.startAmount,
                order.input.endAmount,
                hashOutputs(order.outputs)
            )
        );
    }

    /**
     * @notice The EIP-712 digest Permit2 recovers/validates when the reactor pulls the input token.
     *         This is the exact value passed to the swapper's isValidSignature — so it is what the
     *         BittyVault intent protocol registers on-chain.
     * @param order          the fully-specified order (witness source)
     * @param permit2Domain  Permit2.DOMAIN_SEPARATOR() on the current chain
     * @param spender        the reactor address (Permit2 transfer spender)
     * @param permitAmount   the permitted input token amount (Dutch input maxAmount)
     */
    function permit2Digest(
        ExclusiveDutchOrder memory order,
        bytes32 permit2Domain,
        address spender,
        uint256 permitAmount
    ) internal pure returns (bytes32) {
        bytes32 witnessTypeHash = keccak256(abi.encodePacked(PERMIT2_WITNESS_STUB, PERMIT2_WITNESS_TYPE));
        bytes32 tokenPermissionsHash =
            keccak256(abi.encode(TOKEN_PERMISSIONS_TYPE_HASH, order.input.token, permitAmount));
        bytes32 structHash = keccak256(
            abi.encode(
                witnessTypeHash, tokenPermissionsHash, spender, order.info.nonce, order.info.deadline, hash(order)
            )
        );
        return keccak256(abi.encodePacked(hex"1901", permit2Domain, structHash));
    }
}
