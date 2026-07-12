// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1IntentProtocol, TwapAlreadyRegistered} from "../../interfaces/IBittyV1IntentProtocol.sol";
import {IERC1271} from "../../libs/cow/IERC1271.sol";
import {IPermit2, UniswapXOrders} from "../../libs/uniswapx/UniswapX.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

/**
 * @title UniswapXV1Protocol
 * @notice UniswapX (ExclusiveDutchOrder) intent protocol — a drop-in sibling of CoWSwapV1Protocol.
 *
 *         Implements the SAME IBittyV1IntentProtocol interface, so the vault drives it with the exact
 *         generic flow it uses for CoW (clone → initialize(vault) → build*Instructions → execute
 *         registerCalldata → isValidSignature fan-out). Adding UniswapX therefore requires NO change
 *         to the vault: the vault never references a concrete protocol, only the interface.
 *
 *         Order lifecycle:
 *           - build*Instructions returns OrderInstructions telling the vault to approve Permit2 for the
 *             input token and call registerOrder()/registerTwap() on this clone (owner-only).
 *           - The registry key is the Permit2 `permitWitnessTransferFrom` digest — the exact value
 *             Permit2 passes to the swapper's isValidSignature when the reactor pulls the input token.
 *           - isValidSignature() returns the ERC-1271 magic value for a live registered order whose
 *             Permit2 nonce has not been spent/invalidated. The signature bytes are unused; security
 *             comes from the registry, writable only by the vault (owner).
 *
 *         Single limit order → activeOrders[digest]
 *         TWAP order         → twapOrders[id]; current part digest computed on-the-fly each window.
 *
 *         The 0.2% partner fee is enforced on-chain: every order the vault signs carries an extra
 *         DutchOutput of the fee to PARTNER_FEE_RECIPIENT, so a fee-free order can never be built.
 */
