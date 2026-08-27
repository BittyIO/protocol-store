// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1Protocol} from "./IBittyV1Protocol.sol";
import {IBittyV1Depositable} from "./IBittyV1Depositable.sol";
import {IBittyV1Withdrawable} from "./IBittyV1Withdrawable.sol";

interface IBittyV1LendingProtocol is IBittyV1Protocol, IBittyV1Depositable, IBittyV1Withdrawable {
    /**
     * @notice Get the lending balance of the asset.
     * @dev Get the lending balance of the asset.
     * @param asset The address of the asset.
     * @return The lending balance of the asset.
     */
    function getSuppliedBalance(address asset) external view returns (uint256);
}
