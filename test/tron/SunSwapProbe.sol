// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SunSwapUniversalTradeProtocol} from "../../src/protocols/SunSwapUniversalTradeProtocol.sol";
import {UniversalRoute} from "../../src/libs/uniswap/universal/UniversalRouter.sol";

/// Calls USDT a stable coin and nothing else, as the TRON guard will.
contract SunSwapProbeGuard {
    address immutable usdt;

    constructor(address usdt_) {
        usdt = usdt_;
    }

    function assetCategory(address token) external view returns (uint8) {
        return token == usdt ? 1 : 0;
    }
}

/**
 * @dev Never deployed. tron/sunswap.mjs `probe` runs this init code as a SIMULATED deployment on a live
 *      TRON node (/wallet/triggerconstantcontract: nothing signed, nothing spent) with some TRX
 *      attached. It deploys the adapter behind a proxy, owns it as a vault would, and trades through
 *      SunSwap's real Universal Router, Permit2 and V2 WTRX/USDT pair:
 *
 *        1. TRX -> USDT  (native in: WRAP_ETH + V2_SWAP_EXACT_IN; fee from the USDT output)
 *        2. USDT -> TRX  (Permit2 pull: V2_SWAP_EXACT_IN payerIsUser + UNWRAP_WETH; fee from the USDT input)
 *
 *      which covers native in and out, the Permit2 grant against SunSwap's Permit2, USDT's
 *      false-returning transfer on the payout, and the router's end-of-call sweep. Each result is one
 *      word of the returned "runtime code"; see `probe` in sunswap.mjs.
 */
contract SunSwapProbe {
    address private constant MSG_SENDER = address(1); // router sentinel: its caller, the adapter
    address private constant ADDRESS_THIS = address(2); // router sentinel: the router itself

    constructor(address router, address permit2, address wtrx, address usdt, address feeTo) payable {
        uint256[8] memory r;
        SunSwapUniversalTradeProtocol impl =
            new SunSwapUniversalTradeProtocol(router, permit2, address(new SunSwapProbeGuard(usdt)), feeTo);
        SunSwapUniversalTradeProtocol adapter = SunSwapUniversalTradeProtocol(
            payable(new ERC1967Proxy(address(impl), abi.encodeCall(impl.initialize, (address(this)))))
        );
        IERC20 usd = IERC20(usdt);

        // 1. Sell all attached TRX for USDT.
        uint256 trxIn = msg.value;
        address[] memory path = new address[](2);
        (path[0], path[1]) = (wtrx, usdt);
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(ADDRESS_THIS, trxIn);
        inputs[1] = abi.encode(MSG_SENDER, trxIn, uint256(0), path, false);
        uint256 feeBefore = usd.balanceOf(feeTo);
        adapter.swap{value: trxIn}(
            abi.encode(address(0), trxIn, usdt, uint256(1), UniversalRoute.encode(hex"0b08", inputs, block.timestamp)),
            address(this)
        );
        r[0] = usd.balanceOf(address(this)); // USDT received, net
        r[1] = usd.balanceOf(feeTo) - feeBefore; // USDT fee from the output

        // 2. Sell that USDT back for TRX. A stable sale: the fee comes off the input first.
        uint256 usdIn = r[0];
        uint256 swapIn = usdIn - usdIn * 20 / 10_000;
        (path[0], path[1]) = (usdt, wtrx);
        inputs[0] = abi.encode(ADDRESS_THIS, swapIn, uint256(0), path, true);
        inputs[1] = abi.encode(MSG_SENDER, uint256(0));
        usd.approve(address(adapter), usdIn);
        uint256 trxBefore = address(this).balance;
        feeBefore = usd.balanceOf(feeTo);
        adapter.swap(abi.encode(usdt, usdIn, address(0), uint256(1), UniversalRoute.encode(hex"080c", inputs, block.timestamp)), address(this));
        r[2] = address(this).balance - trxBefore; // TRX received, net
        r[3] = usd.balanceOf(feeTo) - feeBefore; // USDT fee from the input
        r[4] = usd.balanceOf(address(this)); // USDT left with the "vault": 0 when the route spent it all

        // Nothing stays on the adapter.
        r[5] = usd.balanceOf(address(adapter)) + IERC20(wtrx).balanceOf(address(adapter)) + address(adapter).balance;
        r[6] = trxIn;
        r[7] = uint256(adapter.protocolLineage());
        assembly {
            return(r, 256)
        }
    }

    receive() external payable {}
}
