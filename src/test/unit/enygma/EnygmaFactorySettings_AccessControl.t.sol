// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {EnygmaFactorySettings, VerifierAddresses} from "../../../rayls-protocol/Enygma/Enygma-Payments/EnygmaFactorySettings.sol";

/**
 * @title Security Test: EnygmaFactorySettings Access Control
 * @notice Tests that all setter functions have proper access control (restricted)
 * @dev These tests FAIL when vulnerabilities exist, PASS when code is secure.
 *
 * EXPECTED BEHAVIOR:
 * - All setter functions MUST have restricted modifier to prevent unauthorized changes
 * - Attackers replacing verifiers could bypass ZK proof verification
 * - Attackers replacing DVP addresses could redirect funds
 *
 * VULNERABLE FUNCTIONS (14 total):
 * - setDepositToDvpVerifierk2 through setDepositToDvpVerifierk6 (5 functions)
 * - setWithdrawFromDvpVerifierk2 through setWithdrawFromDvpVerifierk6 (5 functions)
 * - setDvpAddress
 * - setDvpTeleportAddress
 * - setPoseidonWrapperAddress
 * - setAllVerifiers
 */
contract EnygmaFactorySettingsAccessControlTest is Test {
    RaylsAccessManagerV1 public manager;
    EnygmaFactorySettings public settings;

    uint64 public SETTINGS_ADMIN_ID;

    address public admin;
    address public attacker;

    // Mock addresses for deployment
    address constant MOCK_VERIFIER = address(0x1234567890123456789012345678901234567890);
    address constant MOCK_DVP = address(0x2345678901234567890123456789012345678901);
    address constant MOCK_DVP_TELEPORT = address(0x3456789012345678901234567890123456789012);
    address constant MOCK_POSEIDON = address(0x4567890123456789012345678901234567890123);
    address constant MALICIOUS_ADDRESS = address(0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF);

    function _singleRole(uint64 roleId) internal pure returns (uint64[] memory roles) {
        roles = new uint64[](1);
        roles[0] = roleId;
    }

    function setUp() public {
        admin = address(this);
        attacker = makeAddr("attacker");

        // Deploy manager via UUPS proxy
        RaylsAccessManagerV1 impl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(RaylsAccessManagerV1.initialize, (admin))))
        );

        // Deploy EnygmaFactorySettings with constructor arguments
        settings = new EnygmaFactorySettings(
            MOCK_VERIFIER,      // enygmaVerifierk2_
            MOCK_VERIFIER,      // enygmaVerifierk3_
            MOCK_VERIFIER,      // enygmaVerifierk4_
            MOCK_VERIFIER,      // enygmaVerifierk5_
            MOCK_VERIFIER,      // enygmaVerifierk6_
            MOCK_DVP,           // dvpAddress_
            MOCK_DVP_TELEPORT,  // dvpTeleportAddress_
            MOCK_POSEIDON,      // poseidonWrapperAddress_
            address(manager)    // _authority
        );

        // Register and grant role
        SETTINGS_ADMIN_ID = manager.registerRole("SETTINGS_ADMIN");
        manager.grantRole(SETTINGS_ADMIN_ID, admin, 0);

        // Allow SETTINGS_ADMIN_ID to call all setter functions on settings
        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = settings.setDepositToDvpVerifierk2.selector;
        selectors[1] = settings.setDepositToDvpVerifierk3.selector;
        selectors[2] = settings.setDepositToDvpVerifierk4.selector;
        selectors[3] = settings.setDepositToDvpVerifierk5.selector;
        selectors[4] = settings.setDepositToDvpVerifierk6.selector;
        selectors[5] = settings.setWithdrawFromDvpVerifierk2.selector;
        selectors[6] = settings.setWithdrawFromDvpVerifierk3.selector;
        selectors[7] = settings.setWithdrawFromDvpVerifierk4.selector;
        selectors[8] = settings.setWithdrawFromDvpVerifierk5.selector;
        selectors[9] = settings.setWithdrawFromDvpVerifierk6.selector;
        selectors[10] = settings.setDvpAddress.selector;
        selectors[11] = settings.setDvpTeleportAddress.selector;
        selectors[12] = settings.setPoseidonWrapperAddress.selector;
        selectors[13] = settings.setAllVerifiers.selector;

        manager.addFunctionAllowedRoles(address(settings), selectors, _singleRole(SETTINGS_ADMIN_ID));
    }

    // ============================================
    // Deposit Verifier Setters - Access Control
    // ============================================

    function test_setDepositToDvpVerifierk2_hasAccessControl() public {
        vm.prank(attacker);
        vm.expectRevert();
        settings.setDepositToDvpVerifierk2(MALICIOUS_ADDRESS);
    }

    function test_setDepositToDvpVerifierk3_hasAccessControl() public {
        vm.prank(attacker);
        vm.expectRevert();
        settings.setDepositToDvpVerifierk3(MALICIOUS_ADDRESS);
    }

    function test_setDepositToDvpVerifierk4_hasAccessControl() public {
        vm.prank(attacker);
        vm.expectRevert();
        settings.setDepositToDvpVerifierk4(MALICIOUS_ADDRESS);
    }

    function test_setDepositToDvpVerifierk5_hasAccessControl() public {
        vm.prank(attacker);
        vm.expectRevert();
        settings.setDepositToDvpVerifierk5(MALICIOUS_ADDRESS);
    }

    function test_setDepositToDvpVerifierk6_hasAccessControl() public {
        vm.prank(attacker);
        vm.expectRevert();
        settings.setDepositToDvpVerifierk6(MALICIOUS_ADDRESS);
    }

    // ============================================
    // Withdraw Verifier Setters - Access Control
    // ============================================

    function test_setWithdrawFromDvpVerifierk2_hasAccessControl() public {
        vm.prank(attacker);
        vm.expectRevert();
        settings.setWithdrawFromDvpVerifierk2(MALICIOUS_ADDRESS);
    }

    function test_setWithdrawFromDvpVerifierk3_hasAccessControl() public {
        vm.prank(attacker);
        vm.expectRevert();
        settings.setWithdrawFromDvpVerifierk3(MALICIOUS_ADDRESS);
    }

    function test_setWithdrawFromDvpVerifierk4_hasAccessControl() public {
        vm.prank(attacker);
        vm.expectRevert();
        settings.setWithdrawFromDvpVerifierk4(MALICIOUS_ADDRESS);
    }

    function test_setWithdrawFromDvpVerifierk5_hasAccessControl() public {
        vm.prank(attacker);
        vm.expectRevert();
        settings.setWithdrawFromDvpVerifierk5(MALICIOUS_ADDRESS);
    }

    function test_setWithdrawFromDvpVerifierk6_hasAccessControl() public {
        vm.prank(attacker);
        vm.expectRevert();
        settings.setWithdrawFromDvpVerifierk6(MALICIOUS_ADDRESS);
    }

    // ============================================
    // DVP and Poseidon Setters - Access Control
    // ============================================

    function test_setDvpAddress_hasAccessControl() public {
        vm.prank(attacker);
        vm.expectRevert();
        settings.setDvpAddress(MALICIOUS_ADDRESS);
    }

    function test_setDvpTeleportAddress_hasAccessControl() public {
        vm.prank(attacker);
        vm.expectRevert();
        settings.setDvpTeleportAddress(MALICIOUS_ADDRESS);
    }

    function test_setPoseidonWrapperAddress_hasAccessControl() public {
        vm.prank(attacker);
        vm.expectRevert();
        settings.setPoseidonWrapperAddress(MALICIOUS_ADDRESS);
    }

    // ============================================
    // Batch Setter - Access Control
    // ============================================

    function test_setAllVerifiers_hasAccessControl() public {
        VerifierAddresses memory maliciousVerifiers = VerifierAddresses({
            enygmaK2: MALICIOUS_ADDRESS,
            enygmaK3: MALICIOUS_ADDRESS,
            enygmaK4: MALICIOUS_ADDRESS,
            enygmaK5: MALICIOUS_ADDRESS,
            enygmaK6: MALICIOUS_ADDRESS,
            depositK2: MALICIOUS_ADDRESS,
            depositK3: MALICIOUS_ADDRESS,
            depositK4: MALICIOUS_ADDRESS,
            depositK5: MALICIOUS_ADDRESS,
            depositK6: MALICIOUS_ADDRESS,
            withdrawK2: MALICIOUS_ADDRESS,
            withdrawK3: MALICIOUS_ADDRESS,
            withdrawK4: MALICIOUS_ADDRESS,
            withdrawK5: MALICIOUS_ADDRESS,
            withdrawK6: MALICIOUS_ADDRESS
        });

        vm.prank(attacker);
        vm.expectRevert();
        settings.setAllVerifiers(maliciousVerifiers);
    }

    // ============================================
    // Attack Scenario Simulations
    // ============================================

    function test_attackScenario_replaceDepositVerifier() public {
        address initialVerifier = settings.depositToDvpVerifierk2();

        vm.prank(attacker);
        vm.expectRevert();
        settings.setDepositToDvpVerifierk2(MALICIOUS_ADDRESS);

        assertEq(settings.depositToDvpVerifierk2(), initialVerifier, "Verifier should not have changed");
    }

    function test_attackScenario_batchReplaceAllVerifiers() public {
        address initialEnygmaK2 = settings.enygmaVerifierk2();

        VerifierAddresses memory maliciousVerifiers = VerifierAddresses({
            enygmaK2: MALICIOUS_ADDRESS,
            enygmaK3: MALICIOUS_ADDRESS,
            enygmaK4: MALICIOUS_ADDRESS,
            enygmaK5: MALICIOUS_ADDRESS,
            enygmaK6: MALICIOUS_ADDRESS,
            depositK2: MALICIOUS_ADDRESS,
            depositK3: MALICIOUS_ADDRESS,
            depositK4: MALICIOUS_ADDRESS,
            depositK5: MALICIOUS_ADDRESS,
            depositK6: MALICIOUS_ADDRESS,
            withdrawK2: MALICIOUS_ADDRESS,
            withdrawK3: MALICIOUS_ADDRESS,
            withdrawK4: MALICIOUS_ADDRESS,
            withdrawK5: MALICIOUS_ADDRESS,
            withdrawK6: MALICIOUS_ADDRESS
        });

        vm.prank(attacker);
        vm.expectRevert();
        settings.setAllVerifiers(maliciousVerifiers);

        assertEq(settings.enygmaVerifierk2(), initialEnygmaK2, "Verifier should not have changed");
    }

    function test_attackScenario_hijackDvpAddress() public {
        address initialDvp = settings.dvpAddress();

        vm.prank(attacker);
        vm.expectRevert();
        settings.setDvpAddress(MALICIOUS_ADDRESS);

        assertEq(settings.dvpAddress(), initialDvp, "DVP address should not have changed");
    }

    function test_attackScenario_hijackDvpTeleportAddress() public {
        address initialDvpTeleport = settings.dvpTeleportAddress();

        vm.prank(attacker);
        vm.expectRevert();
        settings.setDvpTeleportAddress(MALICIOUS_ADDRESS);

        assertEq(settings.dvpTeleportAddress(), initialDvpTeleport, "DVP Teleport address should not have changed");
    }

    function test_attackScenario_hijackPoseidonWrapper() public {
        address initialPoseidon = settings.poseidonWrapperAddress();

        vm.prank(attacker);
        vm.expectRevert();
        settings.setPoseidonWrapperAddress(MALICIOUS_ADDRESS);

        assertEq(settings.poseidonWrapperAddress(), initialPoseidon, "Poseidon address should not have changed");
    }

    // ============================================
    // Admin Access - Positive Tests
    // ============================================

    function test_admin_canCallSetDepositToDvpVerifierk2() public {
        address newVerifier = address(0x5555555555555555555555555555555555555555);

        settings.setDepositToDvpVerifierk2(newVerifier);

        assertEq(settings.depositToDvpVerifierk2(), newVerifier, "Verifier should have been updated");
    }

    function test_admin_canCallSetAllVerifiers() public {
        VerifierAddresses memory newVerifiers = VerifierAddresses({
            enygmaK2: address(0x1111111111111111111111111111111111111111),
            enygmaK3: address(0x2222222222222222222222222222222222222222),
            enygmaK4: address(0x3333333333333333333333333333333333333333),
            enygmaK5: address(0x4444444444444444444444444444444444444444),
            enygmaK6: address(0x5555555555555555555555555555555555555555),
            depositK2: address(0x6666666666666666666666666666666666666666),
            depositK3: address(0x7777777777777777777777777777777777777777),
            depositK4: address(0x8888888888888888888888888888888888888888),
            depositK5: address(0x9999999999999999999999999999999999999999),
            depositK6: address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa),
            withdrawK2: address(0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB),
            withdrawK3: address(0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC),
            withdrawK4: address(0xDDdDddDdDdddDDddDDddDDDDdDdDDdDDdDDDDDDd),
            withdrawK5: address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE),
            withdrawK6: address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF)
        });

        settings.setAllVerifiers(newVerifiers);

        assertEq(settings.enygmaVerifierk2(), newVerifiers.enygmaK2, "enygmaK2 should have been updated");
        assertEq(settings.depositToDvpVerifierk2(), newVerifiers.depositK2, "depositK2 should have been updated");
        assertEq(settings.withdrawFromDvpVerifierk2(), newVerifiers.withdrawK2, "withdrawK2 should have been updated");
    }

    function test_admin_canCallSetDvpAddress() public {
        address newDvp = address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa);

        settings.setDvpAddress(newDvp);

        assertEq(settings.dvpAddress(), newDvp, "DVP address should have been updated");
    }

    // ============================================
    // Authority check
    // ============================================

    function test_authorityIsSetCorrectly() public view {
        assertEq(settings.authority(), address(manager));
    }
}
