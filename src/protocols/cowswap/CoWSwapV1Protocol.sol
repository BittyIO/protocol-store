// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1IntentProtocol, TwapAlreadyRegistered} from "../../interfaces/IBittyV1IntentProtocol.sol";
import {IGPv2Settlement} from "../../libs/cow/IGPv2Settlement.sol";
import {GPv2Order} from "../../libs/cow/GPv2Order.sol";
import {IERC1271} from "../../libs/cow/IERC1271.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";

/**
 * @title CoWSwapV1Protocol
 * @notice CoW Swap intent protocol — order-instruction builder and on-chain order registry.
 *
 *         Implements IBittyV1IntentProtocol. Returns OrderInstructions that tell the vault to:
 *           - registerTarget/registerCalldata: call registerOrder() or registerTwap() on this clone
 *             (owner-only), storing the order in activeOrders or twapOrders.
 *           - approveTarget: grant the vaultRelayer allowance for sellAmount.
 *
 *         After on-chain registration, the asset manager posts the order to the CoW API off-chain
 *         with signingScheme=eip1271. isValidSignature() validates against the on-chain registry.
 *
 *         Single limit orders  → activeOrders[hash] = validTo
 *         TWAP orders          → twapOrders[id]; current part hash computed on-the-fly each window
 */
