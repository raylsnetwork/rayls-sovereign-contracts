// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {ParticipantStorageV1} from "../../../privateHub/ParticipantStorage/ParticipantStorageV1.sol";
import {ParticipantCoreV1} from "../../../privateHub/ParticipantStorage/modules/ParticipantCore/ParticipantCoreV1.sol";
import {AuditManagerV1} from "../../../privateHub/ParticipantStorage/modules/AuditManager/AuditManagerV1.sol";
import {ParticipantStructs} from "../../../privateHub/ParticipantStorage/libraries/ParticipantStructs.sol";

import {F14_RecordingEndpoint} from "./mocks/F14_RecordingEndpoint.sol";

/**
 * @title F12_InitiateKeyAgreementMissingAccessControl
 * @notice Reproduction tests for audit finding F12:
 *         Both the facade `ParticipantStorageV1.initiateKeyAgreement` and the
 *         module `AuditManagerV1.initiateKeyAgreement` lack access control.
 *         The facade is missing `restricted`; the module is missing
 *         `onlyParticipantStorage`.
 *
 * IMPACT
 * ------
 * Any caller can initiate arbitrary key agreements between two ACTIVE
 * participants. Because `initiateKeyAgreement` enforces a strict monotonic
 * block-number ordering (AuditManagerV1.sol L161-166), pinning the block
 * number to `type(uint256).max` permanently blocks every subsequent
 * legitimate key agreement between the same pair of chains — an irreversible
 * DoS without a contract upgrade (the append-only `keyAgreementData[]` has no
 * admin-delete path).
 *
 * TEST SEMANTICS
 * --------------
 *  - `test_F12_baseline_*` — always pass.
 *  - `test_F12_exploit_*` — FAIL pre-fix (exploit succeeds), PASS post-fix.
 *  - `test_F12_postfix_*` — always pass post-fix (explicit `expectRevert`).
 */
