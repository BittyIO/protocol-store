// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {TestProxy} from "../../helpers/Proxy.sol";
import {Test} from "forge-std/Test.sol";
import {CoWSwapV1Protocol} from "protocol-contracts/src/protocols/cowswap/CoWSwapV1Protocol.sol";
import {IBittyVaultOffchainAuth} from "protocol-contracts/src/interfaces/IBittyVaultOffchainAuth.sol";
import {GPv2Order} from "protocol-contracts/src/libs/cow/GPv2Order.sol";
import {IGPv2Settlement} from "protocol-contracts/src/libs/cow/IGPv2Settlement.sol";
import {mainnet} from "../../../script/addresses.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// Just enough of mainnet's GPv2Settlement and its solver allow list to settle one order as a solver.
interface IGPv2Settle {
    struct TradeData {
        uint256 sellTokenIndex;
        uint256 buyTokenIndex;
        address receiver;
        uint256 sellAmount;
        uint256 buyAmount;
        uint32 validTo;
        bytes32 appData;
        uint256 feeAmount;
        uint256 flags;
        uint256 executedAmount;
        bytes signature;
    }

    struct InteractionData {
        address target;
        uint256 value;
        bytes callData;
    }

    function settle(
        IERC20[] calldata tokens,
        uint256[] calldata clearingPrices,
        TradeData[] calldata trades,
        InteractionData[][3] calldata interactions
    ) external;

    function authenticator() external view returns (address);
}

interface IGPv2AllowList {
    function manager() external view returns (address);
    function addSolver(address solver) external;
}

// Stands in for the vault (owns the clone, answers the off-chain auth callback).
contract MockVaultAuth is IBittyVaultOffchainAuth {
    address public authorizedSigner;
    address public allowedBuyToken;

    constructor(address authorizedSigner_, address allowedBuyToken_) {
        authorizedSigner = authorizedSigner_;
        allowedBuyToken = allowedBuyToken_;
    }

    function isOffchainOrderAuthorized(address signer, address, address buyToken, uint256)
        external
        view
        returns (bool)
    {
        return signer == authorizedSigner && buyToken == allowedBuyToken;
    }

    function isOffchainCancellationAuthorized(address signer) external view returns (bool) {
        return signer == authorizedSigner;
    }
}