contract UniswapXV1Protocol is IBittyV1IntentProtocol, IERC1271, Ownable, Initializable {
    using UniswapXOrders for UniswapXOrders.ExclusiveDutchOrder;

    struct RegisteredOrder {
        uint256 validTo;
        uint256 nonce; // Permit2 unordered nonce — invalidated on cancel
    }

    struct TwapParams {
        address sellToken;
        address buyToken;
        uint256 sellAmountPerPart;
        uint256 buyAmountMinPerPart;
        uint32 startTime;
        uint32 partDuration;
        uint32 span; // execution window per part; 0 = full partDuration
        uint32 n; // total number of parts
        // Salt = registration block.timestamp. Derives each part's Permit2 nonce so distinct TWAPs
        // (distinct salts) never collide on nonces or digests, letting them share a sell token.
        uint256 salt;
    }

    bytes4 private constant MAGICVALUE = 0x1626ba7e;
    bytes4 private constant INVALID = 0xffffffff;
    uint32 private constant DEFAULT_VALID_TO_OFFSET = 3600;
    uint256 private constant PARTNER_FEE_BPS = 20;
    address public constant PARTNER_FEE_RECIPIENT = 0x12EE2de7BF086388B1D560eb95e7191Edfab9823;

    // permit2 digest → order (validTo + nonce)
    mapping(bytes32 => RegisteredOrder) public activeOrders;

    mapping(bytes32 => TwapParams) public twapOrders;
    bytes32[] private _activeTwapIds;

    IPermit2 public immutable permit2;
    address public immutable reactor; // UniswapX reactor = Permit2 transfer spender

    constructor(address permit2_, address reactor_) Ownable(msg.sender) {
        permit2 = IPermit2(permit2_);
        reactor = reactor_;
    }

    function initialize(address newOwner) external override initializer {
        _transferOwnership(newOwner);
    }

    receive() external payable {}

    // ============ IBittyV1IntentProtocol — builders ============

    /**
     * @notice Build registration instructions for a single limit order (a no-decay ExclusiveDutchOrder).
     *         The vault approves Permit2 and calls registerOrder() on this clone, storing the Permit2
     *         witness digest. The order is then posted off-chain to the UniswapX API with an eip1271
     *         signature reference; isValidSignature() validates against the on-chain registry.
     * @param data abi.encode(sellToken, sellAmount, buyToken, buyAmountMin[, validTo[, isSellOrder]])
     */
    function buildLimitOrderInstructions(bytes memory data)
        external
        view
        override
        returns (IBittyV1IntentProtocol.OrderInstructions memory instructions)
    {
        (
            address sellToken_,
            uint256 sellAmount_,
            address buyToken_,
            uint256 buyAmountMin_,
            uint32 validTo,
            bool isSell
        ) = _decodeSwapData(data);

        uint256 inputAmount = isSell ? sellAmount_ : _grossUpForPartnerFee(sellAmount_);
        uint256 nonce = uint256(
            keccak256(abi.encode(sellToken_, sellAmount_, buyToken_, buyAmountMin_, validTo, isSell, "uniswapx-limit"))
        );

        UniswapXOrders.ExclusiveDutchOrder memory order =
            _buildOrder(sellToken_, inputAmount, buyToken_, buyAmountMin_, nonce, block.timestamp, validTo);

        bytes32 digest = order.permit2Digest(permit2.DOMAIN_SEPARATOR(), reactor, inputAmount);

        instructions = IBittyV1IntentProtocol.OrderInstructions({
            orderId: digest,
            sellToken: sellToken_,
            sellAmount: inputAmount,
            approveTarget: address(permit2),
            registerTarget: address(this),
            registerCalldata: abi.encodeCall(this.registerOrder, (digest, validTo, nonce))
        });
    }

    /**
     * @notice Build registration instructions for a TWAP order — n sequential ExclusiveDutchOrders,
     *         each valid only within its time window. After registration the caller posts each part to
     *         the UniswapX API at the start of its window.
     * @param data abi.encode(sellToken, totalSellAmount, buyToken, minPartLimit, n, partDuration, span)
     */
    function buildTwapInstructions(bytes memory data)
        external
        view
        override
        returns (IBittyV1IntentProtocol.OrderInstructions memory instructions, uint256 expiresAt)
    {
        (
            address sellToken_,
            uint256 totalSellAmount_,
            address buyToken_,
            uint256 minPartLimit_,
            uint256 n,
            uint256 partDuration_,
            uint256 span_
        ) = abi.decode(data, (address, uint256, address, uint256, uint256, uint256, uint256));

        TwapParams memory params = TwapParams({
            sellToken: sellToken_,
            buyToken: buyToken_,
            sellAmountPerPart: totalSellAmount_ / n,
            buyAmountMinPerPart: minPartLimit_,
            startTime: uint32(block.timestamp),
            partDuration: uint32(partDuration_),
            span: uint32(span_),
            n: uint32(n),
            salt: block.timestamp
        });

        bytes32 twapId = keccak256(abi.encode(params, owner()));
        expiresAt = block.timestamp + n * partDuration_;

        instructions = IBittyV1IntentProtocol.OrderInstructions({
            orderId: twapId,
            sellToken: sellToken_,
            sellAmount: totalSellAmount_,
            approveTarget: address(permit2),
            registerTarget: address(this),
            registerCalldata: abi.encodeCall(this.registerTwap, (twapId, params))
        });
    }

    /**
     * @notice Build cancel instructions.
     *         TWAP → deregister locally (each part self-expires within its window and, once removed
     *         from the registry, isValidSignature stops authorizing its parts).
     *         Limit → invalidate the order's Permit2 nonce, which is externally observable and makes the
     *         order permanently unfillable. Must be called by the swapper (the vault) — which it is.
     */
    function buildCancelInstructions(bytes32 orderId)
        external
        view
        override
        returns (IBittyV1IntentProtocol.CancelInstructions memory instructions)
    {
        if (twapOrders[orderId].n != 0) {
            instructions = IBittyV1IntentProtocol.CancelInstructions({
                cancelTarget: address(this),
                cancelCalldata: abi.encodeCall(this.deregisterTwap, (orderId)),
                approveTarget: address(permit2)
            });
        } else {
            uint256 nonce = activeOrders[orderId].nonce;
            (uint256 wordPos, uint256 mask) = _nonceWord(nonce);
            instructions = IBittyV1IntentProtocol.CancelInstructions({
                cancelTarget: address(permit2),
                cancelCalldata: abi.encodeCall(IPermit2.invalidateUnorderedNonces, (wordPos, mask)),
                approveTarget: address(permit2)
            });
        }
    }

    // ============ Registry (owner-only) ============

    function registerOrder(bytes32 digest, uint256 validTo, uint256 nonce) external onlyOwner {
        activeOrders[digest] = RegisteredOrder({validTo: validTo, nonce: nonce});
    }

    function deregisterOrder(bytes32 digest) external onlyOwner {
        delete activeOrders[digest];
    }

    function registerTwap(bytes32 twapId, TwapParams calldata params) external onlyOwner {
        // params carry a block-timestamp salt, so an existing entry is a genuine same-block duplicate.
        if (twapOrders[twapId].n != 0) revert TwapAlreadyRegistered(twapId);
        twapOrders[twapId] = params;
        _activeTwapIds.push(twapId);
    }

    function deregisterTwap(bytes32 twapId) external onlyOwner {
        delete twapOrders[twapId];
        uint256 len = _activeTwapIds.length;
        for (uint256 i = 0; i < len; i++) {
            if (_activeTwapIds[i] == twapId) {
                _activeTwapIds[i] = _activeTwapIds[len - 1];
                _activeTwapIds.pop();
                break;
            }
        }
    }

    // ============ EIP-1271 ============

    /**
     * @notice Validate a Permit2 witness digest against the on-chain registry. Permit2 calls this on
     *         the swapper (the vault); the vault fans out to each intent clone. Checks limit orders and
     *         the current part of each active TWAP. Signature bytes are unused.
     */
    function isValidSignature(bytes32 digest, bytes memory)
        external
        view
        override(IERC1271, IBittyV1IntentProtocol)
        returns (bytes4)
    {
        RegisteredOrder memory o = activeOrders[digest];
        if (o.validTo != 0 && block.timestamp <= o.validTo && !_isNonceSpent(o.nonce)) {
            return MAGICVALUE;
        }

        uint256 len = _activeTwapIds.length;
        for (uint256 i = 0; i < len; i++) {
            (bytes32 partDigest,) = _computeCurrentTwapPart(twapOrders[_activeTwapIds[i]]);
            if (partDigest != bytes32(0) && partDigest == digest) return MAGICVALUE;
        }
        return INVALID;
    }

    // ============ Views ============

    function isOrderActive(bytes32 digest) external view returns (bool) {
        RegisteredOrder memory o = activeOrders[digest];
        if (o.validTo != 0 && block.timestamp <= o.validTo && !_isNonceSpent(o.nonce)) return true;
        uint256 len = _activeTwapIds.length;
        for (uint256 i = 0; i < len; i++) {
            (bytes32 partDigest,) = _computeCurrentTwapPart(twapOrders[_activeTwapIds[i]]);
            if (partDigest != bytes32(0) && partDigest == digest) return true;
        }
        return false;
    }

    function isTwapActive(bytes32 twapId) external view returns (bool) {
        TwapParams memory p = twapOrders[twapId];
        if (p.n == 0) return false;
        return block.timestamp >= p.startTime
            && block.timestamp < uint256(p.startTime) + uint256(p.n) * uint256(p.partDuration);
    }

    function getCurrentTwapPartDigest(bytes32 twapId) external view returns (bytes32 digest) {
        (digest,) = _computeCurrentTwapPart(twapOrders[twapId]);
    }

    function activeTwapIds() external view returns (bytes32[] memory) {
        return _activeTwapIds;
    }

    // ============ Internal ============

    /**
     * @dev Assemble a no-decay ExclusiveDutchOrder for `owner()` with the partner fee as an extra output.
     */
    function _buildOrder(
        address sellToken_,
        uint256 inputAmount,
        address buyToken_,
        uint256 buyAmountMin_,
        uint256 nonce,
        uint256 decayStart,
        uint256 validTo
    ) internal view returns (UniswapXOrders.ExclusiveDutchOrder memory order) {
        uint256 mainOut = _discountForPartnerFee(buyAmountMin_);
        uint256 feeOut = buyAmountMin_ - mainOut;

        UniswapXOrders.DutchOutput[] memory outputs = new UniswapXOrders.DutchOutput[](2);
        outputs[0] = UniswapXOrders.DutchOutput({
            token: buyToken_, startAmount: mainOut, endAmount: mainOut, recipient: owner()
        });
        outputs[1] = UniswapXOrders.DutchOutput({
            token: buyToken_, startAmount: feeOut, endAmount: feeOut, recipient: PARTNER_FEE_RECIPIENT
        });

        order = UniswapXOrders.ExclusiveDutchOrder({
            info: UniswapXOrders.OrderInfo({
                reactor: reactor,
                swapper: owner(),
                nonce: nonce,
                deadline: validTo,
                additionalValidationContract: address(0),
                additionalValidationData: ""
            }),
            decayStartTime: decayStart,
            decayEndTime: validTo,
            exclusiveFiller: address(0),
            exclusivityOverrideBps: 0,
            input: UniswapXOrders.DutchInput({token: sellToken_, startAmount: inputAmount, endAmount: inputAmount}),
            outputs: outputs
        });
    }

    /**
     * @dev The Permit2 digest of the current part of a TWAP, or (0,0) if outside any execution window.
     */
    function _computeCurrentTwapPart(TwapParams memory p) internal view returns (bytes32 digest, uint256 nonce) {
        if (p.n == 0 || block.timestamp < p.startTime) return (bytes32(0), 0);
        uint256 partIndex = (block.timestamp - p.startTime) / p.partDuration;
        if (partIndex >= p.n) return (bytes32(0), 0);

        uint32 effectiveSpan = p.span > 0 ? p.span : p.partDuration;
        uint32 partStart = p.startTime + uint32(partIndex) * p.partDuration;
        uint32 partEnd = partStart + effectiveSpan;
        if (block.timestamp > partEnd) return (bytes32(0), 0);

        nonce = uint256(keccak256(abi.encode(p.salt, partIndex, "uniswapx-twap")));
        UniswapXOrders.ExclusiveDutchOrder memory order =
            _buildOrder(p.sellToken, p.sellAmountPerPart, p.buyToken, p.buyAmountMinPerPart, nonce, partStart, partEnd);
        digest = order.permit2Digest(permit2.DOMAIN_SEPARATOR(), reactor, p.sellAmountPerPart);
    }

    function _isNonceSpent(uint256 nonce) internal view returns (bool) {
        (uint256 wordPos, uint256 mask) = _nonceWord(nonce);
        return permit2.nonceBitmap(owner(), wordPos) & mask != 0;
    }

    function _nonceWord(uint256 nonce) internal pure returns (uint256 wordPos, uint256 mask) {
        wordPos = nonce >> 8;
        mask = 1 << (nonce & 0xff);
    }

    function _discountForPartnerFee(uint256 amount) internal pure returns (uint256) {
        return amount * (10_000 - PARTNER_FEE_BPS) / 10_000;
    }

    function _grossUpForPartnerFee(uint256 amount) internal pure returns (uint256) {
        return amount * (10_000 + PARTNER_FEE_BPS) / 10_000;
    }

    function _decodeSwapData(bytes memory data)
        internal
        view
        returns (
            address sellToken,
            uint256 sellAmount,
            address buyToken,
            uint256 buyAmountMin,
            uint32 validTo,
            bool isSell
        )
    {
        if (data.length >= 192) {
            (sellToken, sellAmount, buyToken, buyAmountMin, validTo, isSell) =
                abi.decode(data, (address, uint256, address, uint256, uint32, bool));
        } else if (data.length >= 160) {
            (sellToken, sellAmount, buyToken, buyAmountMin, validTo) =
                abi.decode(data, (address, uint256, address, uint256, uint32));
            isSell = true;
        } else {
            (sellToken, sellAmount, buyToken, buyAmountMin) = abi.decode(data, (address, uint256, address, uint256));
            validTo = uint32(block.timestamp + DEFAULT_VALID_TO_OFFSET);
            isSell = true;
        }
    }
}
