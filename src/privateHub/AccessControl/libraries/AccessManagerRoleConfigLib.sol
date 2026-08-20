// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {
    AccessManagerStorage,
    MemberData,
    RoleData,
    ManagedContractConfig,
    ADMIN,
    PUBLIC,
    TOKEN_OWNER,
    _roleIdToBitmap,
    _checkAdmin,
    _checkIsRoleAdmin,
    _getStorage,
    RaylsAccessManagerV1__InvalidInitialAdmin,
    RaylsAccessManagerV1__InvalidCaller,
    RaylsAccessManagerV1__PublicRoleCannotBeGranted,
    RaylsAccessManagerV1__TokenOwnerIsScopeOnly,
    RaylsAccessManagerV1__RoleCapacityExceeded,
    RaylsAccessManagerV1__RoleAlreadyRegistered,
    RaylsAccessManagerV1__RoleNotRegistered,
    RaylsAccessManagerV1__CannotPauseSelf
} from "../AccessManagerTypes.sol";

/// @title AccessManagerRoleConfigLib
/// @notice External library for role management, named registry, hierarchy config,
///         selector config, pause, and initialize body.
///         Called via delegatecall — shares the facade's storage context.
library AccessManagerRoleConfigLib {
    using EnumerableSet for EnumerableSet.AddressSet;

    // Events (must be redeclared in libraries for emit)
    event RoleGranted(uint64 indexed roleId, address indexed account, uint32 executionDelay, uint48 activeSince, address indexed grantor);
    event RoleRevoked(uint64 indexed roleId, address indexed account, address indexed revoker);
    event RoleAdminChanged(uint64 indexed roleId, uint64 indexed newAdmin);
    event RoleGuardianChanged(uint64 indexed roleId, uint64 indexed newGuardian);
    event RoleGrantDelayChanged(uint64 indexed roleId, uint32 newDelay);
    event RoleLabelSet(uint64 indexed roleId, string label);
    event RoleRegistered(uint64 indexed roleId, string name);
    event FunctionAllowedRoleAdded(address indexed managedContract, bytes4 indexed selector, uint64 indexed roleId);
    event FunctionAllowedRoleRemoved(address indexed managedContract, bytes4 indexed selector, uint64 indexed roleId);
    event ContractPauseUpdated(address indexed managedContract, bool paused);

    // ─────────────────────────────────────────────────────────────
    //  Initialize
    // ─────────────────────────────────────────────────────────────

    /// @dev Initialize storage after proxy deployment. Called by the facade's initialize().
    /// @param self The address of the facade contract (address(this) in delegatecall context).
    /// @param publicSelectors The 10 public selectors to map to PUBLIC in the self-management bitmap.
    function initializeStorage(
        address initialAdmin,
        address self,
        bytes4[10] memory publicSelectors
    ) external {
        AccessManagerStorage storage $ = _getStorage();
        if (initialAdmin == address(0)) revert RaylsAccessManagerV1__InvalidInitialAdmin(initialAdmin);

        // ADMIN grant.
        MemberData storage m = $._roles[ADMIN].globalGrants[initialAdmin];
        m.activeSince = uint48(block.timestamp);
        m.executionDelay = 0;

        $._globalGrantSummary[initialAdmin] = 1;
        $._globalGrantSegments[initialAdmin][0] = 1;
        $._globalRoleMembers[ADMIN].add(initialAdmin);

        // Well-known role labels.
        $._roles[PUBLIC].label = "PUBLIC";
        $._roles[TOKEN_OWNER].label = "TOKEN_OWNER";
        $._nextRoleId = 3;

        // Self-management bitmap: public selectors -> PUBLIC.
        ManagedContractConfig storage mc = $._managedContracts[self];
        {
            (uint256 pubSegIdx, uint256 pubBitMask) = _roleIdToBitmap(PUBLIC);
            for (uint256 i; i < 10; ++i) {
                mc.allowedRoleSummary[publicSelectors[i]] = (1 << pubSegIdx);
                mc.allowedRoleSegments[publicSelectors[i]][pubSegIdx] = pubBitMask;
            }
        }

        emit RoleGranted(ADMIN, initialAdmin, 0, uint48(block.timestamp), address(0));
    }

    // ─────────────────────────────────────────────────────────────
    //  Global Role Management
    // ─────────────────────────────────────────────────────────────

    function grantRole(
        uint64 roleId,
        address account,
        uint32 executionDelay
    ) external {
        AccessManagerStorage storage $ = _getStorage();
        if (roleId == PUBLIC) revert RaylsAccessManagerV1__PublicRoleCannotBeGranted();
        if (roleId == TOKEN_OWNER) revert RaylsAccessManagerV1__TokenOwnerIsScopeOnly();
        _checkIsRoleAdmin($, msg.sender, roleId);

        RoleData storage role = $._roles[roleId];
        uint48 activeSince = uint48(block.timestamp) + role.grantDelay;
        MemberData storage m = role.globalGrants[account];
        m.activeSince = activeSince;
        m.executionDelay = executionDelay;

        (uint256 segIdx, uint256 bitMask) = _roleIdToBitmap(roleId);
        $._globalGrantSummary[account] |= (1 << segIdx);
        $._globalGrantSegments[account][segIdx] |= bitMask;
        $._globalRoleMembers[roleId].add(account);

        emit RoleGranted(roleId, account, executionDelay, activeSince, msg.sender);
    }

    function revokeRole(
        uint64 roleId,
        address account
    ) external {
        AccessManagerStorage storage $ = _getStorage();
        _checkIsRoleAdmin($, msg.sender, roleId);

        delete $._roles[roleId].globalGrants[account];

        (uint256 segIdx, uint256 bitMask) = _roleIdToBitmap(roleId);
        uint256 newSegment = $._globalGrantSegments[account][segIdx] & ~bitMask;
        $._globalGrantSegments[account][segIdx] = newSegment;
        if (newSegment == 0) {
            $._globalGrantSummary[account] &= ~(1 << segIdx);
        }
        $._globalRoleMembers[roleId].remove(account);

        emit RoleRevoked(roleId, account, msg.sender);
    }

    function renounceRole(
        uint64 roleId,
        address callerConfirmation
    ) external {
        AccessManagerStorage storage $ = _getStorage();
        if (callerConfirmation != msg.sender) {
            revert RaylsAccessManagerV1__InvalidCaller(callerConfirmation, msg.sender);
        }

        delete $._roles[roleId].globalGrants[msg.sender];

        (uint256 segIdx, uint256 bitMask) = _roleIdToBitmap(roleId);
        uint256 newSegment = $._globalGrantSegments[msg.sender][segIdx] & ~bitMask;
        $._globalGrantSegments[msg.sender][segIdx] = newSegment;
        if (newSegment == 0) {
            $._globalGrantSummary[msg.sender] &= ~(1 << segIdx);
        }
        $._globalRoleMembers[roleId].remove(msg.sender);

        emit RoleRevoked(roleId, msg.sender, msg.sender);
    }

    function hasRole(
        uint64 roleId,
        address account
    ) external view returns (bool isMember, uint32 executionDelay) {
        AccessManagerStorage storage $ = _getStorage();
        MemberData storage m = $._roles[roleId].globalGrants[account];
        if (m.activeSince == 0 || m.activeSince > block.timestamp) return (false, 0);
        return (true, m.executionDelay);
    }

    // ─────────────────────────────────────────────────────────────
    //  Named Role Registry
    // ─────────────────────────────────────────────────────────────

    function registerRole(
        string calldata name
    ) external returns (uint64) {

        AccessManagerStorage storage $ = _getStorage();
        return _registerRoleInternal($, name, name);
    }

    function registerRoleAndLabel(
        string calldata name,
        string calldata label
    ) external returns (uint64) {

        AccessManagerStorage storage $ = _getStorage();
        return _registerRoleInternal($, name, label);
    }

    function _registerRoleInternal(
        AccessManagerStorage storage $,
        string calldata name,
        string calldata label
    ) private returns (uint64 roleId) {
        _checkAdmin($, msg.sender);
        if ($._nextRoleId >= 65536) revert RaylsAccessManagerV1__RoleCapacityExceeded();
        bytes32 nameHash = keccak256(bytes(name));
        if ($._roleNameToId[nameHash] != 0) {
            revert RaylsAccessManagerV1__RoleAlreadyRegistered(name);
        }
        roleId = $._nextRoleId++;
        $._roleNameToId[nameHash] = roleId;
        $._roles[roleId].label = bytes(label).length > 0 ? label : name;
        emit RoleRegistered(roleId, name);
        emit RoleLabelSet(roleId, $._roles[roleId].label);
    }

    function getRoleIdByName(
        string calldata name
    ) external view returns (uint64) {
        AccessManagerStorage storage $ = _getStorage();
        bytes32 nameHash = keccak256(bytes(name));
        uint64 roleId = $._roleNameToId[nameHash];
        if (roleId == 0) revert RaylsAccessManagerV1__RoleNotRegistered(name);
        return roleId;
    }

    function hasRoleByName(
        string calldata name,
        address account
    ) external view returns (bool) {
        AccessManagerStorage storage $ = _getStorage();
        bytes32 nameHash = keccak256(bytes(name));
        uint64 roleId = $._roleNameToId[nameHash];
        if (roleId == 0) return false;
        MemberData storage m = $._roles[roleId].globalGrants[account];
        return m.activeSince != 0 && m.activeSince <= block.timestamp;
    }

    // ─────────────────────────────────────────────────────────────
    //  Role Hierarchy
    // ─────────────────────────────────────────────────────────────

    function setRoleAdmin(uint64 roleId, uint64 adminRoleId) external {

        AccessManagerStorage storage $ = _getStorage();
        _checkAdmin($, msg.sender);
        $._roles[roleId].adminRole = adminRoleId;
        emit RoleAdminChanged(roleId, adminRoleId);
    }

    function setRoleGuardian(uint64 roleId, uint64 guardianRoleId) external {

        AccessManagerStorage storage $ = _getStorage();
        _checkAdmin($, msg.sender);
        $._roles[roleId].guardianRole = guardianRoleId;
        emit RoleGuardianChanged(roleId, guardianRoleId);
    }

    function setGrantDelay(uint64 roleId, uint32 newDelay) external {

        AccessManagerStorage storage $ = _getStorage();
        _checkAdmin($, msg.sender);
        $._roles[roleId].grantDelay = newDelay;
        emit RoleGrantDelayChanged(roleId, newDelay);
    }

    function labelRole(uint64 roleId, string calldata label) external {

        AccessManagerStorage storage $ = _getStorage();
        _checkAdmin($, msg.sender);
        $._roles[roleId].label = label;
        emit RoleLabelSet(roleId, label);
    }

    function getRoleLabel(uint64 roleId) external view returns (string memory) {
        AccessManagerStorage storage $ = _getStorage();
        return $._roles[roleId].label;
    }

    function getRoleAdmin(uint64 roleId) external view returns (uint64) {
        AccessManagerStorage storage $ = _getStorage();
        return $._roles[roleId].adminRole;
    }

    function getRoleGuardian(uint64 roleId) external view returns (uint64) {
        AccessManagerStorage storage $ = _getStorage();
        return $._roles[roleId].guardianRole;
    }

    // ─────────────────────────────────────────────────────────────
    //  Selector Config
    // ─────────────────────────────────────────────────────────────

    function addFunctionAllowedRoles(
        address managedContract,
        bytes4[] calldata selectors,
        uint64[] calldata roleIds
    ) external {

        AccessManagerStorage storage $ = _getStorage();
        _checkAdmin($, msg.sender);
        ManagedContractConfig storage mc = $._managedContracts[managedContract];
        uint256 sLen = selectors.length;
        uint256 rLen = roleIds.length;
        for (uint256 r; r < rLen; ++r) {
            (uint256 segIdx, uint256 bitMask) = _roleIdToBitmap(roleIds[r]);
            for (uint256 i; i < sLen; ++i) {
                bytes4 sel = selectors[i];
                mc.allowedRoleSummary[sel] |= (1 << segIdx);
                mc.allowedRoleSegments[sel][segIdx] |= bitMask;
                emit FunctionAllowedRoleAdded(managedContract, sel, roleIds[r]);
            }
        }
    }

    function removeFunctionAllowedRoles(
        address managedContract,
        bytes4[] calldata selectors,
        uint64[] calldata roleIds
    ) external {

        AccessManagerStorage storage $ = _getStorage();
        _checkAdmin($, msg.sender);
        ManagedContractConfig storage mc = $._managedContracts[managedContract];
        for (uint256 r; r < roleIds.length; ++r) {
            _removeRoleFromSelectors(mc, managedContract, selectors, roleIds[r]);
        }
    }

    function _removeRoleFromSelectors(
        ManagedContractConfig storage mc,
        address managedContract,
        bytes4[] calldata selectors,
        uint64 roleId
    ) private {
        (uint256 segIdx, uint256 bitMask) = _roleIdToBitmap(roleId);
        for (uint256 i; i < selectors.length; ++i) {
            bytes4 sel = selectors[i];
            uint256 newSegment = mc.allowedRoleSegments[sel][segIdx] & ~bitMask;
            mc.allowedRoleSegments[sel][segIdx] = newSegment;
            if (newSegment == 0) {
                mc.allowedRoleSummary[sel] &= ~(1 << segIdx);
            }
            emit FunctionAllowedRoleRemoved(managedContract, sel, roleId);
        }
    }

    // ─────────────────────────────────────────────────────────────
    //  Pause
    // ─────────────────────────────────────────────────────────────

    function setContractPaused(
        address managedContract,
        bool paused
    ) external {

        AccessManagerStorage storage $ = _getStorage();
        if (managedContract == address(this)) revert RaylsAccessManagerV1__CannotPauseSelf();
        _checkAdmin($, msg.sender);
        $._managedContracts[managedContract].emergencyPaused = paused;
        emit ContractPauseUpdated(managedContract, paused);
    }

    function isContractPaused(
        address managedContract
    ) external view returns (bool) {
        AccessManagerStorage storage $ = _getStorage();
        return $._managedContracts[managedContract].emergencyPaused;
    }

}
