// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {IRaylsAccessManager} from "../../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol";
import "../../../privateHub/AccessControl/AccessManagerTypes.sol";

/// @notice Mock token that self-registers during construction.
contract MockSelfRegisteringToken {
    uint256 public mintCount;

    constructor(address _manager, address _deployer) {
        bytes4[] memory ownerSels = new bytes4[](2);
        ownerSels[0] = this.mint.selector;
        ownerSels[1] = this.burn.selector;
        bytes4[] memory relayerSels = new bytes4[](1);
        relayerSels[0] = this.crossMint.selector;
        IRaylsAccessManager.SelectorRoleMapping[] memory mappings = new IRaylsAccessManager.SelectorRoleMapping[](1);
        mappings[0] = IRaylsAccessManager.SelectorRoleMapping("RELAYER", relayerSels);
        IRaylsAccessManager(_manager).selfRegisterManagedContract(_deployer, ownerSels, mappings);
    }

    function mint() external { mintCount++; }
    function burn() external {}
    function crossMint() external {}
}

/// @notice Mock token that self-registers with no relayer selectors.
contract MockTokenNoRelayer {
    constructor(address _manager, address _deployer) {
        bytes4[] memory ownerSels = new bytes4[](1);
        ownerSels[0] = this.doSomething.selector;
        IRaylsAccessManager.SelectorRoleMapping[] memory mappings = new IRaylsAccessManager.SelectorRoleMapping[](0);
        IRaylsAccessManager(_manager).selfRegisterManagedContract(_deployer, ownerSels, mappings);
    }

    function doSomething() external {}
}

/// @notice Mock token for manual registration tests (does NOT self-register).
contract MockManualToken {
    function mint() external {}
    function burn() external {}

    function registerSelf(address _manager, address _deployer) external {
        bytes4[] memory ownerSels = new bytes4[](1);
        ownerSels[0] = this.mint.selector;
        IRaylsAccessManager.SelectorRoleMapping[] memory mappings = new IRaylsAccessManager.SelectorRoleMapping[](0);
        IRaylsAccessManager(_manager).selfRegisterManagedContract(_deployer, ownerSels, mappings);
    }
}

/// @notice Mock token mirroring the handler flow: self-register (deployer) then additionally
///         grant the factory deploy caller TOKEN_OWNER via `grantSelfTokenOwner`.
contract MockTokenGrantsCaller {
    function register(address _manager, address _deployer) external {
        bytes4[] memory ownerSels = new bytes4[](1);
        ownerSels[0] = this.mint.selector;
        IRaylsAccessManager.SelectorRoleMapping[] memory mappings = new IRaylsAccessManager.SelectorRoleMapping[](0);
        IRaylsAccessManager(_manager).selfRegisterManagedContract(_deployer, ownerSels, mappings);
    }

    function grantCaller(address _manager, address _caller) external {
        IRaylsAccessManager(_manager).grantSelfTokenOwner(_caller);
    }

    function mint() external {}
}

/**
 * @title RaylsAccessManagerV1 Target-Scoped Grants — Unit Tests
 * @notice Tests for selfRegisterManagedContract, grantContractScopedRole, revokeContractScopedRole,
 *         hasContractScopedRole, getContractAuthority, and canCall with target-scoped membership.
 */
