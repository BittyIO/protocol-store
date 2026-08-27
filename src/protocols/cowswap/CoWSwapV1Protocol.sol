// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1IntentProtocol} from "../../interfaces/IBittyV1IntentProtocol.sol";
import {IBittyVaultOffchainAuth} from "../../interfaces/IBittyVaultOffchainAuth.sol";
import {IGPv2Settlement} from "../../libs/cow/IGPv2Settlement.sol";
import {GPv2Order} from "../../libs/cow/GPv2Order.sol";
import {IERC1271} from "../../libs/cow/IERC1271.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";

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
    using Strings for uint256;

    bytes4 private constant MAGICVALUE = 0x1626ba7e;
    bytes4 private constant INVALID = 0xffffffff;

    // Fee-bearing appData a limit order must carry (0.2% partner fee to PARTNER_FEE_RECIPIENT). The
    // off-chain layer posts the byte-identical fullAppData to the CoW API so solvers apply the fee.
    // keccak256('{"appCode":"BittyVault","metadata":{"partnerFee":{"bps":20,"recipient":"0x12EE2de7BF086388B1D560eb95e7191Edfab9823"}},"version":"1.3.0"}')
    bytes32 public constant APP_DATA = 0xdd81467643ffa93587d2dcaa8d583d5d953920b659e6c8f7235c8d613f737693;
    address public constant PARTNER_FEE_RECIPIENT = 0x12EE2de7BF086388B1D560eb95e7191Edfab9823;

    // Fee-bearing appData for TWAP part orders, split around a per-schedule salt placed in the free-form
    // `environment` field. The partnerFee block is identical to APP_DATA's, so a TWAP part carries the same
    // 0.2% fee, while distinct salts keep concurrent same-token TWAPs' part UIDs unique and let the
    // off-chain layer group parts by schedule. The manager passes the salt in the signature payload; the
    // clone recomputes twapAppData(salt) and requires the signed order to carry exactly that.
    string private constant TWAP_APP_DATA_PREFIX = '{"appCode":"BittyVault","environment":"';
    string private constant TWAP_APP_DATA_SUFFIX =
        '","metadata":{"partnerFee":{"bps":20,"recipient":"0x12EE2de7BF086388B1D560eb95e7191Edfab9823"}},"version":"1.3.0"}';

    // EIP-712 type hash for CoW's batch order cancellation, signed off-chain to soft-cancel orders.
    bytes32 private constant CANCELLATIONS_TYPE_HASH = keccak256("OrderCancellations(bytes[] orderUids)");

    // A whole TWAP schedule, signed ONCE by the manager. Each of `numParts` parts is a fill-or-kill
    // SELL of `sellAmountPerPart` for at least `buyAmountPerPart`, valid only during its slot
    // [startTime + i*partDuration, startTime + (i+1)*partDuration]. `startTime` doubles as the appData
    // salt so a schedule's parts share one fee-bearing appData. The clone reconstructs part i from these
    // params and matches it to the presented order, so N parts need only this single signature.
    struct TwapOrder {
        address sellToken;
        address buyToken;
        uint256 sellAmountPerPart;
        uint256 buyAmountPerPart;
        uint256 startTime;
        uint256 partDuration;
        uint256 numParts;
    }

    bytes32 private constant TWAP_TYPE_HASH = keccak256(
        "TwapOrder(address sellToken,address buyToken,uint256 sellAmountPerPart,uint256 buyAmountPerPart,uint256 startTime,uint256 partDuration,uint256 numParts)"
    );

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
        // The same eip1271 entry validates both order placements and order cancellations (CoW asks the
        // owner to validate the OrderCancellations digest too). Try the order shape first, then the
        // cancellation shape; each is wrapped so a mismatched payload can't revert.
        try this.validateOffchainOrder(hash, signature) returns (bytes4 res) {
            if (res == MAGICVALUE) return res;
        } catch {}
        try this.validateOffchainTwapPart(hash, signature) returns (bytes4 resTwap) {
            if (resTwap == MAGICVALUE) return resTwap;
        } catch {}
        try this.validateOffchainCancellation(hash, signature) returns (bytes4 res2) {
            return res2;
        } catch {}
        return INVALID;
    }

    /**
     * @notice Validate a gasless, off-chain-signed CoW order cancellation. `signature` is
     *         abi.encode(bytes[] orderUids, bytes managerSignature). The EIP-712 OrderCancellations digest
     *         (under the settlement domain) must equal `hash`, and the recovered signer must be the vault's
     *         asset manager. Cancelling moves no funds, so no token/balance checks apply.
     */
    function validateOffchainCancellation(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (bytes[] memory orderUids, bytes memory managerSig) = abi.decode(signature, (bytes[], bytes));

        bytes32[] memory hashedUids = new bytes32[](orderUids.length);
        for (uint256 i = 0; i < orderUids.length; i++) {
            hashedUids[i] = keccak256(orderUids[i]);
        }
        bytes32 structHash = keccak256(abi.encode(CANCELLATIONS_TYPE_HASH, keccak256(abi.encodePacked(hashedUids))));
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", settlement.domainSeparator(), structHash));
        if (digest != hash) return INVALID;

        address signer = ECDSA.recover(hash, managerSig);
        if (IBittyVaultOffchainAuth(owner()).isOffchainManager(signer)) {
            return MAGICVALUE;
        }
        return INVALID;
    }

    /**
     * @notice The exact fee-bearing appData JSON a TWAP part with `salt` commits to. The off-chain layer
     *         PUTs this byte-for-byte to the CoW API so solvers resolve the hash and apply the partner fee.
     */
    function twapFullAppData(uint256 salt) public pure returns (string memory) {
        return string.concat(TWAP_APP_DATA_PREFIX, salt.toString(), TWAP_APP_DATA_SUFFIX);
    }

    /// @notice keccak256 of twapFullAppData(salt) — the appData a TWAP part's order must carry.
    function twapAppData(uint256 salt) public pure returns (bytes32) {
        return keccak256(bytes(twapFullAppData(salt)));
    }

    /// @notice The EIP-712 digest a manager signs once to authorize a whole TWAP schedule, under the
    ///         settlement domain (its own type hash keeps it distinct from a GPv2 order).
    function twapDigest(TwapOrder memory p) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                TWAP_TYPE_HASH,
                p.sellToken,
                p.buyToken,
                p.sellAmountPerPart,
                p.buyAmountPerPart,
                p.startTime,
                p.partDuration,
                p.numParts
            )
        );
        return keccak256(abi.encodePacked(hex"1901", settlement.domainSeparator(), structHash));
    }

    /**
     * @notice Validate a gasless, off-chain-signed CoW LIMIT order. External so {isValidSignature} can reach
     *         it via a self staticcall and treat any revert as "not signable". `signature` is
     *         abi.encode(GPv2Order.Data order, bytes managerSignature, uint256 appDataSalt); appDataSalt must
     *         be 0 (a limit order carries APP_DATA — TWAP parts go through {validateOffchainTwapPart}).
     * @dev  1. the carried order must hash (under the settlement domain) to exactly `hash` — a tampered
     *          field changes the hash and fails;
     *       2. it must settle to the vault (receiver == owner()), carry the fee-bearing APP_DATA, be
     *          fill-or-kill ERC-20/ERC-20 with feeAmount 0, and not be expired;
     *       3. the recovered manager must be authorized by the vault for this exact trade (a pure view, so
     *          no reservation is written and nothing can leak).
     */
    function validateOffchainOrder(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (GPv2Order.Data memory order, bytes memory managerSig, uint256 appDataSalt) =
            abi.decode(signature, (GPv2Order.Data, bytes, uint256));

        if (appDataSalt != 0) return INVALID;
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

    /**
     * @notice Validate a single part of a gasless TWAP the manager signed ONCE. External so
     *         {isValidSignature} can reach it via a self staticcall. `signature` is
     *         abi.encode(GPv2Order.Data order, TwapOrder params, uint256 partIndex, bytes managerSignature):
     *         the manager's signature is over `params` (the whole schedule), and the clone reconstructs what
     *         part `partIndex` must be from `params` and requires the presented order to match — so N parts
     *         need only this one signature.
     * @dev  1. the carried order must hash (settlement domain) to exactly `hash`;
     *       2. every field must equal the deterministic part-`partIndex` order derived from `params`
     *          (fill-or-kill ERC-20/ERC-20 SELL, feeAmount 0, receiver == vault, salted fee appData, and the
     *          slot's validTo), and the part must be within the schedule and not expired;
     *       3. the manager recovered from the single `params` signature must be authorized for the trade.
     */
    function validateOffchainTwapPart(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (GPv2Order.Data memory order, TwapOrder memory p, uint256 partIndex, bytes memory managerSig) =
            abi.decode(signature, (GPv2Order.Data, TwapOrder, uint256, bytes));

        if (GPv2Order.hash(order, settlement.domainSeparator()) != hash) return INVALID;
        if (partIndex >= p.numParts) return INVALID;
        if (address(order.sellToken) != p.sellToken) return INVALID;
        if (address(order.buyToken) != p.buyToken) return INVALID;
        if (order.receiver != owner()) return INVALID;
        if (order.sellAmount != p.sellAmountPerPart) return INVALID;
        if (order.buyAmount != p.buyAmountPerPart) return INVALID;
        if (order.validTo != p.startTime + (partIndex + 1) * p.partDuration) return INVALID;
        if (order.appData != twapAppData(p.startTime)) return INVALID;
        if (order.feeAmount != 0) return INVALID;
        if (order.kind != GPv2Order.KIND_SELL) return INVALID;
        if (order.partiallyFillable) return INVALID;
        if (order.sellTokenBalance != GPv2Order.BALANCE_ERC20) return INVALID;
        if (order.buyTokenBalance != GPv2Order.BALANCE_ERC20) return INVALID;
        if (order.validTo < block.timestamp) return INVALID;

        address signer = ECDSA.recover(twapDigest(p), managerSig);
        if (IBittyVaultOffchainAuth(owner())
                .isOffchainOrderAuthorized(signer, p.sellToken, p.buyToken, order.sellAmount)) {
            return MAGICVALUE;
        }
        return INVALID;
    }
}
