// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {UniswapUniversalTradeProtocol} from "./UniswapUniversalTradeProtocol.sol";
import {TRC20Transfer} from "../libs/tron/TRC20Transfer.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

error ZeroFeeRecipient();

/**
 * @title SunSwapUniversalTradeProtocol
 * @notice Market trades on TRON through SunSwap's Universal Router: SunSwap V1, V2 and V3 pools, its
 *         stable (Curve-style) and PSM pools, and routes that split across them.
 *
 * @dev SunSwap's router (github.com/sun-protocol/sunswap-universal-router) is a fork of Uniswap's: the
 *      same `execute(commands, inputs, deadline)` entry point, the same Permit2 pull (SunSwap runs its own
 *      Permit2 deployment) and the same recipient sentinels (1 = the caller, 2 = the router). Its command
 *      NUMBERING differs from Uniswap's past v2/v3 (V1 swaps at 0x10/0x11, stable/PSM at 0x22+), but the
 *      adapter never looks inside a route, so the shared trade code serves it unchanged: fee model,
 *      minimum checked on the net payout, refunds, one-block Permit2 allowance. Routes are the quoting
 *      service's to build with SunSwap's command table. At the end of every `execute` the router sweeps
 *      what is left of each token it touched to SunSwap's own vault, so a route must deliver its output
 *      to the caller (recipient 1); an output sent anywhere else never reaches this adapter, and the
 *      minimum-output check then reverts the trade.
 *
 *      What differs from the EVM deployments:
 *      - LINEAGE, as for PancakeSwap: a vault keeps one clone per lineage.
 *      - FEE RECIPIENT: the fee Safe's vault does not exist on TRON, so the recipient is a constructor
 *        argument and {feeRecipient} returns it. The inherited {FEE_RECIPIENT} constant still reads the
 *        EVM address; it is not used here.
 *      - TOKEN TRANSFERS go through {TRC20Transfer}: TRON USDT's `transfer` returns false on success.
 *        Its `transferFrom` and `approve` return true, so pulls and Permit2 grants are unchanged.
 */
contract SunSwapUniversalTradeProtocol is UniswapUniversalTradeProtocol {
    address private immutable _feeRecipient;

    constructor(address universalRouter_, address permit2_, address bittyGuard_, address feeRecipient_)
        UniswapUniversalTradeProtocol(universalRouter_, permit2_, bittyGuard_)
    {
        if (feeRecipient_ == address(0)) revert ZeroFeeRecipient();
        _feeRecipient = feeRecipient_;
    }

    function protocolLineage() external pure override returns (bytes32) {
        return keccak256("bitty.adapter.sunswap.universal");
    }

    function feeRecipient() public view override returns (address) {
        return _feeRecipient;
    }

    function _transferToken(address token, address to, uint256 amount) internal override {
        TRC20Transfer.safeTransfer(IERC20(token), to, amount);
    }
}
