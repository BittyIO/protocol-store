// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BittyV1IntentProtocolBase} from "../../BittyV1IntentProtocolBase.sol";
import {IBittyV1IntentProtocol, InvalidOrderId} from "../../interfaces/IBittyV1IntentProtocol.sol";
import {IBittyVaultOffchainAuth} from "../../interfaces/IBittyVaultOffchainAuth.sol";
import {IERC1271} from "../../libs/cow/IERC1271.sol";
import {V3DutchOrder, V3DutchOutput, V3DutchOrderLib, IPermit2Domain} from "../../libs/uniswapx/V3DutchOrder.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {SignatureChecker} from "openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";

/**
 * @title UniswapXV1Protocol
 * @notice UniswapX intent protocol — a thin ERC-1271 validator for the vault's gasless, off-chain-signed
 *         V3 Dutch orders. There is NO on-chain order registry and NO on-chain placement.
 *
 *         The vault is the order's swapper. An authorised signer signs the order's Permit2 digest
 *         (PermitWitnessTransferFrom with the order as witness, EIP-712 under Permit2's domain) and the
 *         order is posted to the UniswapX API with `abi.encode(order, signerSignature)` as its signature.
 *         At fill, the reactor asks Permit2 to pull the input from the vault; Permit2 calls the vault's
 *         isValidSignature, which delegates to this clone's isValidSignature → validateOffchainOrder: it
 *         re-hashes the carried order into the Permit2 digest to bind it to `hash`, checks reactor /
 *         swapper / outputs / fee, identifies the signer ({_signerOf}), and defers the allow/auth
 *         decision to the vault (IBittyVaultOffchainAuth).
 *
 *         The vault approves its sell token to Permit2 ({spender}), not to the reactor. That
 *         approval is only spendable through a Permit2 signature transfer the vault validates, and this
 *         clone validates nothing but a PermitWitnessTransferFrom digest it rebuilt itself, for its own
 *         reactor, with the vault as swapper.
 *
 *         Cancellation: replay is prevented by Permit2's unordered nonce, which a fill consumes. To cancel
 *         early, the vault records the order hash (the id UniswapX names the order by) with
 *         {cancelOrders}; validation refuses it from then on. Otherwise an order stops being fillable when
 *         it expires (`deadline`), when its backing balance is gone, or when the vault stops authorising
 *         its signer.
 *
 *         Fee: the order must carry a second output of the buy token to FEE_RECIPIENT worth at least
 *         0.2% of the total, at both the start of the auction and its floor (see {_feeOk}).
 */
