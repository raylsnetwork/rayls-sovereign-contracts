// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TeleportV1} from "../../../privateHub/Teleport/TeleportV1.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";

/**
 * @title TeleportV1 Access Control Tests
 * @notice Verifies that relayer-triggered functions require RELAYER and that the
 *         `restricted` modifier blocks unauthorised callers.
 * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
 */
contract TeleportV1AccessTest is Test {
    TeleportV1 public teleport;
    RaylsAccessManagerV1 public manager;

    address public admin;
    address public attacker;
    address public relayer;

    uint64 public relayerRoleId;

    function _singleRole(uint64 roleId) internal pure returns (uint64[] memory roles) {
        roles = new uint64[](1);
        roles[0] = roleId;
    }

    function setUp() public {
        admin    = address(this);
        attacker = makeAddr("attacker");
        relayer  = makeAddr("relayer");

        // Deploy RaylsAccessManagerV1 via proxy
        RaylsAccessManagerV1 managerImpl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(
            address(new ERC1967Proxy(address(managerImpl), abi.encodeCall(RaylsAccessManagerV1.initialize, (admin))))
        );

        // Register RELAYER
        relayerRoleId = manager.registerRole("RELAYER");

        // Deploy TeleportV1 directly (no constructor _disableInitializers)
        teleport = new TeleportV1();
        teleport.initialize(address(manager));

        // Map relayer-gated selectors to RELAYER
        bytes4[] memory relayerSelectors = new bytes4[](5);
        relayerSelectors[0] = TeleportV1.storeEncryptedDataBatch.selector;
        relayerSelectors[1] = TeleportV1.addHeader.selector;
        relayerSelectors[2] = TeleportV1.addSingleHeader.selector;
        relayerSelectors[3] = TeleportV1.executeAtomicMessageBatch.selector;
        relayerSelectors[4] = TeleportV1.revertAtomicMessageBatch.selector;
        manager.addFunctionAllowedRoles(address(teleport), relayerSelectors, _singleRole(relayerRoleId));

        // Grant RELAYER to relayer
        manager.grantRole(relayerRoleId, relayer, 0);
    }

    // ─── authority ───────────────────────────────────────────────────────────

    function test_authority_isSet() public view {
        assertEq(teleport.authority(), address(manager));
    }

    // ─── RELAYER — attacker blocked ─────────────────────────────────────────

    function test_addHeader_attacker_reverts() public {
        TeleportV1.Header memory h;
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        teleport.addHeader(1, h);
    }

    function test_executeAtomicMessageBatch_attacker_reverts() public {
        string[] memory ids = new string[](1);
        ids[0] = "msg1";
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        teleport.executeAtomicMessageBatch(ids, "encrypted");
    }

    // ─── RELAYER — relayer passes ─────────────────────────────────────────────

    function test_addHeader_relayer_passes() public {
        TeleportV1.Header memory h;
        vm.prank(relayer);
        teleport.addHeader(1, h); // passes auth check, succeeds
    }

    // ─── contractVersion ─────────────────────────────────────────────────────

    function test_contractVersion_returns1() public view {
        assertEq(teleport.contractVersion(), 1);
    }
}
