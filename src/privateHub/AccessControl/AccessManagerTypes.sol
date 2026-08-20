// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

// ─────────────────────────────────────────────────────────────
//  Constants
// ─────────────────────────────────────────────────────────────

uint64 constant ADMIN = 0;
uint64 constant PUBLIC = 1;
uint64 constant TOKEN_OWNER = 2;
uint48 constant EXPIRATION = 7 days;

// ─────────────────────────────────────────────────────────────
//  Errors
// ─────────────────────────────────────────────────────────────

error RaylsAccessManagerV1__Unauthorized(address caller);
error RaylsAccessManagerV1__CannotPauseSelf();
error RaylsAccessManagerV1__NotScheduled(bytes32 operationId);
error RaylsAccessManagerV1__NotReady(bytes32 operationId, uint48 readyAt);
error RaylsAccessManagerV1__Expired(bytes32 operationId);
error RaylsAccessManagerV1__AlreadyScheduled(bytes32 operationId);
error RaylsAccessManagerV1__InvalidCaller(address provided, address expected);
error RaylsAccessManagerV1__InvalidInitialAdmin(address admin);
error RaylsAccessManagerV1__RoleNotRegistered(string name);
error RaylsAccessManagerV1__RoleAlreadyRegistered(string name);
error RaylsAccessManagerV1__NotRoleAdmin(address caller, uint64 roleId);
error RaylsAccessManagerV1__NotRoleGuardianOrScheduler(bytes32 operationId);
error RaylsAccessManagerV1__ContractAlreadyRegistered(address managedContract);
error RaylsAccessManagerV1__ContractNotRegistered(address managedContract);
error RaylsAccessManagerV1__PublicRoleCannotBeGranted();
error RaylsAccessManagerV1__TokenOwnerIsScopeOnly();
error RaylsAccessManagerV1__NotContractAuthority(address caller, address managedContract);
error RaylsAccessManagerV1__RoleCapacityExceeded();
error RaylsAccessManagerV1__AdminRoleCannotBeScoped();
error RaylsAccessManagerV1__SelectorTooShort();
error RaylsAccessManagerV1__ZeroAddress();
error RaylsAccessManagerV1__ContractPaused();

// ─────────────────────────────────────────────────────────────
//  Structs
// ─────────────────────────────────────────────────────────────

struct MemberData {
    uint48 activeSince;     // Timestamp when this grant becomes active (0 = not a member)
    uint32 executionDelay;  // Per-member delay before executing restricted functions
}

struct RoleData {
    uint64 adminRole;       // Role ID that can grant/revoke this role
    uint64 guardianRole;    // Role ID that can cancel scheduled ops of this role's members
    uint32 grantDelay;      // Delay before newly granted membership becomes active
    string label;           // Human-readable name (set via labelRole or registerRole)
    mapping(address => MemberData) globalGrants;
    mapping(address => mapping(address => MemberData)) contractScopedGrants; // account -> managed contract -> grant
}

struct ManagedContractConfig {
    bool emergencyPaused;                    // true = ALL restricted functions on this contract are blocked
    address contractAuthority;               // Wallet that can grant/revoke contract-scoped roles
    bool selfRegistered;                     // One-shot flag for selfRegisterManagedContract
    // Two-level bitmap: selector -> allowed roles
    mapping(bytes4 => uint256) allowedRoleSummary;
    mapping(bytes4 => mapping(uint256 => uint256)) allowedRoleSegments;
}

/// @custom:storage-location erc7201:rayls.storage.RaylsAccessManagerV1
struct AccessManagerStorage {
    mapping(uint64 => RoleData) _roles;
    mapping(address => ManagedContractConfig) _managedContracts;
    mapping(bytes32 => uint48) _schedules;      // operationId -> executeAfter timestamp
    mapping(bytes32 => uint64) _roleNameToId;   // keccak256(name) -> roleId
    uint64 _nextRoleId;                         // Auto-increment counter (starts at 3)
    // Two-level bitmap: member -> roles held globally
    mapping(address => uint256) _globalGrantSummary;
    mapping(address => mapping(uint256 => uint256)) _globalGrantSegments;
    // Two-level bitmap: member -> managed contract -> roles held (contract-scoped)
    mapping(address => mapping(address => uint256)) _contractScopedGrantSummary;
    mapping(address => mapping(address => mapping(uint256 => uint256))) _contractScopedGrantSegments;
    // Depth counter set during execute() to allow the manager's call through restricted targets.
    uint256 _executingScheduledOpDepth;
    // Enumerable member tracking: roleId -> set of addresses holding that role.
    mapping(uint64 => EnumerableSet.AddressSet) _globalRoleMembers;
    mapping(uint64 => mapping(address => EnumerableSet.AddressSet)) _contractScopedRoleMembers;
}

