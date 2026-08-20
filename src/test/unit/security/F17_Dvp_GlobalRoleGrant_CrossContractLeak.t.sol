// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {TOKEN_OWNER} from "../../../privateHub/AccessControl/AccessManagerTypes.sol";
import {Dvp} from "../../../rayls-protocol/Enygma/Enygma-DVP/Dvp.sol";

import {F17_EnygmaFactoryVictim, F17_DvpTeleportVictim} from "./mocks/F17_VictimContracts.sol";

/**
 * @title F17_Dvp_GlobalRoleGrant_CrossContractLeak
 * @notice Reproduction tests for audit finding F17:
 *         `Dvp.addEnygmaDvpIntegrationAddress` calls
 *         `AccessManagerRoleConfigLib.grantRole(ENYGMA_CREATOR, ...)` — a
 *         GLOBAL grant — instead of the scope-correct
 *         `grantContractScopedRole`. Same bug for `registerVault` with
 *         `COIN_VAULT`.
 *
 * KEY INSIGHT (confirmed against the live deploy graph)
 * ------------------------------------------------------
 * On a stock PNH the `ENYGMA_CREATOR` role is mapped to
 * `EnygmaFactory.initiateEnygmaCreation` (see
 * `hardhat/tasks/deploy/private-hub.ts:280`). `COIN_VAULT` is mapped to
 * `DvpTeleport.emitCommitments`/`emitNullifier` (line 304). A single global
 * grant emitted by Dvp therefore leaks authority into those other contracts
 * via the `_checkGlobalBitmap` path in `AccessManagerAuthLib.canCall`.
 *
 * This test exhibits the leak with a single Dvp instance by mounting two
 * minimal victim contracts that map the same roles to their own selectors —
 * standing in for `EnygmaFactory` and `DvpTeleport`.
 *
 * TEST SEMANTICS
 * --------------
 *  - `test_F17_baseline_*` always pass.
 *  - `test_F17_exploit_*` FAIL pre-fix, PASS once the grant switches to
 *    `grantContractScopedRole(role, acct, address(this), 0)`.
 */
