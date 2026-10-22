// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {TestProxy} from "../../helpers/Proxy.sol";
import {UniswapXV1Protocol} from "protocol-contracts/src/protocols/uniswapx/UniswapXV1Protocol.sol";
import {IBittyVaultOffchainAuth} from "protocol-contracts/src/interfaces/IBittyVaultOffchainAuth.sol";
import {
    OrderInfo,
    NonlinearDutchDecay,
    V3DutchInput,
    V3DutchOutput,
    V3DutchOrder,
    V3DutchOrderLib,
    IPermit2Domain
} from "protocol-contracts/src/libs/uniswapx/V3DutchOrder.sol";
import {robinhood} from "../../../script/addresses.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @dev The reactor's full V3DutchOrder: the swapper-signed fields plus what the cosigner adds.
struct CosignerData {
    uint256 decayStartBlock;
    address exclusiveFiller;
    uint256 exclusivityOverrideBps;
    uint256 inputAmount;
    uint256[] outputAmounts;
}

struct ReactorV3DutchOrder {
    OrderInfo info;
    address cosigner;
    uint256 startingBaseFee;
    V3DutchInput baseInput;
    V3DutchOutput[] baseOutputs;
    CosignerData cosignerData;
    bytes cosignature;
}

struct SignedOrder {
    bytes order;
    bytes sig;
}

interface IReactor {
    function execute(SignedOrder calldata order) external payable;
}

/// @dev Permit2's SignatureVerification error when the swapper's ERC-1271 answer is not the magic value.
error InvalidContractSignature();

interface IArbSys {
    function arbBlockNumber() external view returns (uint256);
}

/**
 * @dev Stands in for the vault on the parts UniswapX touches: it is the swapper, approves its sell
 *      token to Permit2, answers isValidSignature by delegating to its clone (as the vault's DeFi facet
 *      does), and authorises one manager.
 */
contract ForkVault is IBittyVaultOffchainAuth {
    address public immutable manager;
    address public clone;

    constructor(address manager_) {
        manager = manager_;
    }

    function setClone(address clone_) external {
        clone = clone_;
    }

    function approve(address token, address spender) external {
        IERC20(token).approve(spender, type(uint256).max);
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        return UniswapXV1Protocol(clone).isValidSignature(hash, signature);
    }

    function isOffchainOrderAuthorized(address signer, address sellToken, address, uint256 sellAmount)
        external
        view
        returns (bool)
    {
        return signer == manager && IERC20(sellToken).balanceOf(address(this)) >= sellAmount;
    }

    function isOffchainCancellationAuthorized(address signer) external view returns (bool) {
        return signer == manager;
    }
}

/**
 * Robinhood Chain: a vault-signed V3 Dutch order filled through the LIVE V3DutchOrderReactor and
 * Permit2. The local suite proves the validation rules; this proves the digest the clone rebuilds is
 * byte-for-byte the one Permit2 asks the vault about, so real orders actually settle.
 */
