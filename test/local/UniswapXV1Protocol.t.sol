// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {TestProxy} from "../helpers/Proxy.sol";
import {UniswapXV1Protocol} from "../../src/protocols/uniswapx/UniswapXV1Protocol.sol";
import {IBittyVaultOffchainAuth} from "../../src/interfaces/IBittyVaultOffchainAuth.sol";
import {InvalidOrderId} from "../../src/interfaces/IBittyV1IntentProtocol.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {
    OrderInfo,
    NonlinearDutchDecay,
    V3DutchInput,
    V3DutchOutput,
    V3DutchOrder,
    V3DutchOrderLib
} from "../../src/libs/uniswapx/V3DutchOrder.sol";

contract MockPermit2 {
    bytes32 public constant DOMAIN_SEPARATOR = keccak256("bitty-test-permit2-domain");
}

// Stands in for the vault: owns the clone and answers the off-chain auth callback for one signer.
contract MockUniswapXVault is IBittyVaultOffchainAuth {
    address public authorizedSigner;
    address public allowedBuyToken;

    constructor(address authorizedSigner_, address allowedBuyToken_) {
        authorizedSigner = authorizedSigner_;
        allowedBuyToken = allowedBuyToken_;
    }

    function isOffchainOrderAuthorized(address signer, address, address buyToken, uint256 sellAmount)
        external
        view
        returns (bool)
    {
        return signer == authorizedSigner && buyToken == allowedBuyToken && sellAmount <= 1e18;
    }

    function isOffchainCancellationAuthorized(address signer) external view returns (bool) {
        return signer == authorizedSigner;
    }
}

