// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import "../../../rayls-protocol/modules/MessageReceiver.sol";
import "../../../rayls-protocol-sdk/RaylsMessage.sol";

contract MockResourceManager {
    function handleWithResourceId(RaylsMessageMetadata memory, address _dst) external pure returns (address) {
        return _dst;
    }
}

contract MockMessageExecutor {
    function executeMessage(address, bytes memory, bytes32, uint256, address) external {}
}

/**
 * @title Security Test: MessageReceiver Access Control
 * @notice Tests onlyEndpoint on receivePayload, onlyOwner on setters,
 *         and zero-address checks in constructor.
 */
contract MessageReceiverAccessControlTest is Test {
    MessageReceiver public messageReceiver;
    MockResourceManager public mockRM;
    MockMessageExecutor public mockME;
    RaylsAccessManagerV1 public manager;

    address public owner;
    address public attacker;
    address public endpoint;

    function setUp() public {
        owner = address(this);
        attacker = makeAddr("attacker");
        endpoint = makeAddr("endpoint");
        mockRM = new MockResourceManager();
        mockME = new MockMessageExecutor();

        // Deploy RaylsAccessManagerV1 via proxy
        RaylsAccessManagerV1 impl = new RaylsAccessManagerV1();
        bytes memory initData = abi.encodeCall(RaylsAccessManagerV1.initialize, (owner));
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(address(impl), initData)));

        messageReceiver = new MessageReceiver(address(mockRM), address(mockME), endpoint, owner, address(manager));
    }

    // --- Constructor zero-address checks ---

    function test_constructor_revertsOnZeroResourceManager() public {
        vm.expectRevert(MessageReceiver.MessageReceiver__ZeroAddress.selector);
        new MessageReceiver(address(0), address(mockME), endpoint, owner, address(manager));
    }

    function test_constructor_revertsOnZeroMessageExecutor() public {
        vm.expectRevert(MessageReceiver.MessageReceiver__ZeroAddress.selector);
        new MessageReceiver(address(mockRM), address(0), endpoint, owner, address(manager));
    }

    function test_constructor_revertsOnZeroEndpoint() public {
        vm.expectRevert(MessageReceiver.MessageReceiver__ZeroAddress.selector);
        new MessageReceiver(address(mockRM), address(mockME), address(0), owner, address(manager));
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert();
        new MessageReceiver(address(mockRM), address(mockME), endpoint, address(0), address(manager));
    }

    // --- onlyEndpoint: attacker reverts ---

    function test_receivePayload_attackerReverts() public {
        RaylsMessage memory msg;
        msg.messageMetadata.ignoresNonce = true;
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(MessageReceiver.MessageReceiver__UnauthorizedEndpoint.selector, attacker));
        messageReceiver.receivePayload(12345, attacker, makeAddr("dest"), msg, bytes32(uint256(1)));
    }

    // --- onlyOwner: attacker reverts ---

    function test_setResourceManager_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        messageReceiver.setResourceManager(makeAddr("x"));
    }

    function test_setMessageExecutor_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        messageReceiver.setMessageExecutor(makeAddr("x"));
    }

    function test_setAuthorizedEndpoint_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        messageReceiver.setAuthorizedEndpoint(makeAddr("x"));
    }

    function test_removeAuthorizedEndpoint_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        messageReceiver.removeAuthorizedEndpoint();
    }

    // --- Setter zero-address checks ---

    function test_setAuthorizedEndpoint_revertsOnZero() public {
        vm.expectRevert(MessageReceiver.MessageReceiver__ZeroAddress.selector);
        messageReceiver.setAuthorizedEndpoint(address(0));
    }

    function test_setResourceManager_revertsOnZero() public {
        vm.expectRevert(MessageReceiver.MessageReceiver__ZeroAddress.selector);
        messageReceiver.setResourceManager(address(0));
    }

    function test_setMessageExecutor_revertsOnZero() public {
        vm.expectRevert(MessageReceiver.MessageReceiver__ZeroAddress.selector);
        messageReceiver.setMessageExecutor(address(0));
    }

    // --- Positive: owner can call setters ---

    function test_owner_canSetResourceManager() public {
        address v = makeAddr("v");
        messageReceiver.setResourceManager(v);
        assertEq(address(messageReceiver.resourceManager()), v);
    }

    function test_owner_canSetMessageExecutor() public {
        address v = makeAddr("v");
        messageReceiver.setMessageExecutor(v);
        assertEq(address(messageReceiver.messageExecutor()), v);
    }

    function test_owner_canSetAuthorizedEndpoint() public {
        address e = makeAddr("e");
        messageReceiver.setAuthorizedEndpoint(e);
        assertEq(messageReceiver.authorizedEndpoint(), e);
    }

    function test_owner_canRemoveAuthorizedEndpoint() public {
        messageReceiver.removeAuthorizedEndpoint();
        assertEq(messageReceiver.authorizedEndpoint(), address(0));
    }

    // --- Positive: endpoint can receivePayload ---

    function test_endpoint_canCallReceivePayload() public {
        RaylsMessage memory msg;
        msg.messageMetadata.ignoresNonce = true;
        vm.prank(endpoint);
        messageReceiver.receivePayload(12345, makeAddr("src"), makeAddr("dest"), msg, bytes32(uint256(1)));
    }
}