contract F12_InitiateKeyAgreementMissingAccessControl is Test {
    address internal admin;
    address internal attacker;

    RaylsAccessManagerV1 internal manager;
    F14_RecordingEndpoint internal endpoint;
    ParticipantStorageV1 internal facade;
    ParticipantCoreV1 internal core;
    AuditManagerV1 internal auditManager;

    uint256 constant PN_A = 12345;
    uint256 constant PN_B = 12346;
    uint256 constant PRIVATE_HUB_CHAIN_ID = 99999;

    bytes4 internal facadeInitiateSelector;
    bytes4 internal moduleInitiateSelector;

    function setUp() public {
        admin = makeAddr("ADMIN");
        attacker = makeAddr("ATTACKER");

        // ── Manager ──
        RaylsAccessManagerV1 mgrImpl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(
            address(mgrImpl), abi.encodeCall(RaylsAccessManagerV1.initialize, (admin))
        )));

        // ── Endpoint ──
        endpoint = new F14_RecordingEndpoint(PRIVATE_HUB_CHAIN_ID, PRIVATE_HUB_CHAIN_ID);
        endpoint.setAuthority(address(manager));

        // ── Facade + modules (all UUPS proxies) ──
        ParticipantStorageV1 facadeImpl = new ParticipantStorageV1();
        facade = ParticipantStorageV1(address(new ERC1967Proxy(
            address(facadeImpl),
            abi.encodeCall(ParticipantStorageV1.initialize, (address(endpoint), address(manager)))
        )));

        ParticipantCoreV1 coreImpl = new ParticipantCoreV1();
        core = ParticipantCoreV1(address(new ERC1967Proxy(
            address(coreImpl),
            abi.encodeCall(ParticipantCoreV1.initialize, (address(endpoint), address(manager)))
        )));

        AuditManagerV1 auditImpl = new AuditManagerV1();
        auditManager = AuditManagerV1(address(new ERC1967Proxy(
            address(auditImpl),
            abi.encodeCall(AuditManagerV1.initialize, (address(core), address(facade), address(manager)))
        )));

        // Wire parentStorage on the core (the facade address).
        vm.prank(admin);
        core.setParticipantStorageAddress(address(facade));

        // Wire modules on the facade. EnygmaManager is not exercised by F12 —
        // supply a scratch non-zero address to satisfy the zero-address check.
        vm.prank(admin);
        facade.configureModules(
            address(core),
            address(auditManager),
            makeAddr("ENYGMA_MANAGER_STANDIN")
        );

        // Seed two ACTIVE participants (PN_A and PN_B) so
        // initiateKeyAgreement's verifyParticipant preconditions pass.
        _addAndActivateParticipant(PN_A);
        _addAndActivateParticipant(PN_B);

        facadeInitiateSelector = ParticipantStorageV1.initiateKeyAgreement.selector;
        moduleInitiateSelector = AuditManagerV1.initiateKeyAgreement.selector;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  BASELINE
    // ═════════════════════════════════════════════════════════════════════════

    function test_F12_baseline_canCall_attacker_false_on_facade() public view {
        (bool allowedFacade, , ) =
            manager.canCall(attacker, address(facade), facadeInitiateSelector);
        (bool allowedModule, , ) =
            manager.canCall(attacker, address(auditManager), moduleInitiateSelector);
        assertFalse(allowedFacade, "baseline: attacker canCall false on facade");
        assertFalse(allowedModule, "baseline: attacker canCall false on module");
    }

    function test_F12_baseline_admin_can_legitimately_initiate() public {
        bytes memory ct = hex"deadbeef";
        bytes memory dg = hex"c0ffee";
        vm.prank(admin);
        facade.initiateKeyAgreement(PN_A, PN_B, ct, dg, 1_000);
        assertEq(auditManager.getKeyAgreements(PN_A).length, 1, "legit key agreement must land");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  EXPLOIT — fails pre-fix, passes post-fix
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Attacker calls the facade's `initiateKeyAgreement` directly. Pre-fix:
     * no `restricted` on the facade, so the call lands and poisons state.
     * Post-fix: `restricted` reverts with Unauthorized.
     *
     * Assertion: no key agreement landed under PN_A after attacker's call.
     * Pre-fix → one landed → FAIL.
     * Post-fix → zero landed → PASS.
     */
    function test_F12_exploit_facade_poisons_state() public {
        bytes memory ct = hex"1337";
        bytes memory dg = hex"beef";
        uint256 pinBlock = type(uint256).max;

        bool exploited;
        vm.prank(attacker);
        try facade.initiateKeyAgreement(PN_A, PN_B, ct, dg, pinBlock) {
            exploited = true;
        } catch {
            exploited = false;
        }

        ParticipantStructs.KeyAgreementData[] memory entries = auditManager.getKeyAgreements(PN_A);
        if (exploited) {
            console2.log("F12-exploit: facade call poisoned PN_A <-> PN_B key agreement");
            console2.log("  entries on PN_A:", entries.length);
            if (entries.length > 0) {
                console2.log("  pinned blockNumber:", entries[0].blockNumber);
            }
        }

        assertEq(
            entries.length,
            0,
            "F12: attacker forged a key agreement via the facade (no `restricted` on facade)"
        );
    }

    /**
     * Attacker bypasses the facade entirely and calls the module directly.
     * Pre-fix: no `onlyParticipantStorage` on the module → the call lands.
     * Post-fix: `onlyParticipantStorage` reverts.
     */
    function test_F12_exploit_module_direct_call_poisons_state() public {
        bytes memory ct = hex"baad";
        bytes memory dg = hex"f00d";

        bool exploited;
        vm.prank(attacker);
        try auditManager.initiateKeyAgreement(PN_A, PN_B, ct, dg, type(uint256).max) {
            exploited = true;
        } catch {
            exploited = false;
        }

        ParticipantStructs.KeyAgreementData[] memory entries = auditManager.getKeyAgreements(PN_A);
        if (exploited) {
            console2.log("F12-exploit: module-direct call poisoned PN_A <-> PN_B key agreement");
            console2.log("  entries on PN_A:", entries.length);
        }

        assertEq(
            entries.length,
            0,
            "F12: attacker forged a key agreement via module-direct call (no `onlyParticipantStorage`)"
        );
    }

    /**
     * Full DoS demonstration: attacker pins blockNumber=max via the facade,
     * then admin's legitimate call with a realistic blockNumber reverts on
     * the strict monotonicity check at AuditManagerV1.sol L161-166.
     *
     * Pre-fix: the pin lands, the legit follow-up reverts → `legitLanded ==
     *          false` → assertion `legitLanded == true` FAILS.
     * Post-fix: the pin reverts, legit call succeeds → PASS.
     */
    function test_F12_exploit_dos_legitimate_call_blocked_after_poison() public {
        bytes memory ct = hex"11";
        bytes memory dg = hex"22";

        // Step 1 — attacker pins blockNumber=max.
        vm.prank(attacker);
        try facade.initiateKeyAgreement(PN_A, PN_B, ct, dg, type(uint256).max) {} catch {}

        // Step 2 — admin attempts a legitimate agreement with a realistic block.
        bool legitLanded;
        vm.prank(admin);
        try facade.initiateKeyAgreement(PN_A, PN_B, ct, dg, 42) {
            legitLanded = true;
        } catch {
            legitLanded = false;
        }

        if (!legitLanded) {
            console2.log("F12-exploit: DoS confirmed. Admin's legitimate initiateKeyAgreement reverted.");
            console2.log("  Admin is blocked by the poisoned max-blockNumber entry.");
        }

        assertTrue(
            legitLanded,
            "F12: legitimate admin call reverts after attacker pins blockNumber=max (DoS)"
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  POSTFIX explicit expectRevert — document the intended protections
    // ═════════════════════════════════════════════════════════════════════════

    function test_F12_postfix_facade_rejects_attacker() public {
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector,
                attacker
            )
        );
        facade.initiateKeyAgreement(PN_A, PN_B, hex"00", hex"00", 1);
    }

    function test_F12_postfix_module_rejects_attacker() public {
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                AuditManagerV1.AuditManagerV1__UnauthorizedCaller.selector,
                attacker
            )
        );
        auditManager.initiateKeyAgreement(PN_A, PN_B, hex"00", hex"00", 1);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Helpers
    // ═════════════════════════════════════════════════════════════════════════

    function _addAndActivateParticipant(uint256 chainId) internal {
        ParticipantStructs.ParticipantData memory data = ParticipantStructs.ParticipantData({
            chainId: chainId,
            role: ParticipantStructs.Role.PARTICIPANT,
            ownerId: "",
            name: "",
            allowedToBroadcast: true
        });
        vm.prank(admin);
        facade.addParticipant(data);
        vm.prank(admin);
        facade.updateStatus(chainId, ParticipantStructs.Status.ACTIVE);
    }
}
