// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IRaylsAccessManager
/// @notice Interface for RaylsAccessManagerV1 — adapts the OZ AccessManager data model
///         (role → managed contract → function selector mapping) for Rayls' two-tier topology
///         (Private Network Hub + Privacy Nodes).
///
///         Each chain deploys an independent instance. Roles, managed contracts, and grants
///         are all local to each manager. There is no cross-chain permission dependency.
///
/// @dev Role IDs are uint64. Three well-known roles:
///      - ADMIN          = 0  (global admin; self-administered)
///      - PUBLIC         = 1  (implicit "everyone" role; no grant needed)
///      - TOKEN_OWNER    = 2  (contract-scoped token ownership)
///      Custom roles start at ID 3 (auto-increment via registerRole).
///
///      Default for unmapped selectors is ADMIN (fail-closed).
interface IRaylsAccessManager {
    // ─────────────────────────────────────────────────────────────
    //  Core Authorization
    // ─────────────────────────────────────────────────────────────

    /// @notice Check if `caller` can call `selector` on `managedContract`.
    /// @return allowed True if the call may proceed immediately.
    /// @return delay   Non-zero execution delay the caller must observe via `schedule`/`execute`.
    /// @return paused  True if `managedContract` is emergency-paused.
    function canCall(
        address caller,
        address managedContract,
        bytes4 selector
    ) external view returns (bool allowed, uint32 delay, bool paused);

    // ─────────────────────────────────────────────────────────────
    //  Role Member Management
    // ─────────────────────────────────────────────────────────────

    /// @notice Grant `roleId` to `account` (global grant — applies to all managed contracts).
    ///         Caller must hold the role's admin role.
    /// @param executionDelay Per-member delay (seconds) before restricted calls are allowed.
    ///                       0 = immediate access.
    function grantRole(uint64 roleId, address account, uint32 executionDelay) external;

    /// @notice Revoke `roleId` from `account`. Caller must hold the role's admin role.
    function revokeRole(uint64 roleId, address account) external;

    /// @notice Allow a member to renounce their own role.
    /// @param callerConfirmation Must equal msg.sender to prevent accidental calls.
    function renounceRole(uint64 roleId, address callerConfirmation) external;

    /// @notice Query global role membership.
    /// @return isMember       True if the account holds the role and its grant delay has elapsed.
    /// @return executionDelay The per-member execution delay (0 = immediate).
    function hasRole(
        uint64 roleId,
        address account
    ) external view returns (bool isMember, uint32 executionDelay);

    // ─────────────────────────────────────────────────────────────
    //  Managed Contract Configuration
    // ─────────────────────────────────────────────────────────────

    /// @notice Add `roleIds` to the bitmap of allowed roles for `selectors` on `managedContract`.
    ///         Additive — preserves existing role mappings. Only ADMIN may call this.
    function addFunctionAllowedRoles(
        address managedContract,
        bytes4[] calldata selectors,
        uint64[] calldata roleIds
    ) external;

    /// @notice Remove `roleIds` from the bitmap of allowed roles for `selectors` on `managedContract`.
    ///         Only ADMIN may call this.
    function removeFunctionAllowedRoles(
        address managedContract,
        bytes4[] calldata selectors,
        uint64[] calldata roleIds
    ) external;

    /// @notice Emergency pause / unpause all `restricted` calls on `managedContract`.
    function setContractPaused(address managedContract, bool paused) external;

    /// @notice Query all roles that govern `selector` on `managedContract`.
    ///         Returns empty array for unmapped selectors (fail-closed: only ADMIN can call).
    function getFunctionAllowedRoles(address managedContract, bytes4 selector) external view returns (uint64[] memory);

    /// @notice Query all roles that govern `selector` on `managedContract`, with full metadata.
    function getFunctionAllowedRolesWithInfo(address managedContract, bytes4 selector) external view returns (RoleInfo[] memory);

    /// @notice Check whether `managedContract` is currently paused (all restricted calls blocked).
    function isContractPaused(address managedContract) external view returns (bool);

    // ─────────────────────────────────────────────────────────────
    //  Role Hierarchy
    // ─────────────────────────────────────────────────────────────

    /// @notice Set which role administers (can grant/revoke) `roleId`.
    function setRoleAdmin(uint64 roleId, uint64 adminRoleId) external;

    /// @notice Set which role can cancel scheduled operations of `roleId` members.
    function setRoleGuardian(uint64 roleId, uint64 guardianRoleId) external;

    /// @notice Set the delay between `grantRole` and membership becoming active.
    function setGrantDelay(uint64 roleId, uint32 newDelay) external;

