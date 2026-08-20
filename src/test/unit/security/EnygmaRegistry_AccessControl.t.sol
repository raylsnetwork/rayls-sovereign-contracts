// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {EnygmaRegistry} from "../../../rayls-protocol/Enygma/Enygma-Payments/EnygmaRegistry.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";

contract EnygmaRegistryAccessControlTest is Test {
    EnygmaRegistry public registry;
    RaylsAccessManagerV1 public manager;

    address public admin;
    address public attacker;

    bytes32 constant RESOURCE_ID = bytes32(uint256(1));

    function setUp() public {
        admin = address(this);
        attacker = makeAddr("attacker");

        RaylsAccessManagerV1 impl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(
            address(impl), abi.encodeCall(RaylsAccessManagerV1.initialize, (admin))
        )));

        registry = new EnygmaRegistry(address(manager));
    }

    // ========== Negative: attacker cannot call register functions ==========

    function test_registerVault_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        registry.registerVault(RESOURCE_ID, attacker);
    }

    function test_registerMerkle_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        registry.registerMerkle(RESOURCE_ID, attacker);
    }

    function test_registerEnygma_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        registry.registerEnygma(RESOURCE_ID, attacker);
    }

    function test_registerDvpIntegration_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        registry.registerDvpIntegration(RESOURCE_ID, attacker);
    }

    // ========== Positive: admin can call register functions ==========

    function test_registerVault_ownerSucceeds() public {
        address vault = makeAddr("vault");
        registry.registerVault(RESOURCE_ID, vault);
        assertEq(registry.getVaultAddress(RESOURCE_ID), vault);
    }

    function test_registerMerkle_ownerSucceeds() public {
        address merkle = makeAddr("merkle");
        registry.registerMerkle(RESOURCE_ID, merkle);
        assertEq(registry.getMerkleAddress(RESOURCE_ID), merkle);
    }

    function test_registerEnygma_ownerSucceeds() public {
        address enygma = makeAddr("enygma");
        registry.registerEnygma(RESOURCE_ID, enygma);
        assertEq(registry.getEnygmaAddress(RESOURCE_ID), enygma);
    }

    function test_registerDvpIntegration_ownerSucceeds() public {
        address integration = makeAddr("integration");
        registry.registerDvpIntegration(RESOURCE_ID, integration);
        assertEq(registry.getDvpIntegrationAddress(RESOURCE_ID), integration);
    }
}
