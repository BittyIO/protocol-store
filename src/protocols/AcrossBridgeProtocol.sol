// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BittyV1ProtocolBase} from "../BittyV1ProtocolBase.sol";
import {IBittyV1BridgeProtocol} from "../interfaces/IBittyV1BridgeProtocol.sol";
import {IBittyV1Guard} from "../interfaces/IBittyV1Guard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";

error BridgeFeeTooHigh();
error BridgeAmountZero();
error BridgeValueMismatch();
error BridgeRouteUnknown();
error BridgeOutputTooLow();
error BridgeDestinationUnsupported();
error BridgeOriginOwnerNeeded();
error BridgeOriginOwnerWrong();

/**
 * @dev Across's SpokePool, as far as a deposit goes. Addresses are bytes32 so non-EVM chains fit; an
 *      EVM or TRON address is its 20 bytes, left-padded. See https://docs.across.to.
 */
interface IAcrossSpokePool {
    function deposit(
        bytes32 depositor,
        bytes32 recipient,
        bytes32 inputToken,
        bytes32 outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        bytes32 exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityParameter,
        bytes calldata message
    ) external payable;

    function wrappedNativeToken() external view returns (address);
}

/**
 * @title AcrossBridgeProtocol
 * @notice Bridges through Across (across.to). Unlike a bridge whose recipient lives in an off-chain
 *         quote, Across takes the recipient, the destination chain, the token that arrives and how
 *         much of it as arguments to the deposit, so this adapter decides them rather than trusting
 *         the caller:
 *
 *         - The recipient is always this vault's own counterpart on the destination chain: between
 *           EVM chains its own address, since every EVM vault is the factory's CREATE2 of its
 *           creation owner and so sits at the same address on every EVM chain. To or from TRON the
 *           address differs (another factory, another CREATE2 prefix), so the request names the
 *           vault's creation owner, the adapter checks that this vault is that owner's vault here,
 *           and pays that owner's vault there. Nothing the caller passes can name another address.
 *         - The route (this token to that chain) must be configured in the guard, which fixes the
 *           token that arrives, its decimals, and the most the bridge may cost.
 *         - What arrives must be at least what was sent less that cost, so a quote cannot hand the
 *           difference to a colluding relayer.
 *
 *         So a stolen owner key can move the vault's money only into this vault's counterparts on
 *         other chains, losing at most the route's cost on each crossing. {bridge} returns what
 *         arrives, and the vault charges the difference to its daily loss allowance, so repeated
 *         crossings lose at most that allowance a day. Those vaults keep their own locks and
 *         timelocks, so the set of vaults is only as strong as its weakest member.
 *
 *         The counterpart is whoever owns it THERE. Ownership is per chain: a vault handed to a new
 *         key on this chain (a quantum-safe rotation, a sale, the recovery from a stolen key) is
 *         still the old key's on any chain it was not also handed over on, and a bridge pays it all
 *         the same. Until 1.1.0 the recipient was the current owner's own vault instead; that
 *         followed a handover, but a vault whose key rotates bridged into a vault of the new key at
 *         a new address, never the one its owner knows.
 *
 *         Bitty's fee is taken out of `amount` before the deposit, at most {MAX_FEE_BPS}, and sent to
 *         {FEE_RECIPIENT}. The vault is the depositor, so an unfilled deposit is refunded to it on
 *         this chain after its fill deadline. No allowance to the SpokePool outlives the call.
 *
 * @dev The vault's address on every EVM chain comes from the same factory and init code (salt =
 *      keccak256(owner)); on TRON the factory differs, the proxy init code compiles differently, and
 *      CREATE2 hashes with 0x41 instead of 0xff, so those two values are constructor arguments. Left
 *      zero, TRON is not a destination from this deployment.
 */