    /// @notice Attach a human-readable label to a role for off-chain tooling.
    function labelRole(uint64 roleId, string calldata label) external;

    /// @notice Get the human-readable label of `roleId`.
    function getRoleLabel(uint64 roleId) external view returns (string memory);

    /// @notice Get the admin role of `roleId`.
    function getRoleAdmin(uint64 roleId) external view returns (uint64);

    /// @notice Get the guardian role of `roleId`.
    function getRoleGuardian(uint64 roleId) external view returns (uint64);

    // ─────────────────────────────────────────────────────────────
    //  Scheduled Operations (for roles with execution delay)
    // ─────────────────────────────────────────────────────────────

    /// @notice Schedule a future call of `data` on `managedContract` for `when` (unix timestamp).
    ///         Pass `when = 0` to let the manager compute `block.timestamp + roleDelay`.
    /// @return operationId keccak256(abi.encode(msg.sender, managedContract, data))
    function schedule(
        address managedContract,
        bytes calldata data,
        uint48 when
    ) external returns (bytes32 operationId);

    /// @notice Execute a previously scheduled operation after its delay has elapsed.
    /// @return delay The execution delay that was applied.
    function execute(address managedContract, bytes calldata data) external payable returns (uint32 delay);

    /// @notice Cancel a scheduled operation.
    ///         Caller must be the original scheduler OR hold the guardian role of the
    ///         role that scheduled the operation.
    function cancel(
        address caller,
        address managedContract,
        bytes calldata data
    ) external returns (uint32 delay);

    /// @notice Query when a scheduled operation can be executed.
    /// @return when The earliest execution timestamp (0 if not scheduled or already executed).
    function getSchedule(bytes32 operationId) external view returns (uint48 when);

    // ─────────────────────────────────────────────────────────────
    //  Rayls Extension: Named Role Registry
    // ─────────────────────────────────────────────────────────────

    /// @notice Register a new named role, auto-assigning the next uint64 ID (starts at 3).
    ///         Caller must hold ADMIN.
    ///         Roles cannot be deleted once registered. To deactivate a role, revoke all
    ///         members and remove it from function mappings — but the ID remains allocated.
    /// @return roleId The assigned role ID.
    function registerRole(string calldata name) external returns (uint64 roleId);

    /// @notice Register a new named role with a custom human-readable label.
    function registerRoleAndLabel(string calldata name, string calldata label) external returns (uint64 roleId);

    /// @notice Look up a role ID by its registered name.
    function getRoleIdByName(string calldata name) external view returns (uint64);

    /// @notice Convenience: check role membership by name.
    function hasRoleByName(string calldata name, address account) external view returns (bool);

    // ─────────────────────────────────────────────────────────────
    //  Contract-Scoped Grants
    // ─────────────────────────────────────────────────────────────

    /// @notice Maps a set of function selectors to a named role for selfRegisterManagedContract.
    struct SelectorRoleMapping {
        string roleName;       // Looked up via named role registry
        bytes4[] selectors;    // Function selectors to map to this role
    }

    /// @notice Permissionless self-registration for newly deployed managed contracts.
    ///         `msg.sender` is the managed contract. One-shot: cannot re-register.
    /// @param deployer The address that deployed the contract (becomes contract authority).
    /// @param ownerSelectors Function selectors mapped to TOKEN_OWNER.
    /// @param roleMappings Generic role mappings — each entry maps selectors to a named role.
    function selfRegisterManagedContract(
        address deployer,
        bytes4[] calldata ownerSelectors,
        SelectorRoleMapping[] calldata roleMappings
    ) external;

    /// @notice Grant TOKEN_OWNER scoped to `msg.sender` for `account`. Callable only by an
    ///         already self-registered managed contract. Does not change the contract authority.
    /// @param account The address receiving TOKEN_OWNER scoped to the calling contract.
    function grantSelfTokenOwner(address account) external;

    /// @notice Grant `roleId` to `account` scoped to `managedContract`.
    ///         Caller must be the contract's authority or hold ADMIN.
    /// @param roleId The role to grant.
    /// @param account The address receiving the role.
    /// @param managedContract The managed contract this grant is scoped to.
    /// @param executionDelay Per-member delay (0 = immediate).
    function grantContractScopedRole(
        uint64 roleId,
        address account,
        address managedContract,
        uint32 executionDelay
    ) external;

    /// @notice Revoke `roleId` from `account` scoped to `managedContract`.
    ///         Caller must be the contract's authority or hold ADMIN.
    function revokeContractScopedRole(
        uint64 roleId,
        address account,
        address managedContract
    ) external;

