// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BittyV1IntentProtocolBase} from "../../BittyV1IntentProtocolBase.sol";
import {IBittyV1IntentProtocol, InvalidOrderId} from "../../interfaces/IBittyV1IntentProtocol.sol";
import {IBittyVaultOffchainAuth} from "../../interfaces/IBittyVaultOffchainAuth.sol";
import {IGPv2Settlement} from "../../libs/cow/IGPv2Settlement.sol";
import {GPv2Order} from "../../libs/cow/GPv2Order.sol";
import {IERC1271} from "../../libs/cow/IERC1271.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {SignatureChecker} from "openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";

/**
 * @title CoWSwapV1Protocol
 * @notice CoW Swap intent protocol — a thin ERC-1271 validator for the vault's gasless, off-chain-signed
 *         orders. There is NO on-chain order registry and NO on-chain placement or cancellation.
 *
 *         An authorised signer signs a {vaultOrderDigest} off-chain (EIP-712) and posts the order to the
 *         CoW API with signingScheme=eip1271. At settlement CoW calls the vault's isValidSignature, which delegates to
 *         this clone's isValidSignature → validateOffchainOrder: it re-hashes the carried order under the
 *         settlement domain to bind it to the digest, checks the fee-bearing appData / receiver / shape,
 *         identifies the signer of the Bitty VaultOrder that wraps it ({_signerOf}), and defers the allow/auth decision to the vault
 *         (IBittyVaultOffchainAuth). Cancellation is off-chain (CoW API soft-cancel / order expiry) or
 *         recorded in this clone by the vault ({cancelOrders}, keyed by the order digest — or, for a
 *         TWAP, by its schedule digest, which cancels every part).
 *
 *         Because nothing is reserved on-chain, an over-signed order simply fails validation at settlement
 *         once its backing balance is gone — no reservation, no leak, no cleanup.
 *
 *         The signer is either an EOA or a contract wallet (a Safe owning the vault, say). An EOA's
 *         signature is the bare 65 bytes and its signer is RECOVERED, exactly as before. A contract
 *         wallet has no single key to recover — a Safe's signature is its owners' signatures
 *         concatenated — so it presents abi.encode(address signer, bytes signature) instead: the signer
 *         is ASSERTED and checked with ERC-1271 against it. See {_signerOf}.
 *
 *         EOA recovery is secp256k1 ECDSA, which Shor's algorithm breaks. Left that way
 *         deliberately: CoW constrains only the ERC-1271 magic value, never the inner scheme, so a
 *         post-quantum move needs no groundwork here — ship a PQ protocol and let owners swap it in
 *         with updateProtocols(), or park this one in the guard's deprecated tier so in-flight orders
 *         keep settling. Only hash-based signatures (WOTS+/XMSS) fit the gas budget of a settlement
 *         staticcall; ML-DSA, Falcon and SPHINCS+ are orders of magnitude too expensive. Make the
 *         swap while ECDSA is still trusted — the updateProtocols() call is itself ECDSA-signed.
 */
