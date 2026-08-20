// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsReentrancyGuardV1} from "../../../rayls-protocol/utils/RaylsReentrancyGuardV1.sol";
import {RNReentrancyGuardV1} from "../../../rayls-node/rayls-privacy-node/RNReentrancyGuardV1.sol";

/**
 * @title TestRaylsGuardHarness
 * @notice Exposes RaylsReentrancyGuardV1 internals for testing
 */
contract TestRaylsGuardHarness is RaylsReentrancyGuardV1 {
    uint256 public counter;

    function initializeGuard() external {
        initialize();
    }

    function guardedSend() external sendNonReentrant {
        counter++;
    }

    function guardedReceive() external receiveNonReentrant {
        counter++;
    }

    function getSendState() external view returns (uint8) {
        return _send_entered_state;
    }

    function getReceiveState() external view returns (uint8) {
        return _receive_entered_state;
    }
}

/**
 * @title TestRNGuardHarness
 * @notice Exposes RNReentrancyGuardV1 internals for testing
 */
contract TestRNGuardHarness is RNReentrancyGuardV1 {
    uint256 public counter;

    function initializeGuard() external {
        initialize();
    }

    function guardedSend() external sendNonReentrant {
        counter++;
    }

    function guardedReceive() external receiveNonReentrant {
        counter++;
    }

    function getSendState() external view returns (uint8) {
        return _send_entered_state;
    }

    function getReceiveState() external view returns (uint8) {
        return _receive_entered_state;
    }

    // Allow external callback to test reentrancy
    // NOTE: We do NOT require success on the callback — the re-entrant call is expected to fail.
    // We just need the outer call to succeed, and verify the attacker's count stays at 1 (no re-entry).
    function guardedSendWithCallback(address callback) external sendNonReentrant {
        counter++;
        if (callback != address(0)) {
            callback.call(abi.encodeWithSignature("attack()"));
        }
    }

    function guardedReceiveWithCallback(address callback) external receiveNonReentrant {
        counter++;
        if (callback != address(0)) {
            callback.call(abi.encodeWithSignature("attack()"));
        }
    }
}

/**
 * @title SendReentrancyAttacker
 * @notice Attempts to re-enter a sendNonReentrant function
 */
contract SendReentrancyAttacker {
    address public target;
    uint256 public attackCount;

    constructor(address _target) {
        target = _target;
    }

    function attack() external {
        attackCount++;
        (bool success,) = target.call(
            abi.encodeWithSignature("guardedSend()")
        );
        // We don't require success here — we just record the attempt
        if (success) attackCount++;
    }
}

/**
 * @title ReceiveReentrancyAttacker
 * @notice Attempts to re-enter a receiveNonReentrant function
 */
contract ReceiveReentrancyAttacker {
    address public target;
    uint256 public attackCount;

    constructor(address _target) {
        target = _target;
    }

    function attack() external {
        attackCount++;
        (bool success,) = target.call(
            abi.encodeWithSignature("guardedReceive()")
        );
        if (success) attackCount++;
    }
}

/**
 * @title SEC-003: RaylsReentrancyGuardV1 Initialization Bug
 * @notice Tests that reproduce the initialization bug where the guard's default state (0)
 *         doesn't match _NOT_ENTERED (1), causing all guarded functions to revert on first use.
 *
 * TEST BEHAVIOR:
 * - Tests marked "reproduces bug" FAIL when the bug is present, PASS after fix
 * - Tests marked "confirms working" validate correct behavior
 */
