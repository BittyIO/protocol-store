// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

error AMMProtocolShouldNotBeAllRemoved();
error NotRegistered();
error Deprecated();

/**
 * @title Manage the registered assets and protocols (v1).
 * @dev Manage the registered assets and protocols by Bitty.
 */
interface IBittyV1Guard {
    /**
     * @notice Add a registered asset to Bitty.
     * @dev Add a registered asset to Bitty.
     * @param assetAddresses The addresses of the assets.
     */
    function addAssets(address[] memory assetAddresses) external;

    /**
     * @notice Remove a registered asset from Bitty.
     * @dev Remove a registered asset from Bitty.
     *      A removed asset can only be sold instead of being bought.
     * @param assetAddresses The addresses of the assets.
     */
    function removeAssets(address[] memory assetAddresses) external;

    /**
     * @notice Check if an asset is registered.
     * @dev Check if an asset is registered.
     * @param assetAddress The address of the asset.
     * @return bool True if the asset is registered, false otherwise.
     */
    function isAssetRegistered(address assetAddress) external view returns (bool);

    /**
     * @notice Add a stable coin to Bitty.
     * @dev Add a stable coin to Bitty.
     * @param stableCoinAddresses The addresses of the stable coins.
     */
    function addStableCoins(address[] memory stableCoinAddresses) external;

    /**
     * @notice Remove a stable coin from Bitty.
     * @dev Remove a stable coin from Bitty.
     *      A removed stable coin can only be sold, can not be bought anymore.
     * @param stableCoinAddresses The addresses of the stable coins.
     */
    function removeStableCoins(address[] memory stableCoinAddresses) external;

    /**
     * @notice Check if a stable coin is registered.
     * @dev Check if a stable coin is registered.
     * @param stableCoinAddress The address of the stable coin.
     * @return bool True if the stable coin is registered, false otherwise.
     */
    function isStableCoinRegistered(address stableCoinAddress) external view returns (bool);

    /**
     * @notice Add a yield protocol to Bitty.
     * @dev Add a yield protocol to Bitty.
     * @param lendingProtocolAddresses The addresses of the yield protocols.
     */
    function addLendingProtocols(address[] memory lendingProtocolAddresses) external;

    /**
     * @notice Deprecate a yield protocol from Bitty.
     * @dev Deprecate a yield protocol from Bitty.
     *      A deprecated yield protocol is only used for withdrawals, can not supply to it anymore.
     * @param lendingProtocolAddresses The addresses of the yield protocols.
     */
    function deprecateLendingProtocols(address[] memory lendingProtocolAddresses) external;

    /**
     * @notice Check if a yield protocol is registered.
     * @dev Check if a yield protocol is registered.
     * @param lendingProtocolAddress The address of the yield protocol.
     * @return bool True if the yield protocol is registered, false otherwise.
     */
    function isLendingProtocolRegistered(address lendingProtocolAddress) external view returns (bool);

    /**
     * @notice Check if a yield protocol is deprecated.
     * @dev Check if a yield protocol is deprecated.
     * @param lendingProtocolAddress The address of the yield protocol.
     * @return bool True if the yield protocol is deprecated, false otherwise.
     */
    function isLendingProtocolDeprecated(address lendingProtocolAddress) external view returns (bool);

    /**
     * @notice Add a staking protocol to Bitty.
     * @dev Add a staking protocol to Bitty.
     * @param stakingProtocols the addresses of the staking protocols.
     */
    function addStakingProtocols(address[] memory stakingProtocols) external;

    /**
     * @notice Check if a staking protocol is registered.
     * @dev Check if a staking protocol is registered.
     * @param stakingProtocol The address of the staking protocol.
     * @return bool True if the staking protocol is registered, false otherwise.
     */
    function isStakingProtocolRegistered(address stakingProtocol) external view returns (bool);

