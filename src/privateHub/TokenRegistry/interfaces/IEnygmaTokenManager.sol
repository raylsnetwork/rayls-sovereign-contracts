// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../../rayls-protocol-sdk/libraries/SharedObjects.sol";

/**
 * @title IEnygmaTokenManager
 * @dev Interface for the EnygmaTokenManager module that handles Enygma-specific functionality
 */
interface IEnygmaTokenManager {
    // ========== Enygma Token Management ==========

    /**
     * @notice Sets the Enygma factory address
     * @param _enygmaFactory The new Enygma factory address
     */
    function setEnygmaFactory(address _enygmaFactory) external;

    /**
     * @notice Gets the Enygma factory address
     * @return The Enygma factory address
     */
    function getEnygmaFactory() external view returns (address);

    // ========== Module Configuration ==========

    /**
     * @notice Sets the TokenRegistry address
     * @param _tokenRegistryAddress The TokenRegistry address
     */
    function setTokenRegistryAddress(address _tokenRegistryAddress) external;

    /**
     * @notice Sets the endpoint address
     * @param _endpoint The endpoint address
     */
    function setEndpoint(address _endpoint) external;

    /**
     * @notice Registers an Enygma token
     * @param resourceId The resource ID of the Enygma token
     * @param tokenData The token data
     * @param totalSupply The total supply of the token
     * @param owner The owner of the token
     * @param participantStorage The participant storage address
     */
    function registerEnygmaToken(bytes32 resourceId, SharedObjects.TokenRegistrationData calldata tokenData, uint256 totalSupply, address owner, address participantStorage) external;
} 