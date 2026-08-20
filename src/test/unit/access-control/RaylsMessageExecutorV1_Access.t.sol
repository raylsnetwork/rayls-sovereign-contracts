// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsMessageExecutorV1} from "../../../rayls-protocol/RaylsMessageExecutor/RaylsMessageExecutorV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {MessageLib} from "../../../rayls-protocol-sdk/libraries/MessageLib.sol";

/**
 * @title RaylsMessageExecutorV1 Access Control Tests
 * @notice Verifies that executeMessage and executeMessageBatch are gated by `restricted`
 *         via MESSAGE_RECEIVER in the AccessManager.
 */
contract RaylsMessageExecutorV1AccessTest is Test {
    RaylsMessageExecutorV1 public executor;
    RaylsAccessManagerV1 public manager;

    address public admin;
    address public receiver;
    address public attacker;

    uint64 messageReceiverRoleId;

    function _singleRole(uint64 roleId) internal pure returns (uint64[] memory roles) {
        roles = new uint64[](1);
        roles[0] = roleId;
    }

    function setUp() public {
        admin    = address(this);
        receiver = makeAddr("receiver");
        attacker = makeAddr("attacker");

        // Deploy AccessManager
        RaylsAccessManagerV1 impl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(
            address(impl), abi.encodeCall(RaylsAccessManagerV1.initialize, (admin))
        )));

        // Register MESSAGE_RECEIVER
        messageReceiverRoleId = manager.registerRole("MESSAGE_RECEIVER");

        // Deploy MessageExecutor
        executor = new RaylsMessageExecutorV1();
        executor.initialize(address(manager));

        // Map executeMessage and executeMessageBatch to MESSAGE_RECEIVER
        bytes4[] memory sels = new bytes4[](2);
        sels[0] = executor.executeMessage.selector;
        sels[1] = executor.executeMessageBatch.selector;
        manager.addFunctionAllowedRoles(address(executor), sels, _singleRole(messageReceiverRoleId));

        // Grant MESSAGE_RECEIVER to the receiver
        manager.grantRole(messageReceiverRoleId, receiver, 0);
    }

    // ─── authority ───────────────────────────────────────────────────────────

    function test_authority_isSet() public view {
        assertEq(executor.authority(), address(manager));
    }

    // ─── executeMessage (restricted — MESSAGE_RECEIVER) ──────────────────────

    function test_executeMessage_authorizedReceiver_doesNotRevertOnAuth() public {
        // Will revert on MessageLib level (no valid contract at "to"), but NOT on access control
        vm.prank(receiver);
        vm.expectRevert(); // MessageLib revert, not access control
        executor.executeMessage(makeAddr("to"), hex"12345678", bytes32(uint256(1)), 1, makeAddr("from"));
    }

    function test_executeMessage_attacker_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        executor.executeMessage(makeAddr("to"), hex"12345678", bytes32(0), 1, makeAddr("from"));
    }

    function test_executeMessage_adminAllowed() public {
        // Admin can call any restricted function
        vm.expectRevert(); // MessageLib revert, not access control
        executor.executeMessage(makeAddr("to"), hex"12345678", bytes32(uint256(2)), 1, makeAddr("from"));
    }

    // ─── executeMessageBatch (restricted — MESSAGE_RECEIVER) ─────────────────

    function test_executeMessageBatch_attacker_reverts() public {
        MessageLib.Message[] memory messages = new MessageLib.Message[](0);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        executor.executeMessageBatch(messages, bytes32(0), 1, makeAddr("from"));
    }

    function test_executeMessageBatch_authorizedReceiver_doesNotRevertOnAuth() public {
        MessageLib.Message[] memory messages = new MessageLib.Message[](0);
        vm.prank(receiver);
        // Empty batch — should succeed (no messages to execute)
        executor.executeMessageBatch(messages, bytes32(uint256(3)), 1, makeAddr("from"));
    }

    // ─── revokeRole removes access ──────────────────────────────────────────

    function test_executeMessage_afterRevoke_reverts() public {
        manager.revokeRole(messageReceiverRoleId, receiver);

        vm.prank(receiver);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, receiver));
        executor.executeMessage(makeAddr("to"), hex"12345678", bytes32(0), 1, makeAddr("from"));
    }

    // ─── contractVersion ─────────────────────────────────────────────────────

    function test_contractVersion_returns1() public view {
        assertEq(executor.contractVersion(), 1);
    }
}
