// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import './../../rayls-protocol-sdk/RaylsMessage.sol';
import './../../rayls-protocol-sdk/libraries/MessageLib.sol';
import './../../MessageDispatcher.sol';

/**
 * @title IBatchMessageSender
 * @dev Interface for the BatchMessageSender contract
 */
interface IBatchMessageSender {
    /**
     * @dev Emitted when the participant validator is updated
     * @param participantValidator The new participant validator address
     */
    event ParticipantValidatorUpdated(address indexed participantValidator);
    
    /**
     * @dev Emitted when the token validator is updated
     * @param tokenValidator The new token validator address
     */
    event TokenValidatorUpdated(address indexed tokenValidator);
    
    /**
     * @dev Updates the participant validator
     * @param _participantValidator Address of the new participant validator
     */
    function setParticipantValidator(address _participantValidator) external;
    
    /**
     * @dev Updates the token validator
     * @param _tokenValidator Address of the new token validator
     */
    function setTokenValidator(address _tokenValidator) external;
    
    /**
     * @dev Prepares and validates a batch of messages for sending
     * @param requests Array of send requests containing message details
     * @param sender The address sending the message batch
     * @param chainId The ID of the current chain
     * @return messages The batch messages prepared for dispatch
     * @return batchId The unique identifier for the batch
     * @return nonces The nonces used for each message
     */
    function prepareBatch(
        SendRequest[] memory requests,
        address sender,
        uint256 chainId
    ) external returns (
        BatchMessage[] memory messages,
        bytes32 batchId,
        uint256[] memory nonces
    );
} 