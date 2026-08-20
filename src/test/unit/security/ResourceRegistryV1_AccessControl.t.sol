// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ResourceRegistryV1} from "../../../privateHub/ResourceRegistry/ResourceRegistryV1.sol";
import {SharedObjects} from "../../../rayls-protocol-sdk/libraries/SharedObjects.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";

/**
 * @title Security Test: ResourceRegistryV1 Access Control
 * @notice Tests that registerResource is protected by onlyTokenRegistry
 *         and setTokenRegistry is protected by restricted (Auth V3).
 */
contract ResourceRegistryV1AccessControlTest is Test {
    ResourceRegistryV1 public registry;
    RaylsAccessManagerV1 public manager;

    address public admin;
    address public tokenRegistry;
    address public attacker;

    function setUp() public {
        admin = address(this);
        tokenRegistry = makeAddr("tokenRegistry");
        attacker = makeAddr("attacker");

        // Deploy AccessManager
        RaylsAccessManagerV1 mgrImpl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(
            address(mgrImpl), abi.encodeCall(RaylsAccessManagerV1.initialize, (admin))
        )));

        // Deploy ResourceRegistryV1 proxy
        ResourceRegistryV1 impl = new ResourceRegistryV1();
        bytes memory initData = abi.encodeWithSelector(ResourceRegistryV1.initialize.selector, address(manager));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        registry = ResourceRegistryV1(address(proxy));

        // Set the token registry address (admin can call restricted functions via ADMIN)
        registry.setTokenRegistry(tokenRegistry);
    }

    // --- Negative: attacker cannot call registerResource ---

    function test_registerResource_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ResourceRegistryV1.ResourceRegistryV1__UnauthorizedCaller.selector, attacker));
        registry.registerResource(SharedObjects.ErcStandard.ERC20, "", "");
    }

    // --- Negative: admin (non-tokenRegistry) cannot call registerResource ---

    function test_registerResource_adminReverts() public {
        // Admin has ADMIN but registerResource is gated by onlyTokenRegistry (identity check),
        // not restricted. So admin is also blocked.
        vm.expectRevert(abi.encodeWithSelector(ResourceRegistryV1.ResourceRegistryV1__UnauthorizedCaller.selector, admin));
        registry.registerResource(SharedObjects.ErcStandard.ERC20, "", "");
    }

    // --- Positive: tokenRegistry can call registerResource ---

    function test_registerResource_tokenRegistrySucceeds() public {
        vm.prank(tokenRegistry);
        bytes32 resourceId = registry.registerResource(SharedObjects.ErcStandard.ERC20, "", "");
        assertTrue(resourceId != bytes32(0));
    }

    // --- Negative: if tokenRegistry not set, reverts ---

    function test_registerResource_noTokenRegistrySet_reverts() public {
        ResourceRegistryV1 impl2 = new ResourceRegistryV1();
        bytes memory initData2 = abi.encodeWithSelector(ResourceRegistryV1.initialize.selector, admin);
        ERC1967Proxy proxy2 = new ERC1967Proxy(address(impl2), initData2);
        ResourceRegistryV1 freshRegistry = ResourceRegistryV1(address(proxy2));

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ResourceRegistryV1.ResourceRegistryV1__TokenRegistryNotSet.selector));
        freshRegistry.registerResource(SharedObjects.ErcStandard.ERC20, "", "");
    }

    // --- setTokenRegistry: attacker reverts with Unauthorized ---

    function test_setTokenRegistry_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        registry.setTokenRegistry(makeAddr("evil"));
    }

    // --- setTokenRegistry: admin succeeds ---

    function test_setTokenRegistry_adminSucceeds() public {
        address newTokenRegistry = makeAddr("newTokenRegistry");
        registry.setTokenRegistry(newTokenRegistry);
    }
}
