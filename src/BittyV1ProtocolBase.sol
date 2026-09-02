// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1Protocol} from "./interfaces/IBittyV1Protocol.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";

/**
 * @title BittyV1ProtocolBase
 * @notice Shared base for protocol adapters: owner-controlled UUPS upgrades, mirroring the vault's own
 *         upgrade model. An adapter bug is therefore patchable in place, without abandoning the adapter
 *         instance or the pending state it holds (Lido's unstake request ids are the case that cannot
 *         simply be re-created on a fresh instance).
 *
 *         An adapter instance is an ERC-1967 proxy owned by the vault that deployed it, so `onlyOwner`
 *         here means "only that vault". The vault gates the call on its own owner AND on the guard's
 *         implementation registry, which is why this contract does not consult the guard itself: the
 *         curation boundary stays in one place, and adapters keep no dependency on guard-contracts.
 *
 *         UUPSUpgradeable declares no storage of its own (only an immutable, which lives in code), so
 *         inheriting it leaves every adapter's existing slot layout untouched.
 */
abstract contract BittyV1ProtocolBase is IBittyV1Protocol, Ownable, Initializable, UUPSUpgradeable {
    constructor() Ownable(msg.sender) {
        _disableInitializers();
    }

    function initialize(address newOwner) external override initializer {
        _transferOwnership(newOwner);
    }

    function _authorizeUpgrade(address) internal view override {
        _checkOwner();
    }

    function versionName() external view override returns (string memory) {
        uint256 v = this.protocolVersion();
        return string.concat(
            Strings.toString(v / 1_000_000),
            ".",
            Strings.toString((v / 1_000) % 1_000),
            ".",
            Strings.toString(v % 1_000)
        );
    }
}
