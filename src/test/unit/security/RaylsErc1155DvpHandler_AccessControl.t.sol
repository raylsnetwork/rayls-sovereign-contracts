// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../../rayls-protocol/test-contracts/Erc1155DvpExample.sol";
import "../mocks/MockEndpointForSecurityTest.sol";
import {RaylsApp} from "../../../rayls-protocol-sdk/RaylsApp.sol";
import {RaylsErc1155DvpHandler} from "../../../rayls-protocol-sdk/tokens/RaylsErc1155DvpHandler.sol";
import "../../../rayls-protocol-sdk/libraries/SharedObjects.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";

/**
 * @title Security Test: RaylsErc1155DvpHandler Access Control
 * @notice Tests that DVP functions are protected by appropriate modifiers.
 *
 * VULNERABILITY (before fix):
 * - Anyone could call unlock(), dvpSwapCompleted(), unlockFromDvp(),
 *   cancelSwap(), notifySenderWithPNCommunicator(), notifySenderAndReceiverWithPNCommunicator()
 *
 * EXPECTED BEHAVIOR (after fix):
 * - unlock: only endpoint's trusted executor (receiveMethod)
 * - dvpSwapCompleted, unlockFromDvp, notifySender*, notifySenderAndReceiver*:
 *   onlyRelayerRole (checks RELAYER via endpoint.authority() access manager)
 * - cancelSwap: user-called; downstream EnygmaPNEvents.onlyAuthorized provides protection
 */
contract RaylsErc1155DvpHandlerAccessControlTest is Test {
    Erc1155DvpExample public token;
    MockEndpointForSecurityTest public mockEndpoint;
    RaylsAccessManagerV1 public manager;

    address public owner;
    address public attacker;
    address public recipient;

    uint256 constant CHAIN_ID = 12345;
    uint256 constant PRIVATE_HUB_CHAIN_ID = 99999;

    function setUp() public {
        owner = address(this);
        attacker = makeAddr("attacker");
        recipient = makeAddr("recipient");

        // Deploy RaylsAccessManagerV1 via proxy
        RaylsAccessManagerV1 managerImpl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(
            address(new ERC1967Proxy(address(managerImpl), abi.encodeCall(RaylsAccessManagerV1.initialize, (owner))))
        );

        // Register RELAYER and MESSAGE_EXECUTOR (no grant — attacker should not have it)
        manager.registerRole("RELAYER");
        manager.registerRole("MESSAGE_EXECUTOR");

        mockEndpoint = new MockEndpointForSecurityTest(CHAIN_ID, PRIVATE_HUB_CHAIN_ID);
        mockEndpoint.setTrustedExecutor(owner);
        mockEndpoint.setAuthority(address(manager));

        token = new Erc1155DvpExample(
            "https://example.com/",
            "Test1155",
            address(mockEndpoint)
        );
    }

    // ========== unlock() ==========

    function test_unlock_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        token.unlock(recipient, 1, 1, "");
    }

    // ========== dvpSwapCompleted() ==========

    function test_dvpSwapCompleted_attackerReverts() public {
        SharedObjects.DvpSwapCompletedParams memory params = SharedObjects.DvpSwapCompletedParams({
            tokenId: 1,
            destinationChainId: 2,
            destinationOwner: recipient,
            sharedId: bytes32(0)
        });

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        token.dvpSwapCompleted(params, attacker, 1, "");
    }

    // ========== unlockFromDvp() ==========

    function test_unlockFromDvp_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        token.unlockFromDvp(1, 1, attacker);
    }

    // ========== cancelSwap() ==========

    function test_cancelSwap_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(); // cancelSwap is user-called; downstream EnygmaPNEvents.onlyAuthorized provides protection
        token.cancelSwap(bytes32(0), 1, 1, 1, bytes32(0), 100);
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