contract CoWSwapV1Protocol is IBittyV1IntentProtocol, IERC1271, Ownable, Initializable {
    using Strings for uint256;

    struct TwapParams {
        address sellToken;
        address buyToken;
        uint256 sellAmountPerPart;
        uint256 buyAmountMinPerPart;
        uint32 startTime;
        uint32 partDuration;
        uint32 span; // execution window per part; 0 = full partDuration
        uint32 n; // total number of parts
        // Per-TWAP CoW appData hash, DERIVED ON-CHAIN by twapAppData(salt) — never taken
        // from the caller. It is keccak256 of a fee-bearing appData document whose
        // partnerFee {bps, recipient} is baked into this contract as constants, with only
        // the free-form `environment` field varied by the caller's salt. This guarantees
        // every TWAP part the vault signs carries the 0.2% partner fee (a user cannot
        // create a fee-free TWAP), while distinct salts keep each TWAP's part-order UIDs
        // unique so multiple TWAPs can share a sell token without colliding at settlement.
        // The off-chain layer must post the byte-identical fullAppData to the CoW API.
        bytes32 appData;
    }

    bytes4 private constant MAGICVALUE = 0x1626ba7e;
    uint32 private constant DEFAULT_VALID_TO_OFFSET = 3600;
    uint256 private constant PARTNER_FEE_BPS = 20;
    address public constant PARTNER_FEE_RECIPIENT = 0x12EE2de7BF086388B1D560eb95e7191Edfab9823;

    // orderHash → validTo;
    mapping(bytes32 => uint256) public activeOrders;

    mapping(bytes32 => TwapParams) public twapOrders;
    bytes32[] private _activeTwapIds;

    // keccak256('{"appCode":"BittyVault","metadata":{"partnerFee":{"bps":20,"recipient":"0x12EE2de7BF086388B1D560eb95e7191Edfab9823"}},"version":"1.3.0"}')
    bytes32 public constant APP_DATA = 0xdd81467643ffa93587d2dcaa8d583d5d953920b659e6c8f7235c8d613f737693;

    // Fee-bearing appData document for TWAPs, split around the per-TWAP salt. The salt is
    // placed in the free-form `environment` field (root `additionalProperties:false` forbids
    // custom keys). Keys are alphabetical + compact to match CoW's canonical serialization.
    // The partnerFee block below is identical to APP_DATA's, so TWAP fees are enforced on-chain.
    // Full document = TWAP_APP_DATA_PREFIX + Strings.toString(salt) + TWAP_APP_DATA_SUFFIX.
    string private constant TWAP_APP_DATA_PREFIX = '{"appCode":"BittyVault","environment":"';
    string private constant TWAP_APP_DATA_SUFFIX =
        '","metadata":{"partnerFee":{"bps":20,"recipient":"0x12EE2de7BF086388B1D560eb95e7191Edfab9823"}},"version":"1.3.0"}';

    IGPv2Settlement public immutable settlement;
    address public immutable vaultRelayer;

    function name() external pure override returns (string memory) {
        return "CoWSwap V1";
    }

    function version() external pure override returns (string memory) {
        return "1.0.0";
    }

    constructor(address settlement_, address vaultRelayer_) Ownable(msg.sender) {
        settlement = IGPv2Settlement(settlement_);
        vaultRelayer = vaultRelayer_;
    }

    function initialize(address newOwner) external override initializer {
        _transferOwnership(newOwner);
    }

    receive() external payable {}

    // ============ IBittyV1IntentProtocol — builders ============

    /**
     * @notice Build registration instructions for a single limit order.
     *         The vault approves the vaultRelayer and calls registerOrder() on this clone,
     *         storing the GPv2Order hash in activeOrders. The order is then posted off-chain
     *         to the CoW API with signingScheme=eip1271. No composableCow involvement.
     * @param data abi.encode(sellToken, sellAmount, buyToken, buyAmountMin[, validTo[, isSellOrder]])
     */
    /**
     * @notice Build a limit order whose bought token settles to `recipient`.
     * @dev Pass the vault as `recipient` for a normal order, or a receiver to have CoW settle the buy
     * token straight to it. The receiver is part of the order hash, so the registered digest (and thus
     * what isValidSignature authorizes) is bound to this exact recipient.
     * @param data abi.encode(sellToken, sellAmount, buyToken, buyAmountMin[, validTo[, isSellOrder]])
     * @param recipient The address that receives the bought token.
     */
    function buildLimitOrderInstructions(bytes memory data, address recipient)
        external
        view
        override
        returns (IBittyV1IntentProtocol.OrderInstructions memory instructions)
    {
        return _buildLimitOrder(data, recipient);
    }

    function _buildLimitOrder(bytes memory data, address receiver_)
        internal
        view
        returns (IBittyV1IntentProtocol.OrderInstructions memory instructions)
    {
        (
            address sellToken_,
            uint256 sellAmount_,
            address buyToken,
            uint256 buyAmountMin,
            uint32 validTo,
            bool isSellOrder
        ) = _decodeSwapData(data);

        uint256 adjustedSellAmount = isSellOrder ? sellAmount_ : _grossUpForPartnerFee(sellAmount_);
        uint256 adjustedBuyAmount = isSellOrder ? _discountForPartnerFee(buyAmountMin) : buyAmountMin;

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(sellToken_),
            buyToken: IERC20(buyToken),
            receiver: receiver_,
            sellAmount: adjustedSellAmount,
            buyAmount: adjustedBuyAmount,
            validTo: validTo,
            appData: APP_DATA,
            feeAmount: 0,
            kind: isSellOrder ? GPv2Order.KIND_SELL : GPv2Order.KIND_BUY,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        bytes32 orderHash = GPv2Order.hash(order, settlement.domainSeparator());

        instructions = IBittyV1IntentProtocol.OrderInstructions({
            orderId: orderHash,
            sellToken: sellToken_,
            sellAmount: adjustedSellAmount,
            approveTarget: vaultRelayer,
            registerTarget: address(this),
            registerCalldata: abi.encodeCall(this.registerOrder, (orderHash, validTo))
        });
    }

    // ============ Order registry ============

    function registerOrder(bytes32 orderHash, uint256 validTo) external onlyOwner {
        activeOrders[orderHash] = validTo;
    }

    function deregisterOrder(bytes32 orderHash) external onlyOwner {
        delete activeOrders[orderHash];
    }

    /**
     * @notice The exact fee-bearing appData JSON string a TWAP with `salt` commits to.
     *         The off-chain layer must PUT this byte-for-byte to the CoW API so solvers
     *         can resolve the hash and apply the partner fee.
     */
    function twapFullAppData(uint256 salt) public pure returns (string memory) {
        return string.concat(TWAP_APP_DATA_PREFIX, salt.toString(), TWAP_APP_DATA_SUFFIX);
    }

    /**
     * @notice keccak256 of twapFullAppData(salt) — the appData hash baked into every part
     *         order of the TWAP. Exposed so the frontend can cross-check its own hash.
     */
    function twapAppData(uint256 salt) public pure returns (bytes32) {
        return keccak256(bytes(twapFullAppData(salt)));
    }

    /**
     * @notice Build registration instructions for a TWAP order.
     *         Each of the n parts is a fixed sell-amount GPv2 order valid only within its time window.
     *         Part i is executable from (startTime + i*partDuration) to (partStart + effectiveSpan).
     *         After registration the caller must post each part to CoW API at the start of its window.
     * @param data abi.encode(sellToken, totalSellAmount, buyToken, minPartLimit, n, partDuration, span)
     *             The fee-bearing appData hash is derived on-chain via twapAppData(block.timestamp) — the
     *             caller supplies no appData/salt, so the 0.2% partner fee cannot be stripped. Distinct
     *             block timestamps keep concurrent TWAPs on the same sell token from colliding at settlement.
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
            uint256 minPartLimit,
            uint256 n,
            uint256 partDuration_,
            uint256 span_
        ) = abi.decode(data, (address, uint256, address, uint256, uint256, uint256, uint256));

        // Salt = block.timestamp. The vault gets its own clone, so msg.sender/address(this) add no
        // extra uniqueness; the block timestamp is the only entropy that matters and lets the
        // off-chain layer reconstruct the exact appData document from the mined block.
        bytes32 appData_ = twapAppData(block.timestamp);

        uint256 sellAmountPerPart = totalSellAmount_ / n;

        TwapParams memory params = TwapParams({
            sellToken: sellToken_,
            buyToken: buyToken_,
            sellAmountPerPart: sellAmountPerPart,
            buyAmountMinPerPart: _discountForPartnerFee(minPartLimit),
            startTime: uint32(block.timestamp),
            partDuration: uint32(partDuration_),
            span: uint32(span_),
            n: uint32(n),
            appData: appData_
        });

        bytes32 twapId = keccak256(abi.encode(params, owner()));

        expiresAt = block.timestamp + n * partDuration_;

        instructions = IBittyV1IntentProtocol.OrderInstructions({
            orderId: twapId,
            sellToken: sellToken_,
            sellAmount: totalSellAmount_,
            approveTarget: vaultRelayer,
            registerTarget: address(this),
            registerCalldata: abi.encodeCall(this.registerTwap, (twapId, params))
        });
    }

    // ============ TWAP registry ============

    function registerTwap(bytes32 twapId, TwapParams calldata params) external onlyOwner {
        // twapId derives from (params, owner) and params carries a unique appData salt,
        // so a pre-existing entry means a genuine duplicate — reject it rather than
        // pushing a second _activeTwapIds entry that could never be cleanly cancelled.
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

    /**
     * @notice Build cancel instructions for a limit order or TWAP.
     *         TWAP orders deregister locally (each part self-expires within its window).
     *         Limit orders are invalidated on the settlement contract, which emits
     *         OrderInvalidated — indexed by CoW's orderbook so the order is marked cancelled
     *         off-chain immediately, not just left un-fillable until expiry. invalidateOrder
     *         must be called by the order owner (the vault), which the vault does as msg.sender.
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
                approveTarget: vaultRelayer
            });
        } else {
            bytes memory orderUid = abi.encodePacked(orderId, owner(), uint32(activeOrders[orderId]));
            instructions = IBittyV1IntentProtocol.CancelInstructions({
                cancelTarget: address(settlement),
                cancelCalldata: abi.encodeCall(IGPv2Settlement.invalidateOrder, (orderUid)),
                approveTarget: vaultRelayer
            });
        }
    }

    // ============ EIP-1271 ============

    /**
     * @notice Validates a CoW order hash against the on-chain registry.
     *         Checks limit orders (activeOrders) and the current part of each active TWAP.
     *         The signature bytes are unused — security is guaranteed by the registry; only
     *         the vault (owner) can write to it via registerOrder() / registerTwap().
     */
    function isValidSignature(bytes32 hash, bytes memory)
        external
        view
        override(IERC1271, IBittyV1IntentProtocol)
        returns (bytes4)
    {
        // Limit orders
        uint256 validTo = activeOrders[hash];
        if (validTo != 0 && block.timestamp <= validTo && !_isInvalidated(hash, validTo)) {
            return 0x1626ba7e;
        }

        // TWAP — check if hash matches the current part of any active TWAP
        uint256 len = _activeTwapIds.length;
        for (uint256 i = 0; i < len; i++) {
            bytes32 partHash = _computeCurrentTwapPartHash(twapOrders[_activeTwapIds[i]]);
            if (partHash != bytes32(0) && partHash == hash) return 0x1626ba7e;
        }

        return 0xffffffff;
    }

    // ============ View ============

    function isOrderActive(bytes32 orderHash) external view returns (bool) {
        uint256 validTo = activeOrders[orderHash];
        if (validTo != 0 && block.timestamp <= validTo && !_isInvalidated(orderHash, validTo)) {
            return true;
        }
        uint256 len = _activeTwapIds.length;
        for (uint256 i = 0; i < len; i++) {
            bytes32 partHash = _computeCurrentTwapPartHash(twapOrders[_activeTwapIds[i]]);
            if (partHash == orderHash) return true;
        }
        return false;
    }

    function isTwapActive(bytes32 twapId) external view returns (bool) {
        TwapParams memory p = twapOrders[twapId];
        if (p.n == 0) return false;
        return block.timestamp >= p.startTime
            && block.timestamp < uint256(p.startTime) + uint256(p.n) * uint256(p.partDuration);
    }

    function getCurrentTwapPartHash(bytes32 twapId) external view returns (bytes32) {
        return _computeCurrentTwapPartHash(twapOrders[twapId]);
    }

    function activeTwapIds() external view returns (bytes32[] memory) {
        return _activeTwapIds;
    }

    // ============ Internal ============

    function _computeCurrentTwapPartHash(TwapParams memory p) internal view returns (bytes32) {
        if (p.n == 0 || block.timestamp < p.startTime) return bytes32(0);
        uint256 elapsed = block.timestamp - p.startTime;
        uint256 partIndex = elapsed / p.partDuration;
        if (partIndex >= p.n) return bytes32(0);

        uint32 effectiveSpan = p.span > 0 ? p.span : p.partDuration;
        uint32 partStart = p.startTime + uint32(partIndex) * p.partDuration;
        uint32 partEnd = partStart + effectiveSpan;
        if (block.timestamp > partEnd) return bytes32(0);

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(p.sellToken),
            buyToken: IERC20(p.buyToken),
            receiver: owner(),
            sellAmount: p.sellAmountPerPart,
            buyAmount: p.buyAmountMinPerPart,
            validTo: partEnd,
            appData: p.appData,
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        return GPv2Order.hash(order, settlement.domainSeparator());
    }

    /// @dev A cancelled (or filled) limit order has filledAmount == max/nonzero on the settlement,
    ///      so it is treated as no longer signable even though activeOrders still holds its validTo.
    function _isInvalidated(bytes32 orderHash, uint256 validTo) internal view returns (bool) {
        bytes memory uid = abi.encodePacked(orderHash, owner(), uint32(validTo));
        return settlement.filledAmount(uid) != 0;
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
            bool isSellOrder
        )
    {
        if (data.length >= 192) {
            (sellToken, sellAmount, buyToken, buyAmountMin, validTo, isSellOrder) =
                abi.decode(data, (address, uint256, address, uint256, uint32, bool));
        } else if (data.length >= 160) {
            (sellToken, sellAmount, buyToken, buyAmountMin, validTo) =
                abi.decode(data, (address, uint256, address, uint256, uint32));
            isSellOrder = true;
        } else {
            (sellToken, sellAmount, buyToken, buyAmountMin) = abi.decode(data, (address, uint256, address, uint256));
            validTo = uint32(block.timestamp + DEFAULT_VALID_TO_OFFSET);
            isSellOrder = true;
        }
    }
}
