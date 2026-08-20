// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {ParticipantCoreV1} from "../../../privateHub/ParticipantStorage/modules/ParticipantCore/ParticipantCoreV1.sol";

import {F14_RecordingEndpoint} from "./mocks/F14_RecordingEndpoint.sol";

/**
 * @title F14_BroadcastCurrentParticipants_ModuleBypass
 * @notice Reproduction tests for audit finding F14:
 *         `ParticipantCoreV1.broadcastCurrentParticipants` has no
 *         `onlyParticipantStorage` modifier. Its facade
 *         (`ParticipantStorageV1.broadcastCurrentParticipants`) is correctly
 *         gated by `restricted`, but an attacker can bypass it by calling the
 *         module contract directly at its deployed address.
 *
 * IMPACT
 * ------
 * Unauthorised actors can trigger a protocol-wide cross-chain participant
 * broadcast with an attacker-chosen `fromChainId` — pointing peers at forged
 * origin chains, potentially corrupting replicated `ParticipantStorage` state
 * on every PN.
 *
 * TEST SEMANTICS
 * --------------
 *  - `test_F14_baseline_*` always pass (document expected protections).
 *  - `test_F14_exploit_*` FAIL pre-fix, PASS once the module gains `onlyParticipantStorage`.
 */
contract F14_BroadcastCurrentParticipants_ModuleBypass is Test {
    address internal admin;
    address internal attacker;

    RaylsAccessManagerV1 internal manager;
    F14_RecordingEndpoint internal endpoint;
    ParticipantCoreV1 internal core;

    uint256 constant CHAIN_ID = 12345;
    uint256 constant PRIVATE_HUB_CHAIN_ID = 99999;
    uint256 constant ATTACKER_CHOSEN_CHAIN_ID = 777;

    bytes4 internal broadcastSelector;

    function setUp() public {
        admin = makeAddr("ADMIN");
        attacker = makeAddr("ATTACKER");

        // Deploy manager.
        RaylsAccessManagerV1 mgrImpl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(
            address(mgrImpl), abi.encodeCall(RaylsAccessManagerV1.initialize, (admin))
        )));

        // Deploy recording endpoint.
        endpoint = new F14_RecordingEndpoint(CHAIN_ID, PRIVATE_HUB_CHAIN_ID);
        endpoint.setAuthority(address(manager));

        // Deploy ParticipantCoreV1 via UUPS proxy.
        ParticipantCoreV1 coreImpl = new ParticipantCoreV1();
        core = ParticipantCoreV1(address(new ERC1967Proxy(
            address(coreImpl),
            abi.encodeCall(ParticipantCoreV1.initialize, (address(endpoint), address(manager)))
        )));

        // Set a parentStorage (stand-in — the facade is not needed for the
        // module-direct bypass demonstration).
        vm.prank(admin);
        core.setParticipantStorageAddress(makeAddr("FACADE_STANDIN"));

        broadcastSelector = ParticipantCoreV1.broadcastCurrentParticipants.selector;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  BASELINE
    // ═════════════════════════════════════════════════════════════════════════

    /// canCall returns false for the attacker — proves the selector is
    /// unmapped at the manager layer (ADMIN-only). Always passes.
    function test_F14_baseline_canCall_attacker_false() public view {
        (bool allowed, , ) = manager.canCall(attacker, address(core), broadcastSelector);
        assertFalse(allowed, "baseline: attacker must not pass canCall on the module");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  EXPLOIT — fails pre-fix, passes post-fix
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Attacker calls the module directly at its deployed address with an
     * arbitrary `fromChainId`. Pre-fix: the call lands, the endpoint records
     * an outgoing cross-chain broadcast. Post-fix: `onlyParticipantStorage`
     * reverts the call.
     *
     * Assertion: `endpoint.broadcastCount() == 0`.
     * Pre-fix → count > 0 → FAIL.
     * Post-fix → count == 0 → PASS.
     */
    function test_F14_exploit_attacker_bypasses_via_module_direct_call() public {
        uint256 countBefore = endpoint.broadcastCount();

        bool succeeded;
        vm.prank(attacker);
        try core.broadcastCurrentParticipants(ATTACKER_CHOSEN_CHAIN_ID) {
            succeeded = true;
        } catch {
            succeeded = false;
        }

        uint256 countAfter = endpoint.broadcastCount();

        if (succeeded && countAfter > countBefore) {
            console2.log("F14-exploit: attacker fired a cross-chain broadcast via module-direct call");
            console2.log("  endpoint recorded broadcasts:", countAfter);
            F14_RecordingEndpoint.Broadcast memory b = endpoint.getBroadcast(countAfter - 1);
            console2.log("  dstChainId:", b.dstChainId);
            console2.log("  sender (module):", b.sender);
        }

        assertEq(
            countAfter,
            countBefore,
            "F14: attacker fired broadcastCurrentParticipants via module-direct call (no onlyParticipantStorage)"
        );
    }

    /**
     * Explicit post-fix positive: attacker's direct module call reverts with
     * `ParticipantCoreV1__UnauthorizedCaller`. Pre-fix: the call succeeds and
     * `vm.expectRevert` fires → FAIL. Post-fix: revert matches → PASS.
     */
    function test_F14_postfix_attacker_direct_call_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                ParticipantCoreV1.ParticipantCoreV1__UnauthorizedCaller.selector,
                attacker
            )
        );
        core.broadcastCurrentParticipants(ATTACKER_CHOSEN_CHAIN_ID);
    }

    /**
     * Facade-path positive: when the legitimate `parentStorage` invokes the
     * module, the call must still succeed and produce a broadcast. This
     * guards against an over-restrictive fix that also blocks the facade.
     * PASSES both pre- and post-fix.
     */
    function test_F14_postfix_facade_path_still_broadcasts() public {
        address facadeStandin = makeAddr("FACADE_STANDIN");
        uint256 before_ = endpoint.broadcastCount();

        vm.prank(facadeStandin);
        core.broadcastCurrentParticipants(CHAIN_ID);

        assertEq(endpoint.broadcastCount(), before_ + 1, "facade path must still dispatch broadcasts");
    }
}