contract UniswapXV1Protocol is IERC1271, BittyV1IntentProtocolBase {
    bytes4 private constant MAGICVALUE = 0x1626ba7e;
    bytes4 private constant INVALID = 0xffffffff;

    // The fee Safe's own Bitty vault, so fees land under its locks and whitelist.
    address public constant FEE_RECIPIENT = 0xF0E7f6998B362BD15CF819C7EBfcaCe8865FECA0;
    uint256 public constant FEE_BPS = 20; // 0.2%

    /// @notice The V3DutchOrderReactor orders must target; also the Permit2 spender.
    address public immutable reactor;
    /// @notice Permit2, which pulls the sell token from the vault at fill.
    address public immutable permit2;

    constructor(address reactor_, address permit2_) {
        reactor = reactor_;
        permit2 = permit2_;
    }

    function protocolLineage() external pure override returns (bytes32) {
        return keccak256("bitty.adapter.uniswapx.v1");
    }

    function protocolVersion() external pure override returns (uint256) {
        return 1_000_000; // 1.0.0
    }

    function spender() external view override returns (address) {
        return permit2;
    }

    /// @notice {spender} under the name vaults released before the generic intent interface still read.
    function vaultRelayer() external view returns (address) {
        return permit2;
    }

    /// @dev A UniswapX order is named by its order hash (the Permit2 witness), 32 bytes.
    function _orderKey(bytes calldata orderId) internal pure override returns (bytes32) {
        if (orderId.length != 32) revert InvalidOrderId();
        return bytes32(orderId);
    }

    /**
     * @notice EIP-1271 entry, reached from Permit2 through the vault. Delegated to {validateOffchainOrder}
     *         via a self staticcall so a malformed payload (another protocol's, say) returns INVALID
     *         instead of reverting.
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
        } catch {}
        return INVALID;
    }

    /**
     * @notice Validate a gasless, off-chain-signed UniswapX V3 Dutch order. `signature` is
     *         abi.encode(V3DutchOrder order, bytes signerSignature).
     * @dev  1. the carried order must rebuild exactly `hash` as Permit2's witness-transfer digest — a
     *          tampered field, another reactor, or another Permit2 changes it and fails;
     *       2. it must not be cancelled ({cancelOrders}), must target {reactor}, have the vault as swapper,
     *          no additional validation contract, and not be expired;
     *       3. its outputs must be exactly [buy token → vault, buy token → FEE_RECIPIENT] with the fee
     *          intact ({_feeOk}), and the buy token must be an ERC-20 other than the sell token;
     *       4. the signer ({_signerOf}) must be authorized by the vault to sell up to the input's
     *          maxAmount — the most Permit2 can pull, whatever the decay and gas adjustment do.
     */
    function validateOffchainOrder(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (V3DutchOrder memory order, bytes memory signerSig) = abi.decode(signature, (V3DutchOrder, bytes));

        bytes32 orderHash = V3DutchOrderLib.hash(order);
        if (V3DutchOrderLib.permit2Digest(order, orderHash, IPermit2Domain(permit2).DOMAIN_SEPARATOR()) != hash) {
            return INVALID;
        }
        if (_isCancelled(orderHash)) return INVALID;
        if (order.info.reactor != reactor) return INVALID;
        if (order.info.swapper != owner()) return INVALID;
        if (order.info.additionalValidationContract != address(0)) return INVALID;
        if (order.info.deadline < block.timestamp) return INVALID;
        if (order.baseOutputs.length != 2) return INVALID;

        V3DutchOutput memory out = order.baseOutputs[0];
        V3DutchOutput memory fee = order.baseOutputs[1];
        address sellToken = order.baseInput.token;
        address buyToken = out.token;
        if (buyToken == address(0) || buyToken == sellToken) return INVALID;
        if (out.recipient != owner()) return INVALID;
        if (fee.token != buyToken || fee.recipient != FEE_RECIPIENT) return INVALID;
        if (!_feeOk(out.startAmount, fee.startAmount) || !_feeOk(out.minAmount, fee.minAmount)) return INVALID;

        (address signer, bool ok) = _signerOf(hash, signerSig);
        if (
            ok
                && IBittyVaultOffchainAuth(owner())
                    .isOffchainOrderAuthorized(signer, sellToken, buyToken, order.baseInput.maxAmount)
        ) {
            return MAGICVALUE;
        }
        return INVALID;
    }

    /**
     * @dev `fee` is at least FEE_BPS of `amount + fee`. Checked at the auction's start and at its floor:
     *      the reactor bounds every output below by its minAmount, so the floor is the least the fee can
     *      decay to, against the least the vault can receive. A cosigner may only raise outputs.
     */
    function _feeOk(uint256 amount, uint256 fee) private pure returns (bool) {
        return fee * (10_000 - FEE_BPS) >= amount * FEE_BPS;
    }

    /**
     * @dev Who signed `digest`, and whether that is proven — the same two shapes as CoWSwapV1Protocol:
     *      a 65-byte EOA signature is recovered; anything else must be abi.encode(address signer, bytes
     *      signature) from a contract wallet (a Safe owning the vault, say) and is checked with ERC-1271
     *      against the asserted signer, never ECDSA.
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