contract SEC003_ReentrancyGuard_InitializationTest is Test {

    TestRaylsGuardHarness public raylsGuard;
    TestRNGuardHarness public rnGuard;

    function setUp() public {
        raylsGuard = new TestRaylsGuardHarness();
        rnGuard = new TestRNGuardHarness();
    }

    // =========================================================================
    // RaylsReentrancyGuardV1 Tests
    // =========================================================================

    /**
     * @notice Reproduces the bug: after calling initialize(), state is still 0 (not 1).
     *         The sendNonReentrant modifier requires state == 1, so first call reverts.
     *
     * BEFORE FIX: This test FAILS (the guarded call reverts unexpectedly)
     * AFTER FIX:  This test PASSES (the guarded call succeeds)
     */
    function test_SEC003_RaylsGuard_sendNonReentrant_works_after_initialize() public {
        raylsGuard.initializeGuard();

        // This should succeed after proper initialization
        // BUG: reverts with "Rayls: no send reentrancy" because state is 0, not 1
        raylsGuard.guardedSend();

        assertEq(raylsGuard.counter(), 1, "Counter should be 1 after successful call");
    }

    /**
     * @notice Same bug for receiveNonReentrant
     *
     * BEFORE FIX: This test FAILS
     * AFTER FIX:  This test PASSES
     */
    function test_SEC003_RaylsGuard_receiveNonReentrant_works_after_initialize() public {
        raylsGuard.initializeGuard();

        // BUG: reverts with "Rayls: no receive reentrancy" because state is 0, not 1
        raylsGuard.guardedReceive();

        assertEq(raylsGuard.counter(), 1, "Counter should be 1 after successful call");
    }

    /**
     * @notice Verify the raw state after initialization to prove the root cause
     *
     * BEFORE FIX: States are 0 (bug) — this test FAILS
     * AFTER FIX:  States are 1 (_NOT_ENTERED) — this test PASSES
     */
    function test_SEC003_RaylsGuard_state_is_NOT_ENTERED_after_initialize() public {
        raylsGuard.initializeGuard();

        assertEq(raylsGuard.getSendState(), 1, "Send state should be _NOT_ENTERED (1) after initialize");
        assertEq(raylsGuard.getReceiveState(), 1, "Receive state should be _NOT_ENTERED (1) after initialize");
    }

    /**
     * @notice Verify state without initialization is 0 (default)
     * This always passes — just documents the default behavior.
     */
    function test_SEC003_RaylsGuard_default_state_is_zero() public view {
        assertEq(raylsGuard.getSendState(), 0, "Default send state should be 0");
        assertEq(raylsGuard.getReceiveState(), 0, "Default receive state should be 0");
    }

    /**
     * @notice After fix, verify multiple calls work (guard resets correctly)
     *
     * BEFORE FIX: FAILS (first call reverts)
     * AFTER FIX:  PASSES
     */
    function test_SEC003_RaylsGuard_multiple_calls_work_after_fix() public {
        raylsGuard.initializeGuard();

        raylsGuard.guardedSend();
        raylsGuard.guardedSend();
        raylsGuard.guardedSend();

        assertEq(raylsGuard.counter(), 3, "Counter should be 3 after three calls");
    }

    // =========================================================================
    // RNReentrancyGuardV1 Tests — Verify it works with default zero state
    // =========================================================================

    /**
     * @notice RNReentrancyGuardV1 uses `if (state == _ENTERED)` which checks for 2,
     *         so default state 0 is safe. This test should always PASS.
     */
    function test_SEC003_RNGuard_sendNonReentrant_works_with_default_state() public {
        rnGuard.initializeGuard();

        rnGuard.guardedSend();

        assertEq(rnGuard.counter(), 1, "Counter should be 1");
    }

    /**
     * @notice Verify RNReentrancyGuardV1 receiveNonReentrant works with default state
     */
    function test_SEC003_RNGuard_receiveNonReentrant_works_with_default_state() public {
        rnGuard.initializeGuard();

        rnGuard.guardedReceive();

        assertEq(rnGuard.counter(), 1, "Counter should be 1");
    }

    /**
     * @notice Verify RNReentrancyGuardV1 blocks send reentrancy.
     *         The outer call succeeds, but the attacker's re-entrant call fails silently.
     *         We verify by checking the attacker's count: 1 means the attack() was entered
     *         but the nested guardedSend() reverted, so attackCount stays at 1 (not 2).
     */
    function test_SEC003_RNGuard_blocks_send_reentrancy() public {
        rnGuard.initializeGuard();

        SendReentrancyAttacker attacker = new SendReentrancyAttacker(address(rnGuard));

        // Outer call succeeds; attacker's nested re-entry is silently reverted
        rnGuard.guardedSendWithCallback(address(attacker));

        // attacker.attack() was called (attackCount incremented to 1)
        // but the nested guardedSend() reverted, so attackCount stays at 1 (not 2)
        assertEq(attacker.attackCount(), 1, "Attacker entered attack() once but nested call was blocked");
        assertEq(rnGuard.counter(), 1, "Only the outer guardedSend should have incremented counter");
    }

    /**
     * @notice Verify RNReentrancyGuardV1 blocks receive reentrancy
     */
    function test_SEC003_RNGuard_blocks_receive_reentrancy() public {
        rnGuard.initializeGuard();

        ReceiveReentrancyAttacker attacker = new ReceiveReentrancyAttacker(address(rnGuard));

        rnGuard.guardedReceiveWithCallback(address(attacker));

        assertEq(attacker.attackCount(), 1, "Attacker entered attack() once but nested call was blocked");
        assertEq(rnGuard.counter(), 1, "Only the outer guardedReceive should have incremented counter");
    }

    /**
     * @notice Verify RNReentrancyGuardV1 initialize() now correctly sets state to _NOT_ENTERED (1).
     *         Previously, initialize() did not set the state, leaving it at default 0.
     *         The guard worked anyway because it checked `== _ENTERED` (2), not `== _NOT_ENTERED` (1).
     *         Now that initialize() is fixed, state is properly 1 after init.
     */
    function test_SEC003_RNGuard_state_after_initialize() public {
        rnGuard.initializeGuard();

        uint8 sendState = rnGuard.getSendState();
        uint8 receiveState = rnGuard.getReceiveState();

        // After fix: state is correctly _NOT_ENTERED (1)
        assertEq(sendState, 1, "RN send state after init should be _NOT_ENTERED (1)");
        assertEq(receiveState, 1, "RN receive state after init should be _NOT_ENTERED (1)");

        // Guard works — after one call, state returns to _NOT_ENTERED (1)
        rnGuard.guardedSend();
        assertEq(rnGuard.getSendState(), 1, "After call, state should be _NOT_ENTERED (1)");
    }

    // =========================================================================
    // Cross-guard independence tests
    // =========================================================================

    /**
     * @notice Verify send and receive guards are independent (after fix)
     *
     * BEFORE FIX: FAILS (first call reverts)
     * AFTER FIX:  PASSES
     */
    function test_SEC003_RaylsGuard_send_and_receive_are_independent() public {
        raylsGuard.initializeGuard();

        raylsGuard.guardedSend();
        raylsGuard.guardedReceive();

        assertEq(raylsGuard.counter(), 2, "Both send and receive should work independently");
    }
}