    /// @notice Query contract-scoped role membership.
    /// @return isMember True if account holds roleId scoped to managedContract and grant delay elapsed.
    /// @return executionDelay The per-member execution delay.
    function hasContractScopedRole(
        uint64 roleId,
        address account,
        address managedContract
    ) external view returns (bool isMember, uint32 executionDelay);

    /// @notice Query the authority address for a given managed contract.
    function getContractAuthority(address managedContract) external view returns (address);

    // ─────────────────────────────────────────────────────────────
    //  Enumeration
    // ─────────────────────────────────────────────────────────────

    /// @notice Returns the total number of role IDs allocated (including well-known roles).
    ///         Valid role IDs are `0 .. getRegisteredRoleCount() - 1`.
    function getRegisteredRoleCount() external view returns (uint64);

    /// @notice Returns all global roles currently held by `account`.
    ///         Only returns roles whose grant is active (`activeSince <= block.timestamp`).
    function getAccountRoles(address account) external view returns (uint64[] memory roleIds);

    /// @notice Returns all contract-scoped roles held by `account` on `managedContract`.
    ///         Only returns roles whose grant is active (`activeSince <= block.timestamp`).
    function getAccountContractScopedRoles(
        address account,
        address managedContract
    ) external view returns (uint64[] memory roleIds);

    /// @notice Returns all addresses that hold `roleId` globally.
    function getRoleMembers(uint64 roleId) external view returns (address[] memory);

    /// @notice Returns all addresses that hold `roleId` scoped to `managedContract`.
    function getContractScopedRoleMembers(
        uint64 roleId,
        address managedContract
    ) external view returns (address[] memory);

    /// @notice Rich metadata for a single role, returned by the getRoleInfo family of functions.
    struct RoleInfo {
        uint64 roleId;
        string label;
        uint64 adminRole;
        uint64 guardianRole;
        uint32 grantDelay;
        uint256 memberCount;
    }

    /// @notice Returns metadata for a single role.
    function getRoleInfo(uint64 roleId) external view returns (RoleInfo memory);

    /// @notice Returns metadata for multiple roles in a single call.
    function getRoleInfoBatch(uint64[] calldata roleIds) external view returns (RoleInfo[] memory);

    /// @notice Convenience: returns metadata for all global roles held by `account`.
    ///         Equivalent to `getRoleInfoBatch(getAccountRoles(account))` but in one call.
    function getAccountRolesWithInfo(address account) external view returns (RoleInfo[] memory);

    /// @notice Returns metadata for ALL registered roles (IDs 0 through getRegisteredRoleCount()-1).
    function getAllRoles() external view returns (RoleInfo[] memory);

    // ─────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────

    event RoleGranted(
        uint64 indexed roleId,
        address indexed account,
        uint32 executionDelay,
        uint48 activeSince,
        address indexed grantor
    );
    event RoleRevoked(
        uint64 indexed roleId,
        address indexed account,
        address indexed revoker
    );
    event RoleAdminChanged(uint64 indexed roleId, uint64 indexed newAdmin);
    event RoleGuardianChanged(uint64 indexed roleId, uint64 indexed newGuardian);
    event RoleGrantDelayChanged(uint64 indexed roleId, uint32 newDelay);
    event RoleLabelSet(uint64 indexed roleId, string label);
    event RoleRegistered(uint64 indexed roleId, string name);
    event FunctionAllowedRoleAdded(
        address indexed managedContract,
        bytes4 indexed selector,
        uint64 indexed roleId
    );
    event FunctionAllowedRoleRemoved(
        address indexed managedContract,
        bytes4 indexed selector,
        uint64 indexed roleId
    );
    event ContractPauseUpdated(address indexed managedContract, bool paused);
    event OperationScheduled(
        bytes32 indexed operationId,
        address indexed caller,
        address indexed managedContract,
        uint48 executeAfter
    );
    event OperationExecuted(bytes32 indexed operationId, address indexed managedContract);
    event OperationCanceled(bytes32 indexed operationId);
    event ManagedContractRegistered(address indexed managedContract, address indexed contractAuthority);
    event ContractScopedRoleGranted(
        uint64 indexed roleId,
        address indexed account,
        address indexed managedContract,
        uint32 executionDelay,
        uint48 activeSince,
        address grantor
    );
    event ContractScopedRoleRevoked(
        uint64 indexed roleId,
        address indexed account,
        address indexed managedContract,
        address revoker
    );
}
