// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import "../../../rayls-protocol/Enygma/Enygma-Payments/EnygmaFactory.sol";

/**
 * @title Security Test: EnygmaFactory Access Control (AUTH-V3)
 * @notice Tests that initiateEnygmaCreation() is protected by the AUTH-V3 `restricted`
 *         modifier, gated by a registered ENYGMA_CREATOR role on RaylsAccessManagerV1.
 *
 * Role layout:
 *   ENYGMA_CREATOR_ID — required to call initiateEnygmaCreation().
 *   FACTORY_ADMIN_ID  — admin of ENYGMA_CREATOR_ID (can grant/revoke it).
 */
contract EnygmaFactoryAccessControlTest is Test {
    RaylsAccessManagerV1 public manager;
    EnygmaFactory public factory;

    uint64 public ENYGMA_CREATOR_ID;
    uint64 public FACTORY_ADMIN_ID;

    address public admin;
    address public authorizedCaller;
    address public attacker;
    address public factoryAdmin;

    function _singleRole(uint64 roleId) internal pure returns (uint64[] memory roles) {
        roles = new uint64[](1);
        roles[0] = roleId;
    }

    function setUp() public {
        admin          = address(this);
        authorizedCaller = makeAddr("enygmaTokenManager");
        attacker       = makeAddr("attacker");
        factoryAdmin   = makeAddr("factoryAdmin");

        // Deploy manager via UUPS proxy
        RaylsAccessManagerV1 impl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(RaylsAccessManagerV1.initialize, (admin))))
        );

        // Deploy EnygmaFactory with manager as authority
        factory = new EnygmaFactory(
            makeAddr("registry"),
            makeAddr("integrationCreator"),
            makeAddr("settings"),
            makeAddr("enygmaTeleport"),
            makeAddr("enygmaCreator"),
            makeAddr("vaultCreator"),
            address(manager)
        );

        // Register roles
        ENYGMA_CREATOR_ID = manager.registerRole("ENYGMA_CREATOR");
        FACTORY_ADMIN_ID  = manager.registerRole("FACTORY_ADMIN");

        // FACTORY_ADMIN administers ENYGMA_CREATOR
        manager.setRoleAdmin(ENYGMA_CREATOR_ID, FACTORY_ADMIN_ID);

        // Map initiateEnygmaCreation selector to ENYGMA_CREATOR_ID
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("initiateEnygmaCreation((string,string,uint8,bytes32,address,uint256,address,address,address,uint256))"));
        manager.addFunctionAllowedRoles(address(factory), selectors, _singleRole(ENYGMA_CREATOR_ID));

        // Grant FACTORY_ADMIN to factoryAdmin, then factoryAdmin grants ENYGMA_CREATOR to authorizedCaller
        manager.grantRole(FACTORY_ADMIN_ID, factoryAdmin, 0);
        vm.prank(factoryAdmin);
        manager.grantRole(ENYGMA_CREATOR_ID, authorizedCaller, 0);
    }

    // ── Attacker is blocked ───────────────────────────────────────────────────

    function test_initiateEnygmaCreation_attackerReverts() public {
        EnygmaInitParams memory params;
        params.resourceId = bytes32(uint256(1));

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector,
            attacker
        ));
        factory.initiateEnygmaCreation(params);
    }

    function test_initiateEnygmaCreation_randomEOAReverts() public {
        address random = makeAddr("random");
        EnygmaInitParams memory params;
        params.resourceId = bytes32(uint256(2));

        vm.prank(random);
        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector,
            random
        ));
        factory.initiateEnygmaCreation(params);
    }

    // ── Revoking role blocks further calls ───────────────────────────────────

    function test_revokedCaller_isBlocked() public {
        vm.prank(factoryAdmin);
        manager.revokeRole(ENYGMA_CREATOR_ID, authorizedCaller);

        EnygmaInitParams memory params;
        params.resourceId = bytes32(uint256(3));

        vm.prank(authorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector,
            authorizedCaller
        ));
        factory.initiateEnygmaCreation(params);
    }

    // ── Authority is correctly set ───────────────────────────────────────────

    function test_authority_isManager() public view {
        assertEq(factory.authority(), address(manager));
    }
}
