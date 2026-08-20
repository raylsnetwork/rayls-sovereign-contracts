// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {IRaylsAccessManager} from "../../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol";
import "../../../privateHub/AccessControl/AccessManagerTypes.sol";

/// @notice Dummy managed contract for selfRegisterManagedContract tests.
contract DummyManaged {
    address public authority;
    constructor(address _authority) { authority = _authority; }
    function ownerFn() external {}
    function doSomething() external {}
}

/// @notice Dummy target for schedule/execute tests.
contract ScheduleTarget {
    uint256 public callCount;
    function ping() external { callCount++; }
}

/**
 * @title RaylsAccessManagerV1 — restricted Modifier Tests
 * @notice Covers:
 *   - initialize sets authority, labels, and self-management bitmaps
 *   - Tier 2 selectors are unmapped and default to ADMIN (fail-closed)
 *   - ADMIN works for all functions (no regression)
 *   - Tier 3 PUBLIC functions work for their legitimate callers
 *   - Unauthorized callers are blocked on all tiers
 *   - Defense-in-depth: internal checks still enforce even if bitmap is tampered
 */
contract RaylsAccessManagerV1_RestrictedTest is Test {
    RaylsAccessManagerV1 public manager;

    address public admin;
    address public alice;
    address public attacker;
    address public targetContract;

    uint64 constant ADMIN = 0;
    uint64 constant PUBLIC = 1;
    uint64 constant TOKEN_OWNER = 2;

    function _singleRole(uint64 roleId) internal pure returns (uint64[] memory roles) {
        roles = new uint64[](1);
        roles[0] = roleId;
    }

    function setUp() public {
        admin          = makeAddr("admin");
        alice          = makeAddr("alice");
        attacker       = makeAddr("attacker");
        targetContract = makeAddr("targetContract");

        RaylsAccessManagerV1 impl = new RaylsAccessManagerV1();
        bytes memory initData = abi.encodeCall(RaylsAccessManagerV1.initialize, (admin));
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(address(impl), initData)));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  initialize — authority, labels, self-management bitmaps
    // ═══════════════════════════════════════════════════════════════════

    function test_initialize_setsAuthority() public view {
        assertEq(manager.authority(), address(manager));
    }

    function _assertSingleRole(address target, bytes4 sel, uint64 expectedRole) internal view {
        uint64[] memory roles = manager.getFunctionAllowedRoles(target, sel);
        assertEq(roles.length, 1);
        assertEq(roles[0], expectedRole);
    }

    function test_initialize_mapsTier3SelectorsToPublicRole() public view {
        _assertSingleRole(address(manager), manager.grantRole.selector, PUBLIC);
        _assertSingleRole(address(manager), manager.revokeRole.selector, PUBLIC);
        _assertSingleRole(address(manager), manager.renounceRole.selector, PUBLIC);
        _assertSingleRole(address(manager), manager.grantContractScopedRole.selector, PUBLIC);
        _assertSingleRole(address(manager), manager.revokeContractScopedRole.selector, PUBLIC);
        _assertSingleRole(address(manager), manager.selfRegisterManagedContract.selector, PUBLIC);
        _assertSingleRole(address(manager), manager.schedule.selector, PUBLIC);
        _assertSingleRole(address(manager), manager.execute.selector, PUBLIC);
        _assertSingleRole(address(manager), manager.cancel.selector, PUBLIC);
    }

    function test_initialize_upgradeToAndCallIsUnmapped() public view {
        // Unmapped returns empty array (no roles mapped)
        assertEq(manager.getFunctionAllowedRoles(address(manager), manager.upgradeToAndCall.selector).length, 0);
    }

    function test_initialize_cannotBeCalledTwice() public {
        vm.expectRevert();
        manager.initialize(admin);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Tier 2 selectors are unmapped — default to ADMIN
    // ═══════════════════════════════════════════════════════════════════

    function test_tier2Selectors_areUnmapped_defaultToAdminRole() public view {
        assertEq(manager.getFunctionAllowedRoles(address(manager), manager.registerRole.selector).length, 0);
        assertEq(manager.getFunctionAllowedRoles(address(manager), manager.registerRoleAndLabel.selector).length, 0);
        assertEq(manager.getFunctionAllowedRoles(address(manager), manager.labelRole.selector).length, 0);
        assertEq(manager.getFunctionAllowedRoles(address(manager), manager.addFunctionAllowedRoles.selector).length, 0);
        assertEq(manager.getFunctionAllowedRoles(address(manager), manager.removeFunctionAllowedRoles.selector).length, 0);
        assertEq(manager.getFunctionAllowedRoles(address(manager), manager.setContractPaused.selector).length, 0);
        assertEq(manager.getFunctionAllowedRoles(address(manager), manager.setRoleAdmin.selector).length, 0);
        assertEq(manager.getFunctionAllowedRoles(address(manager), manager.setRoleGuardian.selector).length, 0);
        assertEq(manager.getFunctionAllowedRoles(address(manager), manager.setGrantDelay.selector).length, 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  ADMIN works for everything (no regression)
    // ═══════════════════════════════════════════════════════════════════

    function test_admin_canRegisterRole() public {
        vm.prank(admin);
        uint64 roleId = manager.registerRole("ADMIN_TEST");
        assertGt(roleId, 2);
    }

    function test_admin_canAddFunctionAllowedRoles() public {
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = bytes4(keccak256("adminFn()"));
        vm.prank(admin);
        manager.addFunctionAllowedRoles(targetContract, sels, _singleRole(PUBLIC));
        _assertSingleRole(targetContract, sels[0], PUBLIC);
    }

    function test_admin_canSetContractPaused() public {
        vm.prank(admin);
        manager.setContractPaused(targetContract, true);
        assertTrue(manager.isContractPaused(targetContract));
    }

    function test_admin_canSetRoleAdmin_adminRole() public {
        // Admin CAN target ADMIN itself
        vm.prank(admin);
        uint64 bizRole = manager.registerRole("ADMIN_BIZ");
        vm.prank(admin);
        manager.setRoleAdmin(ADMIN, bizRole);
        assertEq(manager.getRoleAdmin(ADMIN), bizRole);
        // Restore to self-administered
        vm.prank(admin);
        manager.setRoleAdmin(ADMIN, ADMIN);
    }

    function test_admin_canSetRoleGuardian_adminRole() public {
        vm.prank(admin);
        uint64 guardRole = manager.registerRole("ADMIN_GUARD");
        vm.prank(admin);
        manager.setRoleGuardian(ADMIN, guardRole);
        assertEq(manager.getRoleGuardian(ADMIN), guardRole);
    }

    function test_admin_canSetGrantDelay_adminRole() public {
        vm.prank(admin);
        manager.setGrantDelay(ADMIN, 100);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Unauthorized callers blocked on all tiers
    // ═══════════════════════════════════════════════════════════════════

    function test_attacker_cannotRegisterRole() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManagerV1__Unauthorized.selector, attacker));
        manager.registerRole("HACKED");
    }

    function test_attacker_cannotAddFunctionAllowedRoles() public {
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = bytes4(keccak256("hack()"));
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManagerV1__Unauthorized.selector, attacker));
        manager.addFunctionAllowedRoles(targetContract, sels, _singleRole(PUBLIC));
    }

    function test_attacker_cannotSetContractPaused() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManagerV1__Unauthorized.selector, attacker));
        manager.setContractPaused(targetContract, true);
    }

    function test_attacker_cannotSetRoleAdmin() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManagerV1__Unauthorized.selector, attacker));
        manager.setRoleAdmin(ADMIN, PUBLIC);
    }

    function test_attacker_cannotLabelRole() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManagerV1__Unauthorized.selector, attacker));
        manager.labelRole(ADMIN, "pwned");
    }

    function test_attacker_cannotUpgrade() public {
        RaylsAccessManagerV1 newImpl = new RaylsAccessManagerV1();
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManagerV1__Unauthorized.selector, attacker));
        manager.upgradeToAndCall(address(newImpl), "");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Role admin delegation via setRoleAdmin
    // ═══════════════════════════════════════════════════════════════════

    function test_roleAdmin_canGrantRole() public {
        // Admin registers a role, sets alice as its admin, alice can grant it
        vm.prank(admin);
        uint64 bizRole = manager.registerRole("DELEGATED");
        vm.prank(admin);
        uint64 adminOfBiz = manager.registerRole("ADMIN_OF_BIZ");
        vm.prank(admin);
        manager.setRoleAdmin(bizRole, adminOfBiz);
        vm.prank(admin);
        manager.grantRole(adminOfBiz, alice, 0);

        // Alice (adminOfBiz holder) can grant bizRole to bob
        address bob = makeAddr("bob");
        vm.prank(alice);
        manager.grantRole(bizRole, bob, 0);
        (bool isMember,) = manager.hasRole(bizRole, bob);
        assertTrue(isMember);
    }

    function test_roleAdmin_canRevokeRole() public {
        vm.prank(admin);
        uint64 bizRole = manager.registerRole("REVOKE_TEST");
        vm.prank(admin);
        manager.grantRole(bizRole, alice, 0);
        // Admin can revoke
        vm.prank(admin);
        manager.revokeRole(bizRole, alice);
        (bool isMember,) = manager.hasRole(bizRole, alice);
        assertFalse(isMember);
    }

    function test_user_canRenounceRole() public {
        vm.prank(admin);
        uint64 bizRole = manager.registerRole("RENOUNCE_TEST");
        vm.prank(admin);
        manager.grantRole(bizRole, alice, 0);
        // Alice renounces her own role
        vm.prank(alice);
        manager.renounceRole(bizRole, alice);
        (bool isMember,) = manager.hasRole(bizRole, alice);
        assertFalse(isMember);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Defense-in-depth: internal checks enforce even if bitmap is
    //  tampered by admin
    // ═══════════════════════════════════════════════════════════════════

    function test_defenseInDepth_bitmapTamperDoesNotBypassCheckAdmin() public {
        // Admin remaps setContractPaused selector to PUBLIC on the manager
        // itself — this changes the bitmap, but _checkAdmin in the function body
        // still blocks unauthorized callers.
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = manager.setContractPaused.selector;
        vm.prank(admin);
        manager.addFunctionAllowedRoles(address(manager), sels, _singleRole(PUBLIC));

        // The restricted modifier now passes for attacker (PUBLIC), but
        // _checkAdmin blocks them
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManagerV1__Unauthorized.selector, attacker));
        manager.setContractPaused(targetContract, true);
    }

    function test_defenseInDepth_upgradeBitmapTamperDoesNotBypassCheckAdmin() public {
        // Admin remaps the upgradeToAndCall selector to PUBLIC on the manager
        // itself — this changes the bitmap, but _authorizeUpgrade still calls
        // _checkAdmin in the body.
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = manager.upgradeToAndCall.selector;
        vm.prank(admin);
        manager.addFunctionAllowedRoles(address(manager), sels, _singleRole(PUBLIC));

        // Now the restricted modifier passes for attacker (PUBLIC), but
        // _authorizeUpgrade -> _checkAdmin blocks them
        RaylsAccessManagerV1 newImpl = new RaylsAccessManagerV1();
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManagerV1__Unauthorized.selector, attacker));
        manager.upgradeToAndCall(address(newImpl), "");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  canCall reflects self-managed configuration
    // ═══════════════════════════════════════════════════════════════════

    function test_canCall_adminOnTier2Selector_allowed() public view {
        // Admin passes via the ADMIN bypass, not the bitmap
        (bool allowed,,) = manager.canCall(admin, address(manager), manager.registerRole.selector);
        assertTrue(allowed);
    }

    function test_canCall_attackerOnTier2Selector_denied() public view {
        (bool allowed,,) = manager.canCall(attacker, address(manager), manager.registerRole.selector);
        assertFalse(allowed);
    }

    function test_canCall_anyoneOnTier3Selector_allowed() public view {
        (bool allowed,,) = manager.canCall(attacker, address(manager), manager.grantRole.selector);
        assertTrue(allowed);
    }

    function test_canCall_attackerOnUpgradeSelector_denied() public view {
        (bool allowed,,) = manager.canCall(attacker, address(manager), manager.upgradeToAndCall.selector);
        assertFalse(allowed);
    }

    function test_canCall_adminOnUpgradeSelector_allowed() public view {
        (bool allowed,,) = manager.canCall(admin, address(manager), manager.upgradeToAndCall.selector);
        assertTrue(allowed);
    }
}
