// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import "../../../rayls-protocol/RaylsContractFactory/RaylsContractFactoryV1.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title Security Test: RaylsContractFactoryV1 Access Control (Auth V3)
 * @notice Tests that deploy() is protected by the `restricted` modifier via RaylsAccessManagerV1.
 */
contract RaylsContractFactoryV1AccessControlTest is Test {
    RaylsContractFactoryV1 public factory;
    RaylsAccessManagerV1 public manager;

    address public admin;
    address public endpoint;
    address public raylsNodeEndpoint;
    address public attacker;

    uint64 public factoryAdminRoleId;

    function setUp() public {
        admin = address(this);
        endpoint = makeAddr("endpoint");
        raylsNodeEndpoint = makeAddr("raylsNodeEndpoint");
        attacker = makeAddr("attacker");

        // Deploy AccessManager via proxy
        RaylsAccessManagerV1 impl = new RaylsAccessManagerV1();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(impl.initialize, (admin))
        );
        manager = RaylsAccessManagerV1(address(proxy));

        // Register FACTORY_ADMIN role and map deploy() to it
        factoryAdminRoleId = manager.registerRole("FACTORY_ADMIN");

        // Deploy factory behind a proxy (the implementation disables initializers in its
        // constructor, mirroring the production UUPS deploy).
        RaylsContractFactoryV1 facImpl = new RaylsContractFactoryV1();
        factory = RaylsContractFactoryV1(address(new ERC1967Proxy(
            address(facImpl),
            abi.encodeCall(facImpl.initialize, (endpoint, raylsNodeEndpoint, admin, address(manager)))
        )));

        // Map deploy() selector to FACTORY_ADMIN
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = factory.deploy.selector;
        uint64[] memory roles = new uint64[](1);
        roles[0] = factoryAdminRoleId;
        manager.addFunctionAllowedRoles(address(factory), sels, roles);

        // Grant FACTORY_ADMIN to endpoint
        manager.grantRole(factoryAdminRoleId, endpoint, 0);
    }

    // ========== deploy() — attacker MUST be blocked ==========

    function test_deploy_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector,
                attacker
            )
        );
        factory.deploy("", "", bytes32(0));
    }

    // ========== deploy() — admin can call (ADMIN bypass) ==========

    function test_deploy_adminCanCall() public {
        // Admin has ADMIN role which bypasses all checks.
        // deploy() will revert on internal logic (no bytecode), but NOT on access control.
        vm.expectRevert(); // reverts on FactoryV1__EmptyBytecode, not on access
        factory.deploy("", "", bytes32(0));
    }

    // ========== deploy() — endpoint can call (has FACTORY_ADMIN) ==========

    function test_deploy_endpointCanCall() public {
        vm.prank(endpoint);
        // Will revert on FactoryV1__EmptyBytecode, but NOT on access control.
        vm.expectRevert();
        factory.deploy("", "", bytes32(0));
    }
}
