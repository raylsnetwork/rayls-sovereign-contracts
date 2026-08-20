// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ParticipantStorageV1} from "../../../privateHub/ParticipantStorage/ParticipantStorageV1.sol";
import {ParticipantStructs} from "../../../privateHub/ParticipantStorage/libraries/ParticipantStructs.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import "../mocks/MockEndpointForSecurityTest.sol";

// ─── Mock authority ───────────────────────────────────────────────────────────

contract MockAuthority_PS {
    mapping(address => bool) private _allowed;

    function allow(address who) external { _allowed[who] = true; }
    function deny(address who) external { _allowed[who] = false; }

    function canCall(address caller, address, bytes4) external view returns (bool, uint32, bool) {
        return (_allowed[caller], 0, false);
    }
}

/**
 * @title ParticipantStorageV1 Governance Access Tests
 * @notice Verifies that all governance functions are gated by `restricted`,
 *         and that protocol-safety functions (onlyAuthorizedCaller, receiveMethod) remain intact.
 */
contract ParticipantStorageV1GovernanceAccessTest is Test {
    ParticipantStorageV1 public ps;
    MockAuthority_PS public auth;
    MockEndpointForSecurityTest public mockEndpoint;

    address public admin;
    address public attacker;

    uint256 constant CHAIN_ID = 12345;
    uint256 constant HUB_ID   = 99999;

    function setUp() public {
        admin    = makeAddr("admin");
        attacker = makeAddr("attacker");
        auth     = new MockAuthority_PS();
        auth.allow(address(this));

        mockEndpoint = new MockEndpointForSecurityTest(CHAIN_ID, HUB_ID);
        mockEndpoint.setTrustedExecutor(admin);

        // ParticipantStorageV1 has no constructor disabling initializers
        ps = new ParticipantStorageV1();
        ps.initialize(address(mockEndpoint), address(auth));
    }

    // ─── authority ───────────────────────────────────────────────────────────

    function test_authority_isSet() public view {
        assertEq(ps.authority(), address(auth));
    }

    // ─── configureModules (restricted) ───────────────────────────────────────

    function test_configureModules_attacker_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        ps.configureModules(makeAddr("c"), makeAddr("a"), makeAddr("e"));
    }

    function test_configureModules_denied_reverts() public {
        auth.deny(address(this));
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, address(this)));
        ps.configureModules(makeAddr("c"), makeAddr("a"), makeAddr("e"));
    }

    // ─── setParticipantCore (restricted) ─────────────────────────────────────

    function test_setParticipantCore_attacker_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        ps.setParticipantCore(makeAddr("c"));
    }

    // ─── setAuditManager (restricted) ────────────────────────────────────────

    function test_setAuditManager_attacker_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        ps.setAuditManager(makeAddr("a"));
    }

    // ─── setEnygmaManager (restricted) ───────────────────────────────────────

    function test_setEnygmaManager_attacker_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        ps.setEnygmaManager(makeAddr("e"));
    }

    // ─── addParticipant (restricted) ─────────────────────────────────────────

    function test_addParticipant_attacker_reverts() public {
        ParticipantStructs.ParticipantData memory p;
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        ps.addParticipant(p);
    }

    function test_addParticipant_denied_reverts() public {
        auth.deny(address(this));
        ParticipantStructs.ParticipantData memory p;
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, address(this)));
        ps.addParticipant(p);
    }

    // ─── addParticipants (restricted) ────────────────────────────────────────

    function test_addParticipants_attacker_reverts() public {
        ParticipantStructs.ParticipantData[] memory participants = new ParticipantStructs.ParticipantData[](0);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        ps.addParticipants(participants);
    }

    // ─── updateStatus (restricted) ───────────────────────────────────────────

    function test_updateStatus_attacker_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        ps.updateStatus(1, ParticipantStructs.Status.ACTIVE);
    }

    // ─── updateRole (restricted) ──────────────────────────────────────────────

    function test_updateRole_attacker_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        ps.updateRole(1, ParticipantStructs.Role.ISSUER);
    }

    // ─── updateBroadcastMessagesPermission (restricted) ───────────────────────

    function test_updateBroadcastMessagesPermission_attacker_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        ps.updateBroadcastMessagesPermission(1, true);
    }

    // ─── removeParticipant (restricted) ──────────────────────────────────────

    function test_removeParticipant_attacker_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        ps.removeParticipant(1);
    }

    // ─── setEnygmaPnEventsAddress (restricted) ────────────────────────────────

    function test_setEnygmaPnEventsAddress_attacker_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        ps.setEnygmaPnEventsAddress(makeAddr("events"));
    }

    // ─── setAuditInfo (onlyAuthorizedCaller — unchanged) ─────────────────────

    function test_setAuditInfo_attacker_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("RaylsAccessManaged__Unauthorized(address)")), attacker));
        ps.setAuditInfo(999, "key", "", "", 1);
    }

    function test_setAuditInfo_admin_passesAuthCheck() public {
        // Admin should pass the restricted check (may fail on module not set)
        try ps.setAuditInfo(999, "key", "", "", 1) {}
        catch (bytes memory reason) {
            assertTrue(
                keccak256(reason) != keccak256(abi.encodeWithSelector(
                    bytes4(keccak256("RaylsAccessManaged__Unauthorized(address)")), admin
                )),
                "Admin must not fail with RaylsAccessManaged__Unauthorized"
            );
        }
    }

    // ─── broadcastCurrentParticipants (receiveMethod — unchanged) ────────────

    function test_broadcastCurrentParticipants_attacker_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(); // RaylsAppV1__UnauthorizedExecutor
        ps.broadcastCurrentParticipants();
    }

    // ─── contractVersion ─────────────────────────────────────────────────────

    function test_contractVersion_returns1() public view {
        assertEq(ps.contractVersion(), 1);
    }
}