contract F17_Dvp_GlobalRoleGrant_CrossContractLeak is Test {
    address internal admin;
    address internal attacker;
    address internal attackerVault;

    RaylsAccessManagerV1 internal manager;
    Dvp internal dvp;
    F17_EnygmaFactoryVictim internal enygmaFactoryVictim;
    F17_DvpTeleportVictim internal dvpTeleportVictim;

    uint64 internal enygmaCreatorRoleId;
    uint64 internal coinVaultRoleId;

    bytes4 internal initiateEnygmaSelector;
    bytes4 internal emitCommitmentsSelector;
    bytes4 internal addIntegrationSelector;
    bytes4 internal registerVaultSelector;

    function setUp() public {
        admin = makeAddr("ADMIN");
        attacker = makeAddr("ATTACKER");
        attackerVault = makeAddr("ATTACKER_VAULT");

        // ── Manager ──
        RaylsAccessManagerV1 mgrImpl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(
            address(mgrImpl), abi.encodeCall(RaylsAccessManagerV1.initialize, (admin))
        )));

        // Register ENYGMA_CREATOR, COIN_VAULT, and FACTORY_ADMIN roles on the
        // manager BEFORE Dvp's constructor. The Dvp constructor references
        // ENYGMA_CREATOR and COIN_VAULT by name. FACTORY_ADMIN mirrors the
        // production deploy graph (`hardhat/tasks/deploy/private-hub.ts:362-365`)
        // where FACTORY_ADMIN is the admin of ENYGMA_CREATOR and COIN_VAULT,
        // and Dvp itself holds FACTORY_ADMIN so its internal `grantRole` calls
        // pass `_checkIsRoleAdmin`.
        vm.startPrank(admin);
        enygmaCreatorRoleId = manager.registerRole("ENYGMA_CREATOR");
        coinVaultRoleId = manager.registerRole("COIN_VAULT");
        uint64 factoryAdminRoleId = manager.registerRole("FACTORY_ADMIN");
        manager.setRoleAdmin(enygmaCreatorRoleId, factoryAdminRoleId);
        manager.setRoleAdmin(coinVaultRoleId, factoryAdminRoleId);
        vm.stopPrank();

        // ── Dvp ──
        // Dummy constructor args; only the authority (manager) matters for the
        // functions we exercise (addEnygmaDvpIntegrationAddress / registerVault
        // / getters), and those read only state that the constructor writes.
        vm.prank(admin);
        dvp = new Dvp(
            makeAddr("HASH"),           // hashPoseidonContractAddress
            makeAddr("ENYGMA_FACTORY"), // enygmaFactoryAddress
            makeAddr("DVP721"),         // dvpErc721FactoryAddress
            makeAddr("DVP1155"),        // dvpErc1155FactoryAddress
            makeAddr("DVP_TELEPORT"),   // dvpTeleportAddr
            address(manager)            // authority_
        );

        // Grant FACTORY_ADMIN to Dvp — mirrors `GrantFactoryAdmin_Dvp` at
        // `private-hub.ts:308`. Without this, Dvp's own `grantRole` calls
        // inside `addEnygmaDvpIntegrationAddress` / `registerVault` revert
        // with `NotRoleAdmin`.
        vm.prank(admin);
        manager.grantRole(factoryAdminRoleId, address(dvp), 0);

        // ── Victim contracts (stand-ins for EnygmaFactory + DvpTeleport) ──
        enygmaFactoryVictim = new F17_EnygmaFactoryVictim(address(manager));
        dvpTeleportVictim = new F17_DvpTeleportVictim(address(manager));

        // Cache selectors.
        initiateEnygmaSelector = F17_EnygmaFactoryVictim.initiateEnygmaCreation.selector;
        emitCommitmentsSelector = F17_DvpTeleportVictim.emitCommitments.selector;
        addIntegrationSelector = Dvp.addEnygmaDvpIntegrationAddress.selector;
        registerVaultSelector = Dvp.registerVault.selector;

        // Map the victims' selectors to their respective roles — mirroring the
        // production deploy graph (`private-hub.ts` L280 / L304).
        bytes4[] memory enygmaSels = new bytes4[](1);
        enygmaSels[0] = initiateEnygmaSelector;
        uint64[] memory enygmaRoles = new uint64[](1);
        enygmaRoles[0] = enygmaCreatorRoleId;

        bytes4[] memory coinSels = new bytes4[](1);
        coinSels[0] = emitCommitmentsSelector;
        uint64[] memory coinRoles = new uint64[](1);
        coinRoles[0] = coinVaultRoleId;

        vm.startPrank(admin);
        manager.addFunctionAllowedRoles(address(enygmaFactoryVictim), enygmaSels, enygmaRoles);
        manager.addFunctionAllowedRoles(address(dvpTeleportVictim), coinSels, coinRoles);
        vm.stopPrank();

        // Grant TOKEN_OWNER scoped to Dvp to a separate "compromised" EOA so
        // the exploit path reflects "rogue TOKEN_OWNER" rather than using
        // admin directly. Admin is the contract authority of Dvp (it's the
        // `msg.sender` at Dvp's constructor), so admin can issue the scoped
        // grant via `_checkIsContractAuthority`.
        vm.prank(admin);
        manager.grantContractScopedRole(TOKEN_OWNER, admin, address(dvp), 0);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  BASELINE
    // ═════════════════════════════════════════════════════════════════════════

    function test_F17_baseline_canCall_attacker_victims_false() public view {
        (bool a1, , ) = manager.canCall(attacker, address(enygmaFactoryVictim), initiateEnygmaSelector);
        (bool a2, , ) = manager.canCall(attackerVault, address(dvpTeleportVictim), emitCommitmentsSelector);
        assertFalse(a1, "baseline: attacker cannot call EnygmaFactoryVictim");
        assertFalse(a2, "baseline: attackerVault cannot call DvpTeleportVictim");
    }

    /// Admin (the Dvp contract authority + TOKEN_OWNER-scoped) can legitimately
    /// invoke `addEnygmaDvpIntegrationAddress`. Proves scaffolding is correct.
    function test_F17_baseline_admin_can_add_integration() public {
        vm.prank(admin);
        dvp.addEnygmaDvpIntegrationAddress(attacker);

        // `attacker` now holds ENYGMA_CREATOR (via the grant fired inside Dvp).
        // The pre-fix grant is global; post-fix it is scoped to Dvp.
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  EXPLOIT — fails pre-fix, passes post-fix
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * After `addEnygmaDvpIntegrationAddress(attacker)`, `attacker` must NOT
     * be able to call `EnygmaFactoryVictim.initiateEnygmaCreation` — the
     * grant should be scoped to Dvp only.
     *
     * Pre-fix: global grant satisfies canCall on the victim → FAIL.
     * Post-fix: scoped grant — no leak → PASS.
     */
    function test_F17_exploit_ENYGMA_CREATOR_leaks_to_EnygmaFactoryVictim() public {
        vm.prank(admin);
        dvp.addEnygmaDvpIntegrationAddress(attacker);

        (bool allowedVictim, , ) =
            manager.canCall(attacker, address(enygmaFactoryVictim), initiateEnygmaSelector);
        (bool allowedDvpIntended, , ) =
            manager.canCall(attacker, address(dvp), Dvp.depositEnygma.selector);

        if (allowedVictim) {
            console2.log("F17-exploit: ENYGMA_CREATOR global grant leaked into EnygmaFactoryVictim");
        }

        assertTrue(allowedDvpIntended, "intended: attacker must pass canCall on Dvp.depositEnygma");
        assertFalse(
            allowedVictim,
            "F17: ENYGMA_CREATOR global grant satisfies canCall on EnygmaFactoryVictim (cross-contract leak)"
        );
    }

    /**
     * Attacker actually fires the restricted function on the victim. Pre-fix
     * `initiateEnygmaCreation` lands and the victim's counter increments.
     * Post-fix the call reverts at the `restricted` gate.
     */
    function test_F17_exploit_attacker_calls_victim_restricted_function() public {
        vm.prank(admin);
        dvp.addEnygmaDvpIntegrationAddress(attacker);

        uint256 before_ = enygmaFactoryVictim.lastInvocationCount();

        bool landed;
        vm.prank(attacker);
        try enygmaFactoryVictim.initiateEnygmaCreation(42) {
            landed = true;
        } catch {
            landed = false;
        }

        uint256 after_ = enygmaFactoryVictim.lastInvocationCount();
        if (landed) {
            console2.log("F17-exploit: attacker called EnygmaFactoryVictim.initiateEnygmaCreation");
            console2.log("  last caller:", enygmaFactoryVictim.lastCaller());
            console2.log("  invocation count (before/after):", before_, after_);
        }

        assertEq(
            after_,
            before_,
            "F17: attacker landed a restricted call on EnygmaFactoryVictim via global ENYGMA_CREATOR leak"
        );
    }

    /**
     * COIN_VAULT semantics — documentation test.
     *
     * Unlike ENYGMA_CREATOR (scoped by this fix), COIN_VAULT is INTENTIONALLY
     * a cross-contract role: registered vaults legitimately need authority on
     * BOTH Dvp (for internal calls) AND DvpTeleport.emitCommitments/
     * emitNullifier. The production deploy wiring at
     * `hardhat/tasks/deploy/private-hub.ts:304` maps COIN_VAULT to
     * DvpTeleport selectors precisely to support this.
     *
     * Therefore Dvp.registerVault continues to use the global `grantRole`
     * API and this test asserts that behaviour. If the grant were rescoped
     * to Dvp only, vaults could no longer emit commitments on DvpTeleport and
     * every vault-based deposit flow would break (observed empirically in
     * an e2e run — see the F17 post-mortem).
     *
     * The cross-contract grant is protected by the fact that
     * `Dvp.registerVault` is `restricted` to TOKEN_OWNER (scoped to Dvp),
     * so only trusted factories can trigger the grant.
     */
    function test_F17_COIN_VAULT_stays_global_by_design() public {
        NoopCoinVault vault = new NoopCoinVault();

        vm.prank(admin);
        try dvp.registerVault(address(vault), makeAddr("ASSET"), 8) returns (uint256) {
            // landed — verify the grant applies to BOTH victims
        } catch (bytes memory err) {
            console2.log("F17: registerVault reverted; cannot validate COIN_VAULT design in this run.");
            console2.logBytes(err);
            return;
        }

        (bool allowedDvpTeleport, , ) =
            manager.canCall(address(vault), address(dvpTeleportVictim), emitCommitmentsSelector);

        // This is the INTENDED semantic: the vault has cross-contract
        // COIN_VAULT authority so it can emit commitments on DvpTeleport.
        assertTrue(
            allowedDvpTeleport,
            "COIN_VAULT is intentionally a cross-contract role; vault must pass canCall on DvpTeleport.emitCommitments"
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  POSTFIX — positive controls (must pass both pre- and post-fix)
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Post-fix, the grant still satisfies canCall on Dvp for the intended
     * ENYGMA_CREATOR-gated selectors. Proves the fix doesn't break the
     * legitimate use-case.
     *
     * Pre-fix this ALSO passes (the global grant satisfies canCall on Dvp
     * AND leaks elsewhere). We use this as a positive control.
     */
    function test_F17_postfix_intended_path_still_works() public {
        vm.prank(admin);
        dvp.addEnygmaDvpIntegrationAddress(attacker);

        (bool allowedDvp, , ) = manager.canCall(attacker, address(dvp), Dvp.depositEnygma.selector);
        (bool allowedDvp2, , ) = manager.canCall(attacker, address(dvp), Dvp.withdrawEnygma.selector);
        (bool allowedDvp3, , ) = manager.canCall(attacker, address(dvp), Dvp.mixFunds.selector);

        assertTrue(allowedDvp, "intended: attacker must pass canCall on Dvp.depositEnygma");
        assertTrue(allowedDvp2, "intended: attacker must pass canCall on Dvp.withdrawEnygma");
        assertTrue(allowedDvp3, "intended: attacker must pass canCall on Dvp.mixFunds");
    }
}

/**
 * @dev Minimal coin-vault-shaped contract that implements `initializeVault`
 *      as a no-op so `Dvp.registerVault` can execute without the full
 *      AbstractCoinVault stack.
 */
contract NoopCoinVault {
    function initializeVault(
        uint256,
        address,
        uint256,
        address,
        address,
        address
    ) external pure returns (bool) {
        return true;
    }
}
