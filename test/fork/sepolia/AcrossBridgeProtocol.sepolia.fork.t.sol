// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {TestProxy} from "../../helpers/Proxy.sol";
import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AcrossBridgeProtocol} from "protocol-contracts/src/protocols/AcrossBridgeProtocol.sol";

contract ForkRouteGuard {
    mapping(bytes32 => uint256) public getUint;

    function setUint(bytes32 key, uint256 v) external {
        getUint[key] = v;
    }
}

/**
 * Against Across's real SpokePool on Sepolia, bridging to Base Sepolia (the routes Across's testnet
 * carries): the deposit is accepted, and the event Across's relayers fill from names the vault as
 * depositor and the vault's own address on Base Sepolia as recipient.
 *
 * This test contract plays the vault: it owns the adapter and answers owner().
 */
contract TestAcrossBridgeProtocolSepoliaFork is Test {
    address constant SPOKE_POOL = 0x5ef6C01E11889d86803e0B23e3cB3F9E9d97B662;
    address constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14; // Across's wrapped native here
    address constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    uint256 constant BASE_SEPOLIA = 84532;
    address constant BASE_SEPOLIA_WETH = 0x4200000000000000000000000000000000000006;
    address constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    bytes32 constant FUNDS_DEPOSITED = keccak256(
        "FundsDeposited(bytes32,bytes32,uint256,uint256,uint256,uint256,uint32,uint32,uint32,bytes32,bytes32,bytes32,bytes)"
    );

    address public owner = makeAddr("owner");
    AcrossBridgeProtocol adapter;
    ForkRouteGuard guard;

    function setUp() public {
        vm.createSelectFork("sepolia");
        guard = new ForkRouteGuard();
        AcrossBridgeProtocol impl = new AcrossBridgeProtocol(SPOKE_POOL, address(guard), address(0), bytes32(0));
        adapter = AcrossBridgeProtocol(payable(TestProxy.deploy(address(impl), address(this))));
        guard.setUint(adapter.routeKey(WETH, BASE_SEPOLIA), adapter.packRoute(BASE_SEPOLIA_WETH, 18, 300));
        guard.setUint(adapter.routeKey(USDC, BASE_SEPOLIA), adapter.packRoute(BASE_SEPOLIA_USDC, 6, 300));
        vm.deal(address(this), 1 ether);
    }

    function _quote(address outputToken, uint256 outputAmount) internal view returns (bytes memory) {
        return abi.encode(
            AcrossBridgeProtocol.AcrossQuote({
                destinationChainId: BASE_SEPOLIA,
                outputToken: outputToken,
                outputAmount: outputAmount,
                exclusiveRelayer: address(0),
                quoteTimestamp: uint32(block.timestamp),
                fillDeadline: uint32(block.timestamp + 2 hours),
                exclusivityParameter: 0
            })
        );
    }

    function _assertDeposited(address inputToken, uint256 inputAmount, uint256 outputAmount) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != SPOKE_POOL || logs[i].topics[0] != FUNDS_DEPOSITED) continue;
            assertEq(uint256(logs[i].topics[1]), BASE_SEPOLIA);
            assertEq(logs[i].topics[3], bytes32(uint256(uint160(address(this)))), "depositor = vault");
            (bytes32 input,, uint256 inAmt, uint256 outAmt,,,, bytes32 recipient,, bytes memory message) = abi.decode(
                logs[i].data, (bytes32, bytes32, uint256, uint256, uint32, uint32, uint32, bytes32, bytes32, bytes)
            );
            assertEq(input, bytes32(uint256(uint160(inputToken))));
            assertEq(inAmt, inputAmount);
            assertEq(outAmt, outputAmount);
            assertEq(recipient, bytes32(uint256(uint160(address(this)))), "recipient = the vault");
            assertEq(message.length, 0);
            seen = true;
        }
        assertTrue(seen, "FundsDeposited");
    }

    function test_nativeDeposit() public {
        uint256 before = IERC20(WETH).balanceOf(SPOKE_POOL);
        vm.recordLogs();
        adapter.bridge{value: 0.01 ether}(
            address(0), 0.01 ether, 0.00002 ether, _quote(BASE_SEPOLIA_WETH, 0.0099 ether)
        );
        assertEq(IERC20(WETH).balanceOf(SPOKE_POOL) - before, 0.00998 ether, "spoke wrapped the deposit");
        _assertDeposited(WETH, 0.00998 ether, 0.0099 ether);
    }

    function test_usdcDeposit() public {
        deal(USDC, address(this), 100e6);
        IERC20(USDC).approve(address(adapter), 100e6);
        uint256 before = IERC20(USDC).balanceOf(SPOKE_POOL);
        vm.recordLogs();
        adapter.bridge(USDC, 100e6, 0.2e6, _quote(BASE_SEPOLIA_USDC, 99e6));
        assertEq(IERC20(USDC).balanceOf(SPOKE_POOL) - before, 99.8e6);
        assertEq(IERC20(USDC).balanceOf(address(this)), 0);
        assertEq(IERC20(USDC).allowance(address(adapter), SPOKE_POOL), 0);
        _assertDeposited(USDC, 99.8e6, 99e6);
    }
}
