// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1IntentProtocol} from "../../interfaces/IBittyV1IntentProtocol.sol";
import {IGPv2Settlement} from "../../libs/cow/IGPv2Settlement.sol";
import {GPv2Order} from "../../libs/cow/GPv2Order.sol";
import {IComposableCoW} from "../../libs/cow/IComposableCoW.sol";
import {IERC1271} from "../../libs/cow/IERC1271.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

/**
 * @title CoWSwapV1Protocol
 * @notice CoW Swap intent protocol — pure order-instruction builder.
 *
 *         Implements IBittyV1IntentProtocol. Returns OrderInstructions that tell the vault:
 *           - registerTarget/registerCalldata: call composableCow.create() in vault context
 *             so the order is registered under the vault's address.
 *           - approveTarget: grant the vaultRelayer allowance of sellAmount.
 *         The vault never needs to know about CoW internals.
 *
 *         isValidSignature() validates CoW order signatures using composableCow.isValidSafeSignature()
 *         with owner() (vault) as the "safe", enabling the vault's generic isValidSignature() loop.
 *
 *         Single limit orders  → SingleOrderHandlerV1 (KIND_SELL or KIND_BUY)
 *         TWAP orders          → CoW TWAP handler (n equal slots)
 *         Approach 2 (one active TWAP per sell token) is enforced by AssetManagerLogic.
 */
contract CoWSwapV1Protocol is IBittyV1IntentProtocol, IERC1271, Ownable, Initializable {
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

    bytes4 private constant MAGICVALUE = 0x1626ba7e;
    uint32 private constant DEFAULT_VALID_TO_OFFSET = 3600;

    // keccak256('{"appCode":"BittyVault","metadata":{"partnerFee":{"bps":20,"recipient":"0x87C841A0fc4a64B15a7aFc13bC34F837722899aC"}},"version":"1.3.0"}')
    bytes32 public constant APP_DATA = 0x3014c5b08c479e0b12c8766ca87baa1d4ecc8da027f70600d2f93d06737e07a3;

    IGPv2Settlement public immutable settlement;
    address public immutable vaultRelayer;
    IComposableCoW public immutable composableCow;
    address public immutable twapHandler;
    address public immutable singleOrderHandler;

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

    // ============ IBittyV1IntentProtocol — builders ============

    /**
     * @notice Build registration instructions for a single limit order.
     *         The vault will call composableCow.create() in its own context (registering the order
     *         under the vault's address) and approve vaultRelayer for sellAmount.
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
            address buyToken,
            uint256 buyAmountMin,
            uint32 validTo,
            bool isSellOrder
        ) = _decodeSwapData(data);

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(sellToken_),
            buyToken: IERC20(buyToken),
            receiver: owner(),
            sellAmount: sellAmount_,
            buyAmount: buyAmountMin,
            validTo: validTo,
            appData: APP_DATA,
            feeAmount: 0,
            kind: isSellOrder ? GPv2Order.KIND_SELL : GPv2Order.KIND_BUY,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        bytes32 salt = keccak256(abi.encodePacked(block.timestamp, block.prevrandao, owner(), sellToken_, buyToken));
        IComposableCoW.ConditionalOrderParams memory params = IComposableCoW.ConditionalOrderParams({
            handler: singleOrderHandler, salt: salt, staticInput: abi.encode(order)
        });

        instructions = IBittyV1IntentProtocol.OrderInstructions({
            orderId: composableCow.hash(params),
            sellToken: sellToken_,
            sellAmount: sellAmount_,
            approveTarget: vaultRelayer,
            registerTarget: address(composableCow),
            registerCalldata: abi.encodeCall(IComposableCoW.create, (params, true))
        });
    }

    /**
     * @notice Build registration instructions for a TWAP order.
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
            address buyToken,
            uint256 minPartLimit,
            uint256 n,
            uint256 partDuration,
            uint256 span
        ) = abi.decode(data, (address, uint256, address, uint256, uint256, uint256, uint256));

        TWAPData memory twapData = TWAPData({
            sellToken: IERC20(sellToken_),
            buyToken: IERC20(buyToken),
            receiver: owner(),
            partSellAmount: totalSellAmount_ / n,
            minPartLimit: minPartLimit,
            t0: block.timestamp,
            n: n,
            t: partDuration,
            span: span,
            appData: APP_DATA
        });

        bytes32 salt = keccak256(abi.encodePacked(block.timestamp, block.prevrandao, owner(), sellToken_));
        IComposableCoW.ConditionalOrderParams memory params = IComposableCoW.ConditionalOrderParams({
            handler: twapHandler, salt: salt, staticInput: abi.encode(twapData)
        });

        instructions = IBittyV1IntentProtocol.OrderInstructions({
            orderId: composableCow.hash(params),
            sellToken: sellToken_,
            sellAmount: totalSellAmount_,
            approveTarget: vaultRelayer,
            registerTarget: address(composableCow),
            registerCalldata: abi.encodeCall(IComposableCoW.create, (params, true))
        });
        expiresAt = block.timestamp + n * partDuration;
    }

    /**
     * @notice Build cancel instructions for a limit order or TWAP.
     *         The vault will call composableCow.remove() in its own context and revoke
     *         the vaultRelayer allowance.
     */
    function buildCancelInstructions(bytes32 orderId)
        external
        view
        override
        returns (IBittyV1IntentProtocol.CancelInstructions memory instructions)
    {
        instructions = IBittyV1IntentProtocol.CancelInstructions({
            cancelTarget: address(composableCow),
            cancelCalldata: abi.encodeCall(IComposableCoW.remove, (orderId)),
            approveTarget: vaultRelayer
        });
    }

    // ============ EIP-1271 ============

    /**
     * @notice Validates CoW order signatures for orders registered under the vault (owner()).
     *         Called by vault.isValidSignature() as part of the generic intent protocol loop.
     */
    function isValidSignature(bytes32 hash, bytes memory signature)
        external
        view
        override(IERC1271, IBittyV1IntentProtocol)
        returns (bytes4)
    {
        if (signature.length == 0) return 0xffffffff;
        try composableCow.isValidSafeSignature(
            owner(), msg.sender, hash, settlement.domainSeparator(), bytes32(0), bytes(""), signature
        ) returns (
            bytes4 result
        ) {
            return result;
        } catch {
            return 0xffffffff;
        }
    }

    // ============ View ============

    function isOrderActive(bytes32 conditionalOrderHash) external view returns (bool) {
        return composableCow.singleOrders(owner(), conditionalOrderHash);
    }

    // ============ Internal ============

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
