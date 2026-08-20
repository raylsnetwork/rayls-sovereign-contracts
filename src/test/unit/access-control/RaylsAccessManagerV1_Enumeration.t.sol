// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {IRaylsAccessManager} from "../../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol";
import "../../../privateHub/AccessControl/AccessManagerTypes.sol";

/// @notice Helper contract that calls selfRegisterManagedContract during construction.
contract MockSelfRegistering {
    constructor(address manager, address deployer) {
        bytes4[] memory ownerSels = new bytes4[](1);
        ownerSels[0] = bytes4(keccak256("ownerFn()"));
        IRaylsAccessManager.SelectorRoleMapping[] memory mappings = new IRaylsAccessManager.SelectorRoleMapping[](0);
        IRaylsAccessManager(manager).selfRegisterManagedContract(deployer, ownerSels, mappings);
    }
}

/**
 * @title RaylsAccessManagerV1 Enumeration Tests
 * @notice Tests for getRegisteredRoleCount, getAccountRoles, getAccountContractScopedRoles,
 *         getRoleMembers, getContractScopedRoleMembers, and the role capacity overflow guard.
 */
contract RaylsAccessManagerV1_EnumerationTest is Test {
    RaylsAccessManagerV1 public manager;

    address public admin;
    address public alice;
    address public bob;
    address public carol;

    uint64 constant ADMIN = 0;
    uint64 constant PUBLIC = 1;
    uint64 constant TOKEN_OWNER = 2;

    // ─── Setup ───────────────────────────────────────────────────────────────

    function setUp() public {
        admin = makeAddr("admin");
        alice = makeAddr("alice");
        bob   = makeAddr("bob");
        carol = makeAddr("carol");

        RaylsAccessManagerV1 impl = new RaylsAccessManagerV1();
        bytes memory initData = abi.encodeCall(RaylsAccessManagerV1.initialize, (admin));
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(address(impl), initData)));
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    function _registerRole(string memory name) internal returns (uint64 roleId) {
        vm.prank(admin);
        roleId = manager.registerRole(name);
    }

    function _registerAndGrant(string memory name, address account, uint32 execDelay) internal returns (uint64 roleId) {
        roleId = _registerRole(name);
        vm.prank(admin);
        manager.grantRole(roleId, account, execDelay);
    }

    /// @dev Returns true if `arr` contains `val`.
    function _contains(address[] memory arr, address val) internal pure returns (bool) {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == val) return true;
        }
        return false;
    }

    /// @dev Returns true if `arr` contains `val`.
    function _containsU64(uint64[] memory arr, uint64 val) internal pure returns (bool) {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == val) return true;
        }
        return false;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  getRegisteredRoleCount
    // ═════════════════════════════════════════════════════════════════════════

    function test_getRegisteredRoleCount_afterDeploy_returns3() public view {
        // Well-known roles: ADMIN=0, PUBLIC=1, TOKEN_OWNER=2
        // _nextRoleId starts at 3
        assertEq(manager.getRegisteredRoleCount(), 3);
    }

    function test_getRegisteredRoleCount_afterRegister_increments() public {
        _registerRole("ROLE_A");
        assertEq(manager.getRegisteredRoleCount(), 4);

        _registerRole("ROLE_B");
        assertEq(manager.getRegisteredRoleCount(), 5);

        _registerRole("ROLE_C");
        assertEq(manager.getRegisteredRoleCount(), 6);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  getAccountRoles
    // ═════════════════════════════════════════════════════════════════════════

    function test_getAccountRoles_admin_returnsAdminRole() public view {
        uint64[] memory roles = manager.getAccountRoles(admin);
        assertEq(roles.length, 1);
        assertEq(roles[0], ADMIN);
    }

    function test_getAccountRoles_noRoles_returnsEmpty() public view {
        uint64[] memory roles = manager.getAccountRoles(alice);
        assertEq(roles.length, 0);
    }

    function test_getAccountRoles_multipleRoles_returnsAll() public {
        uint64 roleA = _registerAndGrant("ROLE_A", alice, 0);
        uint64 roleB = _registerAndGrant("ROLE_B", alice, 0);
        uint64 roleC = _registerAndGrant("ROLE_C", alice, 0);

        uint64[] memory roles = manager.getAccountRoles(alice);
        assertEq(roles.length, 3);
        assertTrue(_containsU64(roles, roleA));
        assertTrue(_containsU64(roles, roleB));
        assertTrue(_containsU64(roles, roleC));
    }

    function test_getAccountRoles_afterRevoke_excludesRevoked() public {
        uint64 roleA = _registerAndGrant("ROLE_A", alice, 0);
        uint64 roleB = _registerAndGrant("ROLE_B", alice, 0);
        uint64 roleC = _registerAndGrant("ROLE_C", alice, 0);

        // Revoke roleB
        vm.prank(admin);
        manager.revokeRole(roleB, alice);

        uint64[] memory roles = manager.getAccountRoles(alice);
        assertEq(roles.length, 2);
        assertTrue(_containsU64(roles, roleA));
        assertFalse(_containsU64(roles, roleB));
        assertTrue(_containsU64(roles, roleC));
    }

    function test_getAccountRoles_afterRenounce_excludesRenounced() public {
        uint64 roleA = _registerAndGrant("ROLE_A", alice, 0);
        uint64 roleB = _registerAndGrant("ROLE_B", alice, 0);

        // Alice renounces roleA
        vm.prank(alice);
        manager.renounceRole(roleA, alice);

        uint64[] memory roles = manager.getAccountRoles(alice);
        assertEq(roles.length, 1);
        assertFalse(_containsU64(roles, roleA));
        assertTrue(_containsU64(roles, roleB));
    }

    function test_getAccountRoles_pendingGrant_excludedUntilActive() public {
        // Register role with a grant delay
        vm.startPrank(admin);
        uint64 roleId = manager.registerRole("DELAYED");
        manager.setGrantDelay(roleId, 1 days);
        manager.grantRole(roleId, alice, 0);
        vm.stopPrank();

        // Before delay elapsed — role should NOT appear
        uint64[] memory rolesBefore = manager.getAccountRoles(alice);
        assertEq(rolesBefore.length, 0);

        // After delay elapsed — role should appear
        vm.warp(block.timestamp + 1 days + 1);
        uint64[] memory rolesAfter = manager.getAccountRoles(alice);
        assertEq(rolesAfter.length, 1);
        assertEq(rolesAfter[0], roleId);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  getAccountContractScopedRoles
    // ═════════════════════════════════════════════════════════════════════════

    function test_getAccountContractScopedRoles_noRoles_returnsEmpty() public {
        // Deploy a self-registering contract so managedContract exists
        MockSelfRegistering mock = new MockSelfRegistering(address(manager), alice);

        uint64[] memory roles = manager.getAccountContractScopedRoles(bob, address(mock));
        assertEq(roles.length, 0);
    }

    function test_getAccountContractScopedRoles_afterGrant_returnsRole() public {
        MockSelfRegistering mock = new MockSelfRegistering(address(manager), alice);

        // Register a role and grant it contract-scoped to bob
        uint64 roleId = _registerRole("SCOPED");
        vm.prank(admin);
        manager.grantContractScopedRole(roleId, bob, address(mock), 0);

        uint64[] memory roles = manager.getAccountContractScopedRoles(bob, address(mock));
        assertEq(roles.length, 1);
        assertEq(roles[0], roleId);
    }

    function test_getAccountContractScopedRoles_afterRevoke_excludes() public {
        MockSelfRegistering mock = new MockSelfRegistering(address(manager), alice);

        uint64 roleA = _registerRole("SCOPED_A");
        uint64 roleB = _registerRole("SCOPED_B");

        vm.startPrank(admin);
        manager.grantContractScopedRole(roleA, bob, address(mock), 0);
        manager.grantContractScopedRole(roleB, bob, address(mock), 0);
        vm.stopPrank();

        // Revoke roleA
        vm.prank(admin);
        manager.revokeContractScopedRole(roleA, bob, address(mock));

        uint64[] memory roles = manager.getAccountContractScopedRoles(bob, address(mock));
        assertEq(roles.length, 1);
        assertEq(roles[0], roleB);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  getRoleMembers
    // ═════════════════════════════════════════════════════════════════════════

    function test_getRoleMembers_adminRole_returnsAdmin() public view {
        address[] memory members = manager.getRoleMembers(ADMIN);
        assertEq(members.length, 1);
        assertEq(members[0], admin);
    }

    function test_getRoleMembers_emptyRole_returnsEmpty() public {
        uint64 roleId = _registerRole("EMPTY");

        address[] memory members = manager.getRoleMembers(roleId);
        assertEq(members.length, 0);
    }

    function test_getRoleMembers_afterGrant_includesAccount() public {
        uint64 roleId = _registerAndGrant("GRANTED", alice, 0);

        address[] memory members = manager.getRoleMembers(roleId);
        assertEq(members.length, 1);
        assertEq(members[0], alice);
    }

    function test_getRoleMembers_afterRevoke_excludesAccount() public {
        uint64 roleId = _registerAndGrant("REVOKE", alice, 0);

        vm.prank(admin);
        manager.revokeRole(roleId, alice);

        address[] memory members = manager.getRoleMembers(roleId);
        assertEq(members.length, 0);
    }

    function test_getRoleMembers_multipleMembers_returnsAll() public {
        uint64 roleId = _registerRole("MULTI");

        vm.startPrank(admin);
        manager.grantRole(roleId, alice, 0);
        manager.grantRole(roleId, bob, 0);
        manager.grantRole(roleId, carol, 0);
        vm.stopPrank();

        address[] memory members = manager.getRoleMembers(roleId);
        assertEq(members.length, 3);
        assertTrue(_contains(members, alice));
        assertTrue(_contains(members, bob));
        assertTrue(_contains(members, carol));
    }

    function test_getRoleMembers_afterRenounce_excludesAccount() public {
        uint64 roleId = _registerRole("RENOUNCE");

        vm.startPrank(admin);
        manager.grantRole(roleId, alice, 0);
        manager.grantRole(roleId, bob, 0);
        vm.stopPrank();

        // Alice renounces
        vm.prank(alice);
        manager.renounceRole(roleId, alice);

        address[] memory members = manager.getRoleMembers(roleId);
        assertEq(members.length, 1);
        assertEq(members[0], bob);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  getContractScopedRoleMembers
    // ═════════════════════════════════════════════════════════════════════════

    function test_getContractScopedRoleMembers_afterSelfRegister_returnsDeployer() public {
        MockSelfRegistering mock = new MockSelfRegistering(address(manager), alice);

        address[] memory members = manager.getContractScopedRoleMembers(TOKEN_OWNER, address(mock));
        assertEq(members.length, 1);
        assertEq(members[0], alice);
    }

    function test_getContractScopedRoleMembers_afterGrant_includes() public {
        MockSelfRegistering mock = new MockSelfRegistering(address(manager), alice);

        uint64 roleId = _registerRole("CS_GRANT");

        vm.prank(admin);
        manager.grantContractScopedRole(roleId, bob, address(mock), 0);

        address[] memory members = manager.getContractScopedRoleMembers(roleId, address(mock));
        assertEq(members.length, 1);
        assertEq(members[0], bob);
    }

    function test_getContractScopedRoleMembers_afterRevoke_excludes() public {
        MockSelfRegistering mock = new MockSelfRegistering(address(manager), alice);

        uint64 roleId = _registerRole("CS_REVOKE");

        vm.startPrank(admin);
        manager.grantContractScopedRole(roleId, bob, address(mock), 0);
        manager.grantContractScopedRole(roleId, carol, address(mock), 0);
        vm.stopPrank();

        // Revoke bob
        vm.prank(admin);
        manager.revokeContractScopedRole(roleId, bob, address(mock));

        address[] memory members = manager.getContractScopedRoleMembers(roleId, address(mock));
        assertEq(members.length, 1);
        assertEq(members[0], carol);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Overflow guard: _registerRole reverts at capacity
    // ═════════════════════════════════════════════════════════════════════════

    function test_registerRole_atCapacity_reverts() public {
        // The _nextRoleId lives in the AccessManagerStorage struct.
        // ERC-7201 base slot matching the contract's storage location annotation.
        uint256 baseSlot = uint256(
            keccak256(abi.encode(uint256(keccak256("erc7201:rayls.storage.RaylsAccessManagerV1")) - 1))
            & ~bytes32(uint256(0xff))
        );

        // _nextRoleId is the 5th field in AccessManagerStorage (index 4).
        // Fields before it:
        //   0: _roles          (mapping, 1 slot)
        //   1: _managedContracts (mapping, 1 slot)
        //   2: _schedules      (mapping, 1 slot)
        //   3: _roleNameToId   (mapping, 1 slot)
        //   4: _nextRoleId     (uint64)
        uint256 nextRoleIdSlot = baseSlot + 4;

        // Set _nextRoleId = 65535 — one below capacity
        vm.store(address(manager), bytes32(nextRoleIdSlot), bytes32(uint256(65535)));

        // This should succeed (65535 < 65536)
        vm.prank(admin);
        uint64 roleId = manager.registerRole("LAST");
        assertEq(roleId, 65535);

        // Now _nextRoleId == 65536, next register should revert
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManagerV1__RoleCapacityExceeded.selector));
        manager.registerRole("OVERFLOW");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  getRoleInfo
    // ═══════════════════════════════════════════════════════════════════

    function test_getRoleInfo_adminRole() public view {
        IRaylsAccessManager.RoleInfo memory info = manager.getRoleInfo(0);
        assertEq(info.roleId, 0);
        assertEq(info.adminRole, 0);
        assertEq(info.guardianRole, 0);
        assertEq(info.grantDelay, 0);
        assertEq(info.memberCount, 1); // admin granted during initialize
    }

    function test_getRoleInfo_customRole() public {
        vm.prank(admin);
        uint64 roleId = manager.registerRole("INFO_TEST");
        vm.prank(admin);
        manager.labelRole(roleId, "Info Test Label");
        vm.prank(admin);
        manager.setGrantDelay(roleId, 3600);

        IRaylsAccessManager.RoleInfo memory info = manager.getRoleInfo(roleId);
        assertEq(info.roleId, roleId);
        assertEq(keccak256(bytes(info.label)), keccak256("Info Test Label"));
        assertEq(info.adminRole, 0); // default
        assertEq(info.grantDelay, 3600);
        assertEq(info.memberCount, 0);
    }

    function test_getRoleInfo_memberCountUpdatesOnGrantRevoke() public {
        vm.prank(admin);
        uint64 roleId = manager.registerRole("COUNT_TEST");
        vm.prank(admin);
        manager.grantRole(roleId, alice, 0);
        vm.prank(admin);
        manager.grantRole(roleId, bob, 0);

        assertEq(manager.getRoleInfo(roleId).memberCount, 2);

        vm.prank(admin);
        manager.revokeRole(roleId, alice);

        assertEq(manager.getRoleInfo(roleId).memberCount, 1);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  getRoleInfoBatch
    // ═══════════════════════════════════════════════════════════════════

    function test_getRoleInfoBatch_returnsAllRequested() public {
        vm.prank(admin);
        uint64 r1 = manager.registerRole("BATCH_1");
        vm.prank(admin);
        uint64 r2 = manager.registerRole("BATCH_2");

        uint64[] memory ids = new uint64[](3);
        ids[0] = 0; // ADMIN
        ids[1] = r1;
        ids[2] = r2;

        IRaylsAccessManager.RoleInfo[] memory infos = manager.getRoleInfoBatch(ids);
        assertEq(infos.length, 3);
        assertEq(infos[0].roleId, 0);
        assertEq(infos[1].roleId, r1);
        assertEq(infos[2].roleId, r2);
    }

    function test_getRoleInfoBatch_empty() public view {
        uint64[] memory ids = new uint64[](0);
        IRaylsAccessManager.RoleInfo[] memory infos = manager.getRoleInfoBatch(ids);
        assertEq(infos.length, 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  getAccountRolesWithInfo
    // ═══════════════════════════════════════════════════════════════════

    function test_getAccountRolesWithInfo_admin() public view {
        IRaylsAccessManager.RoleInfo[] memory infos = manager.getAccountRolesWithInfo(admin);
        assertEq(infos.length, 1);
        assertEq(infos[0].roleId, 0);
        assertEq(infos[0].memberCount, 1);
    }

    function test_getAccountRolesWithInfo_multipleRoles() public {
        vm.prank(admin);
        uint64 r1 = manager.registerRole("WITH_INFO_1");
        vm.prank(admin);
        uint64 r2 = manager.registerRole("WITH_INFO_2");
        vm.prank(admin);
        manager.grantRole(r1, alice, 0);
        vm.prank(admin);
        manager.grantRole(r2, alice, 0);

        IRaylsAccessManager.RoleInfo[] memory infos = manager.getAccountRolesWithInfo(alice);
        assertEq(infos.length, 2);
        // Roles come from bitmap iteration — ordered by roleId
        assertEq(infos[0].roleId, r1);
        assertEq(infos[1].roleId, r2);
        assertEq(keccak256(bytes(infos[0].label)), keccak256("WITH_INFO_1"));
        assertEq(keccak256(bytes(infos[1].label)), keccak256("WITH_INFO_2"));
    }

    function test_getAccountRolesWithInfo_noRoles_returnsEmpty() public view {
        IRaylsAccessManager.RoleInfo[] memory infos = manager.getAccountRolesWithInfo(carol);
        assertEq(infos.length, 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  getAllRoles
    // ═══════════════════════════════════════════════════════════════════

    function test_getAllRoles_afterDeploy() public view {
        IRaylsAccessManager.RoleInfo[] memory infos = manager.getAllRoles();
        assertEq(infos.length, 3); // ADMIN, PUBLIC, TOKEN_OWNER
        assertEq(infos[0].roleId, 0);
        assertEq(infos[1].roleId, 1);
        assertEq(infos[2].roleId, 2);
    }

    function test_getAllRoles_afterRegister() public {
        vm.prank(admin);
        manager.registerRole("ALL_ROLES_TEST");

        IRaylsAccessManager.RoleInfo[] memory infos = manager.getAllRoles();
        assertEq(infos.length, 4);
        assertEq(infos[3].roleId, 3);
        assertEq(keccak256(bytes(infos[3].label)), keccak256("ALL_ROLES_TEST"));
    }

    function test_getAllRoles_includesMetadata() public {
        vm.prank(admin);
        uint64 roleId = manager.registerRole("META");
        vm.prank(admin);
        manager.labelRole(roleId, "Meta Label");
        vm.prank(admin);
        manager.grantRole(roleId, alice, 0);
        vm.prank(admin);
        manager.grantRole(roleId, bob, 0);

        IRaylsAccessManager.RoleInfo[] memory infos = manager.getAllRoles();
        IRaylsAccessManager.RoleInfo memory meta = infos[roleId];
        assertEq(keccak256(bytes(meta.label)), keccak256("Meta Label"));
        assertEq(meta.memberCount, 2);
    }
}
