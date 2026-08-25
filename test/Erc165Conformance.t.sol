// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC165Checker} from "openzeppelin-contracts/contracts/utils/introspection/ERC165Checker.sol";
import {AaveV3Protocol} from "../src/protocols/AaveV3Protocol.sol";
import {LidoV2Protocol} from "../src/protocols/LidoV2Protocol.sol";
import {SkyV1Protocol} from "../src/protocols/SkyV1Protocol.sol";
import {SkyV1BaseProtocol} from "../src/protocols/SkyV1BaseProtocol.sol";
import {UniswapV3Protocol} from "../src/protocols/UniswapV3Protocol.sol";
import {CoWSwapV1Protocol} from "../src/protocols/cowswap/CoWSwapV1Protocol.sol";

/**
 * @notice Every adapter answers the category the guard will register it under, through the exact
 *         probe the guard uses.
 * @dev {InterfaceIds} pins the ids; this checks the other half — that each deployed adapter actually
 *      CLAIMS its id, and claims it in a way {ERC165Checker} accepts. That checker is stricter than
 *      "supportsInterface returns true": it first requires true for 0x01ffc9a7 and FALSE for
 *      0xffffffff, and a contract failing either is treated as supporting nothing at all. An adapter
 *      could therefore declare the right id and still be unregisterable, which no id test would catch.
 *
 *      Constructors only store addresses, so dummies are enough — nothing here calls the protocols.
 */
contract Erc165ConformanceTest is Test {
    bytes4 internal constant LENDING_ID = 0xb9f16a0c;
    bytes4 internal constant STAKING_ID = 0xc8ada217;
    bytes4 internal constant AMM_ID = 0x932722bd;
    bytes4 internal constant INTENT_ID = 0x1626ba7e;
    bytes4 internal constant ERC165_ID = 0x01ffc9a7;
    bytes4 internal constant INVALID_ID = 0xffffffff;

    function _a(string memory n) internal returns (address) {
        return makeAddr(n);
    }

    function _check(address protocol, bytes4 own, bytes4[3] memory others) internal view {
        // What the guard actually calls.
        assertTrue(ERC165Checker.supportsInterface(protocol, own), "own category not accepted by ERC165Checker");
        // The two rules that make the checker answer at all.
        assertTrue(ERC165Checker.supportsInterface(protocol, ERC165_ID), "must declare ERC-165 itself");
        assertFalse(ERC165Checker.supportsInterface(protocol, INVALID_ID), "must reject 0xffffffff");
        // Exactly one category, or the guard refuses it as ambiguous.
        for (uint256 i; i < others.length; i++) {
            assertFalse(ERC165Checker.supportsInterface(protocol, others[i]), "claims a second category");
        }
    }

    function test_AaveV3IsLending() public {
        address p = address(new AaveV3Protocol(_a("pool"), _a("dataProvider")));
        _check(p, LENDING_ID, [STAKING_ID, AMM_ID, INTENT_ID]);
    }

    function test_LidoV2IsStaking() public {
        address p = address(new LidoV2Protocol(_a("stETH"), _a("unstETH"), _a("weth")));
        _check(p, STAKING_ID, [LENDING_ID, AMM_ID, INTENT_ID]);
    }

    function test_SkyV1IsStaking() public {
        address p = address(new SkyV1Protocol(_a("usdc"), _a("usds"), _a("sUsds"), _a("psm")));
        _check(p, STAKING_ID, [LENDING_ID, AMM_ID, INTENT_ID]);
    }

    /// @dev Constructed against a MOCKED module: this adapter asks the PSM to confirm its own assets
    ///      in the constructor, so unlike its siblings it cannot be built from placeholder addresses.
    function test_SkyV1BaseIsStaking() public {
        address usdc_ = _a("usdc");
        address sUsds_ = _a("sUsds");
        address psm_ = _a("psm3");
        vm.mockCall(psm_, abi.encodeWithSignature("usdc()"), abi.encode(usdc_));
        vm.mockCall(psm_, abi.encodeWithSignature("susds()"), abi.encode(sUsds_));
        address p = address(new SkyV1BaseProtocol(usdc_, sUsds_, psm_));
        _check(p, STAKING_ID, [LENDING_ID, AMM_ID, INTENT_ID]);
    }

    function test_UniswapV3IsAmm() public {
        address p = address(new UniswapV3Protocol(_a("positionManager")));
        _check(p, AMM_ID, [LENDING_ID, STAKING_ID, INTENT_ID]);
    }

    function test_CoWSwapV1IsIntent() public {
        address p = address(new CoWSwapV1Protocol(_a("settlement"), _a("vaultRelayer")));
        _check(p, INTENT_ID, [LENDING_ID, STAKING_ID, AMM_ID]);
    }
}
