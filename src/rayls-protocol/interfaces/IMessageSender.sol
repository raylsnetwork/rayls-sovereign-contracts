// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import './../../rayls-protocol-sdk/RaylsMessage.sol';
import './../../rayls-protocol-sdk/libraries/MessageLib.sol';

/**
 * @title IMessageSender
 * @dev Interface for the MessageSender contract
 */
interface IMessageSender {
    
    /**
     * @dev Parâmetros para broadcast de mensagens
     */
    struct BroadcastParams {
        bytes32 resourceId;
        bytes payload;
        bytes lockData;
        bytes revertDataSender;
        bytes revertDataReceiver;
        BridgedTransferMetadata transferMetadata;
        address sender;
        uint256 chainId;
    }
    
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
     * @dev Gets the outbound nonce for a destination chain
     * @param _dstChainId The destination chain ID
     * @return The current outbound nonce for the destination chain
     */
    function getOutboundNonce(uint256 _dstChainId) external view returns (uint256);
    
    /**
     * @dev Prepares and validates a message for sending
     * @param request The send request containing message details
     * @param sender The address sending the message
     * @return messagePayload The prepared message payload
     * @return messageId The unique identifier for the message
     * @return nonce The nonce used for the message
     */
    function prepareMessage(
        SendRequest memory request,
        address sender
    ) external returns (RaylsMessage memory messagePayload, bytes32 messageId, uint256 nonce);
    
    /**
     * @dev Broadcasts a message to all active participants
     * @param _resourceId The resource ID associated with the message
     * @param _payload The payload to send
     * @param _sender The sender address
     * @param _chainId The current chain ID
     * @return messageId The ID of the last sent message
     */
    function broadcastToAllParticipants(
        bytes32 _resourceId,
        bytes calldata _payload,
        address _sender,
        uint256 _chainId
    ) external returns (bytes32 messageId);
    
    /**
     * @dev Broadcasts a message to all active participants com dados adicionais
     * @param params Parâmetros de broadcast encapsulados em uma struct
     * @return messageId The ID of the last sent message
     */
    function broadcastToAllParticipantsWithData(
        BroadcastParams calldata params
    ) external returns (bytes32 messageId);
} 