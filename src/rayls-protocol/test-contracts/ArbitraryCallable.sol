// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ArbitraryCallable
 * @notice Generic test target for the programmability flow: a contract the
 *         `ProgrammabilityExecutor` can `target.call(selector ‖ args)` as a composed userBlob step.
 *
 * @dev Replaces the old callable-model demo contract. Under the new flow a userBlob step is
 *      `EnygmaProgramData{resourceId|contractAddress, selector, args}` dispatched by the executor;
 *      this contract simply exposes plain functions a step can target. `receiveMsgA` is a benign
 *      sink; `reenter` is a reentrancy probe used by SEC-002 tests — when invoked mid-dispatch it
 *      calls back into a configured target/selector to prove the token/executor `nonReentrant`
 *      guards block re-entry. It records whether the re-entry call succeeded.
 */
contract ArbitraryCallable {
    string public message;
    uint256 public callCount;

    // Reentrancy probe configuration.
    address public reenterTarget;
    bytes public reenterCalldata;
    bool public reentrancySucceeded;
    bool public reentrancyAttempted;

    /// @notice Most-recent attested origin read from the trusted calldata tail (for assertions).
    address public lastOrigin;

    /// @notice Benign sink: a step can target this to set a message. The executor appends the
    ///         attested origin as a trusted 20-byte calldata tail; this reads it via
    ///         `_originFromTail()` so tests can assert the executor controls the origin.
    function receiveMsgA(string calldata _msg) external {
        message = _msg;
        lastOrigin = _originFromTail();
        callCount++;
    }

    /// @notice Configure the re-entry the probe should attempt on its next invocation.
    /// @param _target Contract to call back into (e.g. the Enygma token).
    /// @param _calldata Full calldata (selector ‖ args) for the re-entrant call.
    function setReenter(address _target, bytes calldata _calldata) external {
        reenterTarget = _target;
        reenterCalldata = _calldata;
    }

    /// @notice Reentrancy probe: when the executor dispatches a step targeting this function, it
    ///         attempts the configured re-entrant call IF a re-entry target was configured via
    ///         `setReenter` (otherwise it just bumps `callCount` and returns, leaving
    ///         `reentrancyAttempted == false`). `reentrancySucceeded` stays false if a
    ///         `nonReentrant` guard (on the token or executor) blocks the re-entry. Takes no
    ///         declared params — the executor appends the attested origin as a trusted tail.
    function reenter() external {
        callCount++;
        lastOrigin = _originFromTail();
        if (reenterTarget == address(0)) return;
        reentrancyAttempted = true;
        (bool ok, ) = reenterTarget.call(reenterCalldata);
        reentrancySucceeded = ok;
    }

    /// @dev Read the attested origin the executor appends as the trusted last 20 calldata bytes.
    ///      Mirrors `RaylsApp._getMsgSenderOnReceiveMethod` for these standalone test targets.
    function _originFromTail() private pure returns (address tailOrigin) {
        assembly {
            tailOrigin := shr(96, calldataload(sub(calldatasize(), 20)))
        }
    }
}
