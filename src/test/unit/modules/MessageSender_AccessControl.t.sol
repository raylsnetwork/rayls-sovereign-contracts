// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import "../../../rayls-protocol/modules/MessageSender.sol";
import "../../../rayls-protocol-sdk/RaylsMessage.sol";

contract MockParticipantValidator {
    function validateMessageParticipants(uint256, uint256) external pure {}
    function getAllParticipants() external pure returns (bytes memory) { return ""; }
}

contract MockTokenValidator {
    function validateTokenForParticipant(bytes32, uint256) external pure {}
}

/**
 * @title Security Test: MessageSender Access Control
 * @notice Tests onlyEndpoint on prepareMessage/broadcast, onlyOwner on setters,
 *         and zero-address checks in constructor.
 */
contract MessageSenderAccessControlTest is Test {
    MessageSender public messageSender;
    MockParticipantValidator public mockPV;
    MockTokenValidator public mockTV;
    RaylsAccessManagerV1 public manager;

    address public owner;
    address public attacker;
    address public endpoint;

    uint256 constant CHAIN_ID = 12345;
    uint256 constant PRIVATE_HUB_CHAIN_ID = 99999;

    function setUp() public {
        owner = address(this);
        attacker = makeAddr("attacker");
        endpoint = makeAddr("endpoint");
        mockPV = new MockParticipantValidator();
        mockTV = new MockTokenValidator();

        // Deploy RaylsAccessManagerV1 via proxy
        RaylsAccessManagerV1 impl = new RaylsAccessManagerV1();
        bytes memory initData = abi.encodeCall(RaylsAccessManagerV1.initialize, (owner));
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(address(impl), initData)));

        messageSender = new MessageSender(CHAIN_ID, PRIVATE_HUB_CHAIN_ID, address(mockPV), address(mockTV), endpoint, owner, address(manager));
    }

    // --- Constructor zero-address checks ---

    function test_constructor_revertsOnZeroParticipantValidator() public {
        vm.expectRevert(MessageSender.MessageSender__ZeroAddress.selector);
        new MessageSender(CHAIN_ID, PRIVATE_HUB_CHAIN_ID, address(0), address(mockTV), endpoint, owner, address(manager));
    }

    function test_constructor_revertsOnZeroTokenValidator() public {
        vm.expectRevert(MessageSender.MessageSender__ZeroAddress.selector);
        new MessageSender(CHAIN_ID, PRIVATE_HUB_CHAIN_ID, address(mockPV), address(0), endpoint, owner, address(manager));
    }

    function test_constructor_revertsOnZeroEndpoint() public {
        vm.expectRevert(MessageSender.MessageSender__ZeroAddress.selector);
        new MessageSender(CHAIN_ID, PRIVATE_HUB_CHAIN_ID, address(mockPV), address(mockTV), address(0), owner, address(manager));
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert();
        new MessageSender(CHAIN_ID, PRIVATE_HUB_CHAIN_ID, address(mockPV), address(mockTV), endpoint, address(0), address(manager));
    }

    // --- onlyEndpoint: attacker reverts ---

    function test_prepareMessage_attackerReverts() public {
        SendRequest memory request;
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(MessageSender.MessageSender__UnauthorizedEndpoint.selector, attacker));
        messageSender.prepareMessage(request, attacker);
    }

    function test_broadcastToAllParticipants_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(MessageSender.MessageSender__UnauthorizedEndpoint.selector, attacker));
        messageSender.broadcastToAllParticipants(bytes32(0), bytes(""), attacker, CHAIN_ID);
    }

    function test_broadcastToAllParticipantsWithData_attackerReverts() public {
        IMessageSender.BroadcastParams memory params;
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(MessageSender.MessageSender__UnauthorizedEndpoint.selector, attacker));
        messageSender.broadcastToAllParticipantsWithData(params);
    }

    // --- onlyOwner: attacker reverts ---

    function test_setParticipantValidator_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        messageSender.setParticipantValidator(makeAddr("x"));
    }

    function test_setTokenValidator_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        messageSender.setTokenValidator(makeAddr("x"));
    }

    function test_setAuthorizedEndpoint_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        messageSender.setAuthorizedEndpoint(makeAddr("x"));
    }

    // --- Setter zero-address checks ---

    function test_setAuthorizedEndpoint_revertsOnZero() public {
        vm.expectRevert(MessageSender.MessageSender__ZeroAddress.selector);
        messageSender.setAuthorizedEndpoint(address(0));
    }

    function test_setParticipantValidator_revertsOnZero() public {
        vm.expectRevert(MessageSender.MessageSender__ZeroAddress.selector);
        messageSender.setParticipantValidator(address(0));
    }

    function test_setTokenValidator_revertsOnZero() public {
        vm.expectRevert(MessageSender.MessageSender__ZeroAddress.selector);
        messageSender.setTokenValidator(address(0));
    }

    // --- Positive: owner can call setters ---

    function test_owner_canSetParticipantValidator() public {
        address v = makeAddr("v");
        messageSender.setParticipantValidator(v);
        assertEq(address(messageSender.participantValidator()), v);
    }

    function test_owner_canSetTokenValidator() public {
        address v = makeAddr("v");
        messageSender.setTokenValidator(v);
        assertEq(address(messageSender.tokenValidator()), v);
    }

    function test_owner_canSetAuthorizedEndpoint() public {
        address e = makeAddr("e");
        messageSender.setAuthorizedEndpoint(e);
        assertEq(messageSender.authorizedEndpoint(), e);
    }
}
