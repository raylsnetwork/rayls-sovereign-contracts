// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '../libraries/TokenStructs.sol';

/**
 * @title ITokenFreezeManager
 * @dev Interface for the TokenFreezeManager module that handles token freezing functionality
 */
interface ITokenFreezeManager {
    // ========== Token Freezing ==========

    /**
     * @notice Freezes a token for certain participants
     * @param resourceId The resource ID of the token
     * @param chainIds Array of chain IDs to freeze the token for
     */
    function freezeToken(bytes32 resourceId, uint256[] calldata chainIds) external;

    /**
     * @notice Unfreezes a token for certain participants
     * @param resourceId The resource ID of the token
     * @param chainIds Array of chain IDs to unfreeze the token for
     */
    function unfreezeToken(bytes32 resourceId, uint256[] memory chainIds) external;

    /**
     * @notice Gets all frozen tokens
     * @return Array of all frozen tokens
     */
    function getAllFrozenTokens() external view returns (TokenStructs.FrozenToken[] memory);

    /**
     * @notice Checks if a token is frozen for a specific participant
     * @param resourceId The resource ID of the token
     * @param chainId The chain ID of the participant
     * @return True if the token is frozen for the participant
     */
    function isTokenFrozenForParticipant(bytes32 resourceId, uint256 chainId) external view returns (bool);
 
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
     * @notice Broadcasts current frozen resources for a new participant
     * @param chainId The chain ID of the participant
     */
    function broadcastCurrentFrozenResourcesForNewParticipant(uint256 chainId) external;

    /**
     * @notice Broadcasts unfrozen token data
     * @param unfrozenToken The unfrozen token data to broadcast
     */
    function broadcastUnfrozenToken(TokenStructs.FrozenToken memory unfrozenToken) external;

    /**
     * @notice Broadcasts frozen token data
     * @param frozenToken The frozen token data to broadcast
     */
    function broadcastFrozenToken(TokenStructs.FrozenToken memory frozenToken) external;
} 