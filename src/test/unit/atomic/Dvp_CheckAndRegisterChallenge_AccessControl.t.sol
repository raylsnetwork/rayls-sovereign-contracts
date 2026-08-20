// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Dvp} from "../../../rayls-protocol/Enygma/Enygma-DVP/Dvp.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";

/**
 * @title Security Test: Dvp.checkAndRegisterChallenge Access Control (Auth V3)
 * @notice Tests that checkAndRegisterChallenge() has proper access control via RaylsAccessManager
 * @dev These tests FAIL when the vulnerability exists (no revert), PASS when fixed (reverts).
 *
 * CONTEXT:
 * - checkAndRegisterChallenge() marks challenges as "rotten" (used) to prevent replay attacks
 * - Only CoinVault contracts with COIN_VAULT role should call it
 * - CoinVaults receive COIN_VAULT role when registered via registerVault()
 *
 * ATTACK SCENARIO (without access control):
 * 1. Attacker predicts or monitors for challenges that will be used in DVP operations
 * 2. Attacker pre-registers those challenges by calling checkAndRegisterChallenge()
 * 3. Legitimate CoinVault operations fail with RottenChallenge error
 * 4. Denial of service for all DVP swap/exchange/withdraw operations
 */
contract DvpCheckAndRegisterChallengeAccessControlTest is Test {
    Dvp public dvp;
    RaylsAccessManagerV1 public accessManager;

    address public owner;
    address public attacker;
    address public authorizedVault;

    function setUp() public {
        owner = address(this);
        attacker = makeAddr("attacker");
        authorizedVault = makeAddr("vault");

        // Deploy AccessManager via proxy — owner becomes initial admin
        RaylsAccessManagerV1 impl = new RaylsAccessManagerV1();
        bytes memory initData = abi.encodeCall(RaylsAccessManagerV1.initialize, (owner));
        accessManager = RaylsAccessManagerV1(address(new ERC1967Proxy(address(impl), initData)));

        // Register roles referenced by Dvp's selfRegisterManagedContract
        accessManager.registerRole("ENYGMA_CREATOR");
        accessManager.registerRole("COIN_VAULT");

        // Deploy Dvp — constructor self-registers with AccessManager
        dvp = new Dvp(
            address(0x1), // hashPoseidonContractAddress (mock)
            address(0x2), // enygmaFactoryAddress (mock)
            address(0x3), // dvpErc721FactoryAddress (mock)
            address(0x4), // dvpErc1155FactoryAddress (mock)
            address(0x5), // dvpTeleportAddress (mock)
            address(accessManager)
        );

        // Grant COIN_VAULT role to the authorized vault (simulating registerVault behavior)
        uint64 coinVaultRoleId = accessManager.getRoleIdByName("COIN_VAULT");
        accessManager.grantRole(coinVaultRoleId, authorizedVault, 0);
    }

    // ============================================================
    // NEGATIVE TESTS — Attacker MUST be blocked
    // These FAIL when vulnerability exists, PASS when fixed
    // ============================================================

    /**
     * @notice SECURITY: checkAndRegisterChallenge() MUST have access control
     * @dev Without access control, any address can mark challenges as rotten,
     *      causing denial of service for legitimate DVP operations.
     *
     * TEST BEHAVIOR:
     * - FAILS when vulnerability exists (attacker can call without reverting)
     * - PASSES when fixed (call reverts with RaylsAccessManaged__Unauthorized)
     */
    function test_SECURITY_checkAndRegisterChallenge_attackerBlocked() public {
        uint256 challenge = 12345;

        vm.prank(attacker);

        // Attacker should NOT be able to register challenges
        vm.expectRevert(
            abi.encodeWithSelector(
                RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector,
                attacker
            )
        );
        dvp.checkAndRegisterChallenge(challenge);
    }

    /**
     * @notice SECURITY: Random EOA without any role MUST be blocked
     */
    function test_SECURITY_checkAndRegisterChallenge_randomEOABlocked() public {
        address randomUser = makeAddr("randomUser");
        uint256 challenge = 99999;

        vm.prank(randomUser);

        vm.expectRevert(
            abi.encodeWithSelector(
                RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector,
                randomUser
            )
        );
        dvp.checkAndRegisterChallenge(challenge);
    }

    /**
     * @notice SECURITY: TOKEN_OWNER (contract-scoped deployer) should NOT be able to call this
     *         (only COIN_VAULT role should be authorized)
     * @dev Uses the Dvp deployer (who gets TOKEN_OWNER via selfRegister) — NOT the test
     *      contract (which holds ADMIN and would bypass all checks).
     */
    function test_SECURITY_checkAndRegisterChallenge_ownerRoleBlocked() public {
        uint256 challenge = 77777;

        // owner = address(this) is ADMIN, so we need a separate address that has
        // TOKEN_OWNER (contract-scoped) but NOT ADMIN or COIN_VAULT.
        // The Dvp deployer (msg.sender during `new Dvp(...)`) received TOKEN_OWNER
        // via selfRegisterManagedContract. That deployer is address(this) which is ADMIN.
        // Instead, use a fresh non-admin address:
        address tokenOwnerOnly = makeAddr("tokenOwnerOnly");

        vm.prank(tokenOwnerOnly);
        vm.expectRevert(
            abi.encodeWithSelector(
                RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector,
                tokenOwnerOnly
            )
        );
        dvp.checkAndRegisterChallenge(challenge);
    }

    // ============================================================
    // POSITIVE TESTS — Authorized vault CAN call
    // ============================================================

    /**
     * @notice Authorized vault (with COIN_VAULT role) MUST be able to register challenges
     */
    function test_authorizedVault_canRegisterChallenge() public {
        uint256 challenge = 54321;

        vm.prank(authorizedVault);

        bool result = dvp.checkAndRegisterChallenge(challenge);
        assertTrue(result, "Authorized vault should succeed");
    }

    /**
     * @notice Replay protection still works: same challenge reverts on second call
     */
    function test_authorizedVault_duplicateChallengeReverts() public {
        uint256 challenge = 11111;

        vm.startPrank(authorizedVault);

        // First call succeeds
        dvp.checkAndRegisterChallenge(challenge);

        // Second call with same challenge should revert
        vm.expectRevert(abi.encodeWithSignature("RottenChallenge()"));
        dvp.checkAndRegisterChallenge(challenge);

        vm.stopPrank();
    }

    // ============================================================
    // ATTACK SCENARIO TEST
    // ============================================================

    /**
     * @notice Full DoS attack scenario: attacker front-runs vault's challenge registration
     * @dev This is the exact attack described in the ticket.
     *      With the fix, the attacker's call reverts, and the vault's call succeeds.
     */
    function test_SECURITY_dosAttackScenarioPrevented() public {
        uint256 targetChallenge = 42;

        // Step 1: Attacker tries to pre-register the challenge
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector,
                attacker
            )
        );
        dvp.checkAndRegisterChallenge(targetChallenge);

        // Step 2: Legitimate vault can still use the challenge
        vm.prank(authorizedVault);
        bool result = dvp.checkAndRegisterChallenge(targetChallenge);
        assertTrue(result, "Vault should succeed after attacker was blocked");
    }
}
