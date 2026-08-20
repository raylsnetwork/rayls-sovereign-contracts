// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {CustomTokenExample} from "../../../rayls-protocol/test-contracts/CustomTokenExample.sol";
import {RaylsContractFactoryV1} from "../../../rayls-protocol/RaylsContractFactory/RaylsContractFactoryV1.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {Constants} from "../../../rayls-protocol-sdk/Constants.sol";
import {MockFactoryTokenRegistry} from "./factory/FactoryTestUtils.sol";

/**
 * @notice Endpoint stub for `CustomTokenExample`'s constructor + `initialize` paths.
 * @dev `EndpointV1` is a heavy contract; this stub exposes only the surface the
 *      handler reaches (`authority()` returns the bound AccessManager;
 *      `getUserGovernanceAddress()` returns zero so user-governance wiring is skipped;
 *      `contractVersion()` is referenced by `CustomTokenExample.getVersion()`).
 */
contract _MockEndpointForCustomToken {
    /// @dev Mutable so the test fixture can switch authority between phases.
    ///      Direct-deploy phase: authority = 0 (skip parent's `_registerAccessControl` so the
    ///      explicit `selfRegisterManagedContract` in CustomTokenExample's body doesn't
    ///      collide). Factory-deploy phase: authority = manager (factory's
    ///      auto-grant via `IRaylsEndpoint(endpoint).authority()` looks up the manager).
    address private _authority;
    address private _tokenRegistry;

    /// @notice Sets the mock endpoint authority returned to handlers and the factory.
    /// @param a Authority address to return.
    function setAuthority(address a) external {
        _authority = a;
    }

    /// @notice Sets the mock PN TokenRegistry resource returned to the factory.
    /// @param tokenRegistry TokenRegistry address to return for RESOURCE_ID_TOKEN_REGISTRY.
    function setTokenRegistry(address tokenRegistry) external {
        _tokenRegistry = tokenRegistry;
    }

    /// @notice Returns the configured access authority address.
    /// @return Configured authority address.
    function authority() external view returns (address) {
        return _authority;
    }

    /// @notice Returns no user-governance address for this minimal endpoint fixture.
    /// @return Zero address.
    function getUserGovernanceAddress() external pure returns (address) {
        return address(0);
    }

    /// @notice Returns a fixed endpoint contract version for `CustomTokenExample.getVersion()`.
    /// @return Fixed version value.
    function contractVersion() external pure returns (uint256) {
        return 1;
    }

    /// @notice Returns no configured private-hub address for this minimal endpoint fixture.
    /// @return Zero address.
    function getPrivateHubAddress(string memory) external pure returns (address) {
        return address(0);
    }

    /// @dev Used by the handler when it needs to fall back to `_unlock(address(0), ...)`
    ///      and by the factory to resolve the PN TokenRegistry resource.
    /// @param resourceId Resource id being resolved.
    /// @return Address configured for the resource id, or zero when unconfigured.
    function getAddressByResourceId(bytes32 resourceId) external view returns (address) {
        if (resourceId == Constants.RESOURCE_ID_TOKEN_REGISTRY) {
            return _tokenRegistry;
        }
        return address(0);
    }
}

/**
 * @title CustomTokenExample access-control reproductions
 * @notice Two PR-review findings (#1 HIGH, #2 HIGH) reproduced as fix-asserting tests.
 *         Each test fails while the bug is present, passes after the fix is applied.
 */
