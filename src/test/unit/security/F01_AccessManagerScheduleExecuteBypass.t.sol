// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";

/**
 * @title F01_AccessManagerScheduleExecuteBypass
 * @notice Reproduction tests for audit finding F01:
 *         Universal `restricted` bypass via unauthenticated schedule + execute
 *         on RaylsAccessManagerV1.
 *
 * BACKGROUND
 * ----------
 * `AccessManagerScheduleLib.schedule` destructures only `callerDelay` from the
 * `canCall` return tuple and never reverts when the caller has no authorization.
 * `RaylsAccessManagerV1.execute` does not gate on `allowed` either. The
 * `AccessManagerAuthLib.canCall` short-circuit at line 34
 *
 *     if (caller == address(this) && $._executingScheduledOpDepth > 0)
 *         return (true, 0, false);
 *
 * means that during `execute`, when the manager calls the target, the target's
 * `restricted` modifier sees `allowed = true` regardless of the original
 * scheduler's permissions. This makes `schedule` + `execute` a universal bypass
 * of every `restricted` function on every `RaylsAccessManaged` consumer.
 *
 * TEST SEMANTICS (per project convention)
 * ---------------------------------------
 *  - Tests prefixed `test_F01_baseline_*` document expected behaviour and ALWAYS
 *    pass - they prove that the test scaffolding is correct.
 *  - Tests prefixed `test_F01_exploit_*` REPRODUCE the vulnerability. They are
 *    expected to FAIL on current code (the exploit succeeds) and PASS after the
 *    fix lands (the exploit is blocked).
 *  - Tests prefixed `test_F01_postfix_*` describe the legitimate behaviour the
 *    fix preserves. They MUST pass both pre- and post-fix.
 */
