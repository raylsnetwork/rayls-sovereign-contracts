// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {
    AccessManagerStorage,
    MemberData,
    ManagedContractConfig,
    ADMIN,
    PUBLIC,
    _lowestSetBit,
    _getStorage
} from "../AccessManagerTypes.sol";

/// @title AccessManagerAuthLib
/// @notice External library for the canCall authorization subsystem.
///         Called via delegatecall — shares the facade's storage context.
library AccessManagerAuthLib {

    /// @dev Core authorization logic. Checks whether `caller` can call `selector` on `managedContract`.
    function canCall(
        address caller,
        address managedContract,
        bytes4 selector
    ) external view returns (bool allowed, uint32 delay, bool paused) {
        AccessManagerStorage storage $ = _getStorage();
        ManagedContractConfig storage mc = $._managedContracts[managedContract];

        // Emergency pause wins over everything.
        if (mc.emergencyPaused) return (false, 0, true);

        // Scheduled operation execution: when execute() calls a managed contract,
        // the restricted modifier calls canCall(managerAddress, ...). Allow it if
        // the manager is currently executing a scheduled operation.
        if (caller == address(this) && $._executingScheduledOpDepth > 0) return (true, 0, false);

        // ADMIN bypass.
        {
            MemberData storage adminM = $._roles[ADMIN].globalGrants[caller];
            if (adminM.activeSince != 0 && adminM.activeSince <= block.timestamp) {
                return (true, adminM.executionDelay, false);
            }
        }

        // Load selector summary bitmap.
        uint256 selSummary = mc.allowedRoleSummary[selector];
        if (selSummary == 0) return (false, 0, false); // unmapped = ADMIN only

        // PUBLIC check.
        if ((selSummary & 1) != 0) {
            uint256 selSeg0 = mc.allowedRoleSegments[selector][0];
            if ((selSeg0 & (1 << PUBLIC)) != 0) return (true, 0, false);
        }

        // Check global grants via bitmap AND.
        (bool gFound, uint32 gDelay) = _checkGlobalBitmap(caller, managedContract, selector, selSummary);
        if (gFound) return (true, gDelay, false);
        if (gDelay > 0) return (false, gDelay, false);

        // Check contract-scoped grants via bitmap AND.
        (bool sFound, uint32 sDelay) = _checkScopedBitmap(caller, managedContract, selector, selSummary);
        if (sFound) return (true, sDelay, false);
        if (sDelay > 0) return (false, sDelay, false);

        return (false, 0, false);
    }

    function _checkGlobalBitmap(
        address caller,
        address managedContract,
        bytes4 selector,
        uint256 selectorSegments
    ) private view returns (bool allowed, uint32 delay) {
        AccessManagerStorage storage $ = _getStorage();
        ManagedContractConfig storage mc = $._managedContracts[managedContract];
        uint256 overlap = selectorSegments & $._globalGrantSummary[caller];

        while (overlap != 0) {
            uint256 segIdx = _lowestSetBit(overlap);
            uint256 matchingRoles = mc.allowedRoleSegments[selector][segIdx]
                & $._globalGrantSegments[caller][segIdx];

            while (matchingRoles != 0) {
                uint256 bitPos = _lowestSetBit(matchingRoles);
                uint64 roleId = uint64(segIdx * 256 + bitPos);

                MemberData storage member = $._roles[roleId].globalGrants[caller];
                if (member.activeSince != 0 && member.activeSince <= block.timestamp) {
                    if (member.executionDelay == 0) return (true, 0);
                    return (false, member.executionDelay);
                }
                matchingRoles &= matchingRoles - 1;
            }
            overlap &= overlap - 1;
        }
        return (false, 0);
    }

    function _checkScopedBitmap(
        address caller,
        address managedContract,
        bytes4 selector,
        uint256 selectorSegments
    ) private view returns (bool allowed, uint32 delay) {
        AccessManagerStorage storage $ = _getStorage();
        ManagedContractConfig storage mc = $._managedContracts[managedContract];
        uint256 overlap = selectorSegments & $._contractScopedGrantSummary[caller][managedContract];

        while (overlap != 0) {
            uint256 segIdx = _lowestSetBit(overlap);
            uint256 matchingRoles = mc.allowedRoleSegments[selector][segIdx]
                & $._contractScopedGrantSegments[caller][managedContract][segIdx];

            while (matchingRoles != 0) {
                uint256 bitPos = _lowestSetBit(matchingRoles);
                uint64 roleId = uint64(segIdx * 256 + bitPos);

                MemberData storage scopedMember = $._roles[roleId].contractScopedGrants[caller][managedContract];
                if (scopedMember.activeSince != 0 && scopedMember.activeSince <= block.timestamp) {
                    if (scopedMember.executionDelay == 0) return (true, 0);
                    return (false, scopedMember.executionDelay);
                }
                matchingRoles &= matchingRoles - 1;
            }
            overlap &= overlap - 1;
        }
        return (false, 0);
    }
}
