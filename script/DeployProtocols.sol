// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {console2} from "forge-std/console2.sol";
import {AaveV3Protocol} from "../src/protocols/AaveV3Protocol.sol";
import {UniswapV3Protocol} from "../src/protocols/UniswapV3Protocol.sol";
import {LidoV2Protocol} from "../src/protocols/LidoV2Protocol.sol";
import {SkyV1Protocol} from "../src/protocols/SkyV1Protocol.sol";
import {SkyV1EvmProtocol} from "../src/protocols/SkyV1EvmProtocol.sol";
import {CoWSwapV1Protocol} from "../src/protocols/cowswap/CoWSwapV1Protocol.sol";
import {DeployScript} from "./BaseDeploy.sol";

/**
 * @title DeployProtocols
 * @notice One adapter-deploying step per protocol, shared by the per-chain scripts.
 *
 * @dev The chain scripts differ only in WHICH adapters they call, because no chain supports all of
 *      them: Lido staking is Ethereum-only, Sepolia has no Sky, and Sky on Base is a different
 *      contract from Sky on mainnet. Keeping the steps here means that list is the only thing a
 *      chain script states, and the reuse rule below cannot drift between chains.
 *
 *      Every step is RE-RUNNABLE: an adapter is skipped when the chain TOML already names one with
 *      CODE at that address. Beyond saving gas, that matters because a fresh adapter address has to
 *      be registered in the guard and the old one deprecated — so a partial run should be repeatable
 *      rather than force a full redeploy.
 *
 *      These use plain CREATE, so an address depends on the deployer's nonce rather than on the
 *      code. Reuse is therefore decided by the TOML rather than predicted; there is nothing to
 *      predict.
 */
abstract contract DeployProtocols is DeployScript {
    /**
     * @dev Reuse only when something is actually deployed there. A TOML entry alone is not enough:
     *      a simulated run writes addresses that never existed on chain, and trusting one would
     *      register a phantom adapter in the guard.
     */
    function _existing(string memory key) private view returns (address) {
        address recorded = getAddressOr(key, address(0));
        return recorded.code.length > 0 ? recorded : address(0);
    }

    /**
     * @dev Returns the address to reuse, or zero when the caller should deploy.
     */
    function _reuse(string memory name, string memory key) private returns (address) {
        address existing = _existing(key);
        if (existing == address(0)) return address(0);
        console2.log(string.concat(name, " already at"), existing);
        saveAddress(key, existing);
        return existing;
    }

    function _record(string memory name, string memory key, address deployed) private {
        console2.log(string.concat(name, " deployed at"), deployed);
        saveAddress(key, deployed);
    }

    function _deployAave() internal {
        if (_reuse("AaveV3Protocol", "AAVE_V3_PROTOCOL") != address(0)) return;
        _record(
            "AaveV3Protocol",
            "AAVE_V3_PROTOCOL",
            address(new AaveV3Protocol(getAddress("AAVE_V3"), getAddress("POOL_DATA_PROVIDER")))
        );
    }

    function _deployUniswap() internal {
        if (_reuse("UniswapV3Protocol", "UNISWAP_V3_PROTOCOL") != address(0)) return;
        _record(
            "UniswapV3Protocol",
            "UNISWAP_V3_PROTOCOL",
            address(new UniswapV3Protocol(getAddress("UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER")))
        );
    }

    function _deployCoWSwap() internal {
        if (_reuse("CoWSwapV1Protocol", "COW_SWAP_V1_PROTOCOL") != address(0)) return;
        _record(
            "CoWSwapV1Protocol",
            "COW_SWAP_V1_PROTOCOL",
            address(new CoWSwapV1Protocol(getAddress("COW_SETTLEMENT"), getAddress("COW_VAULT_RELAYER")))
        );
    }

    function _deployLido() internal {
        if (_reuse("LidoV2Protocol", "LIDO_V2_PROTOCOL") != address(0)) return;
        _record(
            "LidoV2Protocol",
            "LIDO_V2_PROTOCOL",
            address(new LidoV2Protocol(getAddress("STETH"), getAddress("UNSTETH"), getAddress("WETH")))
        );
    }

    /**
     * @dev Mainnet's Sky: PSM (sellGem/buyGem) plus the sUSDS ERC-4626 vault.
     */
    function _deploySky() internal {
        if (_reuse("SkyV1Protocol", "SKY_V1_PROTOCOL") != address(0)) return;
        _record(
            "SkyV1Protocol",
            "SKY_V1_PROTOCOL",
            address(
                new SkyV1Protocol(getAddress("USDC"), getAddress("USDS"), getAddress("S_USDS"), getAddress("SKY_PSM"))
            )
        );
    }

    /**
     * @dev Evm's Sky: one PSM3 module. Evm's sUSDS is a plain ERC-20 with no vault to deposit
     *     into, so the evm adapter cannot serve it — see {SkyV1EvmProtocol}.
     */
    function _deploySkyEvm() internal {
        if (_reuse("SkyV1EvmProtocol", "SKY_V1_PROTOCOL") != address(0)) return;
        _record(
            "SkyV1EvmProtocol",
            "SKY_V1_PROTOCOL",
            address(new SkyV1EvmProtocol(getAddress("USDC"), getAddress("S_USDS"), getAddress("SKY_PSM3")))
        );
    }
}
