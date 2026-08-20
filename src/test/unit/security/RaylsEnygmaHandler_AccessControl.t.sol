// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../../rayls-protocol/test-contracts/EnygmaTokenExample.sol";
import "../mocks/MockEndpointForSecurityTest.sol";
import "../../../rayls-protocol-sdk/libraries/SharedObjects.sol";
import {RaylsApp} from "../../../rayls-protocol-sdk/RaylsApp.sol";
import {RaylsEnygmaHandler} from "../../../rayls-protocol-sdk/tokens/RaylsEnygmaHandler.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";

/**
 * @title Security Test: RaylsEnygmaHandler Access Control
 * @notice Tests that DVP-related functions are protected by the appropriate modifiers.
 *
 * VULNERABILITY (before fix):
 * - Anyone could call receiveWithdrawFromDvp() to mint tokens
 * - Anyone could call dvpSwapCompleted(), cancelERC721Swap(), cancelERC1155Swap()
 * - Anyone could call notifySenderWithPNCommunicator(), notifySenderAndReceiverWithPNCommunicator()
 *
 * EXPECTED BEHAVIOR (after fix):
 * - receiveWithdrawFromDvp, dvpSwapCompleted, notifySender*, notifySenderAndReceiver*:
 *   onlyRelayerRole (checks RELAYER via endpoint.authority() access manager)
 * - cancelERC721Swap, cancelERC1155Swap: user-callable; downstream EnygmaPNEvents.onlyAuthorized provides protection
 */
contract RaylsEnygmaHandlerAccessControlTest is Test {
    EnygmaTokenExample public token;
    MockEndpointForSecurityTest public mockEndpoint;
    RaylsAccessManagerV1 public manager;

    address public owner;
    address public attacker;
    address public recipient;

    uint256 constant CHAIN_ID = 12345;
    uint256 constant PRIVATE_HUB_CHAIN_ID = 99999;

    uint64 public relayerRoleId;

    function setUp() public {
        owner = address(this);
        attacker = makeAddr("attacker");
        recipient = makeAddr("recipient");

        // Deploy RaylsAccessManagerV1 via proxy
        RaylsAccessManagerV1 managerImpl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(
            address(new ERC1967Proxy(address(managerImpl), abi.encodeCall(RaylsAccessManagerV1.initialize, (owner))))
        );

        // Register RELAYER and MESSAGE_EXECUTOR (no grant yet — owner is not a relayer for these tests)
        relayerRoleId = manager.registerRole("RELAYER");
        manager.registerRole("MESSAGE_EXECUTOR");

        mockEndpoint = new MockEndpointForSecurityTest(CHAIN_ID, PRIVATE_HUB_CHAIN_ID);
        mockEndpoint.setTrustedExecutor(owner);
        mockEndpoint.setAuthority(address(manager));

        token = new EnygmaTokenExample(
            "TestEnygma",
            "TENYG",
            address(mockEndpoint)
        );
    }

    // ========== receiveWithdrawFromDvp() — CRITICAL: mints tokens ==========

    function test_receiveWithdrawFromDvp_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        token.receiveWithdrawFromDvp(attacker, 1000, bytes32(uint256(1)));
    }

    // ========== dvpSwapCompleted() ==========

    function test_dvpSwapCompleted_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        token.dvpSwapCompleted(1, bytes32(0));
    }

    // ========== cancelERC721Swap() ==========

    function test_cancelERC721Swap_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(); // cancelERC721Swap is user-called; downstream EnygmaPNEvents.onlyAuthorized provides protection
        token.cancelERC721Swap(bytes32(0), 1, 1, bytes32(0), 100);
    }

    // ========== cancelERC1155Swap() ==========

    function test_cancelERC1155Swap_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(); // cancelERC1155Swap is user-called; downstream EnygmaPNEvents.onlyAuthorized provides protection
        token.cancelERC1155Swap(bytes32(0), 1, 1, 1, bytes32(0), 100);
    }

    // ========== notifySenderWithPNCommunicator() ==========

    function test_notifySenderWithPNCommunicator_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        token.notifySenderWithPNCommunicator(
            bytes32(0),
            SharedObjects.DvpCommunicatiorStatus.NOSTATUS,
            "test"
        );
    }

    // ========== notifySenderAndReceiverWithPNCommunicator() ==========

    function test_notifySenderAndReceiverWithPNCommunicator_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        token.notifySenderAndReceiverWithPNCommunicator(
            bytes32(0),
            1,
            SharedObjects.DvpCommunicatiorStatus.NOSTATUS,
            SharedObjects.DvpCommunicatiorStatus.NOSTATUS,
            "sender msg",
            "receiver msg"
        );
    }
}