// ─────────────────────────────────────────────────────────────
//  Storage Slot & Accessor
// ─────────────────────────────────────────────────────────────

bytes32 constant ACCESS_MANAGER_STORAGE =
    keccak256(abi.encode(uint256(keccak256("erc7201:rayls.storage.RaylsAccessManagerV1")) - 1))
    & ~bytes32(uint256(0xff));

function _getStorage() pure returns (AccessManagerStorage storage $) {
    bytes32 slot = ACCESS_MANAGER_STORAGE;
    /// @solidity memory-safe-assembly
    assembly {
        $.slot := slot
    }
}

// ─────────────────────────────────────────────────────────────
//  Bitmap Helpers
// ─────────────────────────────────────────────────────────────

/// @dev Convert a roleId to its bitmap position: segment index and bit mask.
function _roleIdToBitmap(uint64 roleId) pure returns (uint256 segmentIndex, uint256 bitMask) {
    segmentIndex = uint256(roleId) / 256;
    bitMask = 1 << (uint256(roleId) % 256);
}

/// @dev Return the position (0-255) of the lowest set bit in `x`. Undefined if x == 0.
function _lowestSetBit(uint256 x) pure returns (uint256) {
    uint256 isolated = x & (~x + 1);
    uint256 pos;
    if (isolated >= (1 << 128)) { pos += 128; isolated >>= 128; }
    if (isolated >= (1 << 64))  { pos += 64;  isolated >>= 64;  }
    if (isolated >= (1 << 32))  { pos += 32;  isolated >>= 32;  }
    if (isolated >= (1 << 16))  { pos += 16;  isolated >>= 16;  }
    if (isolated >= (1 << 8))   { pos += 8;   isolated >>= 8;   }
    if (isolated >= (1 << 4))   { pos += 4;   isolated >>= 4;   }
    if (isolated >= (1 << 2))   { pos += 2;   isolated >>= 2;   }
    if (isolated >= (1 << 1))   { pos += 1;                     }
    return pos;
}

// ─────────────────────────────────────────────────────────────
//  Auth Helpers
// ─────────────────────────────────────────────────────────────

/// @dev Revert unless `caller` holds ADMIN.
function _checkAdmin(AccessManagerStorage storage $, address caller) view {
    MemberData storage m = $._roles[ADMIN].globalGrants[caller];
    if (m.activeSince == 0 || m.activeSince > block.timestamp) {
        revert RaylsAccessManagerV1__Unauthorized(caller);
    }
}

/// @dev Revert unless `caller` holds the admin role of `roleId`. ADMIN is super-admin.
function _checkIsRoleAdmin(AccessManagerStorage storage $, address caller, uint64 roleId) view {
    MemberData storage adminMember = $._roles[ADMIN].globalGrants[caller];
    if (adminMember.activeSince != 0 && adminMember.activeSince <= block.timestamp) {
        return;
    }
    uint64 adminRoleId = $._roles[roleId].adminRole;
    if (adminRoleId != ADMIN) {
        MemberData storage m = $._roles[adminRoleId].globalGrants[caller];
        if (m.activeSince != 0 && m.activeSince <= block.timestamp) {
            return;
        }
    }
    revert RaylsAccessManagerV1__NotRoleAdmin(caller, roleId);
}

/// @dev Revert unless `caller` is the contract authority for `managedContract`, or holds ADMIN.
function _checkIsContractAuthority(AccessManagerStorage storage $, address caller, address managedContract) view {
    if ($._managedContracts[managedContract].contractAuthority == caller) return;
    MemberData storage m = $._roles[ADMIN].globalGrants[caller];
    if (m.activeSince != 0 && m.activeSince <= block.timestamp) return;
    revert RaylsAccessManagerV1__NotContractAuthority(caller, managedContract);
}

