// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import "../../../rayls-protocol/Enygma/Enygma-Payments/EnygmaDvpIntegration.sol";

/**
 * @title Security Test: EnygmaDvpIntegration Access Control
 * @notice Tests that configuration functions have proper access control (onlyFactory).
 * @dev These tests FAIL when vulnerabilities exist (no revert), PASS when code is secure (reverts).
 *
 * VULNERABILITY:
 * All four configuration functions (addDepositToDvpVerifier, addWithdrawFromDvpVerifier,
 * addDvp, setVaultId) are public with NO access control. An attacker can front-run the
 * factory's configuration and hijack Enygma DvP routing.
 *
 * EXPECTED BEHAVIOR AFTER FIX:
 * - Configuration functions MUST revert when called by non-factory addresses
 * - Only the factory address (set in constructor) may configure the contract
 *
 * TEST LOGIC:
 * - Tests use vm.expectRevert() — expects the function call to revert
 * - If function HAS onlyFactory → reverts → test PASSES
 * - If function LACKS onlyFactory → doesn't revert → test FAILS
 */
contract EnygmaDvpIntegrationAccessControlTest is Test {
    EnygmaDvpIntegration public integration;

    address public factory;
    address public attacker;
    address public enygmaV1;

    // Expected custom error after fix — matches EnygmaV1 naming convention
    error EnygmaDvpIntegration__OnlyFactoryAllowed();

    address constant FAKE_VERIFIER = address(0xBEEF);
    address constant FAKE_DVP = address(0xCAFE);
    uint256 constant FAKE_VAULT_ID = 42;

    function setUp() public {
        factory = makeAddr("factory");
        attacker = makeAddr("attacker");
        enygmaV1 = makeAddr("enygmaV1");

        // Deploy the integration contract with factory as the authorized configurer
        integration = new EnygmaDvpIntegration(enygmaV1, factory);
    }

    // ============================================================
    // ACCESS CONTROL TESTS — NEGATIVE (attacker must be blocked)
    // These FAIL when vulnerability exists, PASS when fixed
    // ============================================================

    /**
     * @notice SECURITY: addDepositToDvpVerifier() MUST have onlyFactory access control
     * @dev ATTACK: Attacker sets a malicious deposit verifier that accepts any proof,
     *      allowing them to fake deposits into the DVP vault.
     *
     * TEST BEHAVIOR:
     * - FAILS when vulnerability exists (function doesn't revert for attacker)
     * - PASSES when fixed (function reverts with OnlyFactoryAllowed)
     */
    function test_SECURITY_addDepositToDvpVerifier_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(EnygmaDvpIntegration__OnlyFactoryAllowed.selector);
        integration.addDepositToDvpVerifier(FAKE_VERIFIER, 2);
    }

    /**
     * @notice SECURITY: addWithdrawFromDvpVerifier() MUST have onlyFactory access control
     * @dev ATTACK: Attacker sets a malicious withdraw verifier that accepts any proof,
     *      allowing them to drain funds from the DVP vault.
     */
    function test_SECURITY_addWithdrawFromDvpVerifier_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(EnygmaDvpIntegration__OnlyFactoryAllowed.selector);
        integration.addWithdrawFromDvpVerifier(FAKE_VERIFIER, 2);
    }

    /**
     * @notice SECURITY: addDvp() MUST have onlyFactory access control
     * @dev ATTACK: Attacker sets a malicious DVP contract address. All deposits and
     *      withdrawals then route through attacker-controlled contract, enabling fund theft.
     */
    function test_SECURITY_addDvp_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(EnygmaDvpIntegration__OnlyFactoryAllowed.selector);
        integration.addDvp(FAKE_DVP);
    }

    /**
     * @notice SECURITY: setVaultId() MUST have onlyFactory access control
     * @dev ATTACK: Attacker front-runs factory to set vaultId to an attacker-controlled vault.
     *      All subsequent DVP operations use the wrong vault, enabling fund redirection.
     *      Note: even though setVaultId has a "already set" check, the attacker can
     *      call it FIRST before the factory, locking in the malicious value permanently.
     */
    function test_SECURITY_setVaultId_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(EnygmaDvpIntegration__OnlyFactoryAllowed.selector);
        integration.setVaultId(FAKE_VAULT_ID);
    }

    /**
     * @notice SECURITY: Complete front-running attack scenario
     * @dev Simulates the full attack: attacker configures ALL settings before factory.
     *      After the fix, every call must revert for the attacker.
     */
    function test_SECURITY_fullFrontRunAttack_allRevert() public {
        vm.startPrank(attacker);

        vm.expectRevert(EnygmaDvpIntegration__OnlyFactoryAllowed.selector);
        integration.addDvp(FAKE_DVP);

        vm.expectRevert(EnygmaDvpIntegration__OnlyFactoryAllowed.selector);
        integration.setVaultId(FAKE_VAULT_ID);

        vm.expectRevert(EnygmaDvpIntegration__OnlyFactoryAllowed.selector);
        integration.addDepositToDvpVerifier(FAKE_VERIFIER, 2);

        vm.expectRevert(EnygmaDvpIntegration__OnlyFactoryAllowed.selector);
        integration.addWithdrawFromDvpVerifier(FAKE_VERIFIER, 2);

        vm.stopPrank();
    }

    /**
     * @notice SECURITY: Verifier overwrite attack
     * @dev Even after legitimate configuration, attacker should NOT be able to
     *      overwrite verifiers with malicious ones.
     */
    function test_SECURITY_addDepositToDvpVerifier_overwriteReverts() public {
        // Legitimate factory configures verifier first
        // (Currently no factory check, so we simulate from any address)
        vm.prank(factory);
        integration.addDepositToDvpVerifier(makeAddr("legitimateVerifier"), 2);

        // Attacker tries to overwrite with malicious verifier
        vm.prank(attacker);
        vm.expectRevert(EnygmaDvpIntegration__OnlyFactoryAllowed.selector);
        integration.addDepositToDvpVerifier(FAKE_VERIFIER, 2);
    }

    /**
     * @notice SECURITY: Withdraw verifier overwrite attack
     */
    function test_SECURITY_addWithdrawFromDvpVerifier_overwriteReverts() public {
        vm.prank(factory);
        integration.addWithdrawFromDvpVerifier(makeAddr("legitimateVerifier"), 2);

        vm.prank(attacker);
        vm.expectRevert(EnygmaDvpIntegration__OnlyFactoryAllowed.selector);
        integration.addWithdrawFromDvpVerifier(FAKE_VERIFIER, 2);
    }

    /**
     * @notice SECURITY: DVP address overwrite attack
     * @dev After factory sets legitimate DVP, attacker should NOT be able to change it.
     */
    function test_SECURITY_addDvp_overwriteReverts() public {
        vm.prank(factory);
        integration.addDvp(makeAddr("legitimateDvp"));

        vm.prank(attacker);
        vm.expectRevert(EnygmaDvpIntegration__OnlyFactoryAllowed.selector);
        integration.addDvp(FAKE_DVP);
    }

    // ============================================================
    // POSITIVE TESTS — Factory MUST be able to configure
    // These should PASS both before and after the fix
    // ============================================================

    /**
     * @notice Factory should be able to call addDepositToDvpVerifier
     */
    function test_factory_canAddDepositToDvpVerifier() public {
        vm.prank(factory);
        bool result = integration.addDepositToDvpVerifier(FAKE_VERIFIER, 2);
        assertTrue(result);
        assertEq(integration.getDepositToDvpVerifierAddress(2), FAKE_VERIFIER);
    }

    /**
     * @notice Factory should be able to call addWithdrawFromDvpVerifier
     */
    function test_factory_canAddWithdrawFromDvpVerifier() public {
        vm.prank(factory);
        bool result = integration.addWithdrawFromDvpVerifier(FAKE_VERIFIER, 2);
        assertTrue(result);
        assertEq(integration.getWithdrawFromDvpVerifierAddress(2), FAKE_VERIFIER);
    }

    /**
     * @notice Factory should be able to call addDvp
     */
    function test_factory_canAddDvp() public {
        vm.prank(factory);
        bool result = integration.addDvp(FAKE_DVP);
        assertTrue(result);
        assertEq(integration.getDvpAddress(), FAKE_DVP);
    }

    /**
     * @notice Factory should be able to call setVaultId
     */
    function test_factory_canSetVaultId() public {
        vm.prank(factory);
        bool result = integration.setVaultId(FAKE_VAULT_ID);
        assertTrue(result);
        assertEq(integration.getVaultId(), FAKE_VAULT_ID);
    }

    /**
     * @notice Factory should be able to configure all settings in sequence
     */
    function test_factory_canConfigureAll() public {
        vm.startPrank(factory);

        integration.addDvp(FAKE_DVP);
        integration.setVaultId(FAKE_VAULT_ID);
        integration.addDepositToDvpVerifier(FAKE_VERIFIER, 2);
        integration.addWithdrawFromDvpVerifier(FAKE_VERIFIER, 2);

        vm.stopPrank();

        assertEq(integration.getDvpAddress(), FAKE_DVP);
        assertEq(integration.getVaultId(), FAKE_VAULT_ID);
        assertEq(integration.getDepositToDvpVerifierAddress(2), FAKE_VERIFIER);
        assertEq(integration.getWithdrawFromDvpVerifierAddress(2), FAKE_VERIFIER);
    }
}