contract AcrossBridgeProtocol is IBittyV1BridgeProtocol, BittyV1ProtocolBase {
    using SafeERC20 for IERC20;

    /**
     * @param destinationChainId Where the money goes.
     * @param outputToken The token that arrives there; must be the route's.
     * @param outputAmount What arrives, from Across's quote; at least the route allows.
     * @param exclusiveRelayer From the quote; address(0) for none.
     * @param quoteTimestamp From the quote.
     * @param fillDeadline From the quote; after it an unfilled deposit is refunded to the vault.
     * @param exclusivityParameter From the quote.
     */
    struct AcrossQuote {
        uint256 destinationChainId;
        address outputToken;
        uint256 outputAmount;
        address exclusiveRelayer;
        uint32 quoteTimestamp;
        uint32 fillDeadline;
        uint32 exclusivityParameter;
    }

    // The fee Safe's own Bitty vault, so fees land under its locks and whitelist.
    address public constant FEE_RECIPIENT = 0xF0E7f6998B362BD15CF819C7EBfcaCe8865FECA0;
    uint256 public constant MAX_FEE_BPS = 20; // 0.2%
    uint256 public constant MAX_COST_BPS = 300; // 3%, the most any route may let the bridge keep

    address public constant EVM_VAULT_FACTORY = 0x3d7Ed3cD011B423dd11BE280BF926667CAf0F120;
    bytes32 public constant EVM_VAULT_INITCODE_HASH =
        0x6c313cb305e616270f7a0ed3e9bb874c27e1a38fbde9d4cf2ccccb10c193a45c;
    uint256 public constant TRON_CHAIN_ID = 728126428;

    bytes32 private constant ROUTE_KEY = keccak256("bitty.bridge.across.route");
    // abi.encode(AcrossQuote, address): seven static words and one more.
    uint256 private constant QUOTE_WITH_ORIGIN_LENGTH = 8 * 32;

    address public immutable spokePool;
    address public immutable bittyGuard;
    address public immutable tronVaultFactory;
    bytes32 public immutable tronVaultInitCodeHash;

    constructor(address spokePool_, address bittyGuard_, address tronVaultFactory_, bytes32 tronVaultInitCodeHash_) {
        spokePool = spokePool_;
        bittyGuard = bittyGuard_;
        tronVaultFactory = tronVaultFactory_;
        tronVaultInitCodeHash = tronVaultInitCodeHash_;
    }

    function protocolLineage() external pure override returns (bytes32) {
        return keccak256("bitty.adapter.across.bridge");
    }

    function protocolVersion() external pure override returns (uint256) {
        return 1_001_000;
    }

    function maxFeeBps() external pure override returns (uint256) {
        return MAX_FEE_BPS;
    }

    /**
     * @notice The guard config key of the route from `inputToken` (the wrapped native token for the
     *         native coin) on this chain to `destinationChainId`.
     * @dev Its value packs the route: bits 0-159 the output token, 160-167 its decimals, 168-183 the
     *      most the bridge may cost in basis points (capped at {MAX_COST_BPS}). 0 means no route.
     */
    function routeKey(address inputToken, uint256 destinationChainId) public pure returns (bytes32) {
        return keccak256(abi.encode(ROUTE_KEY, inputToken, destinationChainId));
    }

    function packRoute(address outputToken, uint8 outputDecimals, uint16 maxCostBps) external pure returns (uint256) {
        return uint256(uint160(outputToken)) | (uint256(outputDecimals) << 160) | (uint256(maxCostBps) << 168);
    }

    /**
     * @notice The vault that `owner` created (or will create) on `destinationChainId`: the factory's
     *         CREATE2 of keccak256(owner) there.
     */
    function vaultOn(uint256 destinationChainId, address owner) public view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(owner));
        if (destinationChainId == TRON_CHAIN_ID) {
            if (tronVaultFactory == address(0)) revert BridgeDestinationUnsupported();
            return _create2(0x41, tronVaultFactory, salt, tronVaultInitCodeHash);
        }
        return _create2(0xff, EVM_VAULT_FACTORY, salt, EVM_VAULT_INITCODE_HASH);
    }

    /**
     * @notice Where a bridge from `vault` to `destinationChainId` pays out: `vault` itself between
     *         EVM chains, or, given the vault's creation owner `originOwner`, that owner's vault on
     *         the destination after checking that `vault` is that owner's vault here.
     * @dev `originOwner` is needed only to or from TRON (address(0) otherwise); a wrong one reverts.
     */
    function recipientFor(address vault, uint256 destinationChainId, address originOwner)
        public
        view
        returns (address)
    {
        if (originOwner == address(0)) {
            if ((destinationChainId == TRON_CHAIN_ID) != _onTron()) revert BridgeOriginOwnerNeeded();
            return vault;
        }
        if (vaultOn(_onTron() ? TRON_CHAIN_ID : block.chainid, originOwner) != vault) revert BridgeOriginOwnerWrong();
        return vaultOn(destinationChainId, originOwner);
    }

    /**
     * @param data abi.encode(AcrossQuote) from Across's quote for this route, with the recipient set
     *        to {recipientFor}; to or from TRON abi.encode(AcrossQuote, originOwner), the vault's
     *        creation owner.
     */
    function bridge(address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        payable
        override
        onlyOwner
        returns (uint256 received)
    {
        if (amount == 0) revert BridgeAmountZero();
        if (fee * 10_000 > amount * MAX_FEE_BPS) revert BridgeFeeTooHigh();
        AcrossQuote memory q;
        address originOwner;
        if (data.length == QUOTE_WITH_ORIGIN_LENGTH) (q, originOwner) = abi.decode(data, (AcrossQuote, address));
        else q = abi.decode(data, (AcrossQuote));
        if (q.destinationChainId == block.chainid) revert BridgeDestinationUnsupported();

        bool native = token == address(0);
        address inputToken = native ? IAcrossSpokePool(spokePool).wrappedNativeToken() : token;
        uint256 deposit = amount - fee;
        received = _checkOutput(inputToken, native ? 18 : IERC20Metadata(token).decimals(), deposit, q);

        address vault = msg.sender;
        address recipient = recipientFor(vault, q.destinationChainId, originOwner);
        if (native) {
            if (msg.value != amount) revert BridgeValueMismatch();
            if (fee != 0) Address.sendValue(payable(FEE_RECIPIENT), fee);
            _deposit(vault, recipient, inputToken, deposit, deposit, q);
        } else {
            if (msg.value != 0) revert BridgeValueMismatch();
            IERC20(token).safeTransferFrom(vault, address(this), amount);
            if (fee != 0) IERC20(token).safeTransfer(FEE_RECIPIENT, fee);
            IERC20(token).forceApprove(spokePool, deposit);
            _deposit(vault, recipient, inputToken, deposit, 0, q);
            if (IERC20(token).allowance(address(this), spokePool) != 0) IERC20(token).forceApprove(spokePool, 0);
        }
        emit Bridged(token, amount, fee, data);
    }

    /**
     * @dev Whether this deployment runs on TRON, where vault addresses come from the TRON factory.
     */
    function _onTron() internal pure virtual returns (bool) {
        return false;
    }

    /**
     * @return received `q.outputAmount` in the input token's units, rounded down.
     */
    function _checkOutput(address inputToken, uint8 inputDecimals, uint256 deposit, AcrossQuote memory q)
        private
        view
        returns (uint256 received)
    {
        uint256 route = IBittyV1Guard(bittyGuard).getUint(routeKey(inputToken, q.destinationChainId));
        if (route == 0 || address(uint160(route)) != q.outputToken) revert BridgeRouteUnknown();
        uint8 outputDecimals = uint8(route >> 160);
        uint256 maxCost = uint16(route >> 168);
        if (maxCost > MAX_COST_BPS) maxCost = MAX_COST_BPS;

        uint256 least = deposit * (10_000 - maxCost) / 10_000;
        if (outputDecimals >= inputDecimals) {
            uint256 scale = 10 ** (outputDecimals - inputDecimals);
            least *= scale;
            received = q.outputAmount / scale;
        } else {
            uint256 scale = 10 ** (inputDecimals - outputDecimals);
            least /= scale;
            received = q.outputAmount * scale;
        }
        if (q.outputAmount < least || q.outputAmount == 0) revert BridgeOutputTooLow();
    }

    function _deposit(
        address vault,
        address recipient,
        address inputToken,
        uint256 inputAmount,
        uint256 value,
        AcrossQuote memory q
    ) private {
        IAcrossSpokePool(spokePool).deposit{value: value}(
            _b32(vault),
            _b32(recipient),
            _b32(inputToken),
            _b32(q.outputToken),
            inputAmount,
            q.outputAmount,
            q.destinationChainId,
            _b32(q.exclusiveRelayer),
            q.quoteTimestamp,
            q.fillDeadline,
            q.exclusivityParameter,
            ""
        );
    }

    function _create2(bytes1 prefix, address factory, bytes32 salt, bytes32 initCodeHash)
        private
        pure
        returns (address)
    {
        return address(uint160(uint256(keccak256(abi.encodePacked(prefix, factory, salt, initCodeHash)))));
    }

    function _b32(address a) private pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }
}
