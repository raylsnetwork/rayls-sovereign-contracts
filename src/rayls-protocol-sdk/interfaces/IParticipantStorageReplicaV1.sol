// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '../../privateHub/ParticipantStorage/libraries/ParticipantStructs.sol';

/**
 * @title IParticipantStorageReplicaV1
 * @dev Interface for interacting with ParticipantStorageReplicaV1 contract
 */
interface IParticipantStorageReplicaV1 {
    /**
     * @dev Add multiple Participants
     * @param _participants Array of Participants structs to add
     */
    function addOrUpdateParticipants(ParticipantStructs.Participant[] calldata _participants) external;

    /**
     * @dev Function to validate both message participants
     * @param originChainId ChainId of the message origin participant
     * @param destinationChainId ChainId of the message destination participant
     */
    function validateMessageParticipants(uint256 originChainId, uint256 destinationChainId) external view;

    /**
     * @dev Sends a message to private hub requesting all participant data
     */
    function requestAllParticipantsDataFromPrivateHub() external;

    /**
     * @dev Get all participants
     * @return Array of Participant structs
     */
    function getAllParticipants() external view returns (ParticipantStructs.Participant[] memory);

    /**
     * @dev Returns the contract version
     * @return Version number
     */
    function contractVersion() external pure returns (uint256);
}
