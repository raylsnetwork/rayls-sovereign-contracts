// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IRaylsAccessManager} from "./interfaces/IRaylsAccessManager.sol";
import {RaylsAccessManaged} from "./RaylsAccessManaged.sol";

import {
    AccessManagerStorage,
    MemberData,
    _getStorage,
    _checkAdmin,
    RaylsAccessManagerV1__Unauthorized,
    RaylsAccessManagerV1__ContractPaused
} from "./AccessManagerTypes.sol";
import {AccessManagerAuthLib} from "./libraries/AccessManagerAuthLib.sol";
import {AccessManagerEnumerationLib} from "./libraries/AccessManagerEnumerationLib.sol";
import {AccessManagerContractScopedLib} from "./libraries/AccessManagerContractScopedLib.sol";
import {AccessManagerScheduleLib} from "./libraries/AccessManagerScheduleLib.sol";
import {AccessManagerRoleConfigLib} from "./libraries/AccessManagerRoleConfigLib.sol";

/// @title RaylsAccessManagerV1 — Central Authorization for the Rayls Protocol
/// @notice Manages role-based access control across all managed contracts on a single chain.
///         Each Privacy Node and each Private Network Hub deploys its own independent instance.
///
/// @dev Thin facade that delegates all logic to external libraries via delegatecall.
///      See AccessManagerTypes.sol for storage layout, constants, and errors.
///      See libraries/ for the extracted function implementations.
///
/// @custom:security-contact security@raylsnetwork.io
/// @custom:oz-upgrades-unsafe-allow external-library-linking
contract RaylsAccessManagerV1 is Initializable, UUPSUpgradeable, IRaylsAccessManager, RaylsAccessManaged {

    // ─────────────────────────────────────────────────────────────
    //  Constants (public for ABI compatibility)
    // ─────────────────────────────────────────────────────────────

    uint64 public constant ADMIN = 0;
    uint64 public constant PUBLIC = 1;
    uint64 public constant TOKEN_OWNER = 2;
    uint48 public constant EXPIRATION = 7 days;

    // ─────────────────────────────────────────────────────────────
    //  Constructor / Initializer
    // ─────────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialAdmin) external initializer {
        __UUPSUpgradeable_init();
        _initializeAuthority(address(this));

        bytes4[10] memory publicSelectors = [
            this.grantRole.selector,
            this.revokeRole.selector,
            this.grantContractScopedRole.selector,
            this.revokeContractScopedRole.selector,
            this.renounceRole.selector,
            this.selfRegisterManagedContract.selector,
            this.grantSelfTokenOwner.selector,
            this.schedule.selector,
            this.execute.selector,
            this.cancel.selector
        ];

        AccessManagerRoleConfigLib.initializeStorage(
            initialAdmin, address(this), publicSelectors
        );
    }

    // ─────────────────────────────────────────────────────────────
    //  Core Authorization
    // ─────────────────────────────────────────────────────────────

    /// @inheritdoc IRaylsAccessManager
    function canCall(
        address caller,
        address managedContract,
        bytes4 selector
    ) external view returns (bool allowed, uint32 delay, bool paused) {
        return AccessManagerAuthLib.canCall(
            caller, managedContract, selector
        );
    }

    // ─────────────────────────────────────────────────────────────
    //  Role Member Management
    // ─────────────────────────────────────────────────────────────

    /// @inheritdoc IRaylsAccessManager
    function grantRole(uint64 roleId, address account, uint32 executionDelay) external {
        AccessManagerRoleConfigLib.grantRole(roleId, account, executionDelay);
    }

    /// @inheritdoc IRaylsAccessManager
    function revokeRole(uint64 roleId, address account) external {
        AccessManagerRoleConfigLib.revokeRole(roleId, account);
    }

    /// @inheritdoc IRaylsAccessManager
    function renounceRole(uint64 roleId, address callerConfirmation) external {
        AccessManagerRoleConfigLib.renounceRole(roleId, callerConfirmation);
    }

    /// @inheritdoc IRaylsAccessManager
    function hasRole(uint64 roleId, address account) external view returns (bool isMember, uint32 executionDelay) {
        return AccessManagerRoleConfigLib.hasRole(roleId, account);
    }

    // ─────────────────────────────────────────────────────────────
    //  Managed Contract Configuration
    // ─────────────────────────────────────────────────────────────

    /// @inheritdoc IRaylsAccessManager
    function addFunctionAllowedRoles(
        address managedContract, bytes4[] calldata selectors, uint64[] calldata roleIds
    ) external {
        AccessManagerRoleConfigLib.addFunctionAllowedRoles(
            managedContract, selectors, roleIds
        );
    }

    /// @inheritdoc IRaylsAccessManager
    function removeFunctionAllowedRoles(
        address managedContract, bytes4[] calldata selectors, uint64[] calldata roleIds
    ) external {
        AccessManagerRoleConfigLib.removeFunctionAllowedRoles(
            managedContract, selectors, roleIds
        );
    }

    /// @inheritdoc IRaylsAccessManager
    function setContractPaused(address managedContract, bool paused) external {
        AccessManagerRoleConfigLib.setContractPaused(
            managedContract, paused
        );
    }

    /// @inheritdoc IRaylsAccessManager
    function getFunctionAllowedRoles(address managedContract, bytes4 selector) external view returns (uint64[] memory) {
        return AccessManagerEnumerationLib.collectSelectorRoles(managedContract, selector);
    }

    /// @inheritdoc IRaylsAccessManager
    function getFunctionAllowedRolesWithInfo(
        address managedContract, bytes4 selector
    ) external view returns (IRaylsAccessManager.RoleInfo[] memory) {
        return AccessManagerEnumerationLib.getFunctionAllowedRolesWithInfo(
            managedContract, selector
        );
    }

    /// @inheritdoc IRaylsAccessManager
    function isContractPaused(address managedContract) external view returns (bool) {
        return AccessManagerRoleConfigLib.isContractPaused(managedContract);
    }

    // ─────────────────────────────────────────────────────────────
    //  Role Hierarchy
    // ─────────────────────────────────────────────────────────────

    /// @inheritdoc IRaylsAccessManager
    function setRoleAdmin(uint64 roleId, uint64 adminRoleId) external {
        AccessManagerRoleConfigLib.setRoleAdmin(roleId, adminRoleId);
    }

    /// @inheritdoc IRaylsAccessManager
    function setRoleGuardian(uint64 roleId, uint64 guardianRoleId) external {
        AccessManagerRoleConfigLib.setRoleGuardian(roleId, guardianRoleId);
    }

    /// @inheritdoc IRaylsAccessManager
    function setGrantDelay(uint64 roleId, uint32 newDelay) external {
        AccessManagerRoleConfigLib.setGrantDelay(roleId, newDelay);
    }

    /// @inheritdoc IRaylsAccessManager
    function labelRole(uint64 roleId, string calldata label) external {
        AccessManagerRoleConfigLib.labelRole(roleId, label);
    }

    /// @inheritdoc IRaylsAccessManager
    function getRoleLabel(uint64 roleId) external view returns (string memory) {
        return AccessManagerRoleConfigLib.getRoleLabel(roleId);
    }

    /// @inheritdoc IRaylsAccessManager
    function getRoleAdmin(uint64 roleId) external view returns (uint64) {
        return AccessManagerRoleConfigLib.getRoleAdmin(roleId);
    }

    /// @inheritdoc IRaylsAccessManager
    function getRoleGuardian(uint64 roleId) external view returns (uint64) {
        return AccessManagerRoleConfigLib.getRoleGuardian(roleId);
    }

    // ─────────────────────────────────────────────────────────────
    //  Scheduled Operations
    // ─────────────────────────────────────────────────────────────

    /// @inheritdoc IRaylsAccessManager
    function schedule(
        address managedContract, bytes calldata data, uint48 when
    ) external returns (bytes32 operationId) {
        return AccessManagerScheduleLib.schedule(
            managedContract, data, when
        );
    }

    /// @inheritdoc IRaylsAccessManager
    function execute(address managedContract, bytes calldata data) external payable returns (uint32 delay) {
        bytes32 opId = AccessManagerScheduleLib.validateAndConsumeSchedule(
            msg.sender, managedContract, data
        );

        // F01 defense-in-depth: re-verify authorization at execution time.
        // The schedule path now rejects unauthorized callers, but a role can
        // be revoked between schedule and execute. Without this re-check, a
        // schedule recorded under an authorization that was later revoked
        // would still execute via the depth-bypass and effectively retain
        // the lost authority. We also reject paused contracts here so an
        // emergency pause applied between schedule and execute is honored.
        bool allowed;
        bool paused;
        (allowed, delay, paused) = AccessManagerAuthLib.canCall(
            msg.sender, managedContract, bytes4(data[:4])
        );
        if (paused) revert RaylsAccessManagerV1__ContractPaused();
        if (!allowed && delay == 0) revert RaylsAccessManagerV1__Unauthorized(msg.sender);

        // Execute with depth counter so canCall allows the manager's call through.
        AccessManagerStorage storage $ = _getStorage();
        $._executingScheduledOpDepth += 1;
        (bool success, bytes memory returndata) = managedContract.call{value: msg.value}(data);
        $._executingScheduledOpDepth -= 1;

        if (!success) {
            assembly {
                revert(add(returndata, 32), mload(returndata))
            }
        }

        emit OperationExecuted(opId, managedContract);
    }

    /// @inheritdoc IRaylsAccessManager
    function cancel(
        address caller, address managedContract, bytes calldata data
    ) external returns (uint32) {
        return AccessManagerScheduleLib.cancel(caller, managedContract, data);
    }

    /// @inheritdoc IRaylsAccessManager
    function getSchedule(bytes32 operationId) external view returns (uint48 when) {
        return AccessManagerScheduleLib.getSchedule(operationId);
    }

    // ─────────────────────────────────────────────────────────────
    //  Named Role Registry
    // ─────────────────────────────────────────────────────────────

    /// @inheritdoc IRaylsAccessManager
    function registerRole(string calldata name) external returns (uint64 roleId) {
        return AccessManagerRoleConfigLib.registerRole(name);
    }

    /// @inheritdoc IRaylsAccessManager
    function registerRoleAndLabel(string calldata name, string calldata label) external returns (uint64 roleId) {
        return AccessManagerRoleConfigLib.registerRoleAndLabel(name, label);
    }

    /// @inheritdoc IRaylsAccessManager
    function getRoleIdByName(string calldata name) external view returns (uint64) {
        return AccessManagerRoleConfigLib.getRoleIdByName(name);
    }

    /// @inheritdoc IRaylsAccessManager
    function hasRoleByName(string calldata name, address account) external view returns (bool) {
        return AccessManagerRoleConfigLib.hasRoleByName(name, account);
    }

    // ─────────────────────────────────────────────────────────────
    //  Contract-Scoped Grants
    // ─────────────────────────────────────────────────────────────

    /// @inheritdoc IRaylsAccessManager
    function selfRegisterManagedContract(
        address deployer, bytes4[] calldata ownerSelectors,
        IRaylsAccessManager.SelectorRoleMapping[] calldata roleMappings
    ) external {
        AccessManagerContractScopedLib.selfRegisterManagedContract(
            deployer, ownerSelectors, roleMappings
        );
    }

    /// @inheritdoc IRaylsAccessManager
    function grantSelfTokenOwner(address account) external {
        AccessManagerContractScopedLib.grantSelfTokenOwner(account);
    }

    /// @inheritdoc IRaylsAccessManager
    function grantContractScopedRole(
        uint64 roleId, address account, address managedContract, uint32 executionDelay
    ) external {
        AccessManagerContractScopedLib.grantContractScopedRole(
            roleId, account, managedContract, executionDelay
        );
    }

    /// @inheritdoc IRaylsAccessManager
    function revokeContractScopedRole(
        uint64 roleId, address account, address managedContract
    ) external {
        AccessManagerContractScopedLib.revokeContractScopedRole(
            roleId, account, managedContract
        );
    }

    /// @inheritdoc IRaylsAccessManager
    function hasContractScopedRole(
        uint64 roleId, address account, address managedContract
    ) external view returns (bool isMember, uint32 executionDelay) {
        return AccessManagerContractScopedLib.hasContractScopedRole(
            roleId, account, managedContract
        );
    }

    /// @inheritdoc IRaylsAccessManager
    function getContractAuthority(address managedContract) external view returns (address) {
        return AccessManagerContractScopedLib.getContractAuthority(managedContract);
    }

    // ─────────────────────────────────────────────────────────────
    //  Enumeration
    // ─────────────────────────────────────────────────────────────

    /// @inheritdoc IRaylsAccessManager
    function getRegisteredRoleCount() external view returns (uint64) {
        return _getStorage()._nextRoleId;
    }

    /// @inheritdoc IRaylsAccessManager
    function getAccountRoles(address account) external view returns (uint64[] memory) {
        return AccessManagerEnumerationLib.getAccountRoles(account);
    }

    /// @inheritdoc IRaylsAccessManager
    function getAccountContractScopedRoles(
        address account, address managedContract
    ) external view returns (uint64[] memory) {
        return AccessManagerEnumerationLib.getAccountContractScopedRoles(
            account, managedContract
        );
    }

    /// @inheritdoc IRaylsAccessManager
    function getRoleMembers(uint64 roleId) external view returns (address[] memory) {
        return AccessManagerEnumerationLib.getRoleMembers(roleId);
    }

    /// @inheritdoc IRaylsAccessManager
    function getContractScopedRoleMembers(
        uint64 roleId, address managedContract
    ) external view returns (address[] memory) {
        return AccessManagerEnumerationLib.getContractScopedRoleMembers(
            roleId, managedContract
        );
    }

    /// @inheritdoc IRaylsAccessManager
    function getRoleInfo(uint64 roleId) external view returns (IRaylsAccessManager.RoleInfo memory) {
        return AccessManagerEnumerationLib.getRoleInfo(roleId);
    }

    /// @inheritdoc IRaylsAccessManager
    function getRoleInfoBatch(uint64[] calldata roleIds) external view returns (IRaylsAccessManager.RoleInfo[] memory) {
        return AccessManagerEnumerationLib.getRoleInfoBatch(roleIds);
    }

    /// @inheritdoc IRaylsAccessManager
    function getAccountRolesWithInfo(address account) external view returns (IRaylsAccessManager.RoleInfo[] memory) {
        return AccessManagerEnumerationLib.getAccountRolesWithInfo(account);
    }

    /// @inheritdoc IRaylsAccessManager
    function getAllRoles() external view returns (IRaylsAccessManager.RoleInfo[] memory) {
        return AccessManagerEnumerationLib.getAllRoles();
    }

    // ─────────────────────────────────────────────────────────────
    //  UUPS Upgrade Authorization
    // ─────────────────────────────────────────────────────────────

    function upgradeToAndCall(
        address newImplementation, bytes memory data
    ) public payable override {
        super.upgradeToAndCall(newImplementation, data);
    }

    function _authorizeUpgrade(address) internal view override {
        _checkAdmin(_getStorage(), msg.sender);
    }
}
