// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {
    IIntentProvider,
    ApprovalNotFound,
    OrderNotExpired
} from "../interfaces/IIntentProvider.sol";
import {IGPv2Settlement} from "../libs/cow/GPv2Settlement.sol";
import {GPv2Order} from "../libs/cow/GPv2Order.sol";
import {IERC1271} from "../libs/cow/IERC1271.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

/**
 * @title CoW Swap Provider
 * @notice IIntentProvider implementation for CoW Protocol using EIP-1271 and PreSign.
 * @dev Orders use PreSign + EIP-1271 (`trade`). Settlement is asynchronous (solver fills the order in a batch).
 */
contract CoWSwapProvider is IIntentProvider, IERC1271, Ownable, Initializable {
    using SafeERC20 for IERC20;

    // @dev EIP-1271 magic value for valid signature
    bytes4 private constant MAGICVALUE = 0x1626ba7e;

    // @dev Default order validity (1 hour) when not specified in swap data
    uint32 private constant DEFAULT_VALID_TO_OFFSET = 3600;

    IGPv2Settlement public immutable settlement;
    address public immutable vaultRelayer;

    // ─────────────── single-order state ───────────────

    // @dev Approved order digests for EIP-1271 signing (owner => digest => approved)
    mapping(address => mapping(bytes32 => bool)) public approvedOrderDigests;

    /// @dev Sell token used for a given order digest so cancelTrade can revoke vault relayer allowance
    mapping(bytes32 => address) private _digestToSellToken;

    /// @dev validTo for a given order digest, used by cleanExpiredOrders
    mapping(bytes32 => uint32) private _digestToValidTo;

    /// @dev Sell amount for a given order digest, used by cleanExpiredOrders to decrease allowance precisely
    mapping(bytes32 => uint256) private _digestToSellAmount;

    /**
     * @notice Constructor.
     * @param settlement_   GPv2Settlement contract address.
     * @param vaultRelayer_ CoW vault relayer address (approved for ERC-20 pulls during settlement).
     */
    constructor(address settlement_, address vaultRelayer_) {
        settlement = IGPv2Settlement(settlement_);
        vaultRelayer = vaultRelayer_;
    }

    function initialize(address newOwner) external override initializer {
        _transferOwnership(newOwner);
    }

    receive() external payable {}

    /**
     * @notice Submit a single CoW Protocol order using PreSign + EIP-1271.
     * @dev Tokens are transferred to this contract and the vault relayer allowance is increased.
     *      The order must be submitted to the CoW API by an off-chain service.
     *      Settlement is asynchronous (solver fills the order in a batch).
     *
     * @param data Encoded: (sellToken, sellAmount, buyToken, buyAmountMin) or
     *             (sellToken, sellAmount, buyToken, buyAmountMin, validTo) or
     *             (sellToken, sellAmount, buyToken, buyAmountMin, validTo, isSellOrder)
     */
    function trade(bytes memory data) external override onlyOwner {
        (
            address sellToken,
            uint256 sellAmount,
            address buyToken,
            uint256 buyAmountMin,
            uint32 validTo,
            bool isSellOrder
        ) = _decodeSwapData(data);

        if (sellToken != address(0)) {
            IERC20(sellToken).safeTransferFrom(msg.sender, address(this), sellAmount);
            IERC20(sellToken).safeIncreaseAllowance(vaultRelayer, sellAmount);
        }

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(sellToken),
            buyToken: IERC20(buyToken),
            receiver: msg.sender,
            sellAmount: sellAmount,
            buyAmount: buyAmountMin,
            validTo: validTo,
            appData: bytes32(0),
            feeAmount: 0,
            kind: isSellOrder ? GPv2Order.KIND_SELL : GPv2Order.KIND_BUY,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        bytes32 orderDigest = GPv2Order.hash(order, settlement.domainSeparator());
        bytes memory orderUid = GPv2Order.packOrderUid(orderDigest, address(this), validTo);

        approvedOrderDigests[owner()][orderDigest] = true;
        settlement.setPreSignature(orderUid, true);

        if (sellToken != address(0)) {
            _digestToSellToken[orderDigest] = sellToken;
            _digestToSellAmount[orderDigest] = sellAmount;
        }
        _digestToValidTo[orderDigest] = validTo;

        emit Trade(data, msg.sender, address(this));
    }

    /**
     * @notice Approve an order digest for EIP-1271 signing (single orders).
     * @param orderDigest The EIP-712 order digest to approve.
     */
    function approveOrderDigest(bytes32 orderDigest) external onlyOwner {
        approvedOrderDigests[owner()][orderDigest] = true;
    }

    /**
     * @notice Revoke an approved order digest.
     * @param orderDigest The EIP-712 order digest to revoke.
     */
    function revokeOrderDigest(bytes32 orderDigest) external onlyOwner {
        approvedOrderDigests[owner()][orderDigest] = false;
    }

    /**
     * @notice Cancel a single trade by revoking its order digest and PreSignature.
     * @param data abi.encode(bytes32 orderDigest, uint32 validTo)
     */
    function cancelTrade(bytes memory data) external override onlyOwner {
        (bytes32 orderDigest, uint32 validTo) = abi.decode(data, (bytes32, uint32));
        approvedOrderDigests[owner()][orderDigest] = false;
        bytes memory orderUid = GPv2Order.packOrderUid(orderDigest, address(this), validTo);
        settlement.setPreSignature(orderUid, false);

        address sellToken = _digestToSellToken[orderDigest];
        if (sellToken != address(0)) {
            uint256 orderSellAmount = _digestToSellAmount[orderDigest];
            uint256 currentAllowance = IERC20(sellToken).allowance(address(this), vaultRelayer);
            uint256 decreaseBy = orderSellAmount < currentAllowance ? orderSellAmount : currentAllowance;
            if (decreaseBy > 0) IERC20(sellToken).safeDecreaseAllowance(vaultRelayer, decreaseBy);
            uint256 balance = IERC20(sellToken).balanceOf(address(this));
            uint256 toReturn = orderSellAmount < balance ? orderSellAmount : balance;
            if (toReturn > 0) IERC20(sellToken).safeTransfer(msg.sender, toReturn);
            delete _digestToSellToken[orderDigest];
            delete _digestToSellAmount[orderDigest];
        }
        delete _digestToValidTo[orderDigest];

        emit CancelTrade(data, msg.sender, address(this));
    }

    /**
     * @notice EIP-1271 signature verification for GPv2Settlement.
     */
    function isValidSignature(
        bytes32 hash,
        bytes memory /* signature */
    )
        external
        view
        override(IERC1271, IIntentProvider)
        returns (bytes4)
    {
        if (approvedOrderDigests[owner()][hash]) return MAGICVALUE;
        return 0xffffffff;
    }

    /**
     * @notice Compute order digest for a given order (for off-chain order submission).
     */
    function getOrderDigest(GPv2Order.Data memory order) external view returns (bytes32) {
        return GPv2Order.hash(order, settlement.domainSeparator());
    }

    function revokeApprovals(address[] calldata tokens) external override onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (IERC20(tokens[i]).allowance(address(this), vaultRelayer) == 0) continue;
            IERC20(tokens[i]).safeApprove(vaultRelayer, 0);
        }
    }

    function cleanExpiredOrders(bytes32[] calldata orderDigests) external override {
        for (uint256 i = 0; i < orderDigests.length; i++) {
            bytes32 orderDigest = orderDigests[i];
            if (_digestToValidTo[orderDigest] == 0 || block.timestamp <= _digestToValidTo[orderDigest]) {
                revert OrderNotExpired();
            }
            approvedOrderDigests[owner()][orderDigest] = false;
            bytes memory orderUid = GPv2Order.packOrderUid(orderDigest, address(this), _digestToValidTo[orderDigest]);
            settlement.setPreSignature(orderUid, false);
            address sellToken = _digestToSellToken[orderDigest];
            if (sellToken != address(0)) {
                uint256 orderSellAmount = _digestToSellAmount[orderDigest];
                uint256 currentAllowance = IERC20(sellToken).allowance(address(this), vaultRelayer);
                uint256 decreaseBy = orderSellAmount < currentAllowance ? orderSellAmount : currentAllowance;
                if (decreaseBy > 0) IERC20(sellToken).safeDecreaseAllowance(vaultRelayer, decreaseBy);
                uint256 balance = IERC20(sellToken).balanceOf(address(this));
                uint256 toReturn = orderSellAmount < balance ? orderSellAmount : balance;
                if (toReturn > 0) IERC20(sellToken).safeTransfer(owner(), toReturn);
                delete _digestToSellToken[orderDigest];
                delete _digestToSellAmount[orderDigest];
            }
            delete _digestToValidTo[orderDigest];
        }
    }

    function getOrderUid(GPv2Order.Data memory order) external view returns (bytes memory) {
        bytes32 digest = GPv2Order.hash(order, settlement.domainSeparator());
        return GPv2Order.packOrderUid(digest, address(this), order.validTo);
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
