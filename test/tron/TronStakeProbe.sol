// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ITronStakeOps} from "../../src/protocols/TronStakeProtocol.sol";

/**
 * @dev Never deployed. tron/stake.mjs `probe` runs this init code as a SIMULATED deployment on a live
 *      TRON node (/wallet/triggerconstantcontract, nothing signed, nothing spent), with a little TRX
 *      attached, to check what the adapter rests on before anything is paid for: that
 *      TronStakeOps.yul's opcodes and argument order are what the TVM executes, that they act on the
 *      DELEGATECALLING account, and that the query precompiles answer.
 *
 *      Each step's result is one word of the returned "runtime code"; see `probe` in stake.mjs.
 */
contract TronStakeProbe {
    uint256 private constant TRX = 1e6;
    uint256 private constant ENERGY = 1;

    constructor(bytes memory opsInitCode, address receiver) payable {
        uint256[10] memory r;
        address ops;
        assembly {
            ops := create(0, add(opsInitCode, 0x20), mload(opsInitCode))
        }
        r[0] = uint160(ops);
        uint256 balance0 = address(this).balance;
        r[1] = _op(ops, abi.encodeCall(ITronStakeOps.freezeBalanceV2, (TRX, ENERGY)));
        r[2] = balance0 - address(this).balance; // the freeze took it from THIS account
        r[3] = _query(address(0x100000f), abi.encode(address(this), ENERGY)); // delegatable
        r[4] = _op(ops, abi.encodeCall(ITronStakeOps.delegateResource, (receiver, TRX, ENERGY)));
        r[5] = _op(ops, abi.encodeCall(ITronStakeOps.unDelegateResource, (receiver, TRX, ENERGY)));
        r[6] = _op(ops, abi.encodeCall(ITronStakeOps.unfreezeBalanceV2, (TRX, ENERGY)));
        r[7] = _query(address(0x100000b), abi.encode(uint256(5))); // unstake delay, days
        r[8] = _op(ops, abi.encodeCall(ITronStakeOps.withdrawExpireUnfreeze, ()));
        // A failed op must report 0, not revert: freezing more than the balance.
        r[9] = _op(ops, abi.encodeCall(ITronStakeOps.freezeBalanceV2, (1_000_000_000 * TRX, ENERGY)));
        assembly {
            return(r, 320)
        }
    }

    function _op(address ops, bytes memory data) private returns (uint256) {
        (bool ok, bytes memory ret) = ops.delegatecall(data);
        if (!ok || ret.length != 32) return type(uint256).max;
        return abi.decode(ret, (uint256));
    }

    function _query(address precompile, bytes memory data) private view returns (uint256) {
        (bool ok, bytes memory ret) = precompile.staticcall(data);
        if (!ok || ret.length < 32) return type(uint256).max;
        return abi.decode(ret, (uint256));
    }
}
