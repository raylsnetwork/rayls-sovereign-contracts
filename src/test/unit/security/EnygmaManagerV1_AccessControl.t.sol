// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EnygmaManagerV1} from "../../../privateHub/ParticipantStorage/modules/EnygmaManager/EnygmaManagerV1.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title Mock ParticipantCore for EnygmaManager tests
 * @dev Always returns true for verifyParticipant
 */
contract MockParticipantCoreForEnygma {
    function verifyParticipant(uint256) external pure returns (bool) {
        return true;
    }

    function verifyParticipants(uint256, uint256) external pure returns (bool) {
        return true;
    }
}

/**
 * @title Security Test: EnygmaManagerV1 Access Control
 * @notice Tests that setPaymentSpendPublicKey and setEnygmaPnEventsAddress
 *         are protected by onlyParentStorage.
 *
 * VULNERABILITY (before fix):
 * - Anyone could set Enygma public keys for any participant
 * - Anyone could change the PN events contract address
 *
 * EXPECTED BEHAVIOR (after fix):
 * - Only the ParticipantStorage contract can call these setter functions
 * - Attackers and even the owner get reverted
 */
contract EnygmaManagerV1AccessControlTest is Test {
    EnygmaManagerV1 public enygmaManager;
    MockParticipantCoreForEnygma public mockCore;

    address public owner;
    address public parentStorage;
    address public attacker;

    function setUp() public {
        owner = makeAddr("owner");
        parentStorage = makeAddr("parentStorage");
        attacker = makeAddr("attacker");

        mockCore = new MockParticipantCoreForEnygma();

        // Deploy AccessManager via proxy (authority_ must be a real contract, not an EOA)
        RaylsAccessManagerV1 managerImpl = new RaylsAccessManagerV1();
        RaylsAccessManagerV1 manager = RaylsAccessManagerV1(address(new ERC1967Proxy(
            address(managerImpl), abi.encodeCall(RaylsAccessManagerV1.initialize, (owner))
        )));

        // Deploy implementation
        EnygmaManagerV1 impl = new EnygmaManagerV1();

        // Deploy proxy and initialize with parentStorage
        // initialize(address _participantCore, address _parentStorage, address authority_)
        bytes memory initData = abi.encodeWithSelector(
            EnygmaManagerV1.initialize.selector,
            address(mockCore),
            parentStorage,
            address(manager)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        enygmaManager = EnygmaManagerV1(address(proxy));
    }

    // --- Negative: attacker cannot call setPaymentSpendPublicKey ---

    function test_setPaymentSpendPublicKey_attackerReverts() public {
        address[] memory pnAddresses = new address[](1);
        pnAddresses[0] = makeAddr("pn1");

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(EnygmaManagerV1.EnygmaManagerV1__UnauthorizedCaller.selector, attacker));
        enygmaManager.setPaymentSpendPublicKey(999, 123, pnAddresses);
    }

    // --- Negative: owner cannot call setPaymentSpendPublicKey directly ---

    function test_setPaymentSpendPublicKey_ownerReverts() public {
        address[] memory pnAddresses = new address[](1);
        pnAddresses[0] = makeAddr("pn1");

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(EnygmaManagerV1.EnygmaManagerV1__UnauthorizedCaller.selector, owner));
        enygmaManager.setPaymentSpendPublicKey(999, 123, pnAddresses);
    }

    // --- Negative: attacker cannot call setEnygmaPnEventsAddress ---

    function test_setEnygmaPnEventsAddress_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(EnygmaManagerV1.EnygmaManagerV1__UnauthorizedCaller.selector, attacker));
        enygmaManager.setEnygmaPnEventsAddress(makeAddr("evil"));
    }

    // --- Positive: parentStorage can call setPaymentSpendPublicKey ---

    function test_setPaymentSpendPublicKey_parentStorageSucceeds() public {
        address[] memory pnAddresses = new address[](1);
        pnAddresses[0] = makeAddr("pn1");

        vm.prank(parentStorage);
        enygmaManager.setPaymentSpendPublicKey(999, 123, pnAddresses);

        uint256 pubKey = enygmaManager.getPaymentSpendPublicKeyByChainId(999);
        assertEq(pubKey, 123);
    }

    // --- Positive: parentStorage can call setEnygmaPnEventsAddress ---

    function test_setEnygmaPnEventsAddress_parentStorageSucceeds() public {
        address newEvents = makeAddr("newEvents");
        vm.prank(parentStorage);
        enygmaManager.setEnygmaPnEventsAddress(newEvents);
        assertEq(enygmaManager.getEnygmaPnEventsAddress(), newEvents);
    }

    // --- View functions remain publicly accessible ---

    function test_anyone_canReadEnygmaData() public {
        // Set data as parentStorage first
        address[] memory pnAddresses = new address[](1);
        pnAddresses[0] = makeAddr("pn1");
        vm.prank(parentStorage);
        enygmaManager.setPaymentSpendPublicKey(999, 123, pnAddresses);

        // Anyone can read
        vm.startPrank(attacker);
        enygmaManager.getPaymentSpendPublicKeyByChainId(999);
        enygmaManager.getEnygmaAllParticipantsChainIds();
        enygmaManager.getEnygmaPnEventsAddress();
        vm.stopPrank();
    }
}
