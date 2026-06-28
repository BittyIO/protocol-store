// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1IntentProtocol, OrderNotExpired} from "../../interfaces/IBittyV1IntentProtocol.sol";
import {IBittyV1CoWTwap} from "../../interfaces/IBittyV1CoWTwap.sol";
import {IGPv2Settlement} from "../../libs/cow/IGPv2Settlement.sol";
import {GPv2Order} from "../../libs/cow/GPv2Order.sol";
import {IERC1271} from "../../libs/cow/IERC1271.sol";
import {IComposableCoW} from "../../libs/cow/IComposableCoW.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

/**
 * @title CoWSwapV1Protocol
 * @notice Intent protocol for CoW Swap. All orders (single limit + TWAP) go through
 *         Composable CoW — no off-chain API calls needed, the CoW watchdog handles submission.
 *
 *         Single limit orders  → SingleOrderHandlerV1 (KIND_SELL or KIND_BUY)
 *         TWAP orders          → CoW TWAP handler (n equal slots, KIND_SELL)
 *
 *         Both use the same Composable CoW lifecycle:
 *           create → watchdog submits each slot → cancel or cleanExpiredOrders to reclaim tokens
 */
contract CoWSwapV1Protocol is IBittyV1IntentProtocol, IBittyV1CoWTwap, IERC1271, Ownable, Initializable {
    using SafeERC20 for IERC20;

    struct TWAPData {
        IERC20 sellToken;
        IERC20 buyToken;
        address receiver;
        uint256 partSellAmount;
        uint256 minPartLimit;
        uint256 t0;
        uint256 n;
        uint256 t;
        uint256 span;
        bytes32 appData;
    }

    struct OrderRecord {
        address sellToken;
        uint256 sellAmount;
        uint256 expiresAt;
    }

    bytes4 private constant MAGICVALUE = 0x1626ba7e;
    uint32 private constant DEFAULT_VALID_TO_OFFSET = 3600;

    // keccak256('{"appCode":"BittyVault","metadata":{"partnerFee":{"bps":20,"recipient":"0x5bd59662E1ef41138581C1A8684B3610fC5fED44"}},"version":"1.3.0"}')
    bytes32 public constant APP_DATA = 0x864bbd76f9fc05b039c436595d0f2ce13d3da2338afcc6bdd15922232bb71570;

    IGPv2Settlement public immutable settlement;
    address public immutable vaultRelayer;
    IComposableCoW public immutable composableCow;
    address public immutable twapHandler;
    address public immutable singleOrderHandler;

    mapping(bytes32 => OrderRecord) private _orders;

    constructor(
        address settlement_,
        address vaultRelayer_,
        address composableCow_,
        address twapHandler_,
        address singleOrderHandler_
    ) Ownable(msg.sender) {
        settlement = IGPv2Settlement(settlement_);
        vaultRelayer = vaultRelayer_;
        composableCow = IComposableCoW(composableCow_);
        twapHandler = twapHandler_;
        singleOrderHandler = singleOrderHandler_;
    }

    function initialize(address newOwner) external override initializer {
        _transferOwnership(newOwner);
    }

    receive() external payable {}

    // ============ Single Limit Orders ============

    /**
     * @notice Place a single limit order (KIND_SELL or KIND_BUY) via Composable CoW.
     *         The CoW watchdog picks up the ConditionalOrderCreated event and submits
     *         the order automatically — no off-chain API call needed.
     * @param data abi.encode(sellToken, sellAmount, buyToken, buyAmountMin[, validTo[, isSellOrder]])
     */
    function trade(bytes memory data) external override onlyOwner returns (bytes32 conditionalOrderHash) {
        (
            address sellToken,
            uint256 sellAmount,
            address buyToken,
            uint256 buyAmountMin,
            uint32 validTo,
            bool isSellOrder
        ) = _decodeSwapData(data);

        IERC20(sellToken).safeTransferFrom(msg.sender, address(this), sellAmount);
        IERC20(sellToken).safeIncreaseAllowance(vaultRelayer, sellAmount);

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(sellToken),
            buyToken: IERC20(buyToken),
            receiver: msg.sender,
            sellAmount: sellAmount,
            buyAmount: buyAmountMin,
            validTo: validTo,
            appData: APP_DATA,
            feeAmount: 0,
            kind: isSellOrder ? GPv2Order.KIND_SELL : GPv2Order.KIND_BUY,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        bytes32 salt = keccak256(abi.encodePacked(block.timestamp, block.prevrandao, msg.sender, sellToken, buyToken));
        IComposableCoW.ConditionalOrderParams memory params = IComposableCoW.ConditionalOrderParams({
            handler: singleOrderHandler, salt: salt, staticInput: abi.encode(order)
        });

        conditionalOrderHash = composableCow.hash(params);
        composableCow.create(params, true);

        _orders[conditionalOrderHash] = OrderRecord({sellToken: sellToken, sellAmount: sellAmount, expiresAt: validTo});

        emit Trade(data, msg.sender, address(this));
        emit LimitOrderCreated(conditionalOrderHash, msg.sender);
    }

    /**
     * @notice Cancel a single limit order and return sell tokens to the vault.
     * @param data abi.encode(bytes32 conditionalOrderHash)
     */
    function cancelTrade(bytes memory data) external override onlyOwner {
        bytes32 conditionalOrderHash = abi.decode(data, (bytes32));
        composableCow.remove(conditionalOrderHash);
        _reclaimTokens(conditionalOrderHash, msg.sender);
        emit CancelTrade(data, msg.sender, address(this));
    }

    /**
     * @notice Permissionless cleanup of expired limit orders. Returns sell tokens to the vault.
     * @param conditionalOrderHashes hashes returned from LimitOrderCreated events
     */
    function cleanExpiredOrders(bytes32[] calldata conditionalOrderHashes) external override {
        for (uint256 i = 0; i < conditionalOrderHashes.length; i++) {
            bytes32 h = conditionalOrderHashes[i];
            OrderRecord memory record = _orders[h];
            if (record.expiresAt == 0 || block.timestamp <= record.expiresAt) revert OrderNotExpired();
            composableCow.remove(h);
            _reclaimTokens(h, owner());
        }
    }

    // ============ TWAP Orders ============

    /**
     * @notice Create a TWAP order via Composable CoW.
     *         Splits totalSellAmount into n equal parts executed every partDuration seconds.
     *         CoW watchdog submits each slot automatically.
     * @param data abi.encode(sellToken, totalSellAmount, buyToken, minPartLimit, n, partDuration, span)
     * @return conditionalOrderHash use to cancel via cancelTwap
     */
    function createTwap(bytes memory data) external override onlyOwner returns (bytes32 conditionalOrderHash) {
        (
            address sellToken,
            uint256 totalSellAmount,
            address buyToken,
            uint256 minPartLimit,
            uint256 n,
            uint256 partDuration,
            uint256 span
        ) = abi.decode(data, (address, uint256, address, uint256, uint256, uint256, uint256));

        IERC20(sellToken).safeTransferFrom(msg.sender, address(this), totalSellAmount);
        IERC20(sellToken).safeIncreaseAllowance(vaultRelayer, totalSellAmount);

        TWAPData memory twapData = TWAPData({
            sellToken: IERC20(sellToken),
            buyToken: IERC20(buyToken),
            receiver: msg.sender,
            partSellAmount: totalSellAmount / n,
            minPartLimit: minPartLimit,
            t0: block.timestamp,
            n: n,
            t: partDuration,
            span: span,
            appData: APP_DATA
        });

        bytes32 salt = keccak256(abi.encodePacked(block.timestamp, block.prevrandao, msg.sender, sellToken));
        IComposableCoW.ConditionalOrderParams memory params = IComposableCoW.ConditionalOrderParams({
            handler: twapHandler, salt: salt, staticInput: abi.encode(twapData)
        });

        conditionalOrderHash = composableCow.hash(params);
        composableCow.create(params, true);

        _orders[conditionalOrderHash] = OrderRecord({
            sellToken: sellToken, sellAmount: totalSellAmount, expiresAt: block.timestamp + n * partDuration
        });

        emit TwapCreated(conditionalOrderHash, msg.sender);
    }

    /**
     * @notice Cancel a TWAP order. Returns unfilled sell tokens to the vault.
     */
    function cancelTwap(bytes32 conditionalOrderHash) external override onlyOwner {
        composableCow.remove(conditionalOrderHash);
        _reclaimTokens(conditionalOrderHash, msg.sender);
        emit TwapCancelled(conditionalOrderHash, msg.sender);
    }

    // ============ EIP-1271 ============

    /**
     * @notice Validates order signatures for CoW settlement.
     *         Delegates entirely to ComposableCoW which handles both single orders and TWAP slots.
     */
    function isValidSignature(bytes32 hash, bytes memory signature)
        external
        view
        override(IERC1271, IBittyV1IntentProtocol)
        returns (bytes4)
    {
        if (signature.length == 0) return 0xffffffff;
        try composableCow.isValidSafeSignature(
            address(this), msg.sender, hash, settlement.domainSeparator(), bytes32(0), bytes(""), signature
        ) returns (
            bytes4 result
        ) {
            return result;
        } catch {
            return 0xffffffff;
        }
    }

    // ============ View Helpers ============

    function isOrderActive(bytes32 conditionalOrderHash) external view returns (bool) {
        return composableCow.singleOrders(address(this), conditionalOrderHash);
    }

    // ============ Internal ============

    function _reclaimTokens(bytes32 conditionalOrderHash, address recipient) private {
        OrderRecord memory record = _orders[conditionalOrderHash];
        if (record.sellToken != address(0)) {
            uint256 currentAllowance = IERC20(record.sellToken).allowance(address(this), vaultRelayer);
            if (currentAllowance > 0) IERC20(record.sellToken).safeDecreaseAllowance(vaultRelayer, currentAllowance);
            uint256 balance = IERC20(record.sellToken).balanceOf(address(this));
            if (balance > 0) IERC20(record.sellToken).safeTransfer(recipient, balance);
        }
        delete _orders[conditionalOrderHash];
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
