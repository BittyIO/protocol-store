// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1IntentProtocol} from "../../interfaces/IBittyV1IntentProtocol.sol";
import {IBittyVaultOffchainAuth} from "../../interfaces/IBittyVaultOffchainAuth.sol";
import {IGPv2Settlement} from "../../libs/cow/IGPv2Settlement.sol";
import {GPv2Order} from "../../libs/cow/GPv2Order.sol";
import {IERC1271} from "../../libs/cow/IERC1271.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title CoWSwapV1Protocol
 * @notice CoW Swap intent protocol — a thin ERC-1271 validator for the vault's gasless, off-chain-signed
 *         orders. There is NO on-chain order registry and NO on-chain placement or cancellation.
 *
 *         The asset manager signs a CoW order off-chain (EIP-712) and posts it to the CoW API with
 *         signingScheme=eip1271. At settlement CoW calls the vault's isValidSignature, which delegates to
 *         this clone's isValidSignature → validateOffchainOrder: it re-hashes the carried order under the
 *         settlement domain to bind it to the digest, checks the fee-bearing appData / receiver / shape,
 *         recovers the manager's signature, and defers the allow/auth decision to the vault
 *         (IBittyVaultOffchainAuth). Cancellation is off-chain (CoW API soft-cancel / order expiry).
 *
 *         Because nothing is reserved on-chain, an over-signed order simply fails validation at settlement
 *         once its backing balance is gone — no reservation, no leak, no cleanup.
 */
contract CoWSwapV1Protocol is IBittyV1IntentProtocol, IERC1271, Ownable, Initializable {
    bytes4 private constant MAGICVALUE = 0x1626ba7e;
    bytes4 private constant INVALID = 0xffffffff;

    // Fee-bearing appData every order must carry (0.2% partner fee to PARTNER_FEE_RECIPIENT). The
    // off-chain layer posts the byte-identical fullAppData to the CoW API so solvers apply the fee.
    // keccak256('{"appCode":"BittyVault","metadata":{"partnerFee":{"bps":20,"recipient":"0x12EE2de7BF086388B1D560eb95e7191Edfab9823"}},"version":"1.3.0"}')
    bytes32 public constant APP_DATA = 0xdd81467643ffa93587d2dcaa8d583d5d953920b659e6c8f7235c8d613f737693;
    address public constant PARTNER_FEE_RECIPIENT = 0x12EE2de7BF086388B1D560eb95e7191Edfab9823;

    IGPv2Settlement public immutable settlement;
    address public immutable vaultRelayer;

    constructor(address settlement_, address vaultRelayer_) Ownable(msg.sender) {
        settlement = IGPv2Settlement(settlement_);
        vaultRelayer = vaultRelayer_;
    }

    function initialize(address newOwner) external override initializer {
        _transferOwnership(newOwner);
    }

    function name() external pure override returns (string memory) {
        return "CoWSwap V1";
    }

    function version() external pure override returns (string memory) {
        return "1.0.0";
    }

    receive() external payable {}

    /**
     * @notice EIP-1271 entry. Every order is gasless off-chain: `signature` carries the order plus the
     *         asset manager's EIP-712 signature. Delegated to {validateOffchainOrder} via a self staticcall
     *         so a malformed/empty payload returns INVALID instead of reverting.
     */
    function isValidSignature(bytes32 hash, bytes memory signature)
        external
        view
        override(IERC1271, IBittyV1IntentProtocol)
        returns (bytes4)
    {
        if (signature.length == 0) return INVALID;
        try this.validateOffchainOrder(hash, signature) returns (bytes4 res) {
            return res;
        } catch {
            return INVALID;
        }
    }

    /**
     * @notice Validate a gasless, off-chain-signed CoW order. External so {isValidSignature} can reach it
     *         via a self staticcall and treat any revert as "not signable". `signature` is
     *         abi.encode(GPv2Order.Data order, bytes managerSignature), where managerSignature is the asset
     *         manager's EIP-712 signature over the CoW order (the same digest an EOA would sign).
     * @dev  1. the carried order must hash (under the settlement domain) to exactly `hash` — a tampered
     *          field changes the hash and fails;
     *       2. it must settle to the vault (receiver == owner()), carry the fee-bearing APP_DATA, be
     *          fill-or-kill ERC-20/ERC-20 with feeAmount 0, and not be expired;
     *       3. the recovered manager must be authorized by the vault for this exact trade (a pure view, so
     *          no reservation is written and nothing can leak).
     */
    function validateOffchainOrder(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (GPv2Order.Data memory order, bytes memory managerSig) = abi.decode(signature, (GPv2Order.Data, bytes));

        if (GPv2Order.hash(order, settlement.domainSeparator()) != hash) return INVALID;
        if (order.receiver != owner()) return INVALID;
        if (order.appData != APP_DATA) return INVALID;
        if (order.feeAmount != 0) return INVALID;
        if (order.partiallyFillable) return INVALID;
        if (order.sellTokenBalance != GPv2Order.BALANCE_ERC20) return INVALID;
        if (order.buyTokenBalance != GPv2Order.BALANCE_ERC20) return INVALID;
        if (order.validTo < block.timestamp) return INVALID;

        address signer = ECDSA.recover(hash, managerSig);
        if (IBittyVaultOffchainAuth(owner())
                .isOffchainOrderAuthorized(signer, address(order.sellToken), address(order.buyToken), order.sellAmount))
        {
            return MAGICVALUE;
        }
        return INVALID;
    }
}
