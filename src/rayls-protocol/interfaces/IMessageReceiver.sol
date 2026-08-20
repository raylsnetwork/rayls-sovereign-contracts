// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {RaylsMessage} from './../../rayls-protocol-sdk/RaylsMessage.sol';
import {MessageLib} from './../../rayls-protocol-sdk/libraries/MessageLib.sol';

/**
 * @title IMessageReceiver
 * @dev Interface for the MessageReceiver contract
 */
interface IMessageReceiver {
    /**
     * @dev Emitted when the resource manager is updated
     * @param resourceManager The new resource manager address
     */
    event ResourceManagerUpdated(address indexed resourceManager);

    /**
     * @dev Emitted when the message executor is updated
     * @param messageExecutor The new message executor address
     */
    event MessageExecutorUpdated(address indexed messageExecutor);

    /**
     * @dev Updates the resource manager
     * @param _resourceManager Address of the new resource manager
     */
    function setResourceManager(address _resourceManager) external;

    /**
     * @dev Updates the message executor
     * @param _messageExecutor Address of the new message executor
     */
    function setMessageExecutor(address _messageExecutor) external;

    /**
     * @dev Gets the inbound nonce for a source chain
     * @param _srcChainId The source chain ID
     * @return The current inbound nonce for the source chain
     */
    function getInboundNonce(uint256 _srcChainId) external view returns (uint256);

    /**
     * @dev Gets the message executor
     * @return The current message executor address
     */
    function getMessageExecutor() external view returns (address);


    /**
     * @dev Receives and processes a message payload
     * @param _srcChainId The source chain ID
     * @param _srcAddress The source address
     * @param _dstAddress The destination address
     * @param _raylsMessage The Rayls message
     * @param _messageId The message ID
     */
    function receivePayload(
        uint256 _srcChainId,
        address _srcAddress,
        address _dstAddress,
        RaylsMessage memory _raylsMessage,
        bytes32 _messageId
    ) external;
}