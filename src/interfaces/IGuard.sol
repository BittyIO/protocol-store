// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

interface IGuard {
    function isStableCoinRegistered(address stableCoinAddress) external view returns (bool);
}