    /**
     * @notice Deprecate a staking protocol from Bitty.
     * @dev Deprecate a staking protocol from Bitty.
     *      A deprecated staking protocol is only used for withdrawals, can not supply to it anymore.
     * @param stakingProtocols The addresses of the staking protocols.
     */
    function deprecateStakingProtocols(address[] memory stakingProtocols) external;

    /**
     * @notice Check if a staking protocol is deprecated.
     * @dev Check if a staking protocol is deprecated.
     * @param stakingProtocolAddress The address of the staking protocol.
     * @return bool True if the staking protocol is deprecated, false otherwise.
     */
    function isStakingProtocolDeprecated(address stakingProtocolAddress) external view returns (bool);

    /**
     * @notice Add an intent protocol to Bitty.
     * @dev Add an intent protocol to Bitty.
     * @param intentProtocolAddresses The addresses of the intent protocols.
     */
    function addIntentProtocols(address[] memory intentProtocolAddresses) external;

    /**
     * @notice Check if an intent protocol is registered.
     * @dev Check if an intent protocol is registered.
     * @param intentProtocolAddress The address of the intent protocol.
     * @return bool True if the intent protocol is registered, false otherwise.
     */
    function isIntentProtocolRegistered(address intentProtocolAddress) external view returns (bool);

    /**
     * @notice Deprecate an intent protocol from Bitty.
     * @dev Deprecate an intent protocol from Bitty.
     *      A deprecated intent protocol is only used for canceling trades, can not be used for executing trades anymore.
     * @param intentProtocolAddresses The addresses of the intent protocols.
     */
    function deprecateIntentProtocols(address[] memory intentProtocolAddresses) external;

    /**
     * @notice Check if an intent protocol is deprecated.
     * @dev Check if an intent protocol is deprecated.
     * @param intentProtocolAddress The address of the intent protocol.
     * @return bool True if the intent protocol is deprecated, false otherwise.
     */
    function isIntentProtocolDeprecated(address intentProtocolAddress) external view returns (bool);

    /**
     * @notice Add a swap protocol to Bitty.
     * @dev Add a swap protocol to Bitty.
     * @param ammProtocolAddresses The addresses of the swap protocols.
     */
    function addAMMProtocols(address[] memory ammProtocolAddresses) external;

    /**
     * @notice Remove a swap protocol from Bitty.
     * @dev Remove a swap protocol from Bitty.
     * @param ammProtocolAddresses The addresses of the swap protocols.
     */
    function removeAMMProtocols(address[] memory ammProtocolAddresses) external;

    /**
     * @notice Check if a swap protocol is registered.
     * @dev Check if a swap protocol is registered.
     * @param ammProtocolAddress The address of the swap protocol.
     * @return bool True if the swap protocol is registered, false otherwise.
     */
    function isAMMProtocolRegistered(address ammProtocolAddress) external view returns (bool);

    /**
     * @notice Get the registered assets.
     * @dev Get the registered assets.
     * @return addresses The addresses of the registered assets.
     */
    function getAssets() external view returns (address[] memory addresses);

    /**
     * @notice Get the registered stable coins.
     * @dev Get the registered stable coins.
     * @return addresses The addresses of the stable coins.
     */
    function getStableCoins() external view returns (address[] memory addresses);

    /**
     * @notice Get the registered AMM protocols.
     * @dev Get the registered AMM protocols.
     * @return addresses The addresses of the registered AMM protocols.
     */
    function getAMMProtocols() external view returns (address[] memory addresses);

    /**
     * @notice Get the registered lending protocols.
     * @dev Get the registered lending protocols.
     * @return addresses The addresses of the registered lending protocols.
     */
    function getLendingProtocols() external view returns (address[] memory addresses);

    /**
     * @notice Get the registered staking protocols.
     * @dev Get the registered staking protocols.
     * @return addresses The addresses of the registered staking protocols.
     */
    function getStakingProtocols() external view returns (address[] memory addresses);

    /**
     * @notice Get the registered intent protocols.
     * @dev Get the registered intent protocols.
     * @return addresses The addresses of the registered intent protocols.
     */
    function getIntentProtocols() external view returns (address[] memory addresses);
}
