// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../../rayls-protocol-sdk/libraries/SharedObjects.sol";
import "../libraries/TokenStructs.sol";

/**
 * @title ITokenCore
 * @dev Interface for the TokenCore module that handles core token management functionality
 */
interface ITokenCore {
    // ========== Token Management ==========

    /**
     * @notice Adds a token to the registry
     * @param tokenData The token registration data
     * @param owner The owner of the token
     * @return The resource ID of the registered token
     */
    function addToken(SharedObjects.TokenRegistrationData calldata tokenData, address owner) external returns (bytes32);

    /**
     * @notice Gets a token by its resource ID
     * @param resourceId The resource ID of the token
     * @return The token data
     */
    function getTokenByResourceId(bytes32 resourceId) external view returns (TokenStructs.Token memory);

    /**
     * @notice Gets all registered tokens
     * @return Array of all registered tokens
     */
    function getAllTokens() external view returns (TokenStructs.Token[] memory);

    /**
     * @notice Updates the status of a token
     * @param resourceId The resource ID of the token
     * @param status The new status
     */
    function updateStatus(bytes32 resourceId, TokenStructs.TokenStatus status) external;

    /**
     * @notice Updates token balance
     * @param issuerChainId The issuer chain ID
     * @param resourceId The resource ID of the token
     * @param updateType The type of balance update
     * @param metadata The update metadata
     */
    function updateTokenBalance(
        uint256 issuerChainId,
        bytes32 resourceId,
        SharedObjects.BalanceUpdateType updateType,
        bytes memory metadata
    ) external;

    /**
     * @notice Checks if a participant is an active issuer
     * @param chainId The chain ID of the participant
     * @return True if the participant is an active issuer
     */
    function isActiveIssuerParticipant(uint256 chainId) external view returns (bool);
   

    /**
     * @notice Sets the TokenRegistry address
     * @param _tokenRegistryAddress The TokenRegistry address
     */
    function setTokenRegistryAddress(address _tokenRegistryAddress) external;

    /**
     * @notice Sets the participant storage address
     * @param _participantStorage The participant storage address
     */
    function setParticipantStorage(address _participantStorage) external;

    /**
     * @notice Sets the resource registry address
     * @param _resourceRegistry The resource registry address
     */
    function setResourceRegistry(address _resourceRegistry) external;

    /**
     * @notice Sets the endpoint address
     * @param _endpoint The endpoint address
     */
    function setEndpoint(address _endpoint) external;

    /**
     * @notice Sets the Enygma token manager address
     * @param _enygmaTokenManager The Enygma token manager address
     */
    function setEnygmaTokenManager(address _enygmaTokenManager) external;
} 