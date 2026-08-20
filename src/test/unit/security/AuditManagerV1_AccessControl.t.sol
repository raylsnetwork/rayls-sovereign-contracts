// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AuditManagerV1} from "../../../privateHub/ParticipantStorage/modules/AuditManager/AuditManagerV1.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title Mock ParticipantCore for AuditManager tests
 * @dev Always returns true for verifyParticipant
 */
contract MockParticipantCore {
    function verifyParticipant(uint256) external pure returns (bool) {
        return true;
    }

    function verifyParticipants(uint256, uint256) external pure returns (bool) {
        return true;
    }
}

/**
 * @title Security Test: AuditManagerV1 Access Control
 * @notice Tests that setAuditInfo and setChainInfo are protected by onlyParentStorage.
 *
 * VULNERABILITY (before fix):
 * - Any active participant could call setAuditInfo/setChainInfo
 * - Attacker could overwrite audit data for any participant
 *
 * EXPECTED BEHAVIOR (after fix):
 * - Only the ParticipantStorage contract can call setAuditInfo and setChainInfo
 * - Attackers and even the owner get reverted
 */
contract AuditManagerV1AccessControlTest is Test {
    AuditManagerV1 public auditManager;
    MockParticipantCore public mockCore;

    address public owner;
    address public parentStorage;
    address public attacker;

    function setUp() public {
        owner = makeAddr("owner");
        parentStorage = makeAddr("parentStorage");
        attacker = makeAddr("attacker");

        mockCore = new MockParticipantCore();

        // Deploy AccessManager via proxy (authority_ must be a real contract, not an EOA)
        RaylsAccessManagerV1 managerImpl = new RaylsAccessManagerV1();
        RaylsAccessManagerV1 manager = RaylsAccessManagerV1(address(new ERC1967Proxy(
            address(managerImpl), abi.encodeCall(RaylsAccessManagerV1.initialize, (owner))
        )));

        // Deploy implementation
        AuditManagerV1 impl = new AuditManagerV1();

        // Deploy proxy and initialize with parentStorage
        // initialize(address _participantCore, address _parentStorage, address authority_)
        bytes memory initData = abi.encodeWithSelector(
            AuditManagerV1.initialize.selector,
            address(mockCore),
            parentStorage,
            address(manager)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        auditManager = AuditManagerV1(address(proxy));
    }

    // --- Negative: attacker cannot call setAuditInfo ---

    function test_setAuditInfo_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(AuditManagerV1.AuditManagerV1__UnauthorizedCaller.selector, attacker));
        auditManager.setAuditInfo(999, "pubkey", "", "", 1);
    }

    // --- Negative: owner cannot call setAuditInfo directly ---

    function test_setAuditInfo_ownerReverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AuditManagerV1.AuditManagerV1__UnauthorizedCaller.selector, owner));
        auditManager.setAuditInfo(999, "pubkey", "encKey", "mac", 1);
    }

    // --- Negative: attacker cannot call setChainInfo ---

    function test_setChainInfo_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(AuditManagerV1.AuditManagerV1__UnauthorizedCaller.selector, attacker));
        auditManager.setChainViewData(999, "pubkey", 1);
    }

    // --- Positive: parentStorage can call setAuditInfo ---

    function test_setAuditInfo_parentStorageSucceeds() public {
        vm.prank(parentStorage);
        auditManager.setAuditInfo(999, "pubkey", "encKey", "mac", 1);
    }

    // --- Positive: parentStorage can call setChainInfo ---

    function test_setChainInfo_parentStorageSucceeds() public {
        vm.prank(parentStorage);
        auditManager.setChainViewData(999, "pubkey", 1);
    }

    // --- View functions remain accessible to anyone ---

    function test_anyone_canReadAuditInfo() public {
        // First set data as parentStorage
        vm.prank(parentStorage);
        auditManager.setAuditInfo(999, "pubkey", "encKey", "mac", 1);

        // Anyone can read
        vm.prank(attacker);
        auditManager.getAuditInfo(999);
    }
}
