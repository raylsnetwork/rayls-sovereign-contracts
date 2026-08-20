// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";

/**
 * @title F01_AuthBoundaryAndRevocation
 * @notice Companion to F01_AccessManagerScheduleExecuteBypass — answers the
 *         specific question: "if schedule() is the only thing missing auth,
 *         and execute() is bound to the scheduler by operationId, can we
 *         get away with fixing schedule() alone?"
 *
 * SHORT ANSWER (proven by tests below):
 *   - Yes, fixing schedule() alone closes the UNIVERSAL bypass (cross-actor
 *     elevation: an unauthorised EOA cannot land any `restricted` call).
 *     Reason: schedule binds the caller into `operationId`; execute requires
 *     the same `msg.sender` to consume the schedule. Bob cannot execute
 *     Alice's schedule (this is NOT a meta-tx pattern).
 *   - But there is a separate, narrower attack: role REVOCATION between
 *     schedule and execute is NOT honoured today. A user who legitimately
 *     scheduled an operation can still execute it after their role is
 *     revoked, because execute() never re-checks `allowed`. The depth-bypass
 *     in canCall lets the call land.
 *   - Closing both layers (schedule + execute) is the OZ-AccessManager-style
 *     defense in depth. Closing only schedule blocks the universal bypass
 *     but leaves the revocation window open.
 *
 * TEST SEMANTICS:
 *   - test_F01_authmodel_schedule_binds_caller_in_operationId — proves
 *     execute() is NOT a meta-tx; Bob cannot execute Alice's schedule.
 *     ALWAYS PASSES (it asserts the existing safety property).
 *   - test_F01_authmodel_execute_via_canCall_depthbypass_PRE_FIX — direct
 *     proof of the depth-bypass mechanic. ALWAYS PASSES; documents the
 *     mechanism that makes the fix necessary.
 *   - test_F01_revocation_window_role_revoked_between_schedule_and_execute
 *     — FAILS pre-fix (revoked admin still executes), PASSES only when
 *     execute() re-verifies authorization.
 *   - test_F01_pause_window_contract_paused_between_schedule_and_execute
 *     — FAILS pre-fix (pause is bypassed), PASSES only when execute()
 *     honours the pause check.
 */
