// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IRaylsAccessManager} from "../interfaces/IRaylsAccessManager.sol";
import {
    AccessManagerStorage,
    MemberData,
    RoleData,
    ManagedContractConfig,
    _lowestSetBit,
    _getStorage
} from "../AccessManagerTypes.sol";

/// @title AccessManagerEnumerationLib
/// @notice External library for RaylsAccessManagerV1 enumeration/query functions.
///         Called via delegatecall — shares the facade's storage context.
library AccessManagerEnumerationLib {
    using EnumerableSet for EnumerableSet.AddressSet;

    function getAccountRoles(
        address account
    ) external view returns (uint64[] memory roleIds) {
        AccessManagerStorage storage $ = _getStorage();
        uint256 summary = $._globalGrantSummary[account];
        if (summary == 0) return new uint64[](0);

        // First pass: count active roles.
        uint256 count;
        uint256 remaining = summary;
        while (remaining != 0) {
            uint256 segIdx = _lowestSetBit(remaining);
            uint256 bits = $._globalGrantSegments[account][segIdx];
            while (bits != 0) {
                uint256 bitPos = _lowestSetBit(bits);
                uint64 roleId = uint64(segIdx * 256 + bitPos);
                MemberData storage m = $._roles[roleId].globalGrants[account];
                if (m.activeSince != 0 && m.activeSince <= block.timestamp) {
                    count++;
                }
                bits &= bits - 1;
            }
            remaining &= remaining - 1;
        }

        // Second pass: populate array.
        roleIds = new uint64[](count);
        uint256 idx;
        remaining = summary;
        while (remaining != 0) {
            uint256 segIdx = _lowestSetBit(remaining);
            uint256 bits = $._globalGrantSegments[account][segIdx];
            while (bits != 0) {
                uint256 bitPos = _lowestSetBit(bits);
                uint64 roleId = uint64(segIdx * 256 + bitPos);
                MemberData storage m = $._roles[roleId].globalGrants[account];
                if (m.activeSince != 0 && m.activeSince <= block.timestamp) {
                    roleIds[idx++] = roleId;
                }
                bits &= bits - 1;
            }
            remaining &= remaining - 1;
        }
    }

    function getAccountContractScopedRoles(
        address account,
        address managedContract
    ) external view returns (uint64[] memory roleIds) {
        AccessManagerStorage storage $ = _getStorage();
        uint256 summary = $._contractScopedGrantSummary[account][managedContract];
        if (summary == 0) return new uint64[](0);

        // First pass: count active roles.
        uint256 count;
        uint256 remaining = summary;
        while (remaining != 0) {
            uint256 segIdx = _lowestSetBit(remaining);
            uint256 bits = $._contractScopedGrantSegments[account][managedContract][segIdx];
            while (bits != 0) {
                uint256 bitPos = _lowestSetBit(bits);
                uint64 roleId = uint64(segIdx * 256 + bitPos);
                MemberData storage m = $._roles[roleId].contractScopedGrants[account][managedContract];
                if (m.activeSince != 0 && m.activeSince <= block.timestamp) {
                    count++;
                }
                bits &= bits - 1;
            }
            remaining &= remaining - 1;
        }

        // Second pass: populate array.
        roleIds = new uint64[](count);
        uint256 idx;
        remaining = summary;
        while (remaining != 0) {
            uint256 segIdx = _lowestSetBit(remaining);
            uint256 bits = $._contractScopedGrantSegments[account][managedContract][segIdx];
            while (bits != 0) {
                uint256 bitPos = _lowestSetBit(bits);
                uint64 roleId = uint64(segIdx * 256 + bitPos);
                MemberData storage m = $._roles[roleId].contractScopedGrants[account][managedContract];
                if (m.activeSince != 0 && m.activeSince <= block.timestamp) {
                    roleIds[idx++] = roleId;
                }
                bits &= bits - 1;
            }
            remaining &= remaining - 1;
        }
    }

    function getRoleMembers(
        uint64 roleId
    ) external view returns (address[] memory) {
        AccessManagerStorage storage $ = _getStorage();
        return $._globalRoleMembers[roleId].values();
    }

    function getContractScopedRoleMembers(
        uint64 roleId,
        address managedContract
    ) external view returns (address[] memory) {
        AccessManagerStorage storage $ = _getStorage();
        return $._contractScopedRoleMembers[roleId][managedContract].values();
    }

    function getRoleInfo(
        uint64 roleId
    ) external view returns (IRaylsAccessManager.RoleInfo memory) {
        AccessManagerStorage storage $ = _getStorage();
        return _buildRoleInfo($, roleId);
    }

    function getRoleInfoBatch(
        uint64[] calldata roleIds
    ) external view returns (IRaylsAccessManager.RoleInfo[] memory infos) {
        AccessManagerStorage storage $ = _getStorage();
        infos = new IRaylsAccessManager.RoleInfo[](roleIds.length);
        for (uint256 i; i < roleIds.length; ++i) {
            infos[i] = _buildRoleInfo($, roleIds[i]);
        }
    }

    function getAccountRolesWithInfo(
        address account
    ) external view returns (IRaylsAccessManager.RoleInfo[] memory infos) {
        AccessManagerStorage storage $ = _getStorage();
        uint256 summary = $._globalGrantSummary[account];
        if (summary == 0) return new IRaylsAccessManager.RoleInfo[](0);

        // First pass: count active roles.
        uint256 count;
        uint256 remaining = summary;
        while (remaining != 0) {
            uint256 segIdx = _lowestSetBit(remaining);
            uint256 bits = $._globalGrantSegments[account][segIdx];
            while (bits != 0) {
                uint256 bitPos = _lowestSetBit(bits);
                uint64 roleId = uint64(segIdx * 256 + bitPos);
                MemberData storage m = $._roles[roleId].globalGrants[account];
                if (m.activeSince != 0 && m.activeSince <= block.timestamp) {
                    count++;
                }
                bits &= bits - 1;
            }
            remaining &= remaining - 1;
        }

        // Second pass: populate array with full info.
        infos = new IRaylsAccessManager.RoleInfo[](count);
        uint256 idx;
        remaining = summary;
        while (remaining != 0) {
            uint256 segIdx = _lowestSetBit(remaining);
            uint256 bits = $._globalGrantSegments[account][segIdx];
            while (bits != 0) {
                uint256 bitPos = _lowestSetBit(bits);
                uint64 roleId = uint64(segIdx * 256 + bitPos);
                MemberData storage m = $._roles[roleId].globalGrants[account];
                if (m.activeSince != 0 && m.activeSince <= block.timestamp) {
                    infos[idx++] = _buildRoleInfo($, roleId);
                }
                bits &= bits - 1;
            }
            remaining &= remaining - 1;
        }
    }

    function getAllRoles() external view returns (IRaylsAccessManager.RoleInfo[] memory infos) {
        AccessManagerStorage storage $ = _getStorage();
        uint64 count = $._nextRoleId;
        infos = new IRaylsAccessManager.RoleInfo[](count);
        for (uint64 i; i < count; ++i) {
            infos[i] = _buildRoleInfo($, i);
        }
    }

    function collectSelectorRoles(
        address managedContract,
        bytes4 selector
    ) external view returns (uint64[] memory roleIds) {
        AccessManagerStorage storage $ = _getStorage();
        ManagedContractConfig storage mc = $._managedContracts[managedContract];
        uint256 summary = mc.allowedRoleSummary[selector];
        if (summary == 0) return new uint64[](0);

        // First pass: count.
        uint256 count;
        uint256 remaining = summary;
        while (remaining != 0) {
            uint256 segIdx = _lowestSetBit(remaining);
            uint256 bits = mc.allowedRoleSegments[selector][segIdx];
            while (bits != 0) {
                count++;
                bits &= bits - 1;
            }
            remaining &= remaining - 1;
        }

        // Second pass: populate.
        roleIds = new uint64[](count);
        uint256 idx;
        remaining = summary;
        while (remaining != 0) {
            uint256 segIdx = _lowestSetBit(remaining);
            uint256 bits = mc.allowedRoleSegments[selector][segIdx];
            while (bits != 0) {
                uint256 bitPos = _lowestSetBit(bits);
                roleIds[idx++] = uint64(segIdx * 256 + bitPos);
                bits &= bits - 1;
            }
            remaining &= remaining - 1;
        }
    }

    function getFunctionAllowedRolesWithInfo(
        address managedContract,
        bytes4 selector
    ) external view returns (IRaylsAccessManager.RoleInfo[] memory infos) {
        AccessManagerStorage storage $ = _getStorage();
        ManagedContractConfig storage mc = $._managedContracts[managedContract];
        uint256 summary = mc.allowedRoleSummary[selector];
        if (summary == 0) return new IRaylsAccessManager.RoleInfo[](0);

        // First pass: count.
        uint256 count;
        uint256 remaining = summary;
        while (remaining != 0) {
            uint256 segIdx = _lowestSetBit(remaining);
            uint256 bits = mc.allowedRoleSegments[selector][segIdx];
            while (bits != 0) {
                count++;
                bits &= bits - 1;
            }
            remaining &= remaining - 1;
        }

        // Second pass: populate with info.
        infos = new IRaylsAccessManager.RoleInfo[](count);
        uint256 idx;
        remaining = summary;
        while (remaining != 0) {
            uint256 segIdx = _lowestSetBit(remaining);
            uint256 bits = mc.allowedRoleSegments[selector][segIdx];
            while (bits != 0) {
                uint256 bitPos = _lowestSetBit(bits);
                infos[idx++] = _buildRoleInfo($, uint64(segIdx * 256 + bitPos));
                bits &= bits - 1;
            }
            remaining &= remaining - 1;
        }
    }

    function _buildRoleInfo(
        AccessManagerStorage storage $,
        uint64 roleId
    ) private view returns (IRaylsAccessManager.RoleInfo memory) {
        RoleData storage role = $._roles[roleId];
        return IRaylsAccessManager.RoleInfo({
            roleId: roleId,
            label: role.label,
            adminRole: role.adminRole,
            guardianRole: role.guardianRole,
            grantDelay: role.grantDelay,
            memberCount: $._globalRoleMembers[roleId].length()
        });
    }
}
