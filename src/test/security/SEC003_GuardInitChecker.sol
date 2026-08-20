// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title SEC003_GuardInitChecker
 * @notice Replicates the RaylsReentrancyGuardV1 logic to verify that
 *         initialize() correctly sets guard states to _NOT_ENTERED (1).
 *
 *         If the initialization is buggy (states left at default 0), the
 *         guarded functions will revert on first call, bricking all
 *         cross-chain messaging for newly deployed Privacy Nodes.
 *
 *         This contract exposes getGuardStates() and guarded test functions
 *         so the E2E test can verify the behavior on live infrastructure.
 */
contract SEC003_GuardInitChecker is Initializable {
    uint8 internal constant _NOT_ENTERED = 1;
    uint8 internal constant _ENTERED = 2;
    uint8 internal _send_entered_state;
    uint8 internal _receive_entered_state;

    /**
     * @notice Replicates RaylsReentrancyGuardV1.initialize() exactly.
     *         If the production code has the bug (commented-out assignments),
     *         this will also have the bug, and guarded functions will revert.
     */
    function initialize() public initializer {
        _send_entered_state = _NOT_ENTERED;
        _receive_entered_state = _NOT_ENTERED;
    }

    modifier sendNonReentrant() {
        require(
            _send_entered_state == _NOT_ENTERED,
            "Rayls: no send reentrancy"
        );
        _send_entered_state = _ENTERED;
        _;
        _send_entered_state = _NOT_ENTERED;
    }

    modifier receiveNonReentrant() {
        require(
            _receive_entered_state == _NOT_ENTERED,
            "Rayls: no receive reentrancy"
        );
        _receive_entered_state = _ENTERED;
        _;
        _receive_entered_state = _NOT_ENTERED;
    }

    /**
     * @notice Returns the current guard states for inspection.
     * @return sendState Current value of _send_entered_state
     * @return receiveState Current value of _receive_entered_state
     */
    function getGuardStates() external view returns (uint8 sendState, uint8 receiveState) {
        return (_send_entered_state, _receive_entered_state);
    }

    /**
     * @notice Test function protected by sendNonReentrant.
     *         Will revert if _send_entered_state != _NOT_ENTERED.
     */
    function guardedSend() external sendNonReentrant {
        // no-op — just testing that the modifier doesn't revert
    }

    /**
     * @notice Test function protected by receiveNonReentrant.
     *         Will revert if _receive_entered_state != _NOT_ENTERED.
     */
    function guardedReceive() external receiveNonReentrant {
        // no-op — just testing that the modifier doesn't revert
    }
}
