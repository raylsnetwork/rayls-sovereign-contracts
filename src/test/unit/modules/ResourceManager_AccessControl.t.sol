// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../../rayls-protocol/modules/ResourceManager.sol";
import "../../../rayls-protocol-sdk/RaylsMessage.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";

/**
 * @title Security Test: ResourceManager Access Control
 * @notice Tests restricted on handleWithResourceId, onlyEndpointOrOwner
 *         on registerResourceId, onlyOwner on setters, and zero-address in constructor.
 */
contract ResourceManagerAccessControlTest is Test {
    ResourceManager public resourceManager;
    RaylsAccessManagerV1 public manager;

    address public owner;
    address public attacker;
    address public msgReceiver;
    address public endpointAddr;

    uint64 messageReceiverRoleId;
    bytes32 constant RESOURCE_ID = keccak256("test-resource");

    function _singleRole(uint64 roleId) internal pure returns (uint64[] memory roles) {
        roles = new uint64[](1);
        roles[0] = roleId;
    }

    function setUp() public {
        owner = address(this);
        attacker = makeAddr("attacker");
        msgReceiver = makeAddr("msgReceiver");
        endpointAddr = makeAddr("endpoint");

        // Deploy AccessManager
        RaylsAccessManagerV1 impl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(
            address(impl), abi.encodeCall(RaylsAccessManagerV1.initialize, (owner))
        )));

        // Register roles
        messageReceiverRoleId = manager.registerRole("MESSAGE_RECEIVER");
        uint64 endpointSenderRoleId = manager.registerRole("ENDPOINT_SENDER");

        resourceManager = new ResourceManager(makeAddr("factory"), owner, address(manager));
        resourceManager.setEndpoint(endpointAddr);

        // Map handleWithResourceId to MESSAGE_RECEIVER
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = resourceManager.handleWithResourceId.selector;
        manager.addFunctionAllowedRoles(address(resourceManager), sels, _singleRole(messageReceiverRoleId));

        // Map registerResourceId to ENDPOINT_SENDER and grant to endpoint
        bytes4[] memory regSels = new bytes4[](1);
        regSels[0] = resourceManager.registerResourceId.selector;
        manager.addFunctionAllowedRoles(address(resourceManager), regSels, _singleRole(endpointSenderRoleId));
        manager.grantRole(endpointSenderRoleId, endpointAddr, 0);

        // Grant MESSAGE_RECEIVER to msgReceiver
        manager.grantRole(messageReceiverRoleId, msgReceiver, 0);
    }

    // --- Constructor zero-address check ---

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert();
        new ResourceManager(makeAddr("factory"), address(0), address(manager));
    }

    // --- restricted: attacker and endpoint revert on handleWithResourceId ---

    function test_handleWithResourceId_attackerReverts() public {
        RaylsMessageMetadata memory metadata;
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        resourceManager.handleWithResourceId(metadata, makeAddr("dest"));
    }

    function test_handleWithResourceId_endpointReverts() public {
        RaylsMessageMetadata memory metadata;
        vm.prank(endpointAddr);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, endpointAddr));
        resourceManager.handleWithResourceId(metadata, makeAddr("dest"));
    }

    // --- onlyEndpointOrOwner: attacker and msgReceiver revert ---

    function test_registerResourceId_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        resourceManager.registerResourceId(RESOURCE_ID, makeAddr("impl"));
    }

    function test_registerResourceId_msgReceiverReverts() public {
        vm.prank(msgReceiver);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, msgReceiver));
        resourceManager.registerResourceId(RESOURCE_ID, makeAddr("impl"));
    }

    // --- onlyOwner: attacker reverts ---

    function test_setContractFactory_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        resourceManager.setContractFactory(makeAddr("x"));
    }

    function test_setEndpoint_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        resourceManager.setEndpoint(makeAddr("x"));
    }

    // --- Setter zero-address checks ---

    function test_setContractFactory_revertsOnZero() public {
        vm.expectRevert(ResourceManager.ResourceManager__ZeroAddress.selector);
        resourceManager.setContractFactory(address(0));
    }

    function test_setEndpoint_revertsOnZero() public {
        vm.expectRevert(ResourceManager.ResourceManager__ZeroAddress.selector);
        resourceManager.setEndpoint(address(0));
    }

    // --- Positive: owner and endpoint can register ---

    function test_owner_canRegisterResourceId() public {
        address impl2 = makeAddr("impl");
        resourceManager.registerResourceId(RESOURCE_ID, impl2);
        assertEq(resourceManager.getAddressByResourceId(RESOURCE_ID), impl2);
    }

    function test_endpoint_canRegisterResourceId() public {
        address impl2 = makeAddr("impl");
        vm.prank(endpointAddr);
        resourceManager.registerResourceId(RESOURCE_ID, impl2);
        assertEq(resourceManager.getAddressByResourceId(RESOURCE_ID), impl2);
    }

    // --- Positive: msgReceiver can call handleWithResourceId ---

    function test_msgReceiver_canCallHandleWithResourceId() public {
        RaylsMessageMetadata memory metadata;
        address dest = makeAddr("dest");
        vm.prank(msgReceiver);
        address resolved = resourceManager.handleWithResourceId(metadata, dest);
        assertEq(resolved, dest);
    }

    // --- handleWithResourceId reverts with no valid destination ---

    function test_handleWithResourceId_revertsOnNoValidDest() public {
        RaylsMessageMetadata memory metadata;
        vm.prank(msgReceiver);
        vm.expectRevert(ResourceManager.ResourceManager__NoValidDestination.selector);
        resourceManager.handleWithResourceId(metadata, address(0));
    }

    // --- Revoke removes access ---

    function test_handleWithResourceId_afterRevoke_reverts() public {
        manager.revokeRole(messageReceiverRoleId, msgReceiver);

        RaylsMessageMetadata memory metadata;
        vm.prank(msgReceiver);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, msgReceiver));
        resourceManager.handleWithResourceId(metadata, makeAddr("dest"));
    }
}
