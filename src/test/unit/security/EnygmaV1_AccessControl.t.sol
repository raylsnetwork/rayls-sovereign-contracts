// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EnygmaV1} from "../../../rayls-protocol/Enygma/Enygma-Payments/EnygmaV1.sol";
import {EnygmaCreationParams} from "../../../rayls-protocol/Enygma/Enygma-Payments/EnygmaCreator.sol";

/**
 * @title Mock ParticipantStorage for EnygmaV1 constructor
 */
contract MockParticipantStorage {
    function getEnygmaAllParticipantsChainIds() external pure returns (uint256[] memory) {
        return new uint256[](0);
    }
}

/**
 * @title Security Test: EnygmaV1 setDvpIntegrationContract Access Control
 * @notice Tests that setDvpIntegrationContract is protected by onlyFactory.
 *
 * VULNERABILITY (before fix):
 * - Anyone could set the DVP integration contract address
 * - This would allow calling all onlyDvpIntegration functions
 *
 * EXPECTED BEHAVIOR (after fix):
 * - Only the factory can call setDvpIntegrationContract
 * - Unauthorized callers get reverted with EnygmaV1__OnlyFactoryAllowed
 */
contract EnygmaV1AccessControlTest is Test {
    address public factory;
    address public attacker;
    address public integration;

    EnygmaV1 public enygma;

    function setUp() public {
        factory = makeAddr("factory");
        attacker = makeAddr("attacker");
        integration = makeAddr("integration");

        MockParticipantStorage mockPS = new MockParticipantStorage();

        EnygmaCreationParams memory params = EnygmaCreationParams({
            name: "TestEnygma",
            symbol: "TE",
            decimals: 18,
            resourceId: bytes32(uint256(1)),
            owner: factory,
            ownerChainId: 1,
            participantStorageContract: address(mockPS),
            endpoint: address(0),
            tokenRegistryContract: address(0),
            enygmaTeleport: address(0),
            factory: factory
        });

        vm.prank(factory);
        enygma = new EnygmaV1(params);
    }

    // ========== Negative test: attacker cannot set DVP integration ==========

    function test_setDvpIntegrationContract_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(EnygmaV1.EnygmaV1__OnlyFactoryAllowed.selector);
        enygma.setDvpIntegrationContract(integration);
    }

    // ========== Positive test: factory can set DVP integration ==========

    function test_setDvpIntegrationContract_factorySucceeds() public {
        vm.prank(factory);
        enygma.setDvpIntegrationContract(integration);
    }
}
