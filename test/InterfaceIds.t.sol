// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {IBittyV1LendingProtocol} from "../src/interfaces/IBittyV1LendingProtocol.sol";
import {IBittyV1StakingProtocol} from "../src/interfaces/IBittyV1StakingProtocol.sol";
import {IBittyV1AMMProtocol} from "../src/interfaces/IBittyV1AMMProtocol.sol";
import {IBittyV1IntentProtocol} from "../src/interfaces/IBittyV1IntentProtocol.sol";

/**
 * @notice Pins the four category interface ids.
 * @dev These are CONSENSUS values across three repos: the guard verifies one at registration and the
 *      vault checks one on every protocol call, both against already-deployed protocol adapters.
 *      An interface id is the XOR of its function selectors, so adding, removing or re-signing a
 *      single function silently changes it — and every deployed adapter would then answer `false` to
 *      the new id, disabling that whole category rather than failing loudly at compile time.
 *
 *      So this test is not tautological. It exists to turn "the id moved" from a silent production
 *      break into a build failure, forcing whoever changed the interface to plan the redeploy of
 *      every adapter in that category alongside it.
 */
contract InterfaceIdsTest is Test {
    function test_lendingIdIsPinned() public pure {
        assertEq(type(IBittyV1LendingProtocol).interfaceId, bytes4(0xb9f16a0c));
    }

    function test_stakingIdIsPinned() public pure {
        assertEq(type(IBittyV1StakingProtocol).interfaceId, bytes4(0xc8ada217));
    }

    function test_ammIdIsPinned() public pure {
        assertEq(type(IBittyV1AMMProtocol).interfaceId, bytes4(0x932722bd));
    }

    /**
     * @dev Deliberately equal to the ERC-1271 magic value: {IBittyV1IntentProtocol} declares only
     *      `isValidSignature`, so its id IS that selector. Being an intent protocol and being an
     *      ERC-1271 signer are the same claim here, which is why the collision is intended rather
     *      than a hazard — and the guard, not this id, is what decides who may be used at all.
     */
    function test_intentIdIsPinnedToTheErc1271MagicValue() public pure {
        assertEq(type(IBittyV1IntentProtocol).interfaceId, bytes4(0x1626ba7e));
    }

    /// @dev The vault picks a category by id, so two categories sharing one would route calls wrong.
    function test_idsAreDistinct() public pure {
        bytes4[4] memory ids = [
            type(IBittyV1LendingProtocol).interfaceId,
            type(IBittyV1StakingProtocol).interfaceId,
            type(IBittyV1AMMProtocol).interfaceId,
            type(IBittyV1IntentProtocol).interfaceId
        ];
        for (uint256 i = 0; i < ids.length; i++) {
            for (uint256 j = i + 1; j < ids.length; j++) {
                assertTrue(ids[i] != ids[j], "category interface ids collide");
            }
        }
    }
}
