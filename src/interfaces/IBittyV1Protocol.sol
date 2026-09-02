// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

error InvalidAsset();

/**
 * @title IBittyV1Protocol
 * @notice Interface for all protocols.
 * @dev A protocol does NOT declare its own category. The guard defines it, and consumers read it
 *      back from {IBittyV1Guard-protocolCategory}. Curation and classification are therefore the
 *      same act, by the same party, which is why an adapter is never asked to describe itself: a
 *      self-declared category would be one more thing to verify without being the one that counts.
 */
interface IBittyV1Protocol {
    /**
     * @notice Initialize the protocol.
     * @param newOwner The address of the new owner.
     * @dev Initialize the protocol.
     */
    function initialize(address newOwner) external;

    /**
     * @notice The code lineage this adapter belongs to - which protocol it adapts, not which kind of
     *         protocol it is.
     * @dev Guards in-place upgrades. The guard's category is curation and is deliberately coarse:
     *      Aave and Sky are both lending, and their storage layouts are identical, so repointing an
     *      Aave instance at the Sky adapter passes every category check and then silently reads
     *      Aave's cached aToken addresses as Sky's receipt tokens. Nothing reverts, because the
     *      layouts agree and only the meaning changed. An upgrade is therefore refused unless both
     *      sides report the same lineage.
     * @dev Self-declared, unlike the category, and the difference is the point: the category decides
     *      WHETHER an adapter may be used at all and so belongs to whoever curates the registry,
     *      while lineage only answers whether two adapters the guard has ALREADY blessed are the
     *      same code line. A dishonest answer requires the guard to have blessed a dishonest
     *      adapter, so the guard remains the trust root either way.
     * @return The lineage identifier, e.g. keccak256("bitty.adapter.aave.v3").
     */
    function protocolLineage() external view returns (bytes32);

    /**
     * @notice This adapter's version within its {protocolLineage}, increasing with each release.
     * @dev Upgrades are one-way: an instance may only be repointed at a STRICTLY higher version of
     *      its own lineage. Without this, every check still passes when repointing an instance back
     *      at the older adapter it was upgraded away from - so a fixed bug could be silently
     *      reintroduced, and the whole point of patching in place lost. Strictness also rejects
     *      repointing an instance at the version it already runs, which is only ever a wasted
     *      transaction.
     * @dev A number rather than the free-form string this interface used to carry, because the vault
     *      has to ORDER two of these on chain and a string cannot be compared without parsing it.
     *      Semver is encoded as major * 1e6 + minor * 1e3 + patch, which keeps the ordering the
     *      comparison needs while still naming a release a human recognises: 1.0.0 is 1_000_000 and
     *      1.1.2 is 1_001_002. Minor and patch are therefore capped at 999.
     * @return The encoded version. See {versionName} for the readable form.
     */
    function protocolVersion() external view returns (uint256);

    /**
     * @notice The human-readable version, e.g. "1.1.2". For display.
     * @dev DERIVED from {protocolVersion} rather than declared alongside it. Two independently
     *      written fields would eventually disagree - someone bumps the number the vault compares
     *      and forgets the string the UI shows - and the disagreement would surface as a version
     *      that upgrades correctly while displaying the wrong release, which is worse than either
     *      being wrong on its own.
     * @return The version as "major.minor.patch".
     */
    function versionName() external view returns (string memory);
}
