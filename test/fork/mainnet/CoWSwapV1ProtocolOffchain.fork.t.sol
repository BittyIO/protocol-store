// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {CoWSwapV1Protocol} from "protocol-contracts/src/protocols/cowswap/CoWSwapV1Protocol.sol";
import {IBittyVaultOffchainAuth} from "protocol-contracts/src/interfaces/IBittyVaultOffchainAuth.sol";
import {GPv2Order} from "protocol-contracts/src/libs/cow/GPv2Order.sol";
import {IGPv2Settlement} from "protocol-contracts/src/libs/cow/IGPv2Settlement.sol";
import {mainnet} from "../../../script/addresses.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

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
        protocol = new CoWSwapV1Protocol(mainnet.COW_SETTLEMENT, mainnet.COW_VAULT_RELAYER);
        protocol.initialize(address(vault));
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

    // The digest is hashed with the LIVE mainnet domain separator, then signed by the manager EOA —
    // exactly the flow the web uses. The payload is what the vault's eip1271 signature carries.
    function _payload(GPv2Order.Data memory order, uint256 pk) internal view returns (bytes32 hash, bytes memory sig) {
        hash = GPv2Order.hash(order, IGPv2Settlement(mainnet.COW_SETTLEMENT).domainSeparator());
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, hash);
        sig = abi.encode(order, abi.encodePacked(r, s, v), uint256(0));
    }

    function test_offchainOrder_signableAgainstRealSettlement() public view {
        (bytes32 hash, bytes memory sig) = _payload(_order(), managerPk);
        assertEq(protocol.isValidSignature(hash, sig), bytes4(0x1626ba7e));
    }

    function test_offchainOrder_wrongSigner_rejected() public view {
        (bytes32 hash, bytes memory sig) = _payload(_order(), 0xB0B);
        assertEq(protocol.isValidSignature(hash, sig), bytes4(0xffffffff));
    }

    function test_offchainOrder_tampered_rejected() public view {
        GPv2Order.Data memory order = _order();
        (bytes32 hash,) = _payload(order, managerPk);
        order.buyAmount = 1; // accept far less, but reuse the signed hash
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(managerPk, hash);
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