contract CustomTokenExampleAccessControlTest is Test {
    RaylsAccessManagerV1 internal manager;
    RaylsContractFactoryV1 internal factory;
    _MockEndpointForCustomToken internal endpoint;
    MockFactoryTokenRegistry internal tokenRegistry;

    address internal admin = address(this);
    address internal factoryOwner = makeAddr("factoryOwner");
    address internal raylsNodeEndpoint = makeAddr("raylsNodeEndpoint");
    address internal attacker = makeAddr("attacker");
    address internal executor = makeAddr("executor");

    uint64 internal factoryAdminRoleId;
    uint64 internal factoryDeployerRoleId;
    uint64 internal endpointSenderRoleId;
    uint64 internal messageExecutorRoleId;

    bytes4 internal constant RECEIVE_TELEPORT_SEL = bytes4(keccak256("receiveTeleport(address,uint256)"));
    bytes4 internal constant UNLOCK_TO_RID_SEL = bytes4(keccak256("unlockToResourceId(bytes32,uint256)"));

    /// @notice Deploys the custom-token access-control fixture and role mappings.
    function setUp() public {
        // Stand up an AccessManager backed by ERC1967Proxy.
        RaylsAccessManagerV1 mgrImpl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(
            address(mgrImpl),
            abi.encodeCall(mgrImpl.initialize, (admin))
        )));

        // Endpoint stub bound to the AccessManager — `authority()` returns it.
        endpoint = new _MockEndpointForCustomToken();
        tokenRegistry = new MockFactoryTokenRegistry();
        endpoint.setTokenRegistry(address(tokenRegistry));

        // Factory proxy.
        RaylsContractFactoryV1 facImpl = new RaylsContractFactoryV1();
        factory = RaylsContractFactoryV1(address(new ERC1967Proxy(
            address(facImpl),
            abi.encodeCall(facImpl.initialize, (address(endpoint), raylsNodeEndpoint, factoryOwner, address(manager)))
        )));

        // Role tree mirrors the production deploy: ENDPOINT_SENDER admin = FACTORY_ADMIN.
        factoryAdminRoleId    = manager.registerRole("FACTORY_ADMIN");
        factoryDeployerRoleId = manager.registerRole("FACTORY_DEPLOYER");
        endpointSenderRoleId  = manager.registerRole("ENDPOINT_SENDER");
        messageExecutorRoleId = manager.registerRole("MESSAGE_EXECUTOR");

        manager.setRoleAdmin(endpointSenderRoleId, factoryAdminRoleId);

        // factory.deploy() callable by FACTORY_ADMIN + FACTORY_DEPLOYER.
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = factory.deploy.selector;
        uint64[] memory roles = new uint64[](2);
        roles[0] = factoryAdminRoleId;
        roles[1] = factoryDeployerRoleId;
        manager.addFunctionAllowedRoles(address(factory), sels, roles);

        // Factory itself must hold FACTORY_ADMIN to grant ENDPOINT_SENDER post-deploy.
        manager.grantRole(factoryAdminRoleId, address(factory), 0);
        // Test contract holds FACTORY_DEPLOYER so it can call factory.deploy().
        manager.grantRole(factoryDeployerRoleId, address(this), 0);
        // The "executor" wallet holds MESSAGE_EXECUTOR for bug #1 verification.
        manager.grantRole(messageExecutorRoleId, executor, 0);
    }

    // ─────────────────────────────────────────────────────────────────
    //  Bug #1 — `initialize` override forgets `_registerAccessControl`
    // ─────────────────────────────────────────────────────────────────

    /// @notice Direct-deploy + factory-redeploy path for CustomTokenExample.
    ///         Returns the address of the FACTORY-deployed instance (the one initialized
    ///         via `initialize(bytes,RaylsTrustedInit)` — the buggy code path).
    /// @return factoryDeployed Address of the factory-deployed custom token instance.
    function _deployViaFactory() internal returns (address factoryDeployed) {
        // Phase 1: direct-deploy with `endpoint.authority() == 0` so the parent's
        // `_registerAccessControl` short-circuits and only CustomTokenExample's body-level
        // `selfRegisterManagedContract` runs (single registration, no collision).
        endpoint.setAuthority(address(0));
        CustomTokenExample direct = new CustomTokenExample(
            "CustomTok",
            "CTK",
            0,
            address(0),
            address(endpoint),
            raylsNodeEndpoint,
            address(manager)
        );
        bytes memory runtime = address(direct).code;

        // Phase 2: switch endpoint.authority() to the manager so the factory's auto-grant
        // (`IRaylsEndpoint(endpoint).authority().grantRole(...)`) can reach the manager.
        endpoint.setAuthority(address(manager));

        // Encode the 5-tuple userArgs that CustomTokenExample.initialize expects.
        bytes memory userArgs = abi.encode(
            "CustomTok",
            "CTK",
            uint256(0),
            address(0),
            bytes32(uint256(1))
        );

        bytes32 resourceId = bytes32(uint256(0xC0DECA57));
        factoryDeployed = factory.deploy(runtime, userArgs, resourceId);
    }

    /// @notice Verifies factory-deployed custom tokens register MESSAGE_EXECUTOR selectors.
    /// @dev Bug #1 reproduction: after factory-deploy, MESSAGE_EXECUTOR cannot call
    /// `receiveTeleport` because `initialize` did not register the selector mapping.
    /// Pre-fix: `canCall` returns false → assertion fails → test fails.
    /// Post-fix: `canCall` returns true → assertion holds → test passes.
    function test_bug1_factoryDeploy_thenMessageExecutorCanCallReceiveTeleport() public {
        address deployed = _deployViaFactory();

        (bool allowed, , ) = manager.canCall(executor, deployed, RECEIVE_TELEPORT_SEL);
        assertTrue(
            allowed,
            "MESSAGE_EXECUTOR must be allowed to call receiveTeleport on factory-deployed CustomTokenExample (initialize must call _registerAccessControl)"
        );
    }

    // ─────────────────────────────────────────────────────────────────
    //  Factory deploy caller receives TOKEN_OWNER (alongside factoryOwner)
    // ─────────────────────────────────────────────────────────────────

    /// @notice The address that calls `factory.deploy()` (here `address(this)`, holding
    ///         FACTORY_DEPLOYER) must receive TOKEN_OWNER on the deployed token, in addition
    ///         to the `factoryOwner` injected via trusted-init. The factoryOwner remains the
    ///         contract authority. A random EOA gets nothing.
    function test_factoryDeploy_grantsCallerAndOwnerTokenOwner() public {
        address deployed = _deployViaFactory();

        uint64 tokenOwnerRole = manager.TOKEN_OWNER();

        // Both the deploy caller (this test contract) and the factoryOwner hold TOKEN_OWNER.
        (bool callerIsMember,) = manager.hasContractScopedRole(tokenOwnerRole, address(this), deployed);
        (bool ownerIsMember,) = manager.hasContractScopedRole(tokenOwnerRole, factoryOwner, deployed);
        assertTrue(callerIsMember, "deploy caller must hold TOKEN_OWNER");
        assertTrue(ownerIsMember, "factoryOwner must hold TOKEN_OWNER");

        // Authority stays the factoryOwner (injected as trusted.owner), not the caller.
        assertEq(manager.getContractAuthority(deployed), factoryOwner);

        // The caller can call the owner-gated mint; a random attacker cannot.
        bytes4 mintSel = bytes4(keccak256("mint(address,uint256)"));
        (bool callerCanMint,,) = manager.canCall(address(this), deployed, mintSel);
        (bool attackerCanMint,,) = manager.canCall(attacker, deployed, mintSel);
        assertTrue(callerCanMint, "deploy caller must be able to mint");
        assertFalse(attackerCanMint, "random attacker must not be able to mint");
    }

    // ─────────────────────────────────────────────────────────────────
    //  Bug #2 — `unlockToResourceId` missing `restricted` modifier
    // ─────────────────────────────────────────────────────────────────

    /// @notice Reverts when a random EOA calls `unlockToResourceId`.
    /// @dev Bug #2 reproduction: a random EOA calls `unlockToResourceId`. The call MUST revert
    /// with `RaylsAccessManaged__Unauthorized`. Pre-fix: function has no modifier so it
    /// enters the body and reverts for some other reason (or silently succeeds with
    /// no-op branch); the typed Unauthorized error is NOT raised → test fails. Post-fix:
    /// `restricted` modifier is in place → typed error raised → test passes.
    function test_bug2_unlockToResourceId_revertsWithUnauthorizedForRandomCaller() public {
        // Direct-deploy is enough — bug #2 is a pure access-control bug, not factory-specific.
        // Set authority = 0 so the parent's `_registerAccessControl` short-circuits and the
        // explicit `selfRegisterManagedContract` in the body is the single registration.
        endpoint.setAuthority(address(0));
        CustomTokenExample token = new CustomTokenExample(
            "CustomTok",
            "CTK",
            0,
            address(0),
            address(endpoint),
            raylsNodeEndpoint,
            address(manager)
        );

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker)
        );
        token.unlockToResourceId(bytes32(uint256(0xDEAD)), 0);
    }

    /// @notice Documents that the analogous base `unlock` function is already restricted.
    /// @dev Control sample for bug #2: the analogous `unlock` IS already restricted. This test
    /// passes both pre- and post-fix; it documents the expected access-control shape that
    /// `unlockToResourceId` should match.
    function test_bug2_control_unlockBaseFunction_isAlreadyRestricted() public {
        endpoint.setAuthority(address(0));
        CustomTokenExample token = new CustomTokenExample(
            "CustomTok",
            "CTK",
            0,
            address(0),
            address(endpoint),
            raylsNodeEndpoint,
            address(manager)
        );

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker)
        );
        token.unlock(attacker, 0);
    }
}
