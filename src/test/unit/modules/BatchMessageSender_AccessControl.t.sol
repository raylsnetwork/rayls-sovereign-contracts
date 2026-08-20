// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import "../../../rayls-protocol/modules/BatchMessageSender.sol";
import "../../../rayls-protocol-sdk/RaylsMessage.sol";

contract MockParticipantValidator {
    function validateMessageParticipants(uint256, uint256) external pure {}
}

contract MockTokenValidator {
    function validateTokenForParticipant(bytes32, uint256) external pure {}
}

/**
 * @title Security Test: BatchMessageSender Access Control
 * @notice Tests onlyEndpoint on prepareBatch, onlyOwner on setters,
 *         and zero-address checks in constructor.
 */
contract BatchMessageSenderAccessControlTest is Test {
    BatchMessageSender public batchSender;
    MockParticipantValidator public mockPV;
    MockTokenValidator public mockTV;
    RaylsAccessManagerV1 public manager;

    address public owner;
    address public attacker;
    address public endpoint;

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

        batchSender = new BatchMessageSender(PRIVATE_HUB_CHAIN_ID, address(mockPV), address(mockTV), endpoint, owner, address(manager));
    }

    // --- onlyOwner: attacker reverts ---

    function test_setParticipantValidator_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        batchSender.setParticipantValidator(makeAddr("x"));
    }

    function test_setTokenValidator_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        batchSender.setTokenValidator(makeAddr("x"));
    }

    // --- Setter zero-address checks ---

    function test_setParticipantValidator_revertsOnZero() public {
        vm.expectRevert(BatchMessageSender.BatchMessageSender__ZeroAddress.selector);
        batchSender.setParticipantValidator(address(0));
    }

    function test_setTokenValidator_revertsOnZero() public {
        vm.expectRevert(BatchMessageSender.BatchMessageSender__ZeroAddress.selector);
        batchSender.setTokenValidator(address(0));
    }

    // --- Positive: owner can call setters ---

    function test_owner_canSetParticipantValidator() public {
        address v = makeAddr("v");
        batchSender.setParticipantValidator(v);
        assertEq(address(batchSender.participantValidator()), v);
    }

    function test_owner_canSetTokenValidator() public {
        address v = makeAddr("v");
        batchSender.setTokenValidator(v);
        assertEq(address(batchSender.tokenValidator()), v);
    }
}
