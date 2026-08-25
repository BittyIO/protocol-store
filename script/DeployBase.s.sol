// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {DeployProtocols} from "./DeployProtocols.sol";

/**
 * @notice Every adapter Base supports, in one run.
 * @dev No Lido: its staking is Ethereum-only. Base has bridged wstETH but nothing to stake into,
 *      and the adapter needs stETH plus the withdrawal queue.
 *
 *      Sky is {SkyV1BaseProtocol}, not {SkyV1Protocol} — Base's Sky is a single PSM3 module rather
 *      than mainnet's PSM + ERC-4626 vault pair.
 */
contract DeployBase is DeployProtocols {
    function deploy() public override {
        _deployAave();
        _deployUniswap();
        _deployCoWSwap();
        _deploySkyBase();
    }
}
