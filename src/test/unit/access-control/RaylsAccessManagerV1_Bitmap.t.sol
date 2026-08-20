// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {IRaylsAccessManager} from "../../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol";
import "../../../privateHub/AccessControl/AccessManagerTypes.sol";

/// @title Bitmap Multi-Role Tests
/// @notice Tests the two-level bitmap multi-role-per-selector feature.
contract RaylsAccessManagerV1BitmapTest is Test {
    RaylsAccessManagerV1 public manager;

    address public admin;
    address public alice;
    address public bob;
    address public carol;
    address public managedContract;

    uint64 constant ADMIN = 0;
    uint64 constant PUBLIC = 1;
    uint64 constant TOKEN_OWNER = 2;

    // Custom roles (registered in setUp)
    uint64 complianceOfficerRole;
    uint64 complianceToolRole;
    uint64 operatorRole;
    uint64 bankEmployeeRole;

    bytes4 constant FREEZE_SEL = bytes4(keccak256("freezeToken(bytes32,uint256[])"));
    bytes4 constant UNFREEZE_SEL = bytes4(keccak256("unfreezeToken(bytes32,uint256[])"));
    bytes4 constant ADD_TOKEN_SEL = bytes4(keccak256("addToken(bytes32,uint8)"));
    bytes4 constant UPDATE_STATUS_SEL = bytes4(keccak256("updateTokenStatus(bytes32,uint8)"));

    function _singleRole(uint64 roleId) internal pure returns (uint64[] memory roles) {
        roles = new uint64[](1);
        roles[0] = roleId;
    }

    function setUp() public {
        admin = makeAddr("admin");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        managedContract = makeAddr("tokenRegistry");

        RaylsAccessManagerV1 impl = new RaylsAccessManagerV1();
        bytes memory initData = abi.encodeCall(RaylsAccessManagerV1.initialize, (admin));
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(address(impl), initData)));

        vm.startPrank(admin);
        complianceOfficerRole = manager.registerRole("COMPLIANCE_OFFICER");
        complianceToolRole = manager.registerRole("COMPLIANCE_TOOL");
        operatorRole = manager.registerRole("PRIVACY_NODE_OPERATOR");
        bankEmployeeRole = manager.registerRole("BANK_EMPLOYEE");
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────
    //  Multi-Role Per Selector -Core Feature
    // ─────────────────────────────────────────────────────────────

    function test_addFunctionAllowedRoles_multipleRolesOnSameSelector() public {
        vm.startPrank(admin);

        // Map freezeToken to COMPLIANCE_OFFICER
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = FREEZE_SEL;
        manager.addFunctionAllowedRoles(managedContract, sels, _singleRole(complianceOfficerRole));

        // Also map freezeToken to COMPLIANCE_TOOL
        manager.addFunctionAllowedRoles(managedContract, sels, _singleRole(complianceToolRole));

        // Grant COMPLIANCE_OFFICER to Alice
        manager.grantRole(complianceOfficerRole, alice, 0);

        // Grant COMPLIANCE_TOOL to Bob
        manager.grantRole(complianceToolRole, bob, 0);

        vm.stopPrank();

        // Alice can call freezeToken (via COMPLIANCE_OFFICER)
        (bool allowed,,) = manager.canCall(alice, managedContract, FREEZE_SEL);
        assertTrue(allowed, "Alice should be allowed via COMPLIANCE_OFFICER");

        // Bob can call freezeToken (via COMPLIANCE_TOOL)
        (allowed,,) = manager.canCall(bob, managedContract, FREEZE_SEL);
        assertTrue(allowed, "Bob should be allowed via COMPLIANCE_TOOL");

        // Carol cannot call freezeToken (no role)
        (allowed,,) = manager.canCall(carol, managedContract, FREEZE_SEL);
        assertFalse(allowed, "Carol should be denied (no role)");
    }

    function test_addFunctionAllowedRoles_differentScopesPerRole() public {
        vm.startPrank(admin);

        bytes4[] memory freezeSels = new bytes4[](1);
        freezeSels[0] = FREEZE_SEL;
        bytes4[] memory unfreezeSels = new bytes4[](1);
        unfreezeSels[0] = UNFREEZE_SEL;

        // COMPLIANCE_OFFICER: freeze + unfreeze
        manager.addFunctionAllowedRoles(managedContract, freezeSels, _singleRole(complianceOfficerRole));
        manager.addFunctionAllowedRoles(managedContract, unfreezeSels, _singleRole(complianceOfficerRole));

        // COMPLIANCE_TOOL: freeze only (NOT unfreeze)
        manager.addFunctionAllowedRoles(managedContract, freezeSels, _singleRole(complianceToolRole));

        manager.grantRole(complianceOfficerRole, alice, 0);
        manager.grantRole(complianceToolRole, bob, 0);
        vm.stopPrank();

        // Alice: freeze YES, unfreeze YES
        (bool allowed,,) = manager.canCall(alice, managedContract, FREEZE_SEL);
        assertTrue(allowed, "Alice freeze");
        (allowed,,) = manager.canCall(alice, managedContract, UNFREEZE_SEL);
        assertTrue(allowed, "Alice unfreeze");

        // Bob: freeze YES, unfreeze NO
        (allowed,,) = manager.canCall(bob, managedContract, FREEZE_SEL);
        assertTrue(allowed, "Bob freeze");
        (allowed,,) = manager.canCall(bob, managedContract, UNFREEZE_SEL);
        assertFalse(allowed, "Bob should NOT be able to unfreeze");
    }

    function test_removeFunctionAllowedRoles_removesOneRoleKeepsOthers() public {
        vm.startPrank(admin);

        bytes4[] memory sels = new bytes4[](1);
        sels[0] = FREEZE_SEL;
        manager.addFunctionAllowedRoles(managedContract, sels, _singleRole(complianceOfficerRole));
        manager.addFunctionAllowedRoles(managedContract, sels, _singleRole(complianceToolRole));

        manager.grantRole(complianceOfficerRole, alice, 0);
        manager.grantRole(complianceToolRole, bob, 0);

        // Remove COMPLIANCE_TOOL from freezeToken
        manager.removeFunctionAllowedRoles(managedContract, sels, _singleRole(complianceToolRole));
        vm.stopPrank();

        // Alice still allowed (COMPLIANCE_OFFICER still mapped)
        (bool allowed,,) = manager.canCall(alice, managedContract, FREEZE_SEL);
        assertTrue(allowed, "Alice should still be allowed");

        // Bob no longer allowed (COMPLIANCE_TOOL removed)
        (allowed,,) = manager.canCall(bob, managedContract, FREEZE_SEL);
        assertFalse(allowed, "Bob should be denied after role removed");
    }

    // ─────────────────────────────────────────────────────────────
    //  PUBLIC Behavior
    // ─────────────────────────────────────────────────────────────

    function test_publicRole_allowsEveryone() public {
        vm.prank(admin);
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = FREEZE_SEL;
        manager.addFunctionAllowedRoles(managedContract, sels, _singleRole(PUBLIC));

        // Anyone can call -no role needed
        (bool allowed,,) = manager.canCall(alice, managedContract, FREEZE_SEL);
        assertTrue(allowed, "Alice should pass (PUBLIC)");

        (allowed,,) = manager.canCall(bob, managedContract, FREEZE_SEL);
        assertTrue(allowed, "Bob should pass (PUBLIC)");

        (allowed,,) = manager.canCall(carol, managedContract, FREEZE_SEL);
        assertTrue(allowed, "Carol should pass (PUBLIC)");

        // Even a random address
        (allowed,,) = manager.canCall(address(0xdead), managedContract, FREEZE_SEL);
        assertTrue(allowed, "Random address should pass (PUBLIC)");
    }

    function test_publicRole_cannotBeGrantedToIndividual() public {
        // PUBLIC means "everyone can call functions mapped to it." It is enforced by
        // checking the selector's bitmap, not the caller's. Granting it to an individual
        // is meaningless, so it reverts.
        vm.prank(admin);
        vm.expectRevert(RaylsAccessManagerV1__PublicRoleCannotBeGranted.selector);
        manager.grantRole(PUBLIC, alice, 0);
    }

    function test_publicRole_coexistsWithOtherRoles() public {
        vm.startPrank(admin);
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = FREEZE_SEL;

        // Map to both PUBLIC and COMPLIANCE_OFFICER
        manager.addFunctionAllowedRoles(managedContract, sels, _singleRole(PUBLIC));
        manager.addFunctionAllowedRoles(managedContract, sels, _singleRole(complianceOfficerRole));
        vm.stopPrank();

        // Everyone passes because PUBLIC is set
        (bool allowed,,) = manager.canCall(carol, managedContract, FREEZE_SEL);
        assertTrue(allowed, "Carol should pass (PUBLIC present in bitmap)");
    }

    // ─────────────────────────────────────────────────────────────
    //  TOKEN_OWNER -Contract-Scoped via Bitmap
    // ─────────────────────────────────────────────────────────────

    function test_tokenOwnerRole_worksNaturallyInBitmap() public {
        vm.startPrank(admin);

        bytes4[] memory sels = new bytes4[](1);
        sels[0] = FREEZE_SEL;

        // Map freezeToken to TOKEN_OWNER
        manager.addFunctionAllowedRoles(managedContract, sels, _singleRole(TOKEN_OWNER));

        // Grant TOKEN_OWNER via the scoped API (post-F19-fix: the global
        // `grantRole(TOKEN_OWNER, ...)` path is rejected with
        // RaylsAccessManagerV1__TokenOwnerIsScopeOnly — the scoped API is
        // the only legitimate route for this per-contract role).
        manager.grantContractScopedRole(TOKEN_OWNER, alice, managedContract, 0);
        vm.stopPrank();

        (bool allowed,,) = manager.canCall(alice, managedContract, FREEZE_SEL);
        assertTrue(allowed, "Alice should be allowed via scoped TOKEN_OWNER");

        (allowed,,) = manager.canCall(bob, managedContract, FREEZE_SEL);
        assertFalse(allowed, "Bob should be denied (no TOKEN_OWNER)");
    }

    // ─────────────────────────────────────────────────────────────
    //  Grant Delay + Bitmap Interaction
    // ─────────────────────────────────────────────────────────────

    function test_pendingGrant_skippedInBitmapMatch() public {
        vm.startPrank(admin);

        bytes4[] memory sels = new bytes4[](1);
        sels[0] = FREEZE_SEL;

        // Map to both roles
        manager.addFunctionAllowedRoles(managedContract, sels, _singleRole(complianceOfficerRole));
        manager.addFunctionAllowedRoles(managedContract, sels, _singleRole(complianceToolRole));

        // Set 48h grant delay on COMPLIANCE_OFFICER
        manager.setGrantDelay(complianceOfficerRole, 48 hours);

        // Grant both roles to Alice
        manager.grantRole(complianceOfficerRole, alice, 0); // pending (48h delay)
        manager.grantRole(complianceToolRole, alice, 0);    // immediate
        vm.stopPrank();

        // Alice's COMPLIANCE_OFFICER is pending but COMPLIANCE_TOOL is active.
        // The bitmap AND matches both -canCall must skip the pending one and find the active one.
        (bool allowed,,) = manager.canCall(alice, managedContract, FREEZE_SEL);
        assertTrue(allowed, "Alice should be allowed via COMPLIANCE_TOOL (COMPLIANCE_OFFICER is pending)");

        // After 48h, both should work
        vm.warp(block.timestamp + 49 hours);
        (allowed,,) = manager.canCall(alice, managedContract, FREEZE_SEL);
        assertTrue(allowed, "Alice should be allowed (both roles now active)");
    }

    // ─────────────────────────────────────────────────────────────
    //  Emergency Pause
    // ─────────────────────────────────────────────────────────────

    function test_emergencyPause_overridesBitmap() public {
        vm.startPrank(admin);

        bytes4[] memory sels = new bytes4[](1);
        sels[0] = FREEZE_SEL;
        manager.addFunctionAllowedRoles(managedContract, sels, _singleRole(complianceOfficerRole));
        manager.grantRole(complianceOfficerRole, alice, 0);

        // Verify works before pause
        (bool allowed,,) = manager.canCall(alice, managedContract, FREEZE_SEL);
        assertTrue(allowed);

        // Pause the contract
        manager.setContractPaused(managedContract, true);
        vm.stopPrank();

        // Should be denied even though bitmap matches
        (allowed,,) = manager.canCall(alice, managedContract, FREEZE_SEL);
        assertFalse(allowed, "Should be denied while paused");
    }

    // ─────────────────────────────────────────────────────────────
    //  Admin Bypass
    // ─────────────────────────────────────────────────────────────

    function test_adminBypass_worksRegardlessOfBitmap() public {
        // Admin can call even unmapped selectors
        (bool allowed,,) = manager.canCall(admin, managedContract, FREEZE_SEL);
        assertTrue(allowed, "Admin should bypass all checks");

        // Admin can call even if function is mapped to a specific role
        vm.prank(admin);
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = FREEZE_SEL;
        manager.addFunctionAllowedRoles(managedContract, sels, _singleRole(complianceOfficerRole));

        (allowed,,) = manager.canCall(admin, managedContract, FREEZE_SEL);
        assertTrue(allowed, "Admin should still bypass");
    }

    // ─────────────────────────────────────────────────────────────
    //  Fail-Closed Default
    // ─────────────────────────────────────────────────────────────

    function test_unmappedSelector_onlyAdminCanCall() public {
        // No mapping exists for FREEZE_SEL
        (bool allowed,,) = manager.canCall(alice, managedContract, FREEZE_SEL);
        assertFalse(allowed, "Non-admin should be denied on unmapped selector");

        (allowed,,) = manager.canCall(admin, managedContract, FREEZE_SEL);
        assertTrue(allowed, "Admin should pass on unmapped selector");
    }

    // ─────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────

    function test_addFunctionAllowedRoles_emitsEvent() public {
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = FREEZE_SEL;

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit IRaylsAccessManager.FunctionAllowedRoleAdded(managedContract, FREEZE_SEL, complianceOfficerRole);
        manager.addFunctionAllowedRoles(managedContract, sels, _singleRole(complianceOfficerRole));
    }

    function test_removeFunctionAllowedRoles_emitsEvent() public {
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = FREEZE_SEL;

        vm.startPrank(admin);
        manager.addFunctionAllowedRoles(managedContract, sels, _singleRole(complianceOfficerRole));

        vm.expectEmit(true, true, true, true);
        emit IRaylsAccessManager.FunctionAllowedRoleRemoved(managedContract, FREEZE_SEL, complianceOfficerRole);
        manager.removeFunctionAllowedRoles(managedContract, sels, _singleRole(complianceOfficerRole));
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────
    //  Role ID Values
    // ─────────────────────────────────────────────────────────────

    function test_roleIds_startAt3() public {
        // ADMIN=0, PUBLIC=1, TOKEN_OWNER=2, first custom=3
        assertEq(complianceOfficerRole, 3, "First custom role should be 3");
        assertEq(complianceToolRole, 4, "Second custom role should be 4");
        assertEq(operatorRole, 5, "Third custom role should be 5");
        assertEq(bankEmployeeRole, 6, "Fourth custom role should be 6");
    }

    function test_constants_correctValues() public view {
        assertEq(manager.ADMIN(), 0);
        assertEq(manager.PUBLIC(), 1);
        assertEq(manager.TOKEN_OWNER(), 2);
    }

    // ─────────────────────────────────────────────────────────────
    //  Cross-Segment Collision Tests (roleId 256, 257 vs PUBLIC, TOKEN_OWNER)
    // ─────────────────────────────────────────────────────────────

    /// @dev Register roles until we reach the desired IDs.
    ///      setUp already registered roles 3-6, so next is 7.
    function _registerUpTo(uint64 maxRoleId) internal returns (uint64, uint64) {
        vm.startPrank(admin);
        uint64 nextId;
        for (uint256 i = 7; i <= uint256(maxRoleId) + 1; i++) {
            nextId = manager.registerRole(string.concat("R", vm.toString(i)));
        }
        vm.stopPrank();
        return (256, 257);
    }

    function test_role256_doesNotCollideWithAdminRole() public {
        // ADMIN=0 is segment 0 bit 0. Role 256 is segment 1 bit 0.
        // Same bit position (0) but different segments -must not collide.
        (uint64 role256,) = _registerUpTo(257);

        vm.startPrank(admin);
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = FREEZE_SEL;

        // Map freezeToken to role 256 only
        manager.addFunctionAllowedRoles(managedContract, sels, _singleRole(role256));
        manager.grantRole(role256, alice, 0);
        vm.stopPrank();

        // Alice has role 256 → should pass
        (bool allowed,,) = manager.canCall(alice, managedContract, FREEZE_SEL);
        assertTrue(allowed, "Alice should be allowed via role 256");

        // Bob has no roles → should fail (role 256 is not ADMIN)
        (allowed,,) = manager.canCall(bob, managedContract, FREEZE_SEL);
        assertFalse(allowed, "Bob should be denied");
    }

    function test_role257_doesNotCollideWithPublicRole() public {
        // PUBLIC=1 is segment 0 bit 1. Role 257 is segment 1 bit 1.
        // Same bit position (1) but different segments -must not collide.
        (, uint64 role257) = _registerUpTo(257);

        vm.startPrank(admin);
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = FREEZE_SEL;

        // Map freezeToken to role 257 only (NOT PUBLIC which is 1)
        manager.addFunctionAllowedRoles(managedContract, sels, _singleRole(role257));
        manager.grantRole(role257, alice, 0);
        vm.stopPrank();

        // Alice has role 257 → should pass
        (bool allowed,,) = manager.canCall(alice, managedContract, FREEZE_SEL);
        assertTrue(allowed, "Alice should be allowed via role 257");

        // Bob has no roles → should fail
        // Critically: role 257 shares bit position 1 with PUBLIC but in segment 1,
        // so it must NOT behave like PUBLIC (which allows everyone)
        (allowed,,) = manager.canCall(bob, managedContract, FREEZE_SEL);
        assertFalse(allowed, "Bob must NOT be allowed -role 257 is not PUBLIC");

        // Carol with no roles → must also fail
        (allowed,,) = manager.canCall(carol, managedContract, FREEZE_SEL);
        assertFalse(allowed, "Carol must NOT be allowed -role 257 is not PUBLIC");
    }

    function test_role258_doesNotCollideWithTokenOwnerRole() public {
        // TOKEN_OWNER=2 is segment 0 bit 2. Role 258 is segment 1 bit 2.
        // Same bit position (2) but different segments -must not collide.
        _registerUpTo(258);
        uint64 role258 = 258;

        vm.startPrank(admin);
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = FREEZE_SEL;

        // Map to role 258 only
        manager.addFunctionAllowedRoles(managedContract, sels, _singleRole(role258));
        manager.grantRole(role258, alice, 0);
        vm.stopPrank();

        // Alice has role 258 → should pass
        (bool allowed,,) = manager.canCall(alice, managedContract, FREEZE_SEL);
        assertTrue(allowed, "Alice should be allowed via role 258");

        // Bob → denied
        (allowed,,) = manager.canCall(bob, managedContract, FREEZE_SEL);
        assertFalse(allowed, "Bob should be denied");
    }

    function test_publicRole_doesNotLeakToSegment1() public {
        // If freezeToken is mapped to PUBLIC (segment 0 bit 1),
        // it should NOT affect any role in segment 1.
        (, uint64 role257) = _registerUpTo(257);

        vm.startPrank(admin);
        bytes4[] memory freezeSels = new bytes4[](1);
        freezeSels[0] = FREEZE_SEL;
        bytes4[] memory unfreezeSels = new bytes4[](1);
        unfreezeSels[0] = UNFREEZE_SEL;

        // Map freezeToken to PUBLIC (everyone can call)
        manager.addFunctionAllowedRoles(managedContract, freezeSels, _singleRole(PUBLIC));

        // Map unfreezeToken to role 257 only
        manager.addFunctionAllowedRoles(managedContract, unfreezeSels, _singleRole(role257));
        manager.grantRole(role257, alice, 0);
        vm.stopPrank();

        // Everyone can call freezeToken (PUBLIC)
        (bool allowed,,) = manager.canCall(bob, managedContract, FREEZE_SEL);
        assertTrue(allowed, "Bob can freeze (PUBLIC)");

        // Only Alice (role 257) can call unfreezeToken -NOT everyone
        (allowed,,) = manager.canCall(alice, managedContract, UNFREEZE_SEL);
        assertTrue(allowed, "Alice can unfreeze (role 257)");

        (allowed,,) = manager.canCall(bob, managedContract, UNFREEZE_SEL);
        assertFalse(allowed, "Bob cannot unfreeze (no role 257) -PUBLIC on freeze must not leak");
    }

    function test_crossSegment_multiRoleWorks() public {
        // Map a function to both a segment 0 role and a segment 1 role.
        (, uint64 role257) = _registerUpTo(257);

        vm.startPrank(admin);
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = FREEZE_SEL;

        // Map to COMPLIANCE_OFFICER (segment 0) AND role 257 (segment 1)
        manager.addFunctionAllowedRoles(managedContract, sels, _singleRole(complianceOfficerRole));
        manager.addFunctionAllowedRoles(managedContract, sels, _singleRole(role257));

        manager.grantRole(complianceOfficerRole, alice, 0);  // segment 0 role
        manager.grantRole(role257, bob, 0);                   // segment 1 role
        vm.stopPrank();

        // Both should be allowed via different segments
        (bool allowed,,) = manager.canCall(alice, managedContract, FREEZE_SEL);
        assertTrue(allowed, "Alice allowed via COMPLIANCE_OFFICER (segment 0)");

        (allowed,,) = manager.canCall(bob, managedContract, FREEZE_SEL);
        assertTrue(allowed, "Bob allowed via role 257 (segment 1)");

        // Carol has neither → denied
        (allowed,,) = manager.canCall(carol, managedContract, FREEZE_SEL);
        assertFalse(allowed, "Carol denied (no matching role in either segment)");
    }
}