contract CoWSwapV1Protocol is IERC1271, BittyV1IntentProtocolBase {
    using Strings for uint256;

    bytes4 private constant MAGICVALUE = 0x1626ba7e;
    bytes4 private constant INVALID = 0xffffffff;

    // Fee-bearing appData a limit order must carry (0.2% partner fee to PARTNER_FEE_RECIPIENT, the fee
    // Safe's own Bitty vault). The off-chain layer posts the byte-identical fullAppData to the CoW API so
    // solvers apply the fee; it reads PARTNER_FEE_RECIPIENT rather than assuming it.
    // keccak256('{"appCode":"BittyVault","metadata":{"partnerFee":{"bps":20,"recipient":"0xF0E7f6998B362BD15CF819C7EBfcaCe8865FECA0"}},"version":"1.3.0"}')
    bytes32 public constant APP_DATA = 0xdc3a3d5d20e095878083b7fda31de8c1dcd7506cce70648ceff6e983235c5332;
    address public constant PARTNER_FEE_RECIPIENT = 0xF0E7f6998B362BD15CF819C7EBfcaCe8865FECA0;

    // Fee-bearing appData for TWAP part orders, split around a per-schedule salt placed in the free-form
    // `environment` field. The partnerFee block is identical to APP_DATA's, so a TWAP part carries the same
    // 0.2% fee, while distinct salts keep concurrent same-token TWAPs' part UIDs unique and let the
    // off-chain layer group parts by schedule. The signer passes the salt in the signature payload; the
    // clone recomputes twapAppData(salt) and requires the signed order to carry exactly that.
    string private constant TWAP_APP_DATA_PREFIX = '{"appCode":"BittyVault","environment":"';
    string private constant TWAP_APP_DATA_SUFFIX =
        '","metadata":{"partnerFee":{"bps":20,"recipient":"0xF0E7f6998B362BD15CF819C7EBfcaCe8865FECA0"}},"version":"1.3.0"}';

    // EIP-712 type hash for CoW's batch order cancellation, signed off-chain to soft-cancel orders.
    bytes32 private constant CANCELLATIONS_TYPE_HASH = keccak256("OrderCancellations(bytes[] orderUids)");

    /**
     * @dev What a signer signs is never the CoW digest itself. A plain signature over a GPv2 order digest
     *      is what CoW's settlement accepts as an EIP-712 order owned by the SIGNER, so the bytes that
     *      authorised a vault order would also fill from the signer's own wallet: same tokens and limit,
     *      a different order UID, proceeds paid into the vault. Signing instead under Bitty's own domain,
     *      with the vault named in the message, gives CoW nothing it can settle and binds each signature
     *      to one vault. The CoW order is nested whole, so a wallet still shows every field it signs.
     *      Cancellations are wrapped the same way. TWAP schedules already have their own type, which
     *      names the vault.
     */
    bytes32 private constant BITTY_DOMAIN_TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId)");
    bytes32 private constant BITTY_DOMAIN_NAME_HASH = keccak256("Bitty Vault Order");
    bytes32 private constant BITTY_DOMAIN_VERSION_HASH = keccak256("1");
    bytes32 private constant VAULT_ORDER_TYPE_HASH = keccak256(
        "VaultOrder(address vault,Order order)Order(address sellToken,address buyToken,address receiver,uint256 sellAmount,uint256 buyAmount,uint32 validTo,bytes32 appData,uint256 feeAmount,string kind,bool partiallyFillable,string sellTokenBalance,string buyTokenBalance)"
    );
    bytes32 private constant VAULT_CANCELLATIONS_TYPE_HASH =
        keccak256("VaultOrderCancellations(address vault,bytes[] orderUids)");

    struct TwapOrder {
        address sellToken;
        address buyToken;
        uint256 sellAmountPerPart;
        uint256 buyAmountPerPart;
        uint256 startTime;
        uint256 partDuration;
        uint256 numParts;
    }

    /**
     * @dev `vault` binds a signed schedule to exactly one vault. The schedule signature authorises
     *      parts that are RECONSTRUCTED per vault (receiver == owner()), so without this field a signer
     *      authorized on several vaults would have a schedule signed for one of them replayable against
     *      all of them — no receiver or owner check can catch that. The digest therefore carries the
     *      validating clone's vault, and a schedule presented to any other vault's clone recovers a
     *      different signer and fails authorization.
     */
    bytes32 private constant TWAP_TYPE_HASH = keccak256(
        "TwapOrder(address vault,address sellToken,address buyToken,uint256 sellAmountPerPart,uint256 buyAmountPerPart,uint256 startTime,uint256 partDuration,uint256 numParts)"
    );

    IGPv2Settlement public immutable settlement;
    address public immutable vaultRelayer;

    constructor(address settlement_, address vaultRelayer_) {
        settlement = IGPv2Settlement(settlement_);
        vaultRelayer = vaultRelayer_;
    }

    receive() external payable {}

    function protocolLineage() external pure override returns (bytes32) {
        return keccak256("bitty.adapter.cowswap.v1");
    }

    function protocolVersion() external pure override returns (uint256) {
        return 1_000_004; // 1.0.4: signers sign a Bitty VaultOrder, never a bare CoW order digest
    }

    function spender() external view override returns (address) {
        return vaultRelayer;
    }

    /**
     * @dev A CoW order UID is abi.encodePacked(orderDigest, owner, validTo) — 56 bytes — and is keyed by
     *      its digest, the `hash` CoW passes to isValidSignature. A bare 32-byte id is a digest as is:
     *      a TWAP schedule's {twapDigest}, which cancels all of its parts.
     */
    function _orderKey(bytes calldata orderId) internal pure override returns (bytes32) {
        if (orderId.length != 56 && orderId.length != 32) revert InvalidOrderId();
        return bytes32(orderId[:32]);
    }

    /**
     * @notice EIP-1271 entry. Every order is gasless off-chain: `signature` carries the order plus the
     *         signer's EIP-712 signature. Delegated to {validateOffchainOrder} via a self staticcall
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
     *         abi.encode(bytes[] orderUids, bytes signerSignature). The EIP-712 OrderCancellations digest
     *         (under the settlement domain) must equal `hash`, and the signer of the same uids'
     *         {vaultCancellationDigest} ({_signerOf}) must be authorised by the vault. Cancelling moves no
     *         funds, so no token/balance checks apply.
     */
    function validateOffchainCancellation(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (bytes[] memory orderUids, bytes memory signerSig) = abi.decode(signature, (bytes[], bytes));

        bytes32 uidsHash = _uidsHash(orderUids);
        bytes32 structHash = keccak256(abi.encode(CANCELLATIONS_TYPE_HASH, uidsHash));
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", settlement.domainSeparator(), structHash));
        if (digest != hash) return INVALID;

        (address signer, bool ok) = _signerOf(_vaultCancellationDigest(uidsHash), signerSig);
        if (ok && IBittyVaultOffchainAuth(owner()).isOffchainCancellationAuthorized(signer)) {
            return MAGICVALUE;
        }
        return INVALID;
    }

    /**
     * @notice The EIP-712 domain a signer's VaultOrder and VaultOrderCancellations are signed under:
     *         name "Bitty Vault Order", version "1", this chain's id.
     */
    function bittyDomainSeparator() public view returns (bytes32) {
        return
            keccak256(
                abi.encode(BITTY_DOMAIN_TYPE_HASH, BITTY_DOMAIN_NAME_HASH, BITTY_DOMAIN_VERSION_HASH, block.chainid)
            );
    }

    /**
     * @notice What a signer signs to authorise `order` for this clone's vault:
     *         VaultOrder(address vault, Order order), the CoW order nested whole.
     */
    function vaultOrderDigest(GPv2Order.Data memory order) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(VAULT_ORDER_TYPE_HASH, owner(), GPv2Order.structHash(order)));
        return keccak256(abi.encodePacked(hex"1901", bittyDomainSeparator(), structHash));
    }

    /**
     * @notice What a signer signs to cancel `orderUids` of this clone's vault through the CoW API:
     *         VaultOrderCancellations(address vault, bytes[] orderUids).
     */
    function vaultCancellationDigest(bytes[] memory orderUids) public view returns (bytes32) {
        return _vaultCancellationDigest(_uidsHash(orderUids));
    }

    function _vaultCancellationDigest(bytes32 uidsHash) private view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(VAULT_CANCELLATIONS_TYPE_HASH, owner(), uidsHash));
        return keccak256(abi.encodePacked(hex"1901", bittyDomainSeparator(), structHash));
    }

    function _uidsHash(bytes[] memory orderUids) private pure returns (bytes32) {
        bytes32[] memory hashedUids = new bytes32[](orderUids.length);
        for (uint256 i = 0; i < orderUids.length; i++) {
            hashedUids[i] = keccak256(orderUids[i]);
        }
        return keccak256(abi.encodePacked(hashedUids));
    }

    function twapFullAppData(uint256 salt) public pure returns (string memory) {
        return string.concat(TWAP_APP_DATA_PREFIX, salt.toString(), TWAP_APP_DATA_SUFFIX);
    }

    function twapAppData(uint256 salt) public pure returns (bytes32) {
        return keccak256(bytes(twapFullAppData(salt)));
    }

    function twapDigest(TwapOrder memory p) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                TWAP_TYPE_HASH,
                owner(),
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
     *         abi.encode(GPv2Order.Data order, bytes signerSignature, uint256 appDataSalt); appDataSalt must
     *         be 0 (a limit order carries APP_DATA — TWAP parts go through {validateOffchainTwapPart}).
     * @dev  1. the carried order must hash (under the settlement domain) to exactly `hash` — a tampered
     *          field changes the hash and fails;
     *       2. it must settle to the vault (receiver == owner()), carry the fee-bearing APP_DATA, be
     *          fill-or-kill ERC-20/ERC-20 with feeAmount 0, and not be expired;
     *       3. the signer of its {vaultOrderDigest} ({_signerOf}) must be authorized by the vault for this
     *          exact trade (a pure view, so no reservation is written and nothing can leak).
     */
    function validateOffchainOrder(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (GPv2Order.Data memory order, bytes memory signerSig, uint256 appDataSalt) =
            abi.decode(signature, (GPv2Order.Data, bytes, uint256));

        if (appDataSalt != 0) return INVALID;
        if (GPv2Order.hash(order, settlement.domainSeparator()) != hash) return INVALID;
        if (_isCancelled(hash)) return INVALID;
        if (order.receiver != owner()) return INVALID;
        if (order.appData != APP_DATA) return INVALID;
        if (order.feeAmount != 0) return INVALID;
        if (order.partiallyFillable) return INVALID;
        if (order.sellTokenBalance != GPv2Order.BALANCE_ERC20) return INVALID;
        if (order.buyTokenBalance != GPv2Order.BALANCE_ERC20) return INVALID;
        if (order.validTo < block.timestamp) return INVALID;

        (address signer, bool ok) = _signerOf(vaultOrderDigest(order), signerSig);
        if (
            ok
                && IBittyVaultOffchainAuth(owner())
                    .isOffchainOrderAuthorized(
                        signer, address(order.sellToken), address(order.buyToken), order.sellAmount
                    )
        ) {
            return MAGICVALUE;
        }
        return INVALID;
    }

    /**
     * @notice Validate a single part of a gasless TWAP signed ONCE. External so
     *         {isValidSignature} can reach it via a self staticcall. `signature` is
     *         abi.encode(GPv2Order.Data order, TwapOrder params, uint256 partIndex, bytes signerSignature):
     *         the signature is over `params` (the whole schedule), and the clone reconstructs what
     *         part `partIndex` must be from `params` and requires the presented order to match — so N parts
     *         need only this one signature.
     * @dev  1. the carried order must hash (settlement domain) to exactly `hash`;
     *       2. every field must equal the deterministic part-`partIndex` order derived from `params`
     *          (fill-or-kill ERC-20/ERC-20 SELL, feeAmount 0, receiver == vault, salted fee appData, and the
     *          slot's validTo), and the part must be within the schedule, its slot must have opened
     *          (`block.timestamp >= startTime + partIndex * partDuration`), and it must not be expired
     *          (`validTo >= block.timestamp`). A GPv2 order carries no start time, so this check is what
     *          enforces one part per slot instead of letting every part settle from the moment of signing;
     *       3. the signer of the single `params` signature ({_signerOf}) must be authorized for the trade.
     *          That signature is over {twapDigest}, which includes THIS clone's vault, so a schedule
     *          signed for another vault recovers a different signer (or fails ERC-1271) here and is rejected.
     */
    function validateOffchainTwapPart(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (GPv2Order.Data memory order, TwapOrder memory p, uint256 partIndex, bytes memory signerSig) =
            abi.decode(signature, (GPv2Order.Data, TwapOrder, uint256, bytes));

        if (GPv2Order.hash(order, settlement.domainSeparator()) != hash) return INVALID;
        if (partIndex >= p.numParts) return INVALID;
        bytes32 schedule = twapDigest(p);
        if (_isCancelled(hash) || _isCancelled(schedule)) return INVALID;
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
        if (block.timestamp < p.startTime + partIndex * p.partDuration) return INVALID;
        if (order.validTo < block.timestamp) return INVALID;

        (address signer, bool ok) = _signerOf(schedule, signerSig);
        if (
            ok
                && IBittyVaultOffchainAuth(owner())
                    .isOffchainOrderAuthorized(signer, p.sellToken, p.buyToken, order.sellAmount)
        ) {
            return MAGICVALUE;
        }
        return INVALID;
    }

    /**
     * @dev Who signed `digest`, and whether that is proven.
     *
     *      A 65-byte `signerSig` is an EOA's: the signer is recovered, as every version before this one
     *      did, so EOA orders are byte-for-byte unchanged. Anything else must be
     *      abi.encode(address signer, bytes signature) from a contract wallet, and is accepted only if
     *      `signer` answers ERC-1271 for `digest`. The two shapes cannot collide — the wrapped form is at
     *      least 128 bytes — and a 1-of-1 Safe's signature, which is itself 65 bytes, recovers the Safe's
     *      OWNER key rather than the Safe, so it fails authorization unless it is wrapped.
     *
     *      The wrapped branch is ERC-1271 ONLY, never ECDSA: asserting an EOA there would give the same
     *      authorisation two encodings, and nothing needs that.
     *
     *      Contract signatures are revocable (a Safe can rotate owners or change threshold), so an order
     *      a Safe signed can stop validating before it settles. That is the same outcome as an emptied
     *      balance — the order simply fails at settlement — and needs no handling here.
     */
    function _signerOf(bytes32 digest, bytes memory signerSig) internal view returns (address signer, bool ok) {
        if (signerSig.length == 65) {
            ECDSA.RecoverError err;
            (signer, err,) = ECDSA.tryRecover(digest, signerSig);
            return (signer, err == ECDSA.RecoverError.NoError);
        }
        bytes memory inner;
        (signer, inner) = abi.decode(signerSig, (address, bytes));
        return (signer, SignatureChecker.isValidERC1271SignatureNow(signer, digest, inner));
    }
}
