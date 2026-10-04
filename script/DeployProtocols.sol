// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {console2} from "forge-std/console2.sol";
import {AaveV3Protocol} from "../src/protocols/AaveV3Protocol.sol";
import {UniswapUniversalTradeProtocol} from "../src/protocols/UniswapUniversalTradeProtocol.sol";
import {UniswapV3MarketMakerProtocol} from "../src/protocols/UniswapV3MarketMakerProtocol.sol";
import {LidoV2Protocol} from "../src/protocols/LidoV2Protocol.sol";
import {SkyV1Protocol} from "../src/protocols/SkyV1Protocol.sol";
import {SkyV1EvmProtocol} from "../src/protocols/SkyV1EvmProtocol.sol";
import {CoWSwapV1Protocol} from "../src/protocols/cowswap/CoWSwapV1Protocol.sol";
import {DeployScript} from "./BaseDeploy.sol";
import {IBittyV1Protocol} from "../src/interfaces/IBittyV1Protocol.sol";

/**
 * @title DeployProtocols
 * @notice One adapter-deploying step per protocol, shared by the per-chain scripts.
 *
 * @dev The chain scripts differ only in WHICH adapters they call, because no chain supports all of
 *      them: Lido staking is Ethereum-only, Sepolia has no Sky, and Sky on Base is a different
 *      contract from Sky on mainnet. Keeping the steps here means that list is the only thing a
 *      chain script states, and the reuse rule below cannot drift between chains.
 *
 *      Every step is RE-RUNNABLE: an adapter is skipped when the chain TOML already names one whose
 *      on-chain protocolVersion() equals the current source's. Beyond saving gas, that matters
 *      because a fresh adapter address has to be registered in the guard and the old one deprecated —
 *      so a partial run should be repeatable rather than force a full redeploy.
 *
 *      Reuse is decided by the adapter's declared VERSION, not mere presence and not raw bytecode
 *      (see {_reuse}): only a version bump — the same signal upgradeProtocol uses — forces a redeploy
 *      of that adapter alone, while same-version adapters are left in place even though a newer
 *      compiler makes their on-chain bytecode differ from a fresh build.
 */
