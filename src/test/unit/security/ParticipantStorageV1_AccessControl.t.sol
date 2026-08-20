// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import "../../../privateHub/ParticipantStorage/ParticipantStorageV1.sol";
import "../mocks/MockEndpointForSecurityTest.sol";
import {RaylsAppV1} from "../../../rayls-protocol-sdk/RaylsAppV1.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";

/**
 * @title Security Test: ParticipantStorageV1 Access Control
 * @notice Tests that facade functions are protected by access control modifiers.
 *
 * VULNERABILITY (before fix):
 * - Anyone could call setAuditInfo(), setChainViewData(), setPaymentSpendPublicKey(),
 *   broadcastCurrentParticipants() to manipulate participant data on the private hub
 *
 * EXPECTED BEHAVIOR (after fix):
 * - broadcastCurrentParticipants: only endpoint's trusted executor (receiveMethod)
 * - setAuditInfo, setChainViewData, setPaymentSpendPublicKey: only owner, trusted executor,
 *   or authorized relayer (onlyAuthorizedCaller)
 *
 * NOTE: PN relayers must be granted RELAYER in the RaylsAccessManagerV1 (AUTH-V3)
 * BEFORE calling these functions. The relayer bootstrap in rayls-privacy-relayer-api
 * must wait for role assignment before calling SetChainInfo etc.
 */
contract ParticipantStorageV1AccessControlTest is Test {
    ParticipantStorageV1 public participantStorage;
    MockEndpointForSecurityTest public mockEndpoint;
    RaylsAccessManagerV1 public manager;

    address public owner;
    address public attacker;

    uint256 constant CHAIN_ID = 12345;
    uint256 constant PRIVATE_HUB_CHAIN_ID = 99999;

    function setUp() public {
        owner = address(this);
        attacker = makeAddr("attacker");

        // Deploy AccessManager
        RaylsAccessManagerV1 managerImpl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(
            address(managerImpl), abi.encodeCall(RaylsAccessManagerV1.initialize, (owner))
        )));
        manager.registerRole("RELAYER");
        manager.registerRole("MESSAGE_EXECUTOR");

        mockEndpoint = new MockEndpointForSecurityTest(CHAIN_ID, PRIVATE_HUB_CHAIN_ID);
        mockEndpoint.setTrustedExecutor(owner);
        mockEndpoint.setAuthority(address(manager));

        participantStorage = new ParticipantStorageV1();
        participantStorage.initialize(address(mockEndpoint), address(manager));
    }

    // ========== broadcastCurrentParticipants() ==========

    function test_broadcastCurrentParticipants_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        participantStorage.broadcastCurrentParticipants();
    }

    // ========== setAuditInfo() ==========

    function test_setAuditInfo_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("RaylsAccessManaged__Unauthorized(address)")), attacker));
        participantStorage.setAuditInfo(999, "pubkey", "", "", 1);
    }

    // ========== setChainViewData() ==========

    function test_setChainViewData_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("RaylsAccessManaged__Unauthorized(address)")), attacker));
        participantStorage.setChainViewData(999, "pubkey", 1);
    }

    // ========== setPaymentSpendPublicKey() ==========

    function test_setPaymentSpendPublicKey_attackerReverts() public {
        address[] memory pnAddresses = new address[](0);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("RaylsAccessManaged__Unauthorized(address)")), attacker));
        participantStorage.setPaymentSpendPublicKey(999, 1, pnAddresses);
    }
}