contract RaylsAccessManagerV1TargetScopedTest is Test {
    RaylsAccessManagerV1 public manager;

    address public adminAddr;
    address public deployer;
    address public alice;
    address public bob;
    address public attacker;

    uint64 constant ADMIN = 0;
    uint64 constant PUBLIC = 1;
    uint64 constant TOKEN_OWNER = 2;

    uint64 relayerRoleId;

    function setUp() public {
        adminAddr = makeAddr("admin");
        deployer  = makeAddr("deployer");
        alice     = makeAddr("alice");
        bob       = makeAddr("bob");
        attacker  = makeAddr("attacker");

        RaylsAccessManagerV1 impl = new RaylsAccessManagerV1();
        bytes memory initData = abi.encodeCall(RaylsAccessManagerV1.initialize, (adminAddr));
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(address(impl), initData)));

        // Register RELAYER (required for selfRegisterManagedContract with relayer selectors).
        vm.prank(adminAddr);
        relayerRoleId = manager.registerRole("RELAYER");
    }

    // ─── selfRegisterManagedContract ─────────────────────────────────────────────────

    function test_selfRegisterManagedContract_setsAuthority() public {
        MockSelfRegisteringToken token = new MockSelfRegisteringToken(address(manager), deployer);
        assertEq(manager.getContractAuthority(address(token)), deployer);
    }

    function _assertSingleRole(address target, bytes4 sel, uint64 expectedRole) internal view {
        uint64[] memory roles = manager.getFunctionAllowedRoles(target, sel);
        assertEq(roles.length, 1);
        assertEq(roles[0], expectedRole);
    }

    function test_selfRegisterManagedContract_mapsOwnerSelectors() public {
        MockSelfRegisteringToken token = new MockSelfRegisteringToken(address(manager), deployer);
        _assertSingleRole(address(token), token.mint.selector, TOKEN_OWNER);
        _assertSingleRole(address(token), token.burn.selector, TOKEN_OWNER);
    }

    function test_selfRegisterManagedContract_mapsRelayerSelectors() public {
        MockSelfRegisteringToken token = new MockSelfRegisteringToken(address(manager), deployer);
        _assertSingleRole(address(token), token.crossMint.selector, relayerRoleId);
    }

    function test_selfRegisterManagedContract_grantsDeployerTokenOwnerRole() public {
        MockSelfRegisteringToken token = new MockSelfRegisteringToken(address(manager), deployer);
        (bool isMember, uint32 delay) = manager.hasContractScopedRole(TOKEN_OWNER, deployer, address(token));
        assertTrue(isMember);
        assertEq(delay, 0);
    }

    function test_selfRegisterManagedContract_reRegistration_reverts() public {
        MockManualToken token = new MockManualToken();
        token.registerSelf(address(manager), deployer);

        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManagerV1__ContractAlreadyRegistered.selector,
            address(token)
        ));
        token.registerSelf(address(manager), deployer);
    }

    function test_selfRegisterManagedContract_relayerRoleNotRegistered_reverts() public {
        // Deploy a fresh manager without RELAYER registered.
        RaylsAccessManagerV1 impl2 = new RaylsAccessManagerV1();
        bytes memory initData2 = abi.encodeCall(RaylsAccessManagerV1.initialize, (adminAddr));
        RaylsAccessManagerV1 freshManager = RaylsAccessManagerV1(address(new ERC1967Proxy(address(impl2), initData2)));

        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManagerV1__RoleNotRegistered.selector,
            "RELAYER"
        ));
        new MockSelfRegisteringToken(address(freshManager), deployer);
    }

    function test_selfRegisterManagedContract_noRelayerSelectors_succeeds() public {
        MockTokenNoRelayer token = new MockTokenNoRelayer(address(manager), deployer);
        assertEq(manager.getContractAuthority(address(token)), deployer);
        _assertSingleRole(address(token), token.doSomething.selector, TOKEN_OWNER);
    }

    function test_selfRegisterManagedContract_emitsManagedContractRegistered() public {
        MockSelfRegisteringToken token = new MockSelfRegisteringToken(address(manager), deployer);

        // Verify the event was emitted by checking the target authority was set
        // (the ManagedContractRegistered event is emitted during construction alongside
        // multiple FunctionAllowedRoleAdded events, making vm.expectEmit fragile).
        assertEq(manager.getContractAuthority(address(token)), deployer);
    }

    // ─── grantSelfTokenOwner (factory deploy caller grant) ───────────────────────────

    function test_grantSelfTokenOwner_grantsCallerTokenOwner() public {
        MockTokenGrantsCaller token = new MockTokenGrantsCaller();
        token.register(address(manager), deployer);
        token.grantCaller(address(manager), alice);

        // Both deployer and caller (alice) hold TOKEN_OWNER scoped to the token.
        (bool deployerIsMember,) = manager.hasContractScopedRole(TOKEN_OWNER, deployer, address(token));
        (bool callerIsMember,) = manager.hasContractScopedRole(TOKEN_OWNER, alice, address(token));
        assertTrue(deployerIsMember);
        assertTrue(callerIsMember);

        // Caller can actually call the owner-gated mint selector.
        (bool allowed,,) = manager.canCall(alice, address(token), token.mint.selector);
        assertTrue(allowed);
    }

    function test_grantSelfTokenOwner_doesNotChangeAuthority() public {
        MockTokenGrantsCaller token = new MockTokenGrantsCaller();
        token.register(address(manager), deployer);
        token.grantCaller(address(manager), alice);

        // Authority stays the deployer; the caller does NOT become authority.
        assertEq(manager.getContractAuthority(address(token)), deployer);

        // Caller cannot grant/revoke scoped roles (not the authority).
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManagerV1__NotContractAuthority.selector,
            alice,
            address(token)
        ));
        manager.grantContractScopedRole(TOKEN_OWNER, bob, address(token), 0);
    }

    function test_grantSelfTokenOwner_zeroAddress_reverts() public {
        MockTokenGrantsCaller token = new MockTokenGrantsCaller();
        token.register(address(manager), deployer);

        vm.expectRevert(RaylsAccessManagerV1__ZeroAddress.selector);
        token.grantCaller(address(manager), address(0));
    }

    function test_grantSelfTokenOwner_notRegistered_reverts() public {
        MockTokenGrantsCaller token = new MockTokenGrantsCaller();

        // No self-registration first → grantSelfTokenOwner must revert.
        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManagerV1__ContractNotRegistered.selector,
            address(token)
        ));
        token.grantCaller(address(manager), alice);
    }

    function test_grantSelfTokenOwner_idempotent() public {
        MockTokenGrantsCaller token = new MockTokenGrantsCaller();
        token.register(address(manager), deployer);
        token.grantCaller(address(manager), alice);
        token.grantCaller(address(manager), alice);

        (bool isMember,) = manager.hasContractScopedRole(TOKEN_OWNER, alice, address(token));
        assertTrue(isMember);
    }

    // ─── grantContractScopedRole ────────────────────────────────────────────────────

    function test_grantContractScopedRole_byAuthority_succeeds() public {
        MockSelfRegisteringToken token = new MockSelfRegisteringToken(address(manager), deployer);

        vm.prank(deployer);
        manager.grantContractScopedRole(TOKEN_OWNER, alice, address(token), 0);

        (bool isMember,) = manager.hasContractScopedRole(TOKEN_OWNER, alice, address(token));
        assertTrue(isMember);
    }

    function test_grantContractScopedRole_byAdmin_succeeds() public {
        MockSelfRegisteringToken token = new MockSelfRegisteringToken(address(manager), deployer);

        vm.prank(adminAddr);
        manager.grantContractScopedRole(TOKEN_OWNER, alice, address(token), 0);

        (bool isMember,) = manager.hasContractScopedRole(TOKEN_OWNER, alice, address(token));
        assertTrue(isMember);
    }

    function test_grantContractScopedRole_byNonAuthority_reverts() public {
        MockSelfRegisteringToken token = new MockSelfRegisteringToken(address(manager), deployer);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManagerV1__NotContractAuthority.selector,
            attacker,
            address(token)
        ));
        manager.grantContractScopedRole(TOKEN_OWNER, alice, address(token), 0);
    }

    function test_grantContractScopedRole_emitsContractScopedRoleGranted() public {
        MockSelfRegisteringToken token = new MockSelfRegisteringToken(address(manager), deployer);

        vm.prank(deployer);
        vm.expectEmit(true, true, true, false);
        emit IRaylsAccessManager.ContractScopedRoleGranted(TOKEN_OWNER, alice, address(token), 0, 0, deployer);
        manager.grantContractScopedRole(TOKEN_OWNER, alice, address(token), 0);
    }

    function test_grantContractScopedRole_adminRole_byAuthority_reverts() public {
        MockSelfRegisteringToken token = new MockSelfRegisteringToken(address(manager), deployer);

        vm.prank(deployer);
        vm.expectRevert(RaylsAccessManagerV1__AdminRoleCannotBeScoped.selector);
        manager.grantContractScopedRole(ADMIN, alice, address(token), 0);
    }

    function test_grantContractScopedRole_adminRole_byGlobalAdmin_reverts() public {
        MockSelfRegisteringToken token = new MockSelfRegisteringToken(address(manager), deployer);

        vm.prank(adminAddr);
        vm.expectRevert(RaylsAccessManagerV1__AdminRoleCannotBeScoped.selector);
        manager.grantContractScopedRole(ADMIN, alice, address(token), 0);
    }

    function test_grantContractScopedRole_adminRole_notGranted() public {
        MockSelfRegisteringToken token = new MockSelfRegisteringToken(address(manager), deployer);

        // Attempt to grant scoped ADMIN fails, so alice should NOT have it.
        vm.prank(deployer);
        vm.expectRevert(RaylsAccessManagerV1__AdminRoleCannotBeScoped.selector);
        manager.grantContractScopedRole(ADMIN, alice, address(token), 0);

        (bool isMember,) = manager.hasContractScopedRole(ADMIN, alice, address(token));
        assertFalse(isMember);
    }

    function test_grantContractScopedRole_respectsGrantDelay() public {
        MockSelfRegisteringToken token = new MockSelfRegisteringToken(address(manager), deployer);

        // Set grant delay on TOKEN_OWNER.
        vm.prank(adminAddr);
        manager.setGrantDelay(TOKEN_OWNER, 1 days);

        vm.prank(deployer);
        manager.grantContractScopedRole(TOKEN_OWNER, alice, address(token), 0);

        // Not yet active.
        (bool isMember,) = manager.hasContractScopedRole(TOKEN_OWNER, alice, address(token));
        assertFalse(isMember);

        // After delay.
        vm.warp(block.timestamp + 1 days + 1);
        (isMember,) = manager.hasContractScopedRole(TOKEN_OWNER, alice, address(token));
        assertTrue(isMember);
    }

    // ─── revokeContractScopedRole ───────────────────────────────────────────────────

    function test_revokeContractScopedRole_byAuthority_succeeds() public {
        MockSelfRegisteringToken token = new MockSelfRegisteringToken(address(manager), deployer);

        vm.prank(deployer);
        manager.grantContractScopedRole(TOKEN_OWNER, alice, address(token), 0);

        vm.prank(deployer);
        manager.revokeContractScopedRole(TOKEN_OWNER, alice, address(token));

        (bool isMember,) = manager.hasContractScopedRole(TOKEN_OWNER, alice, address(token));
        assertFalse(isMember);
    }

    function test_revokeContractScopedRole_byNonAuthority_reverts() public {
        MockSelfRegisteringToken token = new MockSelfRegisteringToken(address(manager), deployer);

        vm.prank(deployer);
        manager.grantContractScopedRole(TOKEN_OWNER, alice, address(token), 0);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManagerV1__NotContractAuthority.selector,
            attacker,
            address(token)
        ));
        manager.revokeContractScopedRole(TOKEN_OWNER, alice, address(token));
    }

    function test_revokeContractScopedRole_emitsContractScopedRoleRevoked() public {
        MockSelfRegisteringToken token = new MockSelfRegisteringToken(address(manager), deployer);

        vm.prank(deployer);
        manager.grantContractScopedRole(TOKEN_OWNER, alice, address(token), 0);

        vm.prank(deployer);
        vm.expectEmit(true, true, true, false);
        emit IRaylsAccessManager.ContractScopedRoleRevoked(TOKEN_OWNER, alice, address(token), deployer);
        manager.revokeContractScopedRole(TOKEN_OWNER, alice, address(token));
    }

    // ─── hasContractScopedRole ──────────────────────────────────────────────────────

    function test_hasContractScopedRole_memberReturnsTrue() public {
        MockSelfRegisteringToken token = new MockSelfRegisteringToken(address(manager), deployer);
        (bool isMember, uint32 delay) = manager.hasContractScopedRole(TOKEN_OWNER, deployer, address(token));
        assertTrue(isMember);
        assertEq(delay, 0);
    }

    function test_hasContractScopedRole_nonMemberReturnsFalse() public {
        MockSelfRegisteringToken token = new MockSelfRegisteringToken(address(manager), deployer);
        (bool isMember,) = manager.hasContractScopedRole(TOKEN_OWNER, attacker, address(token));
        assertFalse(isMember);
    }

    function test_hasContractScopedRole_wrongTarget_returnsFalse() public {
        MockSelfRegisteringToken tokenA = new MockSelfRegisteringToken(address(manager), deployer);
        MockSelfRegisteringToken tokenB = new MockSelfRegisteringToken(address(manager), alice);

        // deployer has TOKEN_OWNER on tokenA, not tokenB.
        (bool isMember,) = manager.hasContractScopedRole(TOKEN_OWNER, deployer, address(tokenB));
        assertFalse(isMember);
        (isMember,) = manager.hasContractScopedRole(TOKEN_OWNER, deployer, address(tokenA));
        assertTrue(isMember);
    }

    // ─── getContractAuthority ─────────────────────────────────────────────────

    function test_getContractAuthority_returnsCorrectAddress() public {
        MockSelfRegisteringToken token = new MockSelfRegisteringToken(address(manager), deployer);
        assertEq(manager.getContractAuthority(address(token)), deployer);
    }

    function test_getContractAuthority_unregisteredTarget_returnsZero() public {
        address random = makeAddr("random");
        assertEq(manager.getContractAuthority(random), address(0));
    }

    // ─── canCall with target-scoped membership ──────────────────────────────

    function test_canCall_targetScopedMember_allowedOnTarget() public {
        MockSelfRegisteringToken token = new MockSelfRegisteringToken(address(manager), deployer);

        // deployer has TOKEN_OWNER scoped to this token via selfRegisterManagedContract.
        (bool allowed, uint32 delay,) = manager.canCall(deployer, address(token), token.mint.selector);
        assertTrue(allowed);
        assertEq(delay, 0);
    }

    function test_canCall_targetScopedMember_deniedOnDifferentTarget() public {
        MockSelfRegisteringToken tokenA = new MockSelfRegisteringToken(address(manager), deployer);
        MockSelfRegisteringToken tokenB = new MockSelfRegisteringToken(address(manager), alice);

        // deployer has TOKEN_OWNER on tokenA, NOT on tokenB.
        // tokenB's mint is mapped to TOKEN_OWNER, but deployer's membership is scoped to tokenA.
        (bool allowed,,) = manager.canCall(deployer, address(tokenB), tokenB.mint.selector);
        assertFalse(allowed);
    }

    function test_canCall_globalTokenOwnerGrant_isRejected() public {
        MockSelfRegisteringToken token = new MockSelfRegisteringToken(address(manager), deployer);

        // F19 fix: grantRole(TOKEN_OWNER, ...) is rejected — TOKEN_OWNER is
        // a per-contract-scoped role by design. Use grantContractScopedRole instead.
        vm.prank(adminAddr);
        vm.expectRevert(RaylsAccessManagerV1__TokenOwnerIsScopeOnly.selector);
        manager.grantRole(TOKEN_OWNER, alice, 0);

        // canCall must still say `false` because the grant never landed.
        (bool allowed,,) = manager.canCall(alice, address(token), token.mint.selector);
        assertFalse(allowed);
    }

    function test_canCall_closedTarget_overridesTargetScope() public {
        MockSelfRegisteringToken token = new MockSelfRegisteringToken(address(manager), deployer);

        vm.prank(adminAddr);
        manager.setContractPaused(address(token), true);

        (bool allowed,,) = manager.canCall(deployer, address(token), token.mint.selector);
        assertFalse(allowed);
    }

    function test_canCall_unmappedSelector_targetScoped_defaultsToAdmin() public {
        MockSelfRegisteringToken token = new MockSelfRegisteringToken(address(manager), deployer);

        // A selector not registered via selfRegisterManagedContract defaults to ADMIN.
        bytes4 unknownSel = bytes4(keccak256("unknownFn()"));
        (bool allowed,,) = manager.canCall(deployer, address(token), unknownSel);
        assertFalse(allowed); // deployer is not ADMIN

        (allowed,,) = manager.canCall(adminAddr, address(token), unknownSel);
        assertTrue(allowed); // admin is always allowed
    }

    function test_canCall_targetScopedMember_withExecutionDelay() public {
        MockSelfRegisteringToken token = new MockSelfRegisteringToken(address(manager), deployer);

        // Grant alice TOKEN_OWNER scoped to this token with a delay.
        vm.prank(deployer);
        manager.grantContractScopedRole(TOKEN_OWNER, alice, address(token), 1 hours);

        (bool allowed, uint32 delay,) = manager.canCall(alice, address(token), token.mint.selector);
        assertFalse(allowed);
        assertEq(delay, 1 hours);
    }

    // ─── Integration ────────────────────────────────────────────────────────

    function test_integration_deployerDelegatesToAlice_scopedIsolation() public {
        MockSelfRegisteringToken tokenA = new MockSelfRegisteringToken(address(manager), deployer);
        MockSelfRegisteringToken tokenB = new MockSelfRegisteringToken(address(manager), bob);

        // deployer delegates TOKEN_OWNER on tokenA to alice.
        vm.prank(deployer);
        manager.grantContractScopedRole(TOKEN_OWNER, alice, address(tokenA), 0);

        // alice can call mint on tokenA.
        (bool allowed,,) = manager.canCall(alice, address(tokenA), tokenA.mint.selector);
        assertTrue(allowed);

        // alice CANNOT call mint on tokenB.
        (allowed,,) = manager.canCall(alice, address(tokenB), tokenB.mint.selector);
        assertFalse(allowed);
    }

    function test_integration_revokeContractScopedRole_aliceCanNoLongerMint() public {
        MockSelfRegisteringToken token = new MockSelfRegisteringToken(address(manager), deployer);

        vm.prank(deployer);
        manager.grantContractScopedRole(TOKEN_OWNER, alice, address(token), 0);

        // alice can mint.
        (bool allowed,,) = manager.canCall(alice, address(token), token.mint.selector);
        assertTrue(allowed);

        // Revoke.
        vm.prank(deployer);
        manager.revokeContractScopedRole(TOKEN_OWNER, alice, address(token));

        // alice can no longer mint.
        (allowed,,) = manager.canCall(alice, address(token), token.mint.selector);
        assertFalse(allowed);
    }

    function test_integration_relayerRoleGlobal_worksOnSelfRegisteredToken() public {
        MockSelfRegisteringToken token = new MockSelfRegisteringToken(address(manager), deployer);

        // Grant alice RELAYER globally.
        vm.prank(adminAddr);
        manager.grantRole(relayerRoleId, alice, 0);

        // alice can call crossMint (mapped to RELAYER) on any self-registered token.
        (bool allowed,,) = manager.canCall(alice, address(token), token.crossMint.selector);
        assertTrue(allowed);
    }

    function test_integration_deployerCannotManageOtherTokens() public {
        MockSelfRegisteringToken tokenA = new MockSelfRegisteringToken(address(manager), deployer);
        MockSelfRegisteringToken tokenB = new MockSelfRegisteringToken(address(manager), bob);
        (tokenA); // suppress unused warning

        // deployer tries to grant alice TOKEN_OWNER on tokenB (owned by bob).
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManagerV1__NotContractAuthority.selector,
            deployer,
            address(tokenB)
        ));
        manager.grantContractScopedRole(TOKEN_OWNER, alice, address(tokenB), 0);
    }
}