contract UniswapXV1ProtocolTest is Test {
    bytes4 internal constant MAGIC = 0x1626ba7e;
    bytes4 internal constant INVALID = 0xffffffff;

    address internal constant SELL = address(0x1111);
    address internal constant BUY = address(0x2222);
    address internal constant REACTOR = address(0x3333);
    address internal constant COSIGNER = address(0x4444);

    UniswapXV1Protocol internal ux;
    MockPermit2 internal permit2;
    MockUniswapXVault internal vault;

    uint256 internal managerPk = 0xA11CE;

    function setUp() public {
        permit2 = new MockPermit2();
        vault = new MockUniswapXVault(vm.addr(managerPk), BUY);
        ux = UniswapXV1Protocol(
            TestProxy.deploy(address(new UniswapXV1Protocol(REACTOR, address(permit2))), address(vault))
        );
        vm.warp(1_000_000);
    }

    function _output(address token, uint256 startAmount, uint256 minAmount, address recipient)
        internal
        pure
        returns (V3DutchOutput memory)
    {
        return V3DutchOutput({
            token: token,
            startAmount: startAmount,
            curve: NonlinearDutchDecay({relativeBlocks: 0, relativeAmounts: new int256[](0)}),
            recipient: recipient,
            minAmount: minAmount,
            adjustmentPerGweiBaseFee: 0
        });
    }

    function _order() internal view returns (V3DutchOrder memory order) {
        order.info = OrderInfo({
            reactor: REACTOR,
            swapper: address(vault),
            nonce: 7,
            deadline: block.timestamp + 600,
            additionalValidationContract: address(0),
            additionalValidationData: ""
        });
        order.cosigner = COSIGNER;
        order.startingBaseFee = 0.1 gwei;
        order.baseInput = V3DutchInput({
            token: SELL,
            startAmount: 1e18,
            curve: NonlinearDutchDecay({relativeBlocks: 0, relativeAmounts: new int256[](0)}),
            maxAmount: 1e18,
            adjustmentPerGweiBaseFee: 0
        });
        order.baseOutputs = new V3DutchOutput[](2);
        order.baseOutputs[0] = _output(BUY, 1996e6, 1896e6, address(vault));
        order.baseOutputs[1] = _output(BUY, 4e6, 3.8e6, ux.FEE_RECIPIENT());
    }

    function _sign(uint256 pk, bytes32 hash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, hash);
        return abi.encodePacked(r, s, v);
    }

    function _payload(V3DutchOrder memory order, uint256 pk) internal view returns (bytes32 hash, bytes memory sig) {
        hash = V3DutchOrderLib.permit2Digest(order, V3DutchOrderLib.hash(order), permit2.DOMAIN_SEPARATOR());
        sig = abi.encode(order, _sign(pk, hash));
    }

    function _check(V3DutchOrder memory order) internal view returns (bytes4) {
        (bytes32 hash, bytes memory sig) = _payload(order, managerPk);
        return ux.isValidSignature(hash, sig);
    }

    function test_metadata() public view {
        assertEq(ux.protocolLineage(), keccak256("bitty.adapter.uniswapx.v1"));
        assertEq(ux.versionName(), "1.0.0");
        assertEq(ux.spender(), address(permit2));
        assertEq(ux.vaultRelayer(), address(permit2));
        assertEq(ux.reactor(), REACTOR);
    }

    function test_validOrder_isSignable() public view {
        assertEq(_check(_order()), MAGIC);
    }

    function test_unauthorizedSigner_rejected() public view {
        (bytes32 hash, bytes memory sig) = _payload(_order(), 0xB0B);
        assertEq(ux.isValidSignature(hash, sig), INVALID);
    }

    function test_tamperedOrder_rejected() public view {
        V3DutchOrder memory order = _order();
        (bytes32 hash,) = _payload(order, managerPk);
        bytes memory signerSig = _sign(managerPk, hash);
        order.baseOutputs[0].minAmount = 1; // accept far less, keep the signed hash
        assertEq(ux.isValidSignature(hash, abi.encode(order, signerSig)), INVALID);
    }

    function test_otherReactor_rejected() public {
        V3DutchOrder memory order = _order();
        order.info.reactor = address(0xBAD);
        assertEq(_check(order), INVALID);
    }

    function test_otherSwapper_rejected() public {
        V3DutchOrder memory order = _order();
        order.info.swapper = address(0xBAD);
        assertEq(_check(order), INVALID);
    }

    function test_outputNotToVault_rejected() public {
        V3DutchOrder memory order = _order();
        order.baseOutputs[0].recipient = address(0xBAD);
        assertEq(_check(order), INVALID);
    }

    function test_missingFeeOutput_rejected() public {
        V3DutchOrder memory order = _order();
        V3DutchOutput[] memory outs = new V3DutchOutput[](1);
        outs[0] = order.baseOutputs[0];
        order.baseOutputs = outs;
        assertEq(_check(order), INVALID);
    }

    function test_feeBelowRate_rejected() public {
        V3DutchOrder memory order = _order();
        order.baseOutputs[1].startAmount = 3.9e6; // < 0.2% of 1996e6 + fee
        assertEq(_check(order), INVALID);
    }

    function test_feeFloorBelowRate_rejected() public {
        V3DutchOrder memory order = _order();
        order.baseOutputs[1].minAmount = 0; // fee could decay away
        assertEq(_check(order), INVALID);
    }

    function test_feeToOtherRecipient_rejected() public {
        V3DutchOrder memory order = _order();
        order.baseOutputs[1].recipient = address(0xBAD);
        assertEq(_check(order), INVALID);
    }

    function test_feeInOtherToken_rejected() public {
        V3DutchOrder memory order = _order();
        order.baseOutputs[1].token = SELL;
        assertEq(_check(order), INVALID);
    }

    function test_nativeOutput_rejected() public {
        V3DutchOrder memory order = _order();
        order.baseOutputs[0].token = address(0);
        order.baseOutputs[1].token = address(0);
        assertEq(_check(order), INVALID);
    }

    function test_additionalValidation_rejected() public {
        V3DutchOrder memory order = _order();
        order.info.additionalValidationContract = address(0xBAD);
        assertEq(_check(order), INVALID);
    }

    function test_expired_rejected() public {
        V3DutchOrder memory order = _order();
        order.info.deadline = block.timestamp - 1;
        assertEq(_check(order), INVALID);
    }

    /// @dev Authorization is on maxAmount — the most Permit2 can pull — not the starting amount.
    function test_authorizesMaxAmount() public {
        V3DutchOrder memory order = _order();
        order.baseInput.maxAmount = 2e18; // vault mock authorizes at most 1e18
        assertEq(_check(order), INVALID);
    }

    function test_malformedPayload_rejected() public view {
        assertEq(ux.isValidSignature(bytes32(uint256(1)), hex"deadbeef"), INVALID);
        assertEq(ux.isValidSignature(bytes32(uint256(1)), ""), INVALID);
    }

    function _cancel(bytes32 orderHash) internal {
        bytes[] memory ids = new bytes[](1);
        ids[0] = abi.encodePacked(orderHash);
        vm.prank(address(vault));
        ux.cancelOrders(ids);
    }

    function test_cancelByOrderHash_rejectsOrder() public {
        V3DutchOrder memory order = _order();
        bytes32 orderHash = V3DutchOrderLib.hash(order);
        assertEq(_check(order), MAGIC);

        _cancel(orderHash);

        assertTrue(ux.isOrderCancelled(abi.encodePacked(orderHash)));
        assertEq(_check(order), INVALID);
    }

    function test_cancel_leavesOtherOrdersValid() public {
        V3DutchOrder memory other = _order();
        other.info.nonce = 8;
        _cancel(V3DutchOrderLib.hash(other));
        assertEq(_check(_order()), MAGIC);
    }

    function test_cancel_onlyVault() public {
        bytes[] memory ids = new bytes[](1);
        ids[0] = abi.encodePacked(bytes32(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        ux.cancelOrders(ids);
    }

    function test_cancel_malformedId_reverts() public {
        bytes[] memory ids = new bytes[](1);
        ids[0] = new bytes(56); // a CoW-shaped UID is not a UniswapX order id
        vm.expectRevert(InvalidOrderId.selector);
        vm.prank(address(vault));
        ux.cancelOrders(ids);
    }
}
