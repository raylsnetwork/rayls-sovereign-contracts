// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;
import '../../privateHub/ParticipantStorage/libraries/ParticipantStructs.sol';

interface IParticipantValidator {
    /**
     * @dev External function to validate both message participants
     * @param originChainId ChainId of the message origin participant
     * @param destinationChainId ChainId of the message destination participant
     */
    function validateMessageParticipants(uint256 originChainId, uint256 destinationChainId) external;

    /**
     * @dev External function to validate a single participant status
     * @param chainId ChainId of the participant to validate
     */
    function validateParticipantStatus(uint256 chainId) external view;

    function getAllParticipants() external view returns (ParticipantStructs.Participant[] memory);
}