// Exercises the gasless off-chain signing path against mainnet's REAL GPv2Settlement — proving the
// EIP-712 digest the manager signs is byte-identical to what a mainnet CoW solver computes (the one
// thing that can't be checked without real CoW infra). No solver/Sepolia/funds needed: CoW calls
// isValidSignature during settlement, so a passing magic-value here means the order is settleable.
contract TestCoWSwapV1ProtocolOffchainFork is Test {
    CoWSwapV1Protocol public protocol;
    MockVaultAuth public vault;

    uint256 internal managerPk = 0xA11CE;
    address internal manager;

    function setUp() public {
        vm.createSelectFork("mainnet");
        manager = vm.addr(managerPk);
        vault = new MockVaultAuth(manager, address(mainnet.WETH));
        protocol = CoWSwapV1Protocol(
            payable(TestProxy.deploy(
                    address(new CoWSwapV1Protocol(mainnet.COW_SETTLEMENT, mainnet.COW_VAULT_RELAYER)), address(vault)
                ))
        );
    }

    function _order() internal view returns (GPv2Order.Data memory) {
        return GPv2Order.Data({
            sellToken: IERC20(address(mainnet.USDC)),
            buyToken: IERC20(address(mainnet.WETH)),
            receiver: address(vault),
            sellAmount: 1000e6,
            buyAmount: 1e17,
            validTo: uint32(block.timestamp + 3600),
            appData: protocol.APP_DATA(),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
    }

    // The CoW digest is hashed with the LIVE mainnet domain separator; the manager EOA signs the Bitty
    // VaultOrder that wraps it. The payload is what the vault's eip1271 signature carries.
    function _payload(GPv2Order.Data memory order, uint256 pk) internal view returns (bytes32 hash, bytes memory sig) {
        hash = GPv2Order.hash(order, IGPv2Settlement(mainnet.COW_SETTLEMENT).domainSeparator());
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, protocol.vaultOrderDigest(order));
        sig = abi.encode(order, abi.encodePacked(r, s, v), uint256(0));
    }

    function test_offchainOrder_signableAgainstRealSettlement() public view {
        (bytes32 hash, bytes memory sig) = _payload(_order(), managerPk);
        assertEq(protocol.isValidSignature(hash, sig), bytes4(0x1626ba7e));
    }

    /**
     * Settle `order` on mainnet's settlement as an EIP-712 order (flags 0: sell, fill-or-kill, ERC-20
     * balances, EIP-712 scheme) carrying `signature`, with this test as an allow-listed solver. The
     * settlement recovers the order's owner from `signature` over the GPv2 digest and sells its tokens.
     */
    function _settleAsWalletOrder(GPv2Order.Data memory order, bytes memory signature) internal {
        IGPv2Settle settlement = IGPv2Settle(mainnet.COW_SETTLEMENT);
        IGPv2AllowList allowList = IGPv2AllowList(settlement.authenticator());
        vm.prank(allowList.manager());
        allowList.addSolver(address(this));
        deal(address(mainnet.WETH), address(settlement), order.buyAmount);

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = order.sellToken;
        tokens[1] = order.buyToken;
        uint256[] memory prices = new uint256[](2);
        prices[0] = order.buyAmount;
        prices[1] = order.sellAmount;
        IGPv2Settle.TradeData[] memory trades = new IGPv2Settle.TradeData[](1);
        trades[0] = IGPv2Settle.TradeData({
            sellTokenIndex: 0,
            buyTokenIndex: 1,
            receiver: order.receiver,
            sellAmount: order.sellAmount,
            buyAmount: order.buyAmount,
            validTo: order.validTo,
            appData: order.appData,
            feeAmount: order.feeAmount,
            flags: 0,
            executedAmount: order.sellAmount,
            signature: signature
        });
        IGPv2Settle.InteractionData[][3] memory interactions;
        settlement.settle(tokens, prices, trades, interactions);
    }

    /// The manager's wallet holds the order's sell token and has approved CoW, as any CoW trader's has.
    function _fundManagerWallet(GPv2Order.Data memory order) internal {
        deal(address(order.sellToken), manager, order.sellAmount);
        vm.prank(manager);
        order.sellToken.approve(mainnet.COW_VAULT_RELAYER, type(uint256).max);
    }

    /**
     * M-01, the attack 1.0.3 allowed: a signature over the bare GPv2 digest, lifted from a vault order,
     * settles on the real settlement as an order of the manager's own wallet.
     */
    function test_aSignatureOverTheCowDigestFillsFromTheSignersWallet() public {
        GPv2Order.Data memory order = _order();
        _fundManagerWallet(order);
        bytes32 hash = GPv2Order.hash(order, IGPv2Settlement(mainnet.COW_SETTLEMENT).domainSeparator());
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(managerPk, hash);

        _settleAsWalletOrder(order, abi.encodePacked(r, s, v));
        assertEq(IERC20(address(mainnet.USDC)).balanceOf(manager), 0, "the manager's own USDC was sold");
        assertEq(IERC20(address(mainnet.WETH)).balanceOf(address(vault)), order.buyAmount, "into the vault");
    }

    /**
     * M-01, fixed: the signature a 1.0.4 vault order carries is over the Bitty VaultOrder, so the same
     * replay recovers an owner that is not the manager and the manager's wallet is never touched.
     */
    function test_aVaultOrderSignatureDoesNotFillFromTheSignersWallet() public {
        GPv2Order.Data memory order = _order();
        _fundManagerWallet(order);
        (bytes32 hash, bytes memory sig) = _payload(order, managerPk);
        assertEq(protocol.isValidSignature(hash, sig), bytes4(0x1626ba7e), "a valid vault order");
        (, bytes memory managerSig,) = abi.decode(sig, (GPv2Order.Data, bytes, uint256));

        vm.expectRevert();
        this.settleAsWalletOrder(order, managerSig);
        assertEq(IERC20(address(mainnet.USDC)).balanceOf(manager), order.sellAmount, "the manager's USDC is untouched");
    }

    function settleAsWalletOrder(GPv2Order.Data memory order, bytes memory signature) external {
        _settleAsWalletOrder(order, signature);
    }

    function test_offchainOrder_wrongSigner_rejected() public view {
        (bytes32 hash, bytes memory sig) = _payload(_order(), 0xB0B);
        assertEq(protocol.isValidSignature(hash, sig), bytes4(0xffffffff));
    }

    function test_offchainOrder_tampered_rejected() public view {
        GPv2Order.Data memory order = _order();
        (bytes32 hash,) = _payload(order, managerPk);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(managerPk, protocol.vaultOrderDigest(order));
        order.buyAmount = 1; // accept far less, but reuse the signature
        bytes memory tampered = abi.encode(order, abi.encodePacked(r, s, v), uint256(0));
        assertEq(protocol.isValidSignature(hash, tampered), bytes4(0xffffffff));
    }

    function test_offchainOrder_wrongAppData_rejected() public view {
        GPv2Order.Data memory order = _order();
        order.appData = bytes32(uint256(1));
        (bytes32 hash, bytes memory sig) = _payload(order, managerPk);
        assertEq(protocol.isValidSignature(hash, sig), bytes4(0xffffffff));
    }
}
