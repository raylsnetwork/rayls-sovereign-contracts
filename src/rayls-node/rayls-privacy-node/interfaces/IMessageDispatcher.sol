// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./../RNMessageLib.sol";

struct BatchMessage {
    uint256 toChainId;
    address to;
    RaylsNodeMessage data;
    bytes32 messageId;
}

/**
 * @title IMessageDispatcher Interface
 * @notice An interface for dispatching cross-chain messages.
 * @dev This interface describes the methods for dispatching and tracking cross-chain messages.
 */
interface IMessageDispatcher {
    /**
     * @notice Dispatch a message to another chain and emit the associated event.
     * @param fromChainId The unique identifier of the chain from which the message is being sent
     * @param from The address sending the message.
     * @param toChainId The unique identifier to the chain to which the message will be delivered
     * @param to The address on the target chain to which the message will be delivered.
     * @param data The call data to send with the message.
     * @return messageId A unique identifier for the dispatched message.
     */
    function dispatchMessage(
        uint256 fromChainId,
        address from,
        uint256 toChainId,
        address to,
        RaylsNodeMessage memory data
    ) external returns (bytes32);

    /// @dev Event emitted when a message is dispatched.
    event MessageDispatched(
        bytes32 indexed messageId,
        address indexed from,
        uint256 indexed toChainId,
        address to,
        RaylsNodeMessage data
    );

    /**
     * @notice Dispatch a message batch to another chain and emit the associated event.
     * @param batchId A unique identifier for the dispatched batch.
     * @param from The address sending the message batch.
     * @param messages The messages being dispatched on the batch.
     * @return batchId A unique identifier for the dispatched batch.
     */
    function dispatchMessageBatch(
        bytes32 batchId,
        address from,
        BatchMessage[] memory messages
    ) external returns (bytes32);

    /// @dev Event emitted when a message batch is dispatched.
    event MessageBatchDispatched(
        bytes32 batchId,
        address from,
        BatchMessage[] messages
    );
}