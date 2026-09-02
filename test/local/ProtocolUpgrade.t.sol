// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {BittyV1ProtocolBase} from "../../src/BittyV1ProtocolBase.sol";
import {AaveV3Protocol} from "../../src/protocols/AaveV3Protocol.sol";
import {LidoV2Protocol} from "../../src/protocols/LidoV2Protocol.sol";
import {SkyV1Protocol} from "../../src/protocols/SkyV1Protocol.sol";
import {SkyV1EvmProtocol} from "../../src/protocols/SkyV1EvmProtocol.sol";
import {UniswapV3Protocol} from "../../src/protocols/UniswapV3Protocol.sol";
import {CoWSwapV1Protocol} from "../../src/protocols/cowswap/CoWSwapV1Protocol.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

/// SkyV1EvmProtocol's constructor cross-checks its PSM's assets, so the lineage test needs one.
contract MockPsm3 {
    address public usdc;
    address public susds;

    constructor(address usdc_, address susds_) {
        usdc = usdc_;
        susds = susds_;
    }
}

contract AdapterV1 is BittyV1ProtocolBase {
    mapping(address => address) public receiptTokenOf;

    function protocolLineage() external pure override returns (bytes32) {
        return keccak256("bitty.adapter.test");
    }

    function setReceiptToken(address asset, address receipt) external {
        receiptTokenOf[asset] = receipt;
    }

    function protocolVersion() external pure virtual override returns (uint256) {
        return 1_000_000;
    }
}

contract AdapterV2 is AdapterV1 {
    function protocolVersion() external pure override returns (uint256) {
        return 1_001_002;
    }
}

contract ProtocolUpgradeTest is Test {
    address vault = makeAddr("vault");
    address stranger = makeAddr("stranger");

    AdapterV1 v1 = new AdapterV1();
    AdapterV2 v2 = new AdapterV2();
    AdapterV1 adapter;

    function setUp() public {
        adapter =
            AdapterV1(address(new ERC1967Proxy(address(v1), abi.encodeCall(BittyV1ProtocolBase.initialize, (vault)))));
    }

    function test_ownerUpgradesAndKeepsState() public {
        adapter.setReceiptToken(address(1), address(2));
        assertEq(adapter.versionName(), "1.0.0");

        vm.prank(vault);
        UUPSUpgradeable(address(adapter)).upgradeToAndCall(address(v2), "");

        assertEq(adapter.versionName(), "1.1.2");
        assertEq(adapter.receiptTokenOf(address(1)), address(2), "state lost across upgrade");
        assertEq(adapter.owner(), vault, "owner lost across upgrade");
    }

    function test_addressIsStableAcrossUpgrade() public {
        address before = address(adapter);
        vm.prank(vault);
        UUPSUpgradeable(address(adapter)).upgradeToAndCall(address(v2), "");
        assertEq(address(adapter), before);
    }

    function test_nonOwnerCannotUpgrade() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        UUPSUpgradeable(address(adapter)).upgradeToAndCall(address(v2), "");
    }

    function test_implementationCannotBeInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        v1.initialize(stranger);
    }

    function test_realAdapterInitializesBehindProxy() public {
        AaveV3Protocol impl = new AaveV3Protocol(address(0xA1), address(0xA2));
        AaveV3Protocol proxied = AaveV3Protocol(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(BittyV1ProtocolBase.initialize, (vault))))
        );
        assertEq(proxied.owner(), vault);
        assertEq(proxied.aaveV3(), address(0xA1), "immutables must resolve through delegatecall");
    }

    /**
     * Lineage only guards upgrades if no two adapters share one. A copy-pasted constant would let an
     * Aave instance be repointed at Sky - the exact swap the check exists to refuse - while every
     * other check still passed, so the collision must fail here rather than in production.
     */
    function test_everyAdapterHasADistinctLineage() public {
        bytes32[6] memory lineages = [
            new AaveV3Protocol(address(1), address(2)).protocolLineage(),
            new LidoV2Protocol(address(1), address(2), address(3)).protocolLineage(),
            new SkyV1Protocol(address(1), address(2), address(3), address(4)).protocolLineage(),
            new SkyV1EvmProtocol(address(1), address(2), address(new MockPsm3(address(1), address(2))))
                .protocolLineage(),
            new UniswapV3Protocol(address(1)).protocolLineage(),
            new CoWSwapV1Protocol(address(1), address(2)).protocolLineage()
        ];
        for (uint256 i; i < lineages.length; i++) {
            assertTrue(lineages[i] != bytes32(0), "lineage unset");
            for (uint256 j = i + 1; j < lineages.length; j++) {
                assertTrue(lineages[i] != lineages[j], "two adapters share a lineage");
            }
        }
    }

    /// Every shipped adapter must report a real version, or the vault cannot order two of them.
    function test_everyAdapterReportsAVersion() public {
        assertGe(new AaveV3Protocol(address(1), address(2)).protocolVersion(), 1);
        assertGe(new LidoV2Protocol(address(1), address(2), address(3)).protocolVersion(), 1);
        assertGe(new SkyV1Protocol(address(1), address(2), address(3), address(4)).protocolVersion(), 1);
        assertGe(
            new SkyV1EvmProtocol(address(1), address(2), address(new MockPsm3(address(1), address(2))))
                .protocolVersion(),
            1
        );
        assertGe(new UniswapV3Protocol(address(1)).protocolVersion(), 1);
        assertGe(new CoWSwapV1Protocol(address(1), address(2)).protocolVersion(), 1);
    }

    /// The readable name is derived from the number, so the two can never disagree.
    function test_versionNameMatchesTheEncodedNumber() public {
        assertEq(new AaveV3Protocol(address(1), address(2)).versionName(), "1.0.0");
        assertEq(AdapterV1(address(adapter)).versionName(), "1.0.0");
        AdapterV2 v = new AdapterV2();
        assertEq(v.protocolVersion(), 1_001_002);
        assertEq(v.versionName(), "1.1.2", "encoding and display disagree");
    }
}
