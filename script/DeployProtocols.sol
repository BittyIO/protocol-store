// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {console2} from "forge-std/console2.sol";
import {AaveV3Protocol} from "../src/protocols/AaveV3Protocol.sol";
import {UniswapUniversalTradeProtocol} from "../src/protocols/UniswapUniversalTradeProtocol.sol";
import {LidoV2Protocol} from "../src/protocols/LidoV2Protocol.sol";
import {SkyV1Protocol} from "../src/protocols/SkyV1Protocol.sol";
import {SkyV1EvmProtocol} from "../src/protocols/SkyV1EvmProtocol.sol";
import {CoWSwapV1Protocol} from "../src/protocols/cowswap/CoWSwapV1Protocol.sol";
import {DeployScript} from "./BaseDeploy.sol";
import {IBittyV1Protocol} from "../src/interfaces/IBittyV1Protocol.sol";

/// The guard's protocol registry, as far as a deploy needs it. Declared here because the guard
/// interface this repo carries is the read-only slice the adapters use.
interface IGuardProtocolRegistry {
    function PROTOCOL_MANAGER_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function isProtocolRegistered(address protocolAddress) external view returns (bool);
    function addProtocols(address[] memory protocolAddresses, uint8[] memory categories) external;
    function deprecateProtocols(address[] memory protocolAddresses) external;
}

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
 *
 *      A redeploy that moves an adapter to a HIGHER version is then put in the guard in its place: the
 *      new address added under its category, the old one deprecated (see {_register}), so vaults can
 *      `upgradeProtocol` onto it and no new vault clones the old one. A first deploy is only added.
 */
