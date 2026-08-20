// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "src/privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {IRaylsAccessManager} from "src/privateHub/AccessControl/interfaces/IRaylsAccessManager.sol";
import {RaylsAccessManaged} from "src/privateHub/AccessControl/RaylsAccessManaged.sol";
import "src/privateHub/AccessControl/AccessManagerTypes.sol";

// ─── Mock managed contract ───────────────────────────────────────────────────

contract MockPausableTarget is RaylsAccessManaged {
    uint256 public value;

    function init(address auth) external {
        _initializeAuthority(auth);
    }

    function doWrite(uint256 v) external restricted {
        value = v;
    }

    function doRead() external view returns (uint256) {
        return value;
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

contract RaylsAccessManagerV1_Pause_Test is Test {
    RaylsAccessManagerV1 manager;
    MockPausableTarget targetA;
    MockPausableTarget targetB;

    address admin;
    address alice;
    address attacker;

    uint64 WRITER_ROLE;

    function setUp() public {
        admin = address(this);
        alice = makeAddr("alice");
        attacker = makeAddr("attacker");

        // Deploy manager
        RaylsAccessManagerV1 impl = new RaylsAccessManagerV1();
        bytes memory initData = abi.encodeCall(RaylsAccessManagerV1.initialize, (admin));
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(address(impl), initData)));

        // Deploy two target contracts
        targetA = new MockPausableTarget();
        targetA.init(address(manager));

        targetB = new MockPausableTarget();
        targetB.init(address(manager));

        // Register a role and map doWrite to it
        WRITER_ROLE = manager.registerRole("WRITER");

        bytes4[] memory sels = new bytes4[](1);
        sels[0] = MockPausableTarget.doWrite.selector;
        uint64[] memory roles = new uint64[](1);
        roles[0] = WRITER_ROLE;

        manager.addFunctionAllowedRoles(address(targetA), sels, roles);
        manager.addFunctionAllowedRoles(address(targetB), sels, roles);

        // Grant WRITER to alice on both targets
        manager.grantRole(WRITER_ROLE, alice, 0);
    }

    function _singleRole(uint64 roleId) internal pure returns (uint64[] memory r) {
        r = new uint64[](1);
        r[0] = roleId;
    }

    // ─────────────────────────────────────────────────────────────
    //  Self-Pause Prevention
    // ─────────────────────────────────────────────────────────────

    function test_setContractPaused_selfPause_reverts() public {
        vm.expectRevert(RaylsAccessManagerV1__CannotPauseSelf.selector);
        manager.setContractPaused(address(manager), true);
    }

    function test_setContractPaused_selfUnpause_reverts() public {
        vm.expectRevert(RaylsAccessManagerV1__CannotPauseSelf.selector);
        manager.setContractPaused(address(manager), false);
    }

    // ─────────────────────────────────────────────────────────────
    //  Error Discrimination
    // ─────────────────────────────────────────────────────────────

    function test_pausedContract_revertsWithContractPaused() public {
        manager.setContractPaused(address(targetA), true);

        vm.prank(alice);
        vm.expectRevert(RaylsAccessManaged.RaylsAccessManaged__ContractPaused.selector);
        targetA.doWrite(42);
    }

    function test_unpausedContract_wrongRole_revertsWithUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker)
        );
        targetA.doWrite(42);
    }

    function test_pausedContract_adminAlsoBlocked_revertsWithContractPaused() public {
        manager.setContractPaused(address(targetA), true);

        // ADMIN is blocked on the MANAGED contract (not on the manager itself)
        vm.expectRevert(RaylsAccessManaged.RaylsAccessManaged__ContractPaused.selector);
        targetA.doWrite(42);
    }

    function test_pausedContract_viewFunctions_stillWork() public {
        // Write a value first
        vm.prank(alice);
        targetA.doWrite(99);

        // Pause the contract
        manager.setContractPaused(address(targetA), true);

        // View function still works (no restricted modifier)
        assertEq(targetA.doRead(), 99);
    }

    // ─────────────────────────────────────────────────────────────
    //  Pause Lifecycle
    // ─────────────────────────────────────────────────────────────

    function test_pauseAndUnpause_restoresAccess() public {
        // Pause
        manager.setContractPaused(address(targetA), true);

        vm.prank(alice);
        vm.expectRevert(RaylsAccessManaged.RaylsAccessManaged__ContractPaused.selector);
        targetA.doWrite(42);

        // Unpause
        manager.setContractPaused(address(targetA), false);

        vm.prank(alice);
        targetA.doWrite(42);
        assertEq(targetA.value(), 42);
    }

    function test_pause_emitsContractPauseUpdatedEvent() public {
        vm.expectEmit(true, false, false, true, address(manager));
        emit IRaylsAccessManager.ContractPauseUpdated(address(targetA), true);
        manager.setContractPaused(address(targetA), true);

        vm.expectEmit(true, false, false, true, address(manager));
        emit IRaylsAccessManager.ContractPauseUpdated(address(targetA), false);
        manager.setContractPaused(address(targetA), false);
    }

    function test_pause_isolation_otherContractsUnaffected() public {
        manager.setContractPaused(address(targetA), true);

        // targetA is blocked
        vm.prank(alice);
        vm.expectRevert(RaylsAccessManaged.RaylsAccessManaged__ContractPaused.selector);
        targetA.doWrite(1);

        // targetB is unaffected
        vm.prank(alice);
        targetB.doWrite(2);
        assertEq(targetB.value(), 2);
    }

    // ─────────────────────────────────────────────────────────────
    //  Pause + Role Changes
    // ─────────────────────────────────────────────────────────────

    function test_pause_thenGrantRole_stillBlocked() public {
        manager.setContractPaused(address(targetA), true);

        // Grant a new role to attacker
        manager.grantRole(WRITER_ROLE, attacker, 0);

        // Still blocked — pause overrides role grants
        vm.prank(attacker);
        vm.expectRevert(RaylsAccessManaged.RaylsAccessManaged__ContractPaused.selector);
        targetA.doWrite(42);
    }

    function test_pause_thenRevokeRole_thenUnpause_revoked() public {
        manager.setContractPaused(address(targetA), true);

        // Revoke alice's role while paused
        manager.revokeRole(WRITER_ROLE, alice);

        // Unpause
        manager.setContractPaused(address(targetA), false);

        // Alice lost her role — gets Unauthorized, not ContractPaused
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, alice)
        );
        targetA.doWrite(42);
    }

    // ─────────────────────────────────────────────────────────────
    //  Pause + Bitmap
    // ─────────────────────────────────────────────────────────────

    function test_pause_overridesMultiRoleBitmap() public {
        // Add a second role mapped to the same selector
        uint64 SECOND_ROLE = manager.registerRole("SECOND");
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = MockPausableTarget.doWrite.selector;
        uint64[] memory roles = new uint64[](1);
        roles[0] = SECOND_ROLE;
        manager.addFunctionAllowedRoles(address(targetA), sels, roles);
        manager.grantRole(SECOND_ROLE, attacker, 0);

        // Both role holders can call before pause
        vm.prank(alice);
        targetA.doWrite(1);
        vm.prank(attacker);
        targetA.doWrite(2);

        // Pause
        manager.setContractPaused(address(targetA), true);

        // Both are blocked
        vm.prank(alice);
        vm.expectRevert(RaylsAccessManaged.RaylsAccessManaged__ContractPaused.selector);
        targetA.doWrite(3);

        vm.prank(attacker);
        vm.expectRevert(RaylsAccessManaged.RaylsAccessManaged__ContractPaused.selector);
        targetA.doWrite(4);
    }

    // ─────────────────────────────────────────────────────────────
    //  Edge Cases
    // ─────────────────────────────────────────────────────────────

    function test_setContractPaused_nonAdmin_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(RaylsAccessManagerV1__Unauthorized.selector, attacker)
        );
        manager.setContractPaused(address(targetA), true);
    }

    function test_isContractPaused_defaultsFalse() public view {
        assertFalse(manager.isContractPaused(address(targetA)));
        assertFalse(manager.isContractPaused(address(targetB)));
        assertFalse(manager.isContractPaused(address(0xdead)));
    }

    function test_canCall_pausedContract_returnsFalseZeroTrue() public {
        manager.setContractPaused(address(targetA), true);

        (bool allowed, uint32 delay, bool paused) = manager.canCall(
            alice, address(targetA), MockPausableTarget.doWrite.selector
        );
        assertFalse(allowed);
        assertEq(delay, 0);
        assertTrue(paused);
    }

    function test_canCall_unpausedContract_returnsPausedFalse() public view {
        (bool allowed, uint32 delay, bool paused) = manager.canCall(
            alice, address(targetA), MockPausableTarget.doWrite.selector
        );
        assertTrue(allowed);
        assertEq(delay, 0);
        assertFalse(paused);
    }
}