contract UniswapXV1ProtocolRobinhoodForkTest is Test {
    uint256 internal constant MANAGER_PK = 0xA11CE;
    uint256 internal constant COSIGNER_PK = 0xC0516;

    UniswapXV1Protocol internal ux;
    ForkVault internal vault;
    address internal feeRecipient;

    function setUp() public {
        vm.createSelectFork("robinhood");
        // Forge's EVM has no Arbitrum precompiles; the reactor reads the L2 block height from ArbSys.
        vm.etch(address(0x64), hex"00");
        vm.mockCall(address(0x64), abi.encodeCall(IArbSys.arbBlockNumber, ()), abi.encode(block.number));

        vault = new ForkVault(vm.addr(MANAGER_PK));
        ux = UniswapXV1Protocol(
            TestProxy.deploy(
                address(new UniswapXV1Protocol(robinhood.UNISWAPX_V3_DUTCH_REACTOR, robinhood.PERMIT2)), address(vault)
            )
        );
        vault.setClone(address(ux));
        vault.approve(robinhood.WETH, ux.vaultRelayer());
        feeRecipient = ux.FEE_RECIPIENT();

        deal(robinhood.WETH, address(vault), 1e18);
        deal(robinhood.USDG, address(this), 10_000e6);
        IERC20(robinhood.USDG).approve(robinhood.UNISWAPX_V3_DUTCH_REACTOR, type(uint256).max);
    }

    function _flat(address token, uint256 amount, address recipient) internal pure returns (V3DutchOutput memory) {
        return V3DutchOutput({
            token: token,
            startAmount: amount,
            curve: NonlinearDutchDecay({relativeBlocks: 0, relativeAmounts: new int256[](0)}),
            recipient: recipient,
            minAmount: amount,
            adjustmentPerGweiBaseFee: 0
        });
    }

    function _order(uint256 nonce) internal view returns (V3DutchOrder memory order) {
        order.info = OrderInfo({
            reactor: robinhood.UNISWAPX_V3_DUTCH_REACTOR,
            swapper: address(vault),
            nonce: nonce,
            deadline: block.timestamp + 600,
            additionalValidationContract: address(0),
            additionalValidationData: ""
        });
        order.cosigner = vm.addr(COSIGNER_PK);
        order.startingBaseFee = block.basefee;
        order.baseInput = V3DutchInput({
            token: robinhood.WETH,
            startAmount: 1e18,
            curve: NonlinearDutchDecay({relativeBlocks: 0, relativeAmounts: new int256[](0)}),
            maxAmount: 1e18,
            adjustmentPerGweiBaseFee: 0
        });
        order.baseOutputs = new V3DutchOutput[](2);
        order.baseOutputs[0] = _flat(robinhood.USDG, 1996e6, address(vault));
        order.baseOutputs[1] = _flat(robinhood.USDG, 4e6, feeRecipient);
    }

    function _signed(V3DutchOrder memory order, uint256 signerPk) internal view returns (SignedOrder memory) {
        bytes32 digest = V3DutchOrderLib.permit2Digest(
            order, V3DutchOrderLib.hash(order), IPermit2Domain(robinhood.PERMIT2).DOMAIN_SEPARATOR()
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);

        CosignerData memory cd = CosignerData({
            decayStartBlock: block.number,
            exclusiveFiller: address(0),
            exclusivityOverrideBps: 0,
            inputAmount: 0,
            outputAmounts: new uint256[](order.baseOutputs.length)
        });
        bytes32 cosignerDigest = keccak256(abi.encodePacked(V3DutchOrderLib.hash(order), block.chainid, abi.encode(cd)));
        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(COSIGNER_PK, cosignerDigest);

        ReactorV3DutchOrder memory full = ReactorV3DutchOrder({
            info: order.info,
            cosigner: order.cosigner,
            startingBaseFee: order.startingBaseFee,
            baseInput: order.baseInput,
            baseOutputs: order.baseOutputs,
            cosignerData: cd,
            cosignature: abi.encodePacked(cr, cs, cv)
        });
        return SignedOrder({order: abi.encode(full), sig: abi.encode(order, abi.encodePacked(r, s, v))});
    }

    function test_fill_settlesThroughPermit2() public {
        uint256 feeBefore = IERC20(robinhood.USDG).balanceOf(feeRecipient);

        IReactor(robinhood.UNISWAPX_V3_DUTCH_REACTOR).execute(_signed(_order(1), MANAGER_PK));

        assertEq(IERC20(robinhood.WETH).balanceOf(address(vault)), 0);
        assertEq(IERC20(robinhood.WETH).balanceOf(address(this)), 1e18);
        assertEq(IERC20(robinhood.USDG).balanceOf(address(vault)), 1996e6);
        assertEq(IERC20(robinhood.USDG).balanceOf(feeRecipient) - feeBefore, 4e6);
    }

    function test_replay_reverts() public {
        deal(robinhood.WETH, address(vault), 2e18);
        SignedOrder memory signed = _signed(_order(2), MANAGER_PK);
        IReactor(robinhood.UNISWAPX_V3_DUTCH_REACTOR).execute(signed);
        vm.expectRevert();
        IReactor(robinhood.UNISWAPX_V3_DUTCH_REACTOR).execute(signed);
    }

    function test_unauthorizedSigner_reverts() public {
        SignedOrder memory signed = _signed(_order(3), 0xB0B);
        vm.expectRevert(InvalidContractSignature.selector);
        IReactor(robinhood.UNISWAPX_V3_DUTCH_REACTOR).execute(signed);
    }

    function test_feeStripped_reverts() public {
        V3DutchOrder memory order = _order(4);
        V3DutchOutput[] memory outs = new V3DutchOutput[](1);
        outs[0] = order.baseOutputs[0];
        order.baseOutputs = outs;
        SignedOrder memory signed = _signed(order, MANAGER_PK);
        vm.expectRevert(InvalidContractSignature.selector);
        IReactor(robinhood.UNISWAPX_V3_DUTCH_REACTOR).execute(signed);
    }

    function test_cancelled_reverts() public {
        V3DutchOrder memory order = _order(5);
        SignedOrder memory signed = _signed(order, MANAGER_PK);
        bytes[] memory ids = new bytes[](1);
        ids[0] = abi.encodePacked(V3DutchOrderLib.hash(order));
        vm.prank(address(vault));
        ux.cancelOrders(ids);

        vm.expectRevert(InvalidContractSignature.selector);
        IReactor(robinhood.UNISWAPX_V3_DUTCH_REACTOR).execute(signed);
    }
}
