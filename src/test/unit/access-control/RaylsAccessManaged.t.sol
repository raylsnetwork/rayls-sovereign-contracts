// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {IRaylsAccessManager} from "../../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol";

// ─── Mock authority ───────────────────────────────────────────────────────────

/// @dev Configurable mock that returns a fixed (allowed, delay) pair for any canCall.
contract MockAuthority {
    bool public allowed;
    uint32 public delay;

    constructor(bool _allowed, uint32 _delay) {
        allowed = _allowed;
        delay = _delay;
    }

    function setResponse(bool _allowed, uint32 _delay) external {
        allowed = _allowed;
        delay = _delay;
    }

    function canCall(address, address, bytes4) external view returns (bool, uint32, bool) {
        return (allowed, delay, false);
    }
}

// ─── Concrete consumer that exposes restricted functions ─────────────────────

/// @dev Minimal RaylsAccessManaged consumer for unit testing.
contract ConcreteManaged is RaylsAccessManaged {
    uint256 public value;

    /// @notice Governance setter — gated by restricted.
    function setValue(uint256 v) external restricted {
        value = v;
    }

    /// @notice Exposes _initializeAuthority for setup.
    function init(address auth) external {
        _initializeAuthority(auth);
    }

    /// @notice Exposes _setAuthority for testing authority updates.
    function updateAuthority(address auth) external {
        _setAuthority(auth);
    }
}

/**
 * @title RaylsAccessManaged Unit Tests
 * @notice Tests the abstract mixin: authority initialization, restricted modifier,
 *         and authority update logic.
 */
contract RaylsAccessManagedTest is Test {
    ConcreteManaged public managed;
    MockAuthority public allowingAuth;
    MockAuthority public denyingAuth;
    MockAuthority public delayingAuth;

    address public caller;
    address public attacker;

    function setUp() public {
        caller   = makeAddr("caller");
        attacker = makeAddr("attacker");

        managed      = new ConcreteManaged();
        allowingAuth = new MockAuthority(true, 0);
        denyingAuth  = new MockAuthority(false, 0);
        delayingAuth = new MockAuthority(false, 3600);
    }

    // ─── authority() ─────────────────────────────────────────────────────────

    function test_authority_uninitialized_returnsZero() public view {
        assertEq(managed.authority(), address(0));
    }

    function test_authority_afterInit_returnsSet() public {
        managed.init(address(allowingAuth));
        assertEq(managed.authority(), address(allowingAuth));
    }

    // ─── _initializeAuthority ────────────────────────────────────────────────

    function test_initializeAuthority_zeroAddress_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__InvalidAuthority.selector, address(0)));
        managed.init(address(0));
    }

    function test_initializeAuthority_alreadySet_reverts() public {
        managed.init(address(allowingAuth));
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__InvalidAuthority.selector, address(denyingAuth)));
        managed.init(address(denyingAuth));
    }

    function test_initializeAuthority_emitsAuthorityUpdated() public {
        vm.expectEmit(true, true, false, false);
        emit RaylsAccessManaged.AuthorityUpdated(address(0), address(allowingAuth));
        managed.init(address(allowingAuth));
    }

    // ─── _setAuthority ───────────────────────────────────────────────────────

    function test_setAuthority_zeroAddress_reverts() public {
        managed.init(address(allowingAuth));
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__InvalidAuthority.selector, address(0)));
        managed.updateAuthority(address(0));
    }

    function test_setAuthority_updatesAuthority() public {
        managed.init(address(allowingAuth));
        managed.updateAuthority(address(denyingAuth));
        assertEq(managed.authority(), address(denyingAuth));
    }

    function test_setAuthority_emitsAuthorityUpdated() public {
        managed.init(address(allowingAuth));
        vm.expectEmit(true, true, false, false);
        emit RaylsAccessManaged.AuthorityUpdated(address(allowingAuth), address(denyingAuth));
        managed.updateAuthority(address(denyingAuth));
    }

    // ─── restricted — no authority set ───────────────────────────────────────

    function test_restricted_noAuthority_revertsInvalidAuthority() public {
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__InvalidAuthority.selector, address(0)));
        managed.setValue(42);
    }

    // ─── restricted — allowed ────────────────────────────────────────────────

    function test_restricted_allowed_succeeds() public {
        managed.init(address(allowingAuth));
        vm.prank(caller);
        managed.setValue(99);
        assertEq(managed.value(), 99);
    }

    // ─── restricted — denied (no delay) ─────────────────────────────────────

    function test_restricted_denied_revertsUnauthorized() public {
        managed.init(address(denyingAuth));
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        managed.setValue(1);
    }

    // ─── restricted — denied with delay (must schedule) ──────────────────────

    function test_restricted_delayRequired_revertsMustSchedule() public {
        managed.init(address(delayingAuth));
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__MustSchedule.selector, caller, uint32(3600)));
        managed.setValue(1);
    }

    // ─── authority switch affects subsequent calls ────────────────────────────

    function test_restricted_afterAuthoritySwitch_usesNewAuthority() public {
        managed.init(address(allowingAuth));

        // Allowed under allowingAuth
        vm.prank(caller);
        managed.setValue(1);
        assertEq(managed.value(), 1);

        // Switch to denying authority
        managed.updateAuthority(address(denyingAuth));

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, caller));
        managed.setValue(2);

        // Value unchanged
        assertEq(managed.value(), 1);
    }
}
