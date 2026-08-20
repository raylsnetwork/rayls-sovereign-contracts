// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {IRaylsAccessManager} from "../../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol";
import "../../../privateHub/AccessControl/AccessManagerTypes.sol";

/// @notice Helper: a no-op callable target for schedule/execute tests.
contract CallTarget {
    uint256 public callCount;
    function ping() external { callCount++; }
}

/**
 * @title RaylsAccessManagerV1 Unit Tests
 * @notice Exhaustive coverage of the access manager: initialization, canCall, role management,
 *         target configuration, role hierarchy, scheduled operations, and named role registry.
 */
contract RaylsAccessManagerV1Test is Test {
    RaylsAccessManagerV1 public manager;

    address public admin;
    address public alice;
    address public bob;
    address public attacker;
    address public target;

    uint64 constant ADMIN = 0;
    uint64 constant PUBLIC = 1;

    function _singleRole(uint64 roleId) internal pure returns (uint64[] memory roles) {
        roles = new uint64[](1);
        roles[0] = roleId;
    }

    // ─── Setup ───────────────────────────────────────────────────────────────

    function setUp() public {
        admin    = makeAddr("admin");
        alice    = makeAddr("alice");
        bob      = makeAddr("bob");
        attacker = makeAddr("attacker");
        target   = makeAddr("target");

        RaylsAccessManagerV1 impl = new RaylsAccessManagerV1();
        bytes memory initData = abi.encodeCall(RaylsAccessManagerV1.initialize, (admin));
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(address(impl), initData)));
    }

    // ─── initialize ──────────────────────────────────────────────────────────

    function test_initialize_adminHasAdminRole() public view {
        (bool isMember,) = manager.hasRole(ADMIN, admin);
        assertTrue(isMember);
    }

    function test_initialize_nonAdminDoesNotHaveAdminRole() public view {
        (bool isMember,) = manager.hasRole(ADMIN, attacker);
        assertFalse(isMember);
    }

    function test_initialize_revertsOnZeroAdmin() public {
        RaylsAccessManagerV1 impl = new RaylsAccessManagerV1();
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManagerV1__InvalidInitialAdmin.selector, address(0)));
        new ERC1967Proxy(address(impl), abi.encodeCall(RaylsAccessManagerV1.initialize, (address(0))));
    }

    // ─── canCall — closed target ──────────────────────────────────────────────

    function test_canCall_closedTarget_returnsFalse() public {
        vm.prank(admin);
        manager.setContractPaused(target, true);

        (bool allowed, uint32 delay,) = manager.canCall(admin, target, bytes4(0xdeadbeef));
        assertFalse(allowed);
        assertEq(delay, 0);
    }

    // ─── canCall — PUBLIC ────────────────────────────────────────────────

    function test_canCall_publicRole_anyoneAllowed() public {
        bytes4 sel = bytes4(keccak256("publicFn()"));
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = sel;

        vm.prank(admin);
        manager.addFunctionAllowedRoles(target, sels, _singleRole(PUBLIC));

        (bool allowed, uint32 delay,) = manager.canCall(attacker, target, sel);
        assertTrue(allowed);
        assertEq(delay, 0);
    }

    // ─── canCall — unmapped selector (fail-closed = ADMIN) ─────────────

    function test_canCall_unmappedSelector_nonAdmin_denied() public view {
        (bool allowed,,) = manager.canCall(attacker, target, bytes4(0xabcd1234));
        assertFalse(allowed);
    }

    function test_canCall_unmappedSelector_admin_allowed() public view {
        (bool allowed, uint32 delay,) = manager.canCall(admin, target, bytes4(0xabcd1234));
        assertTrue(allowed);
        assertEq(delay, 0);
    }

    // ─── canCall — specific role membership ──────────────────────────────────

    function test_canCall_specificRole_memberAllowed() public {
        uint64 roleId = _registerAndGrant("OP", alice, 0);
        bytes4 sel = bytes4(keccak256("op()"));
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = sel;

        vm.prank(admin);
        manager.addFunctionAllowedRoles(target, sels, _singleRole(roleId));

        (bool allowed, uint32 delay,) = manager.canCall(alice, target, sel);
        assertTrue(allowed);
        assertEq(delay, 0);
    }

    function test_canCall_specificRole_nonMemberDenied() public {
        uint64 roleId = _registerAndGrant("OP", alice, 0);
        bytes4 sel = bytes4(keccak256("op()"));
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = sel;

        vm.prank(admin);
        manager.addFunctionAllowedRoles(target, sels, _singleRole(roleId));

        (bool allowed,,) = manager.canCall(bob, target, sel);
        assertFalse(allowed);
    }

    // ─── canCall — execution delay ────────────────────────────────────────────

    function test_canCall_executionDelay_returnsFalseWithDelay() public {
        uint32 execDelay = 3600;
        uint64 roleId = _registerAndGrant("DELAYED", alice, execDelay);
        bytes4 sel = bytes4(keccak256("delayed()"));
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = sel;

        vm.prank(admin);
        manager.addFunctionAllowedRoles(target, sels, _singleRole(roleId));

        (bool allowed, uint32 delay,) = manager.canCall(alice, target, sel);
        assertFalse(allowed);
        assertEq(delay, execDelay);
    }

    // ─── canCall — grant delay ────────────────────────────────────────────────

    function test_canCall_grantDelay_pendingMembership_denied() public {
        uint64 roleId;
        {
            vm.startPrank(admin);
            roleId = manager.registerRole("DELAYED_GRANT");
            manager.setGrantDelay(roleId, 1 days);
            manager.grantRole(roleId, alice, 0);
            vm.stopPrank();
        }

        bytes4 sel = bytes4(keccak256("fn()"));
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = sel;
        vm.prank(admin);
        manager.addFunctionAllowedRoles(target, sels, _singleRole(roleId));

        // Before delay elapsed
        (bool allowed,,) = manager.canCall(alice, target, sel);
        assertFalse(allowed);

        // After delay elapsed
        vm.warp(block.timestamp + 1 days + 1);
        (allowed,,) = manager.canCall(alice, target, sel);
        assertTrue(allowed);
    }

    // ─── grantRole ────────────────────────────────────────────────────────────

    function test_grantRole_nonAdmin_reverts() public {
        uint64 roleId = _registerRole("MY");

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManagerV1__NotRoleAdmin.selector, attacker, roleId));
        manager.grantRole(roleId, alice, 0);
    }

    function test_grantRole_admin_succeeds() public {
        uint64 roleId = _registerRole("MY");

        vm.prank(admin);
        manager.grantRole(roleId, alice, 0);

        (bool isMember,) = manager.hasRole(roleId, alice);
        assertTrue(isMember);
    }

    function test_grantRole_emitsRoleGranted() public {
        uint64 roleId = _registerRole("MY");

        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit IRaylsAccessManager.RoleGranted(roleId, alice, 0, 0, admin);
        manager.grantRole(roleId, alice, 0);
    }

    // ─── revokeRole ───────────────────────────────────────────────────────────

    function test_revokeRole_nonAdmin_reverts() public {
        uint64 roleId = _registerAndGrant("REVOKE", alice, 0);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManagerV1__NotRoleAdmin.selector, attacker, roleId));
        manager.revokeRole(roleId, alice);
    }

    function test_revokeRole_admin_removesRole() public {
        uint64 roleId = _registerAndGrant("REVOKE", alice, 0);

        vm.prank(admin);
        manager.revokeRole(roleId, alice);

        (bool isMember,) = manager.hasRole(roleId, alice);
        assertFalse(isMember);
    }

    function test_revokeRole_emitsRoleRevoked() public {
        uint64 roleId = _registerAndGrant("REVOKE", alice, 0);

        vm.prank(admin);
        vm.expectEmit(true, true, true, false);
        emit IRaylsAccessManager.RoleRevoked(roleId, alice, admin);
        manager.revokeRole(roleId, alice);
    }

    // ─── renounceRole ─────────────────────────────────────────────────────────

    function test_renounceRole_wrongConfirmation_reverts() public {
        uint64 roleId = _registerAndGrant("RENOUNCE", alice, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManagerV1__InvalidCaller.selector, bob, alice));
        manager.renounceRole(roleId, bob); // wrong confirmation
    }

    function test_renounceRole_correctConfirmation_succeeds() public {
        uint64 roleId = _registerAndGrant("RENOUNCE", alice, 0);

        vm.prank(alice);
        manager.renounceRole(roleId, alice);

        (bool isMember,) = manager.hasRole(roleId, alice);
        assertFalse(isMember);
    }

    // ─── hasRole ──────────────────────────────────────────────────────────────

    function test_hasRole_memberReturnsTrue() public {
        uint64 roleId = _registerAndGrant("HR", alice, 500);
        (bool isMember, uint32 execDelay) = manager.hasRole(roleId, alice);
        assertTrue(isMember);
        assertEq(execDelay, 500);
    }

    function test_hasRole_nonMemberReturnsFalse() public {
        uint64 roleId = _registerRole("HR");
        (bool isMember,) = manager.hasRole(roleId, attacker);
        assertFalse(isMember);
    }

    // ─── addFunctionAllowedRoles ────────────────────────────────────────────────

    function test_addFunctionAllowedRoles_nonAdmin_reverts() public {
        uint64 roleId = _registerRole("TFR");
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = bytes4(0x12345678);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManagerV1__Unauthorized.selector, attacker));
        manager.addFunctionAllowedRoles(target, sels, _singleRole(roleId));
    }

    function test_addFunctionAllowedRoles_admin_mapsSelector() public {
        uint64 roleId = _registerRole("TFR");
        bytes4 sel = bytes4(0x12345678);
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = sel;

        vm.prank(admin);
        manager.addFunctionAllowedRoles(target, sels, _singleRole(roleId));

        uint64[] memory roles = manager.getFunctionAllowedRoles(target, sel);
        assertEq(roles.length, 1);
        assertEq(roles[0], roleId);
    }

    function test_addFunctionAllowedRoles_emitsEvent() public {
        uint64 roleId = _registerRole("TFR");
        bytes4 sel = bytes4(0xaabbccdd);
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = sel;

        vm.prank(admin);
        vm.expectEmit(true, true, true, false);
        emit IRaylsAccessManager.FunctionAllowedRoleAdded(target, sel, roleId);
        manager.addFunctionAllowedRoles(target, sels, _singleRole(roleId));
    }

    // ─── setContractPaused ──────────────────────────────────────────────────────

    function test_setContractPaused_nonAdmin_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManagerV1__Unauthorized.selector, attacker));
        manager.setContractPaused(target, true);
    }

    function test_setContractPaused_admin_closesAndOpens() public {
        vm.prank(admin);
        manager.setContractPaused(target, true);
        assertTrue(manager.isContractPaused(target));

        vm.prank(admin);
        manager.setContractPaused(target, false);
        assertFalse(manager.isContractPaused(target));
    }

    // ─── Role hierarchy ───────────────────────────────────────────────────────

    function test_setRoleAdmin_nonAdmin_reverts() public {
        uint64 roleId = _registerRole("R1");
        uint64 newAdmin = _registerRole("R2");

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManagerV1__Unauthorized.selector, attacker));
        manager.setRoleAdmin(roleId, newAdmin);
    }

    function test_setRoleAdmin_admin_updates() public {
        uint64 roleId = _registerRole("R1");
        uint64 newAdmin = _registerRole("R2");

        vm.prank(admin);
        manager.setRoleAdmin(roleId, newAdmin);
        assertEq(manager.getRoleAdmin(roleId), newAdmin);
    }

    function test_adminCanGrantRole_afterSetRoleAdmin() public {
        uint64 roleId = _registerRole("R1");
        uint64 newAdmin = _registerRole("R2");

        // Change admin of R1 to R2
        vm.prank(admin);
        manager.setRoleAdmin(roleId, newAdmin);
        assertEq(manager.getRoleAdmin(roleId), newAdmin);

        // ADMIN holder can still grant R1 even though R1's admin is now R2
        vm.prank(admin);
        manager.grantRole(roleId, alice, 0);

        (bool isMember,) = manager.hasRole(roleId, alice);
        assertTrue(isMember, "admin should be able to grant any role regardless of roleAdmin");
    }

    function test_adminCanRevokeRole_afterSetRoleAdmin() public {
        uint64 roleId = _registerRole("R1");

        // Grant first
        vm.prank(admin);
        manager.grantRole(roleId, alice, 0);

        // Change admin of R1 to a different role
        uint64 newAdmin = _registerRole("R2");
        vm.prank(admin);
        manager.setRoleAdmin(roleId, newAdmin);

        // ADMIN holder can still revoke R1
        vm.prank(admin);
        manager.revokeRole(roleId, alice);

        (bool isMember,) = manager.hasRole(roleId, alice);
        assertFalse(isMember, "admin should be able to revoke any role regardless of roleAdmin");
    }

    function test_delegatedAdmin_canGrantRole_afterSetRoleAdmin() public {
        uint64 roleId = _registerRole("R1");
        uint64 newAdmin = _registerRole("R2");

        // Grant R2 to bob so he becomes the delegated admin
        vm.prank(admin);
        manager.grantRole(newAdmin, bob, 0);

        // Change admin of R1 to R2
        vm.prank(admin);
        manager.setRoleAdmin(roleId, newAdmin);

        // bob (R2 member) can grant R1
        vm.prank(bob);
        manager.grantRole(roleId, alice, 0);

        (bool isMember,) = manager.hasRole(roleId, alice);
        assertTrue(isMember, "delegated admin should be able to grant the role");
    }

    function test_nonAdmin_cannotGrantRole_afterSetRoleAdmin() public {
        uint64 roleId = _registerRole("R1");
        uint64 newAdmin = _registerRole("R2");

        // Change admin of R1 to R2
        vm.prank(admin);
        manager.setRoleAdmin(roleId, newAdmin);

        // attacker (neither ADMIN nor R2) cannot grant R1
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManagerV1__NotRoleAdmin.selector, attacker, roleId));
        manager.grantRole(roleId, alice, 0);
    }

    function test_setRoleGuardian_admin_updates() public {
        uint64 roleId = _registerRole("R1");
        uint64 guardian = _registerRole("G1");

        vm.prank(admin);
        manager.setRoleGuardian(roleId, guardian);
        assertEq(manager.getRoleGuardian(roleId), guardian);
    }

    function test_setGrantDelay_admin_updates() public {
        uint64 roleId = _registerRole("GD");

        vm.prank(admin);
        manager.setGrantDelay(roleId, 3600);

        vm.expectEmit(true, false, false, true);
        emit IRaylsAccessManager.RoleGrantDelayChanged(roleId, 7200);
        vm.prank(admin);
        manager.setGrantDelay(roleId, 7200);
    }

    function test_labelRole_admin_setsLabel() public {
        uint64 roleId = _registerRole("LABEL");

        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit IRaylsAccessManager.RoleLabelSet(roleId, "New Label");
        manager.labelRole(roleId, "New Label");
    }

    // ─── Named Role Registry ─────────────────────────────────────────────────

    function test_registerRole_nonAdmin_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManagerV1__Unauthorized.selector, attacker));
        manager.registerRole("MY");
    }

    function test_registerRole_admin_incrementsId() public {
        vm.startPrank(admin);
        uint64 id1 = manager.registerRole("ROLE_A");
        uint64 id2 = manager.registerRole("ROLE_B");
        vm.stopPrank();

        assertEq(id1, 3);
        assertEq(id2, 4);
    }

    function test_registerRole_duplicate_reverts() public {
        vm.prank(admin);
        manager.registerRole("DUP");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManagerV1__RoleAlreadyRegistered.selector, "DUP"));
        manager.registerRole("DUP");
    }

    function test_getRoleIdByName_notRegistered_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManagerV1__RoleNotRegistered.selector, "GHOST"));
        manager.getRoleIdByName("GHOST");
    }

    function test_getRoleIdByName_registered_returnsId() public {
        vm.prank(admin);
        uint64 id = manager.registerRole("NAMED");

        assertEq(manager.getRoleIdByName("NAMED"), id);
    }

    function test_hasRoleByName_memberReturnsTrue() public {
        uint64 id = _registerAndGrant("HRN", alice, 0);
        (id); // suppress warning
        assertTrue(manager.hasRoleByName("HRN", alice));
    }

    function test_hasRoleByName_nonMemberReturnsFalse() public {
        _registerRole("HRN2");
        assertFalse(manager.hasRoleByName("HRN2", attacker));
    }

    function test_hasRoleByName_unregisteredReturnsFalse() public view {
        assertFalse(manager.hasRoleByName("DOES_NOT_EXIST", attacker));
    }

    // ─── Scheduled Operations ────────────────────────────────────────────────

    function test_schedule_storesOperation() public {
        // Give alice a role with executionDelay
        uint32 execDelay = 1 hours;
        uint64 roleId = _registerAndGrant("SCHED", alice, execDelay);

        CallTarget ct = new CallTarget();
        bytes4 sel = CallTarget.ping.selector;
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = sel;
        vm.prank(admin);
        manager.addFunctionAllowedRoles(address(ct), sels, _singleRole(roleId));

        bytes memory data = abi.encodeCall(ct.ping, ());
        vm.prank(alice);
        bytes32 opId = manager.schedule(address(ct), data, 0);

        uint48 when = manager.getSchedule(opId);
        assertGt(when, 0);
    }

    function test_schedule_alreadyScheduled_reverts() public {
        uint32 execDelay = 1 hours;
        uint64 roleId = _registerAndGrant("SCHED2", alice, execDelay);

        CallTarget ct = new CallTarget();
        bytes4 sel = CallTarget.ping.selector;
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = sel;
        vm.prank(admin);
        manager.addFunctionAllowedRoles(address(ct), sels, _singleRole(roleId));

        bytes memory data = abi.encodeCall(ct.ping, ());
        vm.prank(alice);
        bytes32 opId = manager.schedule(address(ct), data, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManagerV1__AlreadyScheduled.selector, opId));
        manager.schedule(address(ct), data, 0);
    }

    function test_execute_notScheduled_reverts() public {
        bytes32 fakeOpId = keccak256(abi.encode(alice, target, hex"12345678"));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManagerV1__NotScheduled.selector, fakeOpId));
        manager.execute(target, hex"12345678");
    }

    function test_execute_notReady_reverts() public {
        uint32 execDelay = 1 hours;
        uint64 roleId = _registerAndGrant("EXEC", alice, execDelay);

        CallTarget ct = new CallTarget();
        bytes4 sel = CallTarget.ping.selector;
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = sel;
        vm.prank(admin);
        manager.addFunctionAllowedRoles(address(ct), sels, _singleRole(roleId));

        bytes memory data = abi.encodeCall(ct.ping, ());
        vm.prank(alice);
        bytes32 opId = manager.schedule(address(ct), data, 0);
        uint48 readyAt = manager.getSchedule(opId);

        // Try to execute before ready
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManagerV1__NotReady.selector, opId, readyAt));
        manager.execute(address(ct), data);
    }

    function test_execute_afterDelay_succeeds() public {
        uint32 execDelay = 1 hours;
        uint64 roleId = _registerAndGrant("EXEC2", alice, execDelay);

        CallTarget ct = new CallTarget();
        bytes4 sel = CallTarget.ping.selector;
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = sel;
        vm.prank(admin);
        manager.addFunctionAllowedRoles(address(ct), sels, _singleRole(roleId));

        bytes memory data = abi.encodeCall(ct.ping, ());
        vm.prank(alice);
        manager.schedule(address(ct), data, 0);

        vm.warp(block.timestamp + execDelay + 1);

        vm.prank(alice);
        manager.execute(address(ct), data);

        assertEq(ct.callCount(), 1);
        // Schedule should be cleared
        bytes32 opId = keccak256(abi.encode(alice, address(ct), data));
        assertEq(manager.getSchedule(opId), 0);
    }

    function test_execute_expired_reverts() public {
        uint32 execDelay = 1 hours;
        uint64 roleId = _registerAndGrant("EXEC3", alice, execDelay);

        CallTarget ct = new CallTarget();
        bytes4 sel = CallTarget.ping.selector;
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = sel;
        vm.prank(admin);
        manager.addFunctionAllowedRoles(address(ct), sels, _singleRole(roleId));

        bytes memory data = abi.encodeCall(ct.ping, ());
        vm.prank(alice);
        bytes32 opId = manager.schedule(address(ct), data, 0);

        // Warp past EXPIRATION (7 days) after ready
        vm.warp(block.timestamp + execDelay + 7 days + 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManagerV1__Expired.selector, opId));
        manager.execute(address(ct), data);
    }

    function test_cancel_byScheduler_succeeds() public {
        uint32 execDelay = 1 hours;
        uint64 roleId = _registerAndGrant("CANCEL", alice, execDelay);

        CallTarget ct = new CallTarget();
        bytes4 sel = CallTarget.ping.selector;
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = sel;
        vm.prank(admin);
        manager.addFunctionAllowedRoles(address(ct), sels, _singleRole(roleId));

        bytes memory data = abi.encodeCall(ct.ping, ());
        vm.prank(alice);
        bytes32 opId = manager.schedule(address(ct), data, 0);

        vm.prank(alice); // alice is the scheduler
        manager.cancel(alice, address(ct), data);

        assertEq(manager.getSchedule(opId), 0);
    }

    function test_cancel_notScheduler_notGuardian_reverts() public {
        uint32 execDelay = 1 hours;
        uint64 roleId = _registerAndGrant("CANCEL2", alice, execDelay);

        CallTarget ct = new CallTarget();
        bytes4 sel = CallTarget.ping.selector;
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = sel;
        vm.prank(admin);
        manager.addFunctionAllowedRoles(address(ct), sels, _singleRole(roleId));

        bytes memory data = abi.encodeCall(ct.ping, ());
        vm.prank(alice);
        bytes32 opId = manager.schedule(address(ct), data, 0);
        (opId);

        vm.prank(bob); // not scheduler, not guardian
        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManagerV1__NotRoleGuardianOrScheduler.selector,
            keccak256(abi.encode(alice, address(ct), data))
        ));
        manager.cancel(alice, address(ct), data);
    }

    function test_cancel_notScheduled_reverts() public {
        bytes memory data = abi.encodeCall(CallTarget.ping, ());
        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManagerV1__NotScheduled.selector,
            keccak256(abi.encode(alice, target, data))
        ));
        manager.cancel(alice, target, data);
    }

    function test_cancel_byAdmin_succeeds() public {
        uint32 execDelay = 1 hours;
        uint64 roleId = _registerAndGrant("CANCEL_ADMIN", alice, execDelay);

        CallTarget ct = new CallTarget();
        bytes4 sel = CallTarget.ping.selector;
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = sel;
        vm.prank(admin);
        manager.addFunctionAllowedRoles(address(ct), sels, _singleRole(roleId));

        bytes memory data = abi.encodeCall(ct.ping, ());
        vm.prank(alice);
        bytes32 opId = manager.schedule(address(ct), data, 0);

        // admin is neither the scheduler nor a guardian, but ADMIN is super admin
        vm.prank(admin);
        manager.cancel(alice, address(ct), data);

        assertEq(manager.getSchedule(opId), 0, "admin should be able to cancel any scheduled operation");
    }

    // ─── Admin role — self-administration ────────────────────────────────────

    function test_adminCanGrantAdminRoleToOthers() public {
        vm.prank(admin);
        manager.grantRole(ADMIN, alice, 0);

        (bool isMember,) = manager.hasRole(ADMIN, alice);
        assertTrue(isMember);
    }

    function test_newAdmin_canCallAdminFunctions() public {
        vm.prank(admin);
        manager.grantRole(ADMIN, alice, 0);

        vm.prank(alice);
        manager.registerRole("ALICE"); // should not revert
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
}
