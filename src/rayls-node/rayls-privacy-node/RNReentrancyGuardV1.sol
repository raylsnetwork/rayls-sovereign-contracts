// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title RNReentrancyGuardV1
 * @notice Reentrancy guard with separate locks for send and receive operations
 * @dev Provides nonReentrant modifiers for send and receive functions
 */
abstract contract RNReentrancyGuardV1 is Initializable {

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error RNReentrancyGuardV1__SendReentrancy();
    error RNReentrancyGuardV1__ReceiveReentrancy();

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    uint8 internal constant _NOT_ENTERED = 1;
    uint8 internal constant _ENTERED = 2;
    uint8 internal _send_entered_state;
    uint8 internal _receive_entered_state;

    /*//////////////////////////////////////////////////////////////
                            INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the reentrancy guard
     */
    function initialize() public virtual initializer {
        _send_entered_state = _NOT_ENTERED;
        _receive_entered_state = _NOT_ENTERED;
    }

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Prevents reentrancy for send operations
     */
    modifier sendNonReentrant() {
        if (_send_entered_state == _ENTERED) revert RNReentrancyGuardV1__SendReentrancy();
        _send_entered_state = _ENTERED;
        _;
        _send_entered_state = _NOT_ENTERED;
    }

    /**
     * @notice Prevents reentrancy for receive operations
     */
    modifier receiveNonReentrant() {
        if (_receive_entered_state == _ENTERED) revert RNReentrancyGuardV1__ReceiveReentrancy();
        _receive_entered_state = _ENTERED;
        _;
        _receive_entered_state = _NOT_ENTERED;
    }
}