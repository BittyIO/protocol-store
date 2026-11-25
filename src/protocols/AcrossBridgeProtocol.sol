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
error BridgeRecipientInvalid();
error BridgeDestinationMismatch();

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
 *           and pays that owner's vault there. Nothing passed to {bridge} can name another address;
 *           {bridgeTo} names one on purpose, and the vault meters it as a send.
 *         - The route (this token to that chain) must be configured in the guard, which fixes the
 *           token that arrives, its decimals, and the most the bridge may cost.
 *         - What arrives must be at least what was sent less that cost (a share of it, and on a
 *           route whose bridge charges per transfer, a flat amount besides), so a quote cannot hand
 *           the difference to a colluding relayer.
 *
 *         So through {bridge} a stolen owner key can move the vault's money only into this vault's
 *         counterparts on other chains, losing at most the route's cost on each crossing; through
 *         {bridgeTo}, at most the vault's send allowance a day, as with a send. {bridge} returns what
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
 *         {feeRecipient}. The vault is the depositor, so an unfilled deposit is refunded to it on
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
    // The most flat cost any route may let the bridge keep on top, in whole output tokens: room for
    // a fee Across charges per transfer, not per amount (into TRON, ~6.2 USDT however much is sent).
    uint256 public constant MAX_FLAT_COST_TOKENS = 10;

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

    /**
     * @dev 1.2.2: a route may allow a flat cost on top of its basis points, so a transfer small
     *      against a per-transfer fee (into TRON) can go; 1.2.1 refused anything under ~207 USDT.
     *      1.2.1: {bridgeTo} names the destination chain, which the quote must match, and takes the
     *      recipient as 32 bytes so a Solana address fits; the vault pays whitelisted recipients on
     *      other chains through it. 1.2.0 (0xA56bE4f4225C66B02A29c7D4E7E76a7BDaA31631) had neither.
     *      1.2.0: {bridgeTo}, a bridge to someone else's address, which the vault meters as a send.
     *      1.1.1: the same bridge, deployed with TRON's vault factory and init-code hash on the
     *      chains Across serves to and from TRON.
     */
    function protocolVersion() external pure override returns (uint256) {
        return 1_002_002;
    }

    function maxFeeBps() external pure override returns (uint256) {
        return MAX_FEE_BPS;
    }

    /**
     * @notice Where Bitty's fee goes.
     * @dev Virtual so a deployment on a chain without the fee Safe's vault (TRON) can name its own
     *      recipient; everywhere else it is {FEE_RECIPIENT}.
     */
    function feeRecipient() public view virtual returns (address) {
        return FEE_RECIPIENT;
    }

    /**
     * @notice The guard config key of the route from `inputToken` (the wrapped native token for the
     *         native coin) on this chain to `destinationChainId`.
     * @dev Its value packs the route: bits 0-159 the output token, 160-167 its decimals, 168-183 the
     *      most the bridge may cost in basis points (capped at {MAX_COST_BPS}), 184-247 a flat cost
     *      it may keep on top, in the output token's smallest units (capped at
     *      {MAX_FLAT_COST_TOKENS} whole tokens). 0 means no route. Adapters before 1.2.2 read no
     *      flat cost, so adding one to a route changes nothing for them.
     */
    function routeKey(address inputToken, uint256 destinationChainId) public pure returns (bytes32) {
        return keccak256(abi.encode(ROUTE_KEY, inputToken, destinationChainId));
    }

    function packRoute(address outputToken, uint8 outputDecimals, uint16 maxCostBps) external pure returns (uint256) {
        return packRoute(outputToken, outputDecimals, maxCostBps, 0);
    }

    function packRoute(address outputToken, uint8 outputDecimals, uint16 maxCostBps, uint64 maxFlatCost)
        public
        pure
        returns (uint256)
    {
        return uint256(uint160(outputToken)) | (uint256(outputDecimals) << 160) | (uint256(maxCostBps) << 168)
            | (uint256(maxFlatCost) << 184);
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
        received = _checkOutput(inputToken, native ? _nativeDecimals() : IERC20Metadata(token).decimals(), deposit, q);

        address vault = msg.sender;
        address recipient = recipientFor(vault, q.destinationChainId, originOwner);
        if (native) {
            if (msg.value != amount) revert BridgeValueMismatch();
            if (fee != 0) Address.sendValue(payable(feeRecipient()), fee);
            _deposit(vault, _b32(recipient), inputToken, deposit, deposit, q);
        } else {
            if (msg.value != 0) revert BridgeValueMismatch();
            _depositToken(vault, _b32(recipient), token, amount, fee, q);
        }
        emit Bridged(token, amount, fee, data);
    }

    /**
     * @notice Bridge `amount` of `token` to `recipient` on the quote's chain: someone else's
     *         address, which the vault meters against its send allowance. See
     *         {IBittyV1BridgeProtocol-bridgeTo}.
     * @dev The route and the floor on what arrives are held as for {bridge}, so a quote still
     *      cannot hand the difference to a colluding relayer; only the recipient is the caller's,
     *      and the chain, which the quote must match: the vault decides who may be paid where (a
     *      whitelisted recipient is bound to its chain), so a quote cannot move the payment.
     *      An ERC-20 only. `recipient` may not be the vault: its counterpart goes through {bridge},
     *      and on TRON the same 20 bytes are not even the counterpart.
     * @param destinationChainId The chain the vault means to pay on; the quote must be for it.
     * @param recipient Who is paid there, as 32 bytes, the way Across takes it: a 20-byte address
     *        (EVM, or TRON without its 0x41 prefix) left-padded, a Solana address in full.
     * @param data abi.encode(AcrossQuote) from Across's quote for this route, with this recipient.
     */
    function bridgeTo(
        address token,
        uint256 amount,
        uint256 fee,
        uint256 destinationChainId,
        bytes32 recipient,
        bytes calldata data
    ) external override onlyOwner returns (uint256 received) {
        if (amount == 0) revert BridgeAmountZero();
        if (fee * 10_000 > amount * MAX_FEE_BPS) revert BridgeFeeTooHigh();
        if (token == address(0)) revert BridgeValueMismatch();
        address vault = msg.sender;
        if (recipient == 0 || recipient == _b32(vault)) revert BridgeRecipientInvalid();
        AcrossQuote memory q = abi.decode(data, (AcrossQuote));
        if (q.destinationChainId != destinationChainId) revert BridgeDestinationMismatch();
        if (q.destinationChainId == block.chainid) revert BridgeDestinationUnsupported();

        uint256 deposit = amount - fee;
        received = _checkOutput(token, IERC20Metadata(token).decimals(), deposit, q);
        _depositToken(vault, recipient, token, amount, fee, q);
        emit BridgedTo(token, destinationChainId, recipient, amount, fee, data);
    }

    /**
     * @dev Pulls `amount` from the vault, sends `fee` to Bitty, and deposits the rest for
     *      `recipient`. No allowance to the SpokePool outlives the call.
     */
    function _depositToken(
        address vault,
        bytes32 recipient,
        address token,
        uint256 amount,
        uint256 fee,
        AcrossQuote memory q
    ) private {
        uint256 deposit = amount - fee;
        IERC20(token).safeTransferFrom(vault, address(this), amount);
        if (fee != 0) _transferToken(token, feeRecipient(), fee);
        IERC20(token).forceApprove(spokePool, deposit);
        _deposit(vault, recipient, token, deposit, 0, q);
        if (IERC20(token).allowance(address(this), spokePool) != 0) IERC20(token).forceApprove(spokePool, 0);
    }

    /**
     * @dev The only token the adapter sends out of its own balance is the fee. Virtual for TRON,
     *      whose USDT `transfer` reports false on success and so fails {SafeERC20-safeTransfer}.
     */
    function _transferToken(address token, address to, uint256 amount) internal virtual {
        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @dev Whether this deployment runs on TRON, where vault addresses come from the TRON factory.
     */
    function _onTron() internal pure virtual returns (bool) {
        return false;
    }

    /**
     * @dev The native coin's decimals: 18 on every EVM chain, virtual for TRON's 6.
     */
    function _nativeDecimals() internal pure virtual returns (uint8) {
        return 18;
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
        uint256 flat = uint64(route >> 184);
        uint256 maxFlat = MAX_FLAT_COST_TOKENS * 10 ** outputDecimals;
        if (flat > maxFlat) flat = maxFlat;

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
        least = least > flat ? least - flat : 0;
        if (q.outputAmount < least || q.outputAmount == 0) revert BridgeOutputTooLow();
    }

    function _deposit(
        address vault,
        bytes32 recipient,
        address inputToken,
        uint256 inputAmount,
        uint256 value,
        AcrossQuote memory q
    ) private {
        IAcrossSpokePool(spokePool).deposit{value: value}(
            _b32(vault),
            recipient,
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