abstract contract DeployProtocols is DeployScript {
    /**
     * @dev The protocolVersion() a fresh deploy of `initCode` declares — read from a throwaway
     *      reference built OUTSIDE the broadcast, so it is never sent as a transaction. (The adapter
     *      constructors only store immutables, so constructing one is side-effect free.)
     */
    function _referenceVersion(bytes memory initCode) private returns (uint256 v) {
        vm.stopBroadcast();
        address ref;
        assembly {
            ref := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(ref != address(0), "reference construction failed");
        v = IBittyV1Protocol(ref).protocolVersion();
        vm.startBroadcast();
    }

    function _reuse(string memory name, string memory key, bytes memory initCode) private returns (address) {
        address recorded = getAddressOr(key, address(0));
        if (recorded.code.length == 0) return address(0);
        uint256 want = _referenceVersion(initCode);
        try IBittyV1Protocol(recorded).protocolVersion() returns (uint256 have) {
            if (have == want) {
                console2.log(string.concat(name, " unchanged (version reused) at"), recorded);
                saveAddress(key, recorded);
                return recorded;
            }
            console2.log(string.concat(name, " version bumped; redeploying (was)"), recorded);
        } catch {
            console2.log(string.concat(name, " unreadable version; redeploying (was)"), recorded);
        }
        return address(0);
    }

    function _record(string memory name, string memory key, address deployed) private {
        console2.log(string.concat(name, " deployed at"), deployed);
        saveAddress(key, deployed);
    }

    function _deployAave() internal {
        address aaveV3 = getAddress("AAVE_V3");
        address dataProvider = getAddress("POOL_DATA_PROVIDER");
        bytes memory initCode = abi.encodePacked(type(AaveV3Protocol).creationCode, abi.encode(aaveV3, dataProvider));
        if (_reuse("AaveV3Protocol", "AAVE_V3_PROTOCOL", initCode) != address(0)) return;
        _record("AaveV3Protocol", "AAVE_V3_PROTOCOL", address(new AaveV3Protocol(aaveV3, dataProvider)));
    }

    function _deployUniswapUniversal() internal {
        address guard = getAddress("BITTY_GUARD");
        address universal = getAddress("UNISWAP_UNIVERSAL_ROUTER");
        address permit2 = getAddress("PERMIT2");
        bytes memory initCode = abi.encodePacked(
            type(UniswapUniversalTradeProtocol).creationCode, abi.encode(universal, permit2, guard)
        );
        if (_reuse("UniswapUniversalTradeProtocol", "UNISWAP_TRADE_PROTOCOL", initCode) != address(0)) return;
        _record(
            "UniswapUniversalTradeProtocol",
            "UNISWAP_TRADE_PROTOCOL",
            address(new UniswapUniversalTradeProtocol(universal, permit2, guard))
        );
    }

    function _deployUniswapV3Maker() internal {
        address npm = getAddress("UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER");
        bytes memory initCode = abi.encodePacked(type(UniswapV3MarketMakerProtocol).creationCode, abi.encode(npm));
        if (_reuse("UniswapV3MarketMakerProtocol", "UNISWAP_V3_MAKER_PROTOCOL", initCode) != address(0)) return;
        _record(
            "UniswapV3MarketMakerProtocol",
            "UNISWAP_V3_MAKER_PROTOCOL",
            address(new UniswapV3MarketMakerProtocol(npm))
        );
    }

    function _deployCoWSwap() internal {
        address settlement = getAddress("COW_SETTLEMENT");
        address relayer = getAddress("COW_VAULT_RELAYER");
        bytes memory initCode = abi.encodePacked(type(CoWSwapV1Protocol).creationCode, abi.encode(settlement, relayer));
        if (_reuse("CoWSwapV1Protocol", "COW_SWAP_V1_PROTOCOL", initCode) != address(0)) return;
        _record("CoWSwapV1Protocol", "COW_SWAP_V1_PROTOCOL", address(new CoWSwapV1Protocol(settlement, relayer)));
    }

    function _deployLido() internal {
        address steth = getAddress("STETH");
        address unsteth = getAddress("UNSTETH");
        address weth = getAddress("WETH");
        bytes memory initCode = abi.encodePacked(type(LidoV2Protocol).creationCode, abi.encode(steth, unsteth, weth));
        if (_reuse("LidoV2Protocol", "LIDO_V2_PROTOCOL", initCode) != address(0)) return;
        _record("LidoV2Protocol", "LIDO_V2_PROTOCOL", address(new LidoV2Protocol(steth, unsteth, weth)));
    }

    /**
     * @dev Mainnet's Sky: PSM (sellGem/buyGem) plus the sUSDS ERC-4626 vault.
     */
    function _deploySky() internal {
        address usdc = getAddress("USDC");
        address usds = getAddress("USDS");
        address susds = getAddress("S_USDS");
        address psm = getAddress("SKY_PSM");
        bytes memory initCode = abi.encodePacked(type(SkyV1Protocol).creationCode, abi.encode(usdc, usds, susds, psm));
        if (_reuse("SkyV1Protocol", "SKY_V1_PROTOCOL", initCode) != address(0)) return;
        _record("SkyV1Protocol", "SKY_V1_PROTOCOL", address(new SkyV1Protocol(usdc, usds, susds, psm)));
    }

    /**
     * @dev Evm's Sky: one PSM3 module. Evm's sUSDS is a plain ERC-20 with no vault to deposit
     *     into, so the evm adapter cannot serve it — see {SkyV1EvmProtocol}.
     */
    function _deploySkyEvm() internal {
        address usdc = getAddress("USDC");
        address susds = getAddress("S_USDS");
        address psm3 = getAddress("SKY_PSM3");
        bytes memory initCode = abi.encodePacked(type(SkyV1EvmProtocol).creationCode, abi.encode(usdc, susds, psm3));
        if (_reuse("SkyV1EvmProtocol", "SKY_V1_PROTOCOL", initCode) != address(0)) return;
        _record("SkyV1EvmProtocol", "SKY_V1_PROTOCOL", address(new SkyV1EvmProtocol(usdc, susds, psm3)));
    }
}
