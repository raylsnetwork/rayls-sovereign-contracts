// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../libraries/ParticipantStructs.sol";

/**
 * @title IParticipantCore
 * @dev Interface for the ParticipantCore module that handles core participant management functionality
 */
interface IParticipantCore {
    /**
     * @dev Emitted when a participant is registered
     */
    event ParticipantRegistered(ParticipantStructs.Participant participant);
    
    /**
     * @dev Emitted when a participant is updated
     */
    event ParticipantUpdated(ParticipantStructs.Participant participant);

    /**
     * @dev Get Participant by chainId
     * @param chainId ChainId of the participant to get
     * @return The participant data
     */
    function getParticipant(uint256 chainId) external view returns (ParticipantStructs.Participant memory);

    /**
     * @dev Get all registered chainIds
     * @return Array of registered chain IDs
     */
    function getAllParticipantsChainIds() external view returns (uint256[] memory);

    /**
     * @dev Get all registered participants
     * @return Array of all participants
     */
    function getAllParticipants() external view returns (ParticipantStructs.Participant[] memory);

    /**
     * @dev Add a Participant
     * @param _participant Participant struct to add
     */
    function addParticipant(ParticipantStructs.ParticipantData memory _participant) external;

    /**
     * @dev Add multiple Participants
     * @param _participants Array of Participants structs to add
     */
    function addParticipants(ParticipantStructs.ParticipantData[] memory _participants) external;

    /**
     * @dev Update participant status
     * @param chainId ChainId of the participant to update
     * @param status New status of the participant
     */
    function updateStatus(uint256 chainId, ParticipantStructs.Status status) external;

    /**
     * @dev Update participant role
     * @param chainId ChainId of the participant to update
     * @param role New role of the participant
     */
    function updateRole(uint256 chainId, ParticipantStructs.Role role) external;

    /**
     * @dev Update broadcast messages permission for a participant
     * @param chainId ChainId of the participant to update
     * @param allowed New broadcast permission value
     */
    function updateBroadcastMessagesPermission(uint256 chainId, bool allowed) external;

    /**
     * @dev Remove Participant (set status to INACTIVE)
     * @param chainId ChainId of the participant to remove
     */
    function removeParticipant(uint256 chainId) external;

    /**
     * @dev Verify Participants on whether it exists and has status active
     * @param chainId ChainId of the participant to verify
     * @return True if participant exists and is active, false otherwise
     */
    function verifyParticipant(uint256 chainId) external view returns (bool);

    /**
     * @dev Validate that both origin and destination participants exist and are active
     * @param originChainId ChainId of the message origin participant
     * @param destinationChainId ChainId of the message destination participant
     */
    function validateMessageParticipants(uint256 originChainId, uint256 destinationChainId) external view;

    /**
     * @dev Validate that a single participant exists and is active
     * @param chainId ChainId of the participant to validate
     */
    function validateParticipantStatus(uint256 chainId) external view;

    /**
     * @dev Broadcast all current participants to the request chain
     */
    function broadcastCurrentParticipants(uint256 fromChainId) external;
} 