contract F01_AccessManagerScheduleExecuteBypassTest is Test {
    // ─────────────────────────────────────────────────────────────────────────
    //  Actors
    // ─────────────────────────────────────────────────────────────────────────
    address internal admin;
    address internal attacker;
    address internal innocentBystander;

    // ─────────────────────────────────────────────────────────────────────────
    //  Contracts
    // ─────────────────────────────────────────────────────────────────────────
    RaylsAccessManagerV1 internal manager;
    MintableTokenVault internal vault;

    // selector of MintableTokenVault.mint(address,uint256) - captured in setUp.
    bytes4 internal mintSelector;

    // ─────────────────────────────────────────────────────────────────────────
    //  Setup
    // ─────────────────────────────────────────────────────────────────────────
    function setUp() public {
        admin = makeAddr("ADMIN");
        attacker = makeAddr("ATTACKER");
        innocentBystander = makeAddr("BYSTANDER");

        // Deploy RaylsAccessManagerV1 via ERC1967 proxy with `admin` as initial admin.
        RaylsAccessManagerV1 mgrImpl = new RaylsAccessManagerV1();
        bytes memory mgrInit = abi.encodeCall(RaylsAccessManagerV1.initialize, (admin));
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(address(mgrImpl), mgrInit)));

        // Deploy the victim contract with the manager as its authority.
        // The vault exposes a `restricted mint(address,uint256)` function whose
        // state mutation is publicly observable via balances/totalSupply.
        vault = new MintableTokenVault(address(manager));
        mintSelector = MintableTokenVault.mint.selector;

        // We deliberately do NOT register the mint selector against any role.
        // This is the strictest configuration: an unmapped selector defaults to
        // ADMIN-only via canCall's `if (selSummary == 0) return (false, 0, false)`
        // branch. Even in this configuration, the depth-bypass lets the exploit
        // land - that is the worst case we want to demonstrate.
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  BASELINE TESTS  -  must ALWAYS pass
    // ═════════════════════════════════════════════════════════════════════════

    /// Direct call by the attacker reverts with the expected Unauthorized error.
    /// Proves the vault's `restricted` modifier denies non-privileged callers
    /// when entered through the normal path.
    function test_F01_baseline_attacker_cannot_call_directly() public {
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector,
                attacker
            )
        );
        vault.mint(attacker, 1_000 ether);
    }

    /// Admin can mint directly (ADMIN bypass in canCall).
    /// Proves the test scaffolding correctly wires ADMIN through to the
    /// manager's `canCall` and that direct calls work for authorized actors.
    function test_F01_baseline_admin_can_call_directly() public {
        vm.prank(admin);
        vault.mint(innocentBystander, 1_000 ether);

        assertEq(
            vault.balanceOf(innocentBystander),
            1_000 ether,
            "Admin direct mint should succeed"
        );
        assertEq(vault.totalSupply(), 1_000 ether, "totalSupply should reflect mint");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  EXPLOIT REPRODUCTIONS  -  FAIL pre-fix, PASS post-fix
    // ═════════════════════════════════════════════════════════════════════════

    /// Reproduces the first half of the bypass: attacker calls `schedule()`
    /// without holding any role. Pre-fix: schedule succeeds and emits
    /// `OperationScheduled`. Post-fix: schedule reverts.
    function test_F01_exploit_attacker_can_schedule_without_authorization() public {
        bytes memory call = abi.encodeCall(MintableTokenVault.mint, (attacker, 1_000 ether));

        // The fix will revert here with `RaylsAccessManagerV1__Unauthorized(attacker)`.
        // Pre-fix this expectRevert never fires, the test fails, and the exploit is
        // confirmed (attacker scheduled a privileged op without permission).
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("RaylsAccessManagerV1__Unauthorized(address)")),
                attacker
            )
        );
        manager.schedule(address(vault), call, 0);
    }

    /// Reproduces the FULL exploit chain: attacker schedules + executes a
    /// privileged mint, vault state mutates.
    /// Pre-fix: vault.balanceOf(attacker) becomes 1_000 ether - the assertion
    /// `attackerBalance == 0` fails, and the test logs the exploit details.
    /// Post-fix: schedule reverts, the try/catch records that the exploit was
    /// blocked, the final assertion passes.
    function test_F01_exploit_full_chain_attacker_mints_via_schedule_execute() public {
        bytes memory call = abi.encodeCall(MintableTokenVault.mint, (attacker, 1_000 ether));

        uint256 attackerBalanceBefore = vault.balanceOf(attacker);
        uint256 totalSupplyBefore = vault.totalSupply();

        // Phase 1 - schedule.
        bool scheduleSucceeded;
        bytes32 opId;
        vm.prank(attacker);
        try manager.schedule(address(vault), call, 0) returns (bytes32 _opId) {
            scheduleSucceeded = true;
            opId = _opId;
        } catch {
            scheduleSucceeded = false;
        }

        // Phase 2 - execute (only attempted if schedule succeeded).
        bool executeSucceeded;
        if (scheduleSucceeded) {
            vm.prank(attacker);
            try manager.execute(address(vault), call) returns (uint32) {
                executeSucceeded = true;
            } catch {
                executeSucceeded = false;
            }
        }

        uint256 attackerBalanceAfter = vault.balanceOf(attacker);
        uint256 totalSupplyAfter = vault.totalSupply();

        // Comprehensive evidence dump - this is what a reader sees when the
        // assertion below fires.
        if (attackerBalanceAfter != attackerBalanceBefore) {
            console2.log("============================================================");
            console2.log("F01 EXPLOIT REPRODUCED");
            console2.log("============================================================");
            console2.log("Victim contract              :", address(vault));
            console2.log("Access manager               :", address(manager));
            console2.log("Attacker                     :", attacker);
            console2.log("Admin (uninvolved)           :", admin);
            console2.log("schedule() succeeded?        :", scheduleSucceeded);
            console2.log("execute()  succeeded?        :", executeSucceeded);
            console2.log("operationId                  :", uint256(opId));
            console2.log("--- impact ---");
            console2.log("attacker balance before      :", attackerBalanceBefore);
            console2.log("attacker balance after       :", attackerBalanceAfter);
            console2.log("totalSupply before           :", totalSupplyBefore);
            console2.log("totalSupply after            :", totalSupplyAfter);
            console2.log("tokens minted to attacker    :", attackerBalanceAfter - attackerBalanceBefore);
            console2.log("--- attack chain ---");
            console2.log("1. attacker calls manager.schedule(vault, mint(attacker, 1000e18), 0)");
            console2.log("   schedule() does NOT verify caller authorization");
            console2.log("2. attacker calls manager.execute(vault, mint(attacker, 1000e18))");
            console2.log("   execute() does NOT re-verify authorization");
            console2.log("3. execute() does manager.target.call(mint(attacker, 1000e18))");
            console2.log("   the target sees msg.sender == manager");
            console2.log("4. target's restricted modifier asks manager.canCall(manager, target, mint.selector)");
            console2.log("   canCall hits: caller == address(this) && depth > 0  =>  return (true, 0, false)");
            console2.log("5. mint executes with full authority. Attacker holds 1000 tokens with no role.");
            console2.log("============================================================");
        }

        // The exploit MUST be blocked. Pre-fix this assertion fails and the
        // detailed log above is printed for the engineer reading the failure.
        assertEq(
            attackerBalanceAfter,
            attackerBalanceBefore,
            "F01: attacker minted tokens via schedule+execute bypass"
        );
        assertEq(
            totalSupplyAfter,
            totalSupplyBefore,
            "F01: totalSupply changed without authorization"
        );
    }

    /// Demonstrates that the bypass works regardless of whether the selector
    /// has any role mapping. The mint selector is unmapped (defaults to
    /// ADMIN-only). The depth bypass overrides the selector mapping check.
    /// Pre-fix: bystander gets 500 ether minted to them by the attacker.
    /// Post-fix: schedule reverts.
    function test_F01_exploit_works_on_unmapped_selector() public {
        bytes memory call = abi.encodeCall(MintableTokenVault.mint, (innocentBystander, 500 ether));

        uint256 bystanderBefore = vault.balanceOf(innocentBystander);

        vm.prank(attacker);
        try manager.schedule(address(vault), call, 0) {
            vm.prank(attacker);
            try manager.execute(address(vault), call) {} catch {}
        } catch {}

        uint256 bystanderAfter = vault.balanceOf(innocentBystander);

        if (bystanderAfter != bystanderBefore) {
            console2.log("F01 EXPLOIT REPRODUCED - unmapped selector path");
            console2.log("attacker:", attacker);
            console2.log("bystander:", innocentBystander);
            console2.log("bystander balance before:", bystanderBefore);
            console2.log("bystander balance after :", bystanderAfter);
            console2.log("Even with mint.selector unmapped (ADMIN-only by default), the depth bypass made it callable.");
        }

        assertEq(
            bystanderAfter,
            bystanderBefore,
            "F01: depth bypass let attacker mint to bystander on an unmapped selector"
        );
    }

    /// A paused contract MUST block scheduled execution as well. This catches
    /// fixes that gate `schedule` but forget to gate `execute` (the canCall
    /// pause-check on line 29 is hit BEFORE the depth-bypass on line 34, so
    /// `paused` still returns true - but only if the manager's `canCall`
    /// is consulted at execute time, which the current code does AFTER the
    /// target.call. We assert the protocol-level invariant that pausing a
    /// contract blocks the schedule recording too, since the fix must short
    /// circuit on `paused`).
    function test_F01_exploit_paused_contract_should_reject_schedule() public {
        // Admin pauses the vault.
        vm.prank(admin);
        manager.setContractPaused(address(vault), true);

        bytes memory call = abi.encodeCall(MintableTokenVault.mint, (attacker, 1 ether));

        // After fix this should revert. Pre-fix it succeeds because schedule
        // ignores the `paused` return of canCall.
        bool scheduled;
        vm.prank(attacker);
        try manager.schedule(address(vault), call, 0) {
            scheduled = true;
        } catch {
            scheduled = false;
        }

        if (scheduled) {
            console2.log("F01 EXPLOIT - schedule succeeded against a PAUSED contract");
            console2.log("Pause status was ignored by AccessManagerScheduleLib.schedule");
        }

        assertFalse(
            scheduled,
            "F01: schedule should reject calls targeting a paused contract"
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  POSTFIX SAFETY  -  must always pass
    // ═════════════════════════════════════════════════════════════════════════

    /// Proves the legitimate ADMIN schedule+execute flow is preserved by the
    /// fix. ADMIN holds the role; canCall returns allowed=true; schedule
    /// records; execute lands the call.
    function test_F01_postfix_admin_legitimate_schedule_execute_still_works() public {
        bytes memory call = abi.encodeCall(MintableTokenVault.mint, (innocentBystander, 250 ether));

        vm.prank(admin);
        manager.schedule(address(vault), call, 0);

        vm.prank(admin);
        manager.execute(address(vault), call);

        assertEq(
            vault.balanceOf(innocentBystander),
            250 ether,
            "Admin schedule+execute must still mint successfully"
        );
    }

    /// A user with a delegated, delayed role can still schedule and execute
    /// after the delay. The fix must preserve this opt-in delay path.
    /// Setup: register a "DELAYED_MINTER" role with a 1-day delay, map mint
    /// selector to it, grant to bystander with `executionDelay = 1 days`.
    /// Bystander schedules now, fast-forwards 1 day, executes - succeeds.
    function test_F01_postfix_delayed_role_holder_can_schedule_and_execute() public {
        // Register the role and grant to bystander with a 1-day execution delay.
        vm.startPrank(admin);
        uint64 roleId = manager.registerRole("DELAYED_MINTER");

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = mintSelector;
        uint64[] memory roles = new uint64[](1);
        roles[0] = roleId;
        manager.addFunctionAllowedRoles(address(vault), selectors, roles);

        manager.grantRole(roleId, innocentBystander, 1 days);
        vm.stopPrank();

        bytes memory call = abi.encodeCall(MintableTokenVault.mint, (innocentBystander, 100 ether));

        // Bystander schedules - canCall returns (allowed=true via role, delay=1 day).
        vm.prank(innocentBystander);
        manager.schedule(address(vault), call, 0);

        // Fast-forward past the delay.
        vm.warp(block.timestamp + 1 days + 1);

        // Bystander executes after delay - must succeed.
        vm.prank(innocentBystander);
        manager.execute(address(vault), call);

        assertEq(
            vault.balanceOf(innocentBystander),
            100 ether,
            "Delayed role holder schedule+execute must still work after fix"
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Victim contract - minimal mintable token using RaylsAccessManaged.
//  The `mint` function is the privileged entry point under attack.
// ─────────────────────────────────────────────────────────────────────────────
contract MintableTokenVault is RaylsAccessManaged {
    string public constant name = "F01-Vulnerable-Token";
    string public constant symbol = "F01V";

    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 value);

    constructor(address _authority) {
        _initializeAuthority(_authority);
    }

    /// Restricted mint - under normal authorization rules only ADMIN
    /// (or a granted DELAYED_MINTER role) can call this.
    function mint(address to, uint256 value) external restricted {
        balanceOf[to] += value;
        totalSupply += value;
        emit Transfer(address(0), to, value);
    }
}