abstract contract DeployProtocols is DeployScript {
    uint8 internal constant PROTOCOL_STAKING = 1;
    uint8 internal constant PROTOCOL_LENDING = 2;
    uint8 internal constant PROTOCOL_MARKET_TRADE = 3;
    uint8 internal constant PROTOCOL_INTENT = 4;

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

    /**
     * @return kept The recorded adapter when its version is current (then nothing is deployed).
     * @return replaced The recorded adapter a redeploy supersedes, when the new version is higher.
     * @return register Whether the redeploy goes into the guard: on a first deploy, or a higher version.
     */
    function _reuse(string memory name, string memory key, bytes memory initCode)
        private
        returns (address kept, address replaced, bool register)
    {
        address recorded = getAddressOr(key, address(0));
        if (recorded.code.length == 0) return (address(0), address(0), true);
        uint256 want = _referenceVersion(initCode);
        try IBittyV1Protocol(recorded).protocolVersion() returns (uint256 have) {
            if (have == want) {
                console2.log(string.concat(name, " unchanged (version reused) at"), recorded);
                saveAddress(key, recorded);
                return (recorded, address(0), false);
            }
            if (want > have) {
                console2.log(string.concat(name, " version bumped; redeploying (was)"), recorded);
                return (address(0), recorded, true);
            }
            console2.log(string.concat(name, " version is not higher; redeploying, guard left as is (was)"), recorded);
        } catch {
            console2.log(string.concat(name, " unreadable version; redeploying, guard left as is (was)"), recorded);
        }
        return (address(0), address(0), false);
    }

    /**
     * @dev Add `deployed` to the guard under `category`, then deprecate `replaced` — adding first, so the
     *      lineage is never without a registered adapter, and deprecating rather than removing, so vaults
     *      still on the old one keep working. Sent from the broadcasting key when it holds the guard's
     *      PROTOCOL_MANAGER_ROLE; otherwise printed for whoever does to submit.
     */
    function _register(address replaced, address deployed, uint8 category) private {
        IGuardProtocolRegistry guard = IGuardProtocolRegistry(getAddress("BITTY_GUARD"));
        address[] memory added = new address[](1);
        added[0] = deployed;
        uint8[] memory categories = new uint8[](1);
        categories[0] = category;
        address[] memory old = new address[](1);
        old[0] = replaced;
        bool deprecate = replaced != address(0) && guard.isProtocolRegistered(replaced);

        if (guard.hasRole(guard.PROTOCOL_MANAGER_ROLE(), tx.origin)) {
            guard.addProtocols(added, categories);
            console2.log("  guard: added", deployed);
            if (deprecate) {
                guard.deprecateProtocols(old);
                console2.log("  guard: deprecated", replaced);
            }
            return;
        }
        console2.log("  ACTION REQUIRED - the guard's PROTOCOL_MANAGER_ROLE holder must submit, to", address(guard));
        console2.logBytes(abi.encodeCall(IGuardProtocolRegistry.addProtocols, (added, categories)));
        if (deprecate) console2.logBytes(abi.encodeCall(IGuardProtocolRegistry.deprecateProtocols, (old)));
    }

    function _record(string memory name, string memory key, address deployed) private {
        console2.log(string.concat(name, " deployed at"), deployed);
        saveAddress(key, deployed);
    }

    function _deployAave() internal {
        address aaveV3 = getAddress("AAVE_V3");
        address dataProvider = getAddress("POOL_DATA_PROVIDER");
        bytes memory initCode = abi.encodePacked(type(AaveV3Protocol).creationCode, abi.encode(aaveV3, dataProvider));
        (address kept, address replaced, bool register) = _reuse("AaveV3Protocol", "AAVE_V3_PROTOCOL", initCode);
        if (kept != address(0)) return;
        address deployed = address(new AaveV3Protocol(aaveV3, dataProvider));
        _record("AaveV3Protocol", "AAVE_V3_PROTOCOL", deployed);
        if (register) _register(replaced, deployed, PROTOCOL_LENDING);
    }

    function _deployUniswapUniversal() internal {
        address guard = getAddress("BITTY_GUARD");
        address universal = getAddress("UNISWAP_UNIVERSAL_ROUTER");
        address permit2 = getAddress("PERMIT2");
        bytes memory initCode =
            abi.encodePacked(type(UniswapUniversalTradeProtocol).creationCode, abi.encode(universal, permit2, guard));
        (address kept, address replaced, bool register) =
            _reuse("UniswapUniversalTradeProtocol", "UNISWAP_TRADE_PROTOCOL", initCode);
        if (kept != address(0)) return;
        address deployed = address(new UniswapUniversalTradeProtocol(universal, permit2, guard));
        _record("UniswapUniversalTradeProtocol", "UNISWAP_TRADE_PROTOCOL", deployed);
        if (register) _register(replaced, deployed, PROTOCOL_MARKET_TRADE);
    }

    function _deployCoWSwap() internal {
        address settlement = getAddress("COW_SETTLEMENT");
        address relayer = getAddress("COW_VAULT_RELAYER");
        bytes memory initCode = abi.encodePacked(type(CoWSwapV1Protocol).creationCode, abi.encode(settlement, relayer));
        (address kept, address replaced, bool register) = _reuse("CoWSwapV1Protocol", "COW_SWAP_V1_PROTOCOL", initCode);
        if (kept != address(0)) return;
        address deployed = address(new CoWSwapV1Protocol(settlement, relayer));
        _record("CoWSwapV1Protocol", "COW_SWAP_V1_PROTOCOL", deployed);
        if (register) _register(replaced, deployed, PROTOCOL_INTENT);
    }

    function _deployLido() internal {
        address steth = getAddress("STETH");
        address unsteth = getAddress("UNSTETH");
        address weth = getAddress("WETH");
        bytes memory initCode = abi.encodePacked(type(LidoV2Protocol).creationCode, abi.encode(steth, unsteth, weth));
        (address kept, address replaced, bool register) = _reuse("LidoV2Protocol", "LIDO_V2_PROTOCOL", initCode);
        if (kept != address(0)) return;
        address deployed = address(new LidoV2Protocol(steth, unsteth, weth));
        _record("LidoV2Protocol", "LIDO_V2_PROTOCOL", deployed);
        if (register) _register(replaced, deployed, PROTOCOL_STAKING);
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
        (address kept, address replaced, bool register) = _reuse("SkyV1Protocol", "SKY_V1_PROTOCOL", initCode);
        if (kept != address(0)) return;
        address deployed = address(new SkyV1Protocol(usdc, usds, susds, psm));
        _record("SkyV1Protocol", "SKY_V1_PROTOCOL", deployed);
        if (register) _register(replaced, deployed, PROTOCOL_STAKING);
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
        (address kept, address replaced, bool register) = _reuse("SkyV1EvmProtocol", "SKY_V1_PROTOCOL", initCode);
        if (kept != address(0)) return;
        address deployed = address(new SkyV1EvmProtocol(usdc, susds, psm3));
        _record("SkyV1EvmProtocol", "SKY_V1_PROTOCOL", deployed);
        if (register) _register(replaced, deployed, PROTOCOL_STAKING);
    }
}
