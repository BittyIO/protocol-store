// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BittyV1ProtocolBase} from "./BittyV1ProtocolBase.sol";
import {IBittyV1IntentProtocol} from "./interfaces/IBittyV1IntentProtocol.sol";

/**
 * @title BittyV1IntentProtocolBase
 * @notice Shared base for intent adapters: the cancellation record behind
 *         {IBittyV1IntentProtocol-cancelOrders}. An adapter maps its own order id to the key it validates
 *         against ({_orderKey}) and refuses that key in isValidSignature ({_isCancelled}).
 *
 * @dev The record lives in ERC-7201 namespaced storage rather than the next sequential slot, so adding
 *      it to an adapter that is already deployed (CoW) cannot collide with anything that adapter's
 *      layout holds now or will hold later.
 */
abstract contract BittyV1IntentProtocolBase is IBittyV1IntentProtocol, BittyV1ProtocolBase {
    /// @custom:storage-location erc7201:bitty.storage.IntentCancellations
    struct IntentCancellations {
        mapping(bytes32 key => bool) cancelled;
    }

    // keccak256(abi.encode(uint256(keccak256("bitty.storage.IntentCancellations")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant INTENT_CANCELLATIONS_SLOT =
        0x44580ea1a6b3980bd22afd5f96f9fd03514f25599e924cf13f74846cffbc9c00;

    function _cancellations() private pure returns (IntentCancellations storage $) {
        assembly {
            $.slot := INTENT_CANCELLATIONS_SLOT
        }
    }

    function cancelOrders(bytes[] calldata orderIds) external override onlyOwner {
        IntentCancellations storage $ = _cancellations();
        for (uint256 i = 0; i < orderIds.length; i++) {
            $.cancelled[_orderKey(orderIds[i])] = true;
        }
        emit OrdersCancelled(orderIds);
    }

    function isOrderCancelled(bytes calldata orderId) external view override returns (bool) {
        return _isCancelled(_orderKey(orderId));
    }

    function _isCancelled(bytes32 key) internal view returns (bool) {
        return _cancellations().cancelled[key];
    }

    /// @dev The key isValidSignature checks for `orderId`. Reverts with {InvalidOrderId} when malformed.
    function _orderKey(bytes calldata orderId) internal view virtual returns (bytes32);
}
