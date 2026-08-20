// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import "../../../rayls-protocol/Enygma/Enygma-Payments/EnygmaFactorySettings.sol";

/**
 * @title Security Test: EnygmaFactorySettings Access Control
 * @notice Tests that ALL setter functions are protected by restricted modifier.
 *
 * VULNERABILITY (before fix):
 * - Anyone could change verifier addresses, DVP address, Poseidon wrapper
 * - Attacker could redirect DVP to malicious contract and drain funds
 *
 * EXPECTED BEHAVIOR (after fix):
 * - Only authorized role can call setter functions
 * - Attackers get reverted with RaylsAccessManaged__Unauthorized
 */
contract EnygmaFactorySettingsSecurityTest is Test {
    RaylsAccessManagerV1 public manager;
    EnygmaFactorySettings public settings;

    uint64 public SETTINGS_ADMIN_ID;

    address public admin;
    address public attacker;

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

        settings = new EnygmaFactorySettings(
            makeAddr("verK2"),
            makeAddr("verK3"),
            makeAddr("verK4"),
            makeAddr("verK5"),
            makeAddr("verK6"),
            makeAddr("dvp"),
            makeAddr("dvpTeleport"),
            makeAddr("poseidon"),
            address(manager)
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

    // --- Negative: attacker cannot call any setter ---

    function test_setDepositToDvpVerifierk2_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        settings.setDepositToDvpVerifierk2(makeAddr("evil"));
    }

    function test_setDepositToDvpVerifierk3_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        settings.setDepositToDvpVerifierk3(makeAddr("evil"));
    }

    function test_setDepositToDvpVerifierk4_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        settings.setDepositToDvpVerifierk4(makeAddr("evil"));
    }

    function test_setDepositToDvpVerifierk5_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        settings.setDepositToDvpVerifierk5(makeAddr("evil"));
    }

    function test_setDepositToDvpVerifierk6_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        settings.setDepositToDvpVerifierk6(makeAddr("evil"));
    }

    function test_setWithdrawFromDvpVerifierk2_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        settings.setWithdrawFromDvpVerifierk2(makeAddr("evil"));
    }

    function test_setWithdrawFromDvpVerifierk3_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        settings.setWithdrawFromDvpVerifierk3(makeAddr("evil"));
    }

    function test_setWithdrawFromDvpVerifierk4_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        settings.setWithdrawFromDvpVerifierk4(makeAddr("evil"));
    }

    function test_setWithdrawFromDvpVerifierk5_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        settings.setWithdrawFromDvpVerifierk5(makeAddr("evil"));
    }

    function test_setWithdrawFromDvpVerifierk6_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        settings.setWithdrawFromDvpVerifierk6(makeAddr("evil"));
    }

    function test_setDvpAddress_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        settings.setDvpAddress(makeAddr("evil"));
    }

    function test_setDvpTeleportAddress_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        settings.setDvpTeleportAddress(makeAddr("evil"));
    }

    function test_setPoseidonWrapperAddress_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        settings.setPoseidonWrapperAddress(makeAddr("evil"));
    }

    function test_setAllVerifiers_attackerReverts() public {
        VerifierAddresses memory v;
        vm.prank(attacker);
        vm.expectRevert();
        settings.setAllVerifiers(v);
    }

    // --- Positive: admin can call setters ---

    function test_admin_canSetDepositToDvpVerifierk2() public {
        address newVerifier = makeAddr("newVerifier");
        settings.setDepositToDvpVerifierk2(newVerifier);
        assertEq(settings.depositToDvpVerifierk2(), newVerifier);
    }

    function test_admin_canSetDvpAddress() public {
        address newDvp = makeAddr("newDvp");
        settings.setDvpAddress(newDvp);
        assertEq(settings.dvpAddress(), newDvp);
    }

    function test_admin_canSetAllVerifiers() public {
        VerifierAddresses memory v = VerifierAddresses({
            enygmaK2: makeAddr("eK2"),
            enygmaK3: makeAddr("eK3"),
            enygmaK4: makeAddr("eK4"),
            enygmaK5: makeAddr("eK5"),
            enygmaK6: makeAddr("eK6"),
            depositK2: makeAddr("dK2"),
            depositK3: makeAddr("dK3"),
            depositK4: makeAddr("dK4"),
            depositK5: makeAddr("dK5"),
            depositK6: makeAddr("dK6"),
            withdrawK2: makeAddr("wK2"),
            withdrawK3: makeAddr("wK3"),
            withdrawK4: makeAddr("wK4"),
            withdrawK5: makeAddr("wK5"),
            withdrawK6: makeAddr("wK6")
        });
        settings.setAllVerifiers(v);
        assertEq(settings.enygmaVerifierk2(), makeAddr("eK2"));
        assertEq(settings.depositToDvpVerifierk2(), makeAddr("dK2"));
        assertEq(settings.withdrawFromDvpVerifierk2(), makeAddr("wK2"));
    }

    // --- View functions remain publicly accessible ---

    function test_anyone_canReadVerifiers() public {
        vm.startPrank(attacker);
        settings.enygmaVerifierk2();
        settings.dvpAddress();
        settings.poseidonWrapperAddress();
        settings.depositToDvpVerifierk2();
        settings.withdrawFromDvpVerifierk2();
        vm.stopPrank();
    }
}
