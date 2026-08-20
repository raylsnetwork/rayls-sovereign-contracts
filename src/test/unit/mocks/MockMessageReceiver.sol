// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockMessageReceiver
 * @notice Simple mock contract for testing message receiving functionality
 * @dev Used in unit tests to verify message delivery and execution
 */
contract MockMessageReceiver {
    // State variables for tracking calls
    uint256 public callCount;
    bytes public lastPayload;
    address public lastSender;
    bool public shouldRevert;

    // Events
    event MessageReceived(address indexed sender, bytes payload, uint256 callNumber);
    event RevertFlagSet(bool shouldRevert);

    /**
     * @notice Receives and processes a message
     * @param payload The message payload
     */
    function receiveMessage(bytes calldata payload) external {
        if (shouldRevert) {
            revert("MockMessageReceiver: Forced revert");
        }

        callCount++;
        lastPayload = payload;
        lastSender = msg.sender;

        emit MessageReceived(msg.sender, payload, callCount);
    }

    /**
     * @notice Alternative receive function for testing different interfaces
     * @param data The message data
     */
    function handleMessage(bytes calldata data) external returns (bool) {
        callCount++;
        lastPayload = data;
        lastSender = msg.sender;

        emit MessageReceived(msg.sender, data, callCount);
        return true;
    }

    /**
     * @notice Set whether the contract should revert on receive
     * @param _shouldRevert True to revert, false to succeed
     */
    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
        emit RevertFlagSet(_shouldRevert);
    }

    /**
     * @notice Reset the mock state
     */
    function reset() external {
        callCount = 0;
        lastPayload = "";
        lastSender = address(0);
        shouldRevert = false;
    }

    /**
     * @notice Get the current state
     * @return count Number of times message was received
     * @return payload Last received payload
     * @return sender Last sender address
     */
    function getState() external view returns (
        uint256 count,
        bytes memory payload,
        address sender
    ) {
        return (callCount, lastPayload, lastSender);
    }
}
