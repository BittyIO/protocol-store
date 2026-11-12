// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface IWTRXDeposit {
    function deposit() external payable;
}

interface IMarketTrade {
    function swap(bytes memory data, address recipient) external payable;
}

/**
 * @dev Never deployed. Runs one ROUTE BUILT ELSEWHERE (the web API's route builder) through an adapter
 *      that is already deployed, as a SIMULATED deployment (/wallet/triggerconstantcontract): wraps the
 *      attached TRX into WTRX, sells it for `tokenOut` through `route`, returns what arrived.
 *
 *      The adapter only takes calls from its owner, so the probe puts a fresh minimal proxy (EIP-1167)
 *      over the DEPLOYED implementation and initializes it to itself, as a vault does with its clone.
 *      Returns [amount of tokenOut received, anything left on the adapter]. See `route` in sunswap.mjs.
 */
contract SunSwapRouteProbe {
    constructor(address implementation, address wtrx, address tokenOut, bytes memory route) payable {
        // A fresh proxy over the deployed implementation, owned by this probe as a vault owns its clone.
        address adapter;
        bytes memory init = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", implementation, hex"5af43d82803e903d91602b57fd5bf3"
        );
        assembly {
            adapter := create(0, add(init, 0x20), mload(init))
        }
        (bool ok,) = adapter.call(abi.encodeWithSignature("initialize(address)", address(this)));
        require(ok, "initialize");

        uint256 amountIn = msg.value;
        IWTRXDeposit(wtrx).deposit{value: amountIn}();
        IERC20(wtrx).approve(adapter, amountIn);
        uint256 before = IERC20(tokenOut).balanceOf(address(this));
        IMarketTrade(adapter).swap(abi.encode(wtrx, amountIn, tokenOut, uint256(1), route), address(this));

        uint256[2] memory r;
        r[0] = IERC20(tokenOut).balanceOf(address(this)) - before;
        r[1] = IERC20(wtrx).balanceOf(adapter) + IERC20(tokenOut).balanceOf(adapter);
        assembly {
            return(r, 64)
        }
    }
}
