// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessManagerAuthLib} from "./AccessManagerAuthLib.sol";
import {
    AccessManagerStorage,
    MemberData,
    ManagedContractConfig,
    ADMIN,
    EXPIRATION,
    _lowestSetBit,
    _getStorage,
    RaylsAccessManagerV1__NotScheduled,
    RaylsAccessManagerV1__NotReady,
    RaylsAccessManagerV1__Expired,
    RaylsAccessManagerV1__AlreadyScheduled,
    RaylsAccessManagerV1__SelectorTooShort,
    RaylsAccessManagerV1__NotRoleGuardianOrScheduler,
    RaylsAccessManagerV1__Unauthorized,
    RaylsAccessManagerV1__ContractPaused
} from "../AccessManagerTypes.sol";

/// @title AccessManagerScheduleLib
/// @notice External library for scheduled operation management.
///         Called via delegatecall — shares the facade's storage context.
library AccessManagerScheduleLib {

    event OperationScheduled(bytes32 indexed operationId, address indexed caller, address indexed managedContract, uint48 executeAfter);
    event OperationCanceled(bytes32 indexed operationId);

    function schedule(
        address managedContract,
        bytes calldata data,
        uint48 when
    ) external returns (bytes32 operationId) {
        AccessManagerStorage storage $ = _getStorage();
        operationId = _operationId(msg.sender, managedContract, data);

        uint48 existingSchedule = $._schedules[operationId];
        if (existingSchedule != 0) {
            bool expired = block.timestamp > existingSchedule + EXPIRATION;
            if (!expired) revert RaylsAccessManagerV1__AlreadyScheduled(operationId);
        }

        if (data.length < 4) revert RaylsAccessManagerV1__SelectorTooShort();

        // F01 fix: gate `schedule` on caller authorization. The original code
        // destructured only `callerDelay` and never reverted on `!allowed`,
        // which combined with the depth-bypass in canCall produced a
        // universal `restricted` bypass. We now mirror OpenZeppelin
        // AccessManager semantics: schedule is only permitted for callers
        // that either have immediate access (allowed=true, delay=0),
        // delayed access (delay>0), or are calling against a non-paused
        // managed contract. Unauthorized callers (allowed=false &&
        // delay==0) are rejected. Paused contracts reject all schedules
        // since the eventual execute() would also be blocked.
        (bool allowed, uint32 callerDelay, bool paused) =
            AccessManagerAuthLib.canCall(msg.sender, managedContract, bytes4(data[:4]));
        if (paused) revert RaylsAccessManagerV1__ContractPaused();
        if (!allowed && callerDelay == 0) revert RaylsAccessManagerV1__Unauthorized(msg.sender);

        uint48 earliest = uint48(block.timestamp) + callerDelay;
        uint48 executeAfter = when > earliest ? when : earliest;

        $._schedules[operationId] = executeAfter;
        emit OperationScheduled(operationId, msg.sender, managedContract, executeAfter);
    }

    /// @dev Validates a scheduled operation is ready and consumes (deletes) it.
    ///      Returns the operationId. The facade handles the external call and depth counter.
    function validateAndConsumeSchedule(
        address msgSender,
        address managedContract,
        bytes calldata data
    ) external returns (bytes32 operationId) {
        AccessManagerStorage storage $ = _getStorage();
        operationId = _operationId(msgSender, managedContract, data);

        uint48 readyAt = $._schedules[operationId];
        if (readyAt == 0) revert RaylsAccessManagerV1__NotScheduled(operationId);
        if (block.timestamp < readyAt) revert RaylsAccessManagerV1__NotReady(operationId, readyAt);
        if (block.timestamp > readyAt + EXPIRATION) revert RaylsAccessManagerV1__Expired(operationId);

        delete $._schedules[operationId];
    }

    function cancel(
        address caller,
        address managedContract,
        bytes calldata data
    ) external returns (uint32) {
        AccessManagerStorage storage $ = _getStorage();
        bytes32 operationId = _operationId(caller, managedContract, data);

        if ($._schedules[operationId] == 0) {
            revert RaylsAccessManagerV1__NotScheduled(operationId);
        }

        // ADMIN can always cancel.
        MemberData storage adminMember = $._roles[ADMIN].globalGrants[msg.sender];
        bool isAdmin = adminMember.activeSince != 0 && adminMember.activeSince <= block.timestamp;

        if (!isAdmin) {
            if (data.length < 4) revert RaylsAccessManagerV1__SelectorTooShort();
            bool isScheduler = msg.sender == caller;
            bool isGuardian = _isGuardianOfMappedRole($, msg.sender, managedContract, bytes4(data[:4]));

            if (!isScheduler && !isGuardian) {
                revert RaylsAccessManagerV1__NotRoleGuardianOrScheduler(operationId);
            }
        }

        delete $._schedules[operationId];
        emit OperationCanceled(operationId);

        return 0;
    }

    function getSchedule(
        bytes32 operationId
    ) external view returns (uint48) {
        AccessManagerStorage storage $ = _getStorage();
        return $._schedules[operationId];
    }

    /// @dev Deterministic operation ID for scheduling.
    function _operationId(
        address caller,
        address managedContract,
        bytes calldata data
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(caller, managedContract, data));
    }

    /// @dev Returns true if `caller` holds the guardian role of ANY role mapped to `selector`.
    function _isGuardianOfMappedRole(
        AccessManagerStorage storage $,
        address caller,
        address managedContract,
        bytes4 selector
    ) internal view returns (bool) {
        ManagedContractConfig storage mc = $._managedContracts[managedContract];
        uint256 remaining = mc.allowedRoleSummary[selector];

        while (remaining != 0) {
            uint256 segIdx = _lowestSetBit(remaining);
            uint256 bits = mc.allowedRoleSegments[selector][segIdx];
            while (bits != 0) {
                uint256 bitPos = _lowestSetBit(bits);
                uint64 roleId = uint64(segIdx * 256 + bitPos);
                uint64 guardRole = $._roles[roleId].guardianRole;
                if (guardRole != 0) {
                    MemberData storage gm = $._roles[guardRole].globalGrants[caller];
                    if (gm.activeSince != 0 && gm.activeSince <= block.timestamp) {
                        return true;
                    }
                }
                bits &= bits - 1;
            }
            remaining &= remaining - 1;
        }
        return false;
    }
}