contract F01_AuthBoundaryAndRevocation is Test {
    address internal admin;
    address internal alice;     // legitimate scheduler with a role
    address internal bob;       // unrelated EOA who tries to hijack Alice's schedule

    RaylsAccessManagerV1 internal manager;
    MintableTokenVault internal vault;
    bytes4 internal mintSelector;

    function setUp() public {
        admin = makeAddr("ADMIN");
        alice = makeAddr("ALICE");
        bob = makeAddr("BOB");

        RaylsAccessManagerV1 mgrImpl = new RaylsAccessManagerV1();
        bytes memory mgrInit = abi.encodeCall(RaylsAccessManagerV1.initialize, (admin));
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(address(mgrImpl), mgrInit)));
        vault = new MintableTokenVault(address(manager));
        mintSelector = MintableTokenVault.mint.selector;
    }

    // ─────────────────────────────────────────────────────────────────────
    //  AUTHORIZATION MODEL  -  these document existing protections
    // ─────────────────────────────────────────────────────────────────────

    /**
     * Proves: execute() binds to the scheduler. Bob cannot execute Alice's
     * recorded schedule. operationId = keccak256(msg.sender, target, data).
     * Always passes — it asserts the in-place protection.
     */
    function test_F01_authmodel_schedule_binds_caller_in_operationId() public {
        // POST-FIX REQUIREMENT: schedule() now rejects unauthorised callers.
        // To exercise the operationId-binds-to-scheduler property, Alice must
        // hold a legitimate role so her schedule succeeds. Then Bob (no role)
        // attempts to consume her schedule — must revert with NotScheduled
        // because operationId = keccak256(msg.sender, target, data) doesn't
        // match anything in storage for Bob.
        vm.startPrank(admin);
        uint64 minterRole = manager.registerRole("MINTER");
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = mintSelector;
        uint64[] memory roles = new uint64[](1);
        roles[0] = minterRole;
        manager.addFunctionAllowedRoles(address(vault), selectors, roles);
        manager.grantRole(minterRole, alice, 1 days);
        vm.stopPrank();

        bytes memory call = abi.encodeCall(MintableTokenVault.mint, (bob, 100 ether));

        // Alice schedules (legitimate — has role with 1-day delay).
        vm.prank(alice);
        bytes32 aliceOpId = manager.schedule(address(vault), call, 0);
        assertGt(uint256(aliceOpId), 0, "alice should have a recorded schedule");

        // Bob tries to execute Alice's schedule with the SAME calldata.
        // The operationId Bob recomputes uses Bob's address, so the lookup
        // returns 0 and validateAndConsumeSchedule reverts NotScheduled.
        vm.prank(bob);
        vm.expectRevert(); // reverts with RaylsAccessManagerV1__NotScheduled
        manager.execute(address(vault), call);
    }

    /**
     * Direct proof of the depth-bypass mechanic in canCall.
     * Asserts the property that makes the bypass possible.
     * Always passes — it documents the existing behaviour.
     */
    function test_F01_authmodel_execute_via_canCall_depthbypass_PRE_FIX() public view {
        // Sanity: from a normal external caller perspective, canCall(bob, ...)
        // returns (false, 0, false) for an unmapped selector.
        (bool allowed, uint32 delay, bool paused) = manager.canCall(bob, address(vault), mintSelector);
        assertFalse(allowed);
        assertEq(delay, 0);
        assertFalse(paused);

        // The depth-bypass at AccessManagerAuthLib L34 is what makes execute
        // succeed: when manager.target.call(...) is in flight,
        // _executingScheduledOpDepth > 0 and the manager's own canCall sees
        // `caller == address(this)` returning (true, 0, false). We cannot
        // observe this externally without entering execute(); the
        // F01_AccessManagerScheduleExecuteBypass.t.sol test reproduces the
        // full chain. This view test serves as documentation of the
        // ground-truth oracle for "would the role gate normally permit?".
    }

    // ─────────────────────────────────────────────────────────────────────
    //  REVOCATION WINDOW  -  the residual bug after fixing schedule()
    // ─────────────────────────────────────────────────────────────────────

    /**
     * Setup: register a delayed role and grant Alice ADMIN ability to call
     *        mint via that role's grant. Alice schedules. Admin revokes.
     *        Time advances past the delay. Alice calls execute().
     *
     * Pre-fix (no execute() re-check): Alice's call lands. Bob is minted
     *        100 ether even though Alice's role is gone.
     *        ⇒ test FAILS with "revoked role bypassed via depth bypass".
     *
     * Post-fix (execute() re-checks `allowed`): execute reverts with
     *        Unauthorized; Bob's balance unchanged.
     *        ⇒ test PASSES.
     */
    function test_F01_revocation_window_role_revoked_between_schedule_and_execute() public {
        // Wire up a "MINTER" role with a 1-day delay, mapped to mint selector.
        vm.startPrank(admin);
        uint64 minterRole = manager.registerRole("MINTER");
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = mintSelector;
        uint64[] memory roles = new uint64[](1);
        roles[0] = minterRole;
        manager.addFunctionAllowedRoles(address(vault), selectors, roles);

        // Grant MINTER to Alice with executionDelay=1 day. canCall returns
        // (true, 1 days, false) for Alice on this selector.
        manager.grantRole(minterRole, alice, 1 days);
        vm.stopPrank();

        // Alice schedules.
        bytes memory call = abi.encodeCall(MintableTokenVault.mint, (bob, 100 ether));
        vm.prank(alice);
        manager.schedule(address(vault), call, 0);

        // Admin revokes Alice's MINTER role BEFORE the delay expires.
        vm.prank(admin);
        manager.revokeRole(minterRole, alice);

        // Sanity: Alice now has NO authorization to call mint.
        (bool allowed, , ) = manager.canCall(alice, address(vault), mintSelector);
        assertFalse(allowed, "Alice should be unauthorized after revocation");

        // Time advances past the original 1-day delay.
        vm.warp(block.timestamp + 1 days + 1);

        // Pre-fix: Alice executes; depth-bypass lets it land.
        // Post-fix: execute() re-checks `allowed`, reverts.
        bool executed;
        vm.prank(alice);
        try manager.execute(address(vault), call) {
            executed = true;
        } catch {
            executed = false;
        }

        if (executed) {
            console2.log("F01-revocation: Alice (revoked) successfully minted via the depth bypass");
            console2.log("Bob balance after:", vault.balanceOf(bob));
        }

        assertEq(
            vault.balanceOf(bob),
            0,
            "F01: revoked role still landed mint via execute()'s depth bypass (no re-check)"
        );
    }

    /**
     * Setup: ADMIN schedules a privileged op. Admin pauses the contract.
     *        Time passes (no delay needed). Admin tries to execute.
     *
     * Pre-fix: execute() does not honor the pause. The call lands.
     *          ⇒ test FAILS with "paused contract was bypassed".
     * Post-fix: execute() checks paused → reverts.
     *          ⇒ test PASSES.
     */
    function test_F01_pause_window_contract_paused_between_schedule_and_execute() public {
        bytes memory call = abi.encodeCall(MintableTokenVault.mint, (bob, 50 ether));

        // Admin schedules.
        vm.prank(admin);
        manager.schedule(address(vault), call, 0);

        // Admin pauses the vault BEFORE executing.
        vm.prank(admin);
        manager.setContractPaused(address(vault), true);

        // Sanity: canCall now returns (_, _, paused=true).
        (, , bool paused) = manager.canCall(admin, address(vault), mintSelector);
        assertTrue(paused, "vault should be paused after setContractPaused");

        // Pre-fix: execute() ignores the pause and the depth-bypass lands the call.
        // Post-fix: execute() checks paused → reverts.
        bool landed;
        vm.prank(admin);
        try manager.execute(address(vault), call) {
            landed = true;
        } catch {
            landed = false;
        }

        if (landed) {
            console2.log("F01-pause: paused vault was bypassed by execute() depth check");
            console2.log("Bob balance after:", vault.balanceOf(bob));
        }

        assertEq(
            vault.balanceOf(bob),
            0,
            "F01: paused contract was bypassed via execute()'s depth bypass (no pause re-check)"
        );
    }
}

contract MintableTokenVault is RaylsAccessManaged {
    string public constant name = "F01-AuthBoundary-Vault";
    string public constant symbol = "F01AB";
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 value);

    constructor(address _authority) {
        _initializeAuthority(_authority);
    }

    function mint(address to, uint256 value) external restricted {
        balanceOf[to] += value;
        totalSupply += value;
        emit Transfer(address(0), to, value);
    }
}
