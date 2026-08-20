// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../../rayls-node/rayls-privacy-node/RNReentrancyGuardV1.sol";

/**
 * @title TestReentrancyContract
 * @notice Test contract that uses RNReentrancyGuardV1 for testing reentrancy protection
 */
contract TestReentrancyContract is RNReentrancyGuardV1 {
    uint256 public sendCounter;
    uint256 public receiveCounter;
    address public lastCaller;

    constructor() {
        initialize();
        // Manually set the states to NOT_ENTERED since initialize() doesn't do it
        _send_entered_state = 1;
        _receive_entered_state = 1;
    }

    function protectedSendFunction() external sendNonReentrant {
        lastCaller = msg.sender;
        sendCounter++;
    }

    function protectedReceiveFunction() external receiveNonReentrant {
        lastCaller = msg.sender;
        receiveCounter++;
    }

    function nestedSendCall() external sendNonReentrant {
        sendCounter++;
        // Try to call another send-protected function
        this.protectedSendFunction();
    }

    function nestedReceiveCall() external receiveNonReentrant {
        receiveCounter++;
        // Try to call another receive-protected function
        this.protectedReceiveFunction();
    }

    function crossCall() external sendNonReentrant {
        sendCounter++;
        // Try to call receive-protected function from send context
        this.protectedReceiveFunction();
    }

    function getSendState() external view returns (uint8) {
        return _send_entered_state;
    }

    function getReceiveState() external view returns (uint8) {
        return _receive_entered_state;
    }

    // Function that allows external contract to call back
    function vulnerableFunction(address callback) external sendNonReentrant {
        sendCounter++;
        if (callback != address(0)) {
            (bool success, ) = callback.call(abi.encodeWithSignature("attack()"));
            require(success, "Callback failed");
        }
    }

    function vulnerableReceiveFunction(address callback) external receiveNonReentrant {
        receiveCounter++;
        if (callback != address(0)) {
            (bool success, ) = callback.call(abi.encodeWithSignature("attack()"));
            require(success, "Callback failed");
        }
    }

    function functionThatReverts() external sendNonReentrant {
        revert("Intentional revert");
    }
}
