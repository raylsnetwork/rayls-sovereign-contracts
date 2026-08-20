// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RNContractFactoryV1} from "../../../rayls-node/rayls-privacy-node/RNContractFactoryV1.sol";
import {IRNContractFactoryV1} from "../../../rayls-node/rayls-privacy-node/interfaces/IRNContractFactoryV1.sol";
import {RaylsTrustedInit} from "../../../rayls-protocol-sdk/IRaylsInitializer.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {IRaylsInitializer, RaylsTrustedInit} from "../../../rayls-protocol-sdk/IRaylsInitializer.sol";
import {IBaseContractFactory} from "../../../rayls-protocol/RaylsContractFactory/interfaces/IBaseContractFactory.sol";
import {InitSpy, MockNodeEndpoint, FactoryStubLib} from "./factory/FactoryTestUtils.sol";

/// @notice Behavior contract for `RNContractFactoryV1.deploy()`.
///         Each test names a scenario; the assertion message is the contract.
contract RNContractFactoryV1Test is Test {
    RNContractFactoryV1 internal factory;
    RaylsAccessManagerV1 internal manager;
    MockNodeEndpoint internal endpoint;

    address internal admin = address(this);
    address internal factoryOwner = makeAddr("factoryOwner");
    address internal userGov = makeAddr("userGovernance");
    address internal randomUser = makeAddr("randomUser");

    uint64 internal factoryDeployerRoleId;

    function setUp() public {
        // Stand up the on-chain plumbing the factory expects:
        //   - AccessManager (Auth V3 authority).
        //   - Endpoint stub that returns a fixed user-governance address.
        //   - Factory deployed behind ERC1967 (matches production).
        //   - FACTORY_DEPLOYER role wired to deploy() and granted to this test contract.
        RaylsAccessManagerV1 mgrImpl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(
            address(mgrImpl),
            abi.encodeCall(mgrImpl.initialize, (admin))
        )));

        endpoint = new MockNodeEndpoint(userGov);

        RNContractFactoryV1 facImpl = new RNContractFactoryV1();
        factory = RNContractFactoryV1(address(new ERC1967Proxy(
            address(facImpl),
            abi.encodeCall(facImpl.initialize, (address(endpoint), address(endpoint), factoryOwner, address(manager)))
        )));

        factoryDeployerRoleId = manager.registerRole("FACTORY_DEPLOYER");
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = factory.deploy.selector;
        uint64[] memory roles = new uint64[](1);
        roles[0] = factoryDeployerRoleId;
        manager.addFunctionAllowedRoles(address(factory), sels, roles);
        manager.grantRole(factoryDeployerRoleId, address(this), 0);
    }

    // ─────────────────────────────────────────────────────────────────
    //  Access control
    // ─────────────────────────────────────────────────────────────────

    /// Scenario: a random user tries to call deploy() directly. Auth V3 must reject.
    function test_when_callerHasNoFactoryDeployerRole_then_deployReverts() public {
        vm.prank(randomUser);
        vm.expectRevert(
            abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, randomUser)
        );
        factory.deploy(type(InitSpy).runtimeCode, "", bytes32(0));
    }

    // ─────────────────────────────────────────────────────────────────
    //  Bytecode integrity - runtime stored on chain must match the
    //  bytes the operator supplied
    // ─────────────────────────────────────────────────────────────────

    /// Scenario: an operator deploys a 60-byte template (e.g. an early prototype of a
    /// proxy stub). The factory must store the runtime byte-for-byte; if it shifts or
    /// pads, the deployed contract is broken.
    function test_when_runtimeIsSixtyBytes_then_factoryStoresItExactly() public {
        bytes memory runtime = FactoryStubLib.buildSentinelRuntime(60);
        address deployed = factory.deploy(runtime, "", bytes32(uint256(0xCAFE)));
        assertEq(deployed.code, runtime,
            "on-chain runtime differs from bytes supplied to deploy()");
    }

    /// Scenario: the same as above at the boundary - 255 bytes is the largest single-byte
    /// length the factory's stub supports. Anything larger takes a different code path,
    /// so 255 is the canonical edge case for the small-bytecode path.
    function test_when_runtimeIsAtSmallPathBoundary_then_factoryStoresItExactly() public {
        bytes memory runtime = FactoryStubLib.buildSentinelRuntime(255);
        address deployed = factory.deploy(runtime, "", bytes32(uint256(0xCAFE)));
        assertEq(deployed.code, runtime,
            "on-chain runtime differs from bytes supplied to deploy() at the small-path boundary");
    }

    /// Scenario: at 256 bytes the factory takes its large-bytecode code path. This is a
    /// regression fence - if a future change breaks the large path, this test catches it
    /// even if the small-path tests above still pass.
    function test_when_runtimeIsAtLargePathBoundary_then_factoryStoresItExactly() public {
        bytes memory runtime = FactoryStubLib.buildSentinelRuntime(256);
        address deployed = factory.deploy(runtime, "", bytes32(uint256(0xCAFE)));
        assertEq(deployed.code, runtime,
            "on-chain runtime differs from bytes supplied to deploy() at the large-path boundary");
    }

    // ─────────────────────────────────────────────────────────────────
    //  Empty bytecode - factory must reject early, never produce a
    //  ghost address with no code
    // ─────────────────────────────────────────────────────────────────

    /// Scenario: an integration accidentally calls deploy() with an empty bytes argument.
    /// The factory must refuse rather than produce a 0-code address that subsequent
    /// flows might mistake for a valid contract.
    function test_when_bytecodeIsEmpty_then_deployReverts() public {
        vm.expectRevert(IBaseContractFactory.FactoryV1__EmptyBytecode.selector);
        factory.deploy("", "", bytes32(uint256(0xDEAD)));
    }

    // ─────────────────────────────────────────────────────────────────
    //  Init-call dispatch shape (typed dispatch — fix-asserting)
    //
    //  Factory dispatches `IRaylsInitializer.initialize(bytes,RaylsTrustedInit)` via
    //  `abi.encodeCall`. The deployed contract receives the FIXED selector regardless
    //  of `initializerParams` content; trusted addresses arrive as a typed struct, not
    //  as a fixed-offset calldata tail. Selector-binding migration.
    // ─────────────────────────────────────────────────────────────────

    /// Scenario: caller writes arbitrary bytes in `initializerParams`. Factory must
    /// still dispatch the canonical `IRaylsInitializer.initialize` selector — caller
    /// cannot influence which function the deployed contract sees.
    function test_when_callerSuppliesArbitraryInitParams_then_dispatchedSelectorIsCanonical() public {
        bytes memory probe = type(InitSpy).runtimeCode;
        // User args ABI-encoded as if for an ERC20 handler: (string,string,uint8).
        // Real handlers decode this; InitSpy ignores it, but the SELECTOR is what we test.
        bytes memory params = abi.encode(string("Spy"), string("SPY"), uint8(18));

        address deployed = factory.deploy(probe, params, bytes32(uint256(0xBEEF)));

        bytes4 observed = InitSpy(payable(deployed)).lastSelector();
        assertEq(observed, IRaylsInitializer.initialize.selector,
            "factory must dispatch the canonical IRaylsInitializer.initialize selector regardless of caller bytes");
    }

    /// Scenario: empty `initializerParams`. With typed dispatch the selector still
    /// matches `IRaylsInitializer.initialize` — there is no longer a "trusted-tail
    /// first 4 bytes" observable.
    function test_when_initParamsIsEmpty_then_dispatchedSelectorIsStillCanonical() public {
        bytes memory probe = type(InitSpy).runtimeCode;
        address deployed = factory.deploy(probe, "", bytes32(uint256(0xC0DE)));
        bytes4 observed = InitSpy(payable(deployed)).lastSelector();
        assertEq(observed, IRaylsInitializer.initialize.selector,
            "typed dispatch must produce the canonical selector even when user args are empty");
    }

    // ─────────────────────────────────────────────────────────────────
    //  Reentrancy - deploy() must not be re-enterable from a contract
    //  that received the role and is invoked during init
    // ─────────────────────────────────────────────────────────────────

    /// Scenario: a third-party integration contract holds FACTORY_DEPLOYER and is
    /// (by accident or intent) re-invoked during the factory's post-deploy init-call.
    /// The factory must lock its deploy() entry so reentry cannot succeed end-to-end.
    function test_when_deployedContractReentersDeploy_then_innerCallReverts() public {
        OuterReentryProbe probe = new OuterReentryProbe();
        bytes memory probeRuntime = bytes.concat(
            type(OuterReentryProbe).runtimeCode,
            new bytes(300)  // pad past 255 B to exercise the PUSH2 init-code path
        );

        // Predict where the factory will deploy the probe runtime.
        address predicted = FactoryStubLib.predictCreate2(address(factory), probeRuntime, _saltCounter() + 1);

        // Pre-grant FACTORY_DEPLOYER to the predicted address so the inner re-entry call
        // would be authorized at the AccessManager layer. This isolates the test to the
        // contract-level reentrancy guard rather than the access-control gate.
        manager.grantRole(factoryDeployerRoleId, predicted, 0);

        // Pre-seed the probe's storage slot 0 with the factory address so its fallback
        // knows where to call back. CREATE2 only writes runtime code, not storage -
        // pre-seeded slots survive the deploy.
        vm.store(predicted, bytes32(uint256(0)), bytes32(uint256(uint160(address(factory)))));

        // Trigger the outer deploy. The probe runtime's fallback will attempt to re-enter
        // factory.deploy. We don't care if the outer call reverts (the probe may bubble);
        // we only care whether the inner deploy succeeded (slot 2 set).
        try factory.deploy(probeRuntime, "", bytes32(uint256(0xBEEF))) returns (address) {} catch {}

        bool innerSucceeded = vm.load(predicted, bytes32(uint256(2))) != bytes32(0);
        assertFalse(innerSucceeded,
            "inner factory.deploy() succeeded inside outer init-call - deploy() is reentrant");
        // Silence unused
        probe;
    }

    // ─────────────────────────────────────────────────────────────────
    //  Parity with RaylsContractFactoryV1 - RN factory must NOT auto-grant any role
    // ─────────────────────────────────────────────────────────────────

    /// Scenario: RaylsContractFactoryV1 auto-grants ENDPOINT_SENDER to deployed contracts.
    /// RNContractFactoryV1 deliberately does NOT - its purpose is general-purpose
    /// deployment, not RaylsApp activation. This test guards against a copy-paste
    /// regression that introduces the auto-grant pattern here.
    function test_when_factoryDeploysContract_then_noEndpointSenderRoleIsGranted() public {
        uint64 endpointSenderRoleId = manager.registerRole("ENDPOINT_SENDER");

        bytes memory runtime = type(InitSpy).runtimeCode;
        address deployed = factory.deploy(runtime, hex"abcdef01", bytes32(uint256(0xC0DE)));

        (bool hasEpSender, ) = manager.hasRole(endpointSenderRoleId, deployed);
        (bool hasFactoryDeployer, ) = manager.hasRole(factoryDeployerRoleId, deployed);

        assertFalse(hasEpSender,
            "RN factory must NOT auto-grant ENDPOINT_SENDER - copy-paste regression from RaylsContractFactoryV1");
        assertFalse(hasFactoryDeployer,
            "RN factory must NOT auto-grant FACTORY_DEPLOYER to deployed contracts");
    }

    // ─────────────────────────────────────────────────────────────────
    //  CREATE2 address determinism (documented design choice)
    // ─────────────────────────────────────────────────────────────────

    /// Scenario: an off-chain indexer pre-computes the address where the next deploy
    /// will land (so it can subscribe to events at that address before the deploy tx
    /// confirms). The factory's CREATE2 formula must match this prediction exactly.
    function test_when_predictingCreate2AddressInAdvance_then_matchesActualDeployment() public {
        bytes memory runtime = type(InitSpy).runtimeCode;
        address predicted = FactoryStubLib.predictCreate2(address(factory), runtime, _saltCounter() + 1);
        address deployed = factory.deploy(runtime, "", bytes32(uint256(0xC0DE)));
        assertEq(deployed, predicted,
            "off-chain CREATE2 prediction drifted from on-chain deploy - indexers will mis-target");
    }

    // ─────────────────────────────────────────────────────────────────
    //  raylsNodeEndpoint wiring (PR #268): initialize guard, admin setter,
    //  access control, event, and trusted-init stamping (regression fence)
    // ─────────────────────────────────────────────────────────────────

    /// Scenario: setUp initialized the factory with a non-zero raylsNodeEndpoint. Both the
    /// auto-getter and the explicit interface getter must report it, which locks the initialize
    /// stamping so a regression that drops the assignment is caught.
    function test_when_initialized_then_raylsNodeEndpointIsPersisted() public view {
        assertEq(factory.getRaylsNodeEndpoint(), address(endpoint),
            "getRaylsNodeEndpoint() must return the endpoint stamped at initialize");
        assertEq(factory.raylsNodeEndpoint(), address(endpoint),
            "public auto-getter must agree with getRaylsNodeEndpoint()");
    }

    /// Scenario: a deploy passes address(0) for _raylsNodeEndpoint. initialize() must reject it
    /// Every PN-factory deploy needs a live RNEndpointV1 or teleportToPublicChain empty-reverts.
    function test_when_initializedWithZeroRaylsNodeEndpoint_then_reverts() public {
        RNContractFactoryV1 facImpl = new RNContractFactoryV1();
        vm.expectRevert(IBaseContractFactory.FactoryV1__ZeroAddress.selector);
        new ERC1967Proxy(
            address(facImpl),
            abi.encodeCall(facImpl.initialize, (address(endpoint), address(0), factoryOwner, address(manager)))
        );
    }

    /// Scenario: the AccessManager admin (the deploy task's signer in production) updates the
    /// factory's raylsNodeEndpoint. The getter must reflect it and RaylsNodeEndpointUpdated must
    /// fire with the correct (old, new) ordering. The event captures the value BEFORE the write.
    function test_when_adminSetsRaylsNodeEndpoint_then_getterUpdatesAndEventEmitted() public {
        address newNodeEndpoint = makeAddr("newNodeEndpoint");

        // 5-arg form pins the assertion to the factory; checkData is false because
        // RaylsNodeEndpointUpdated has both params indexed (no ABI data payload).
        vm.expectEmit(true, true, false, false, address(factory));
        emit IRNContractFactoryV1.RaylsNodeEndpointUpdated(address(endpoint), newNodeEndpoint);
        factory.setRaylsNodeEndpoint(newNodeEndpoint);

        assertEq(factory.getRaylsNodeEndpoint(), newNodeEndpoint,
            "setRaylsNodeEndpoint must persist the new endpoint");
    }

    /// Scenario: an operator fat-fingers address(0) into setRaylsNodeEndpoint. The setter must
    /// reject it so the factory can never be configured to stamp a dead endpoint into handlers.
    function test_when_setRaylsNodeEndpointToZero_then_reverts() public {
        vm.expectRevert(IBaseContractFactory.FactoryV1__ZeroAddress.selector);
        factory.setRaylsNodeEndpoint(address(0));
    }


    /// Scenario: the factory deploys a handler. The trusted-init struct dispatched to that handler
    /// MUST carry the configured (non-zero) raylsNodeEndpoint. This is the entire point of the raylsNodeEndpoint wiring.
    /// REGRESSION FENCE: if `_buildTrustedInit` ever reverts to `raylsNodeEndpoint: address(0)`
    /// (the exact bug this PR fixed), the non-zero assertion below fails.
    function test_when_factoryDeploysHandler_then_trustedInitCarriesRaylsNodeEndpoint() public {
        address deployed = factory.deploy(type(InitSpy).runtimeCode, "", bytes32(uint256(0xF00D)));
        RaylsTrustedInit memory trusted = _decodeTrustedInit(deployed);

        assertTrue(trusted.raylsNodeEndpoint != address(0),
            "factory stamped address(0) into trusted-init - teleportToPublicChain regression");
        assertEq(trusted.raylsNodeEndpoint, factory.getRaylsNodeEndpoint(),
            "trusted-init raylsNodeEndpoint must equal the factory's configured endpoint");
        assertEq(trusted.raylsNodeEndpoint, address(endpoint),
            "trusted-init raylsNodeEndpoint must be the endpoint set at initialize");
        assertEq(trusted.resourceId, bytes32(uint256(0xF00D)),
            "trusted-init must pass through the resourceId supplied to deploy()");
    }

    /// Scenario: after the admin re-points raylsNodeEndpoint, the NEXT deploy must stamp the NEW
    /// value, proving the setter actually feeds `_buildTrustedInit`, not just its own getter.
    function test_when_raylsNodeEndpointReconfigured_then_subsequentDeploysCarryNewValue() public {
        address newNodeEndpoint = makeAddr("newNodeEndpoint");
        factory.setRaylsNodeEndpoint(newNodeEndpoint);

        address deployed = factory.deploy(type(InitSpy).runtimeCode, "", bytes32(uint256(0xBEE5)));
        RaylsTrustedInit memory trusted = _decodeTrustedInit(deployed);

        assertEq(trusted.raylsNodeEndpoint, newNodeEndpoint,
            "deploys after setRaylsNodeEndpoint must stamp the reconfigured endpoint");
    }

    // ─────────────────────────────────────────────────────────────────
    //  Trusted-init raylsNodeEndpoint wiring — replicated handlers must
    //  be able to bridge to public chains (teleportToPublicChain)
    // ─────────────────────────────────────────────────────────────────

    /// Scenario: the deploy wires the RN endpoint via setRaylsNodeEndpoint (ADMIN-only).
    /// Every subsequently deployed handler must receive it in trusted-init — a zero value
    /// leaves the handler "unbound" and teleportToPublicChain reverts calling address(0).
    function test_when_raylsNodeEndpointIsWired_then_trustedInitCarriesIt() public {
        address rnEndpoint = makeAddr("rnEndpoint");
        factory.setRaylsNodeEndpoint(rnEndpoint);

        address deployed = factory.deploy(type(InitSpy).runtimeCode, "", bytes32(uint256(0xAA)));
        RaylsTrustedInit memory trusted = _decodeTrusted(InitSpy(payable(deployed)).lastCalldata());
        assertEq(trusted.raylsNodeEndpoint, rnEndpoint,
            "factory must stamp the wired RN endpoint into trusted-init - unbound handlers cannot teleportToPublicChain");
    }

    /// Note: the "unwired factory passes zero" scenario is unreachable since
    /// initialize() rejects a zero _raylsNodeEndpoint (RNContractFactoryV1.sol:54);
    /// that negative path is covered by test_when_initializedWithZeroRaylsNodeEndpoint_then_reverts.

    /// Scenario: wiring to the zero address must be rejected, matching the hub factory.
    function test_when_settingZeroRaylsNodeEndpoint_then_reverts() public {
        vm.expectRevert(IBaseContractFactory.FactoryV1__ZeroAddress.selector);
        factory.setRaylsNodeEndpoint(address(0));
    }

    /// Scenario: setRaylsNodeEndpoint is `restricted` and deliberately unmapped —
    /// ADMIN-only, like the other trusted-init wiring setters.
    function test_when_nonAdminSetsRaylsNodeEndpoint_then_reverts() public {
        vm.prank(randomUser);
        vm.expectRevert(
            abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, randomUser)
        );
        factory.setRaylsNodeEndpoint(makeAddr("rnEndpoint2"));
    }

    // ─────────────────────────────────────────────────────────────────
    //  Internal helpers
    // ─────────────────────────────────────────────────────────────────
    //  Owner override — *AsUser deploy wrappers
    // ─────────────────────────────────────────────────────────────────

    /// Scenario: a user deploys a stablecoin through `deployStableCoinAsUser`. The trusted-init
    /// struct MUST carry the CALLER as `owner`, not the factory's `factoryOwner`.
    ///
    /// This is load-bearing beyond ownership bookkeeping: RaylsStableCoinHandler.initialize seeds
    /// `masterMinter`, `pauser` AND `blacklister` from `trusted.owner`. Without the override every
    /// stablecoin's compliance roles land on one protocol address, and the user who deployed the
    /// token cannot pause it.
    function test_when_stablecoinDeployedAsUser_then_trustedInitOwnerIsCaller() public {
        _seedStablecoinBytecode();

        vm.prank(randomUser);
        address deployed = factory.deployStableCoinAsUser("Rayls USD", "rUSD", 6);
        RaylsTrustedInit memory trusted = _decodeTrustedInit(deployed);

        assertEq(trusted.owner, randomUser,
            "deployStableCoinAsUser must stamp the CALLER as owner - the deployer cannot pause their own token otherwise");
        assertTrue(trusted.owner != factoryOwner,
            "owner must not fall back to factoryOwner when the *AsUser wrapper is used");
        assertEq(trusted.caller, address(0),
            "caller must be zeroed under an owner override so no intermediary is granted TOKEN_OWNER");
    }

    /// Scenario: the non-override path still defaults to `factoryOwner`, so adding the wrapper did
    /// not change governance/relayer-driven deploys.
    function test_when_deployedWithoutOverride_then_trustedInitOwnerIsFactoryOwner() public {
        address deployed = factory.deploy(type(InitSpy).runtimeCode, "", bytes32(uint256(0xD00D)));
        RaylsTrustedInit memory trusted = _decodeTrustedInit(deployed);

        assertEq(trusted.owner, factoryOwner,
            "deploys with no owner override must still default to factoryOwner");
    }

    /// @dev Seeds the stablecoin factory key with the InitSpy runtime so `_deployRegistered`
    ///      has bytecode to deploy. The spy records the dispatched initialize() calldata, which is
    ///      what carries the trusted-init struct under test.
    function _seedStablecoinBytecode() internal {
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = factory.setBytecode.selector;
        uint64[] memory roles = new uint64[](1);
        roles[0] = factoryDeployerRoleId;
        manager.addFunctionAllowedRoles(address(factory), sels, roles);

        factory.setBytecode(factory.RAYLS_STABLECOIN_KEY(), type(InitSpy).runtimeCode);
    }

    /// @dev Decodes the `RaylsTrustedInit` struct the factory dispatched to a freshly deployed
    ///      handler. The factory calls `IRaylsInitializer.initialize(bytes,RaylsTrustedInit)`, so
    ///      the recorded calldata is the 4-byte selector followed by the ABI-encoded `(bytes,
    ///      RaylsTrustedInit)` tuple. Strips the selector, then decodes the typed args.
    function _decodeTrustedInit(address deployed) internal view returns (RaylsTrustedInit memory trusted) {
        bytes memory cd = InitSpy(payable(deployed)).lastCalldata();
        require(cd.length >= 4, "dispatched calldata missing selector");
        bytes memory body = new bytes(cd.length - 4);
        for (uint256 i = 0; i < body.length; i++) {
            body[i] = cd[i + 4];
        }
        (, trusted) = abi.decode(body, (bytes, RaylsTrustedInit));
    }

    /// @dev Decodes the trusted struct from a recorded `initialize(bytes,RaylsTrustedInit)`
    ///      calldata blob captured by {InitSpy}.
    function _decodeTrusted(bytes memory cd) internal view returns (RaylsTrustedInit memory) {
        return this.__sliceAndDecode(cd);
    }

    /// @dev External so the selector can be stripped via a calldata slice.
    function __sliceAndDecode(bytes calldata cd) external pure returns (RaylsTrustedInit memory trusted) {
        (, trusted) = abi.decode(cd[4:], (bytes, RaylsTrustedInit));
    }

    /// @dev Reads `AbstractContractFactoryV1.saltCounter` directly from storage slot 0.
    ///      ASSUMPTION: every parent contract in the inheritance chain (Initializable,
    ///      UUPSUpgradeable, ReentrancyGuardUpgradeable, RaylsAccessManaged) uses ERC-7201
    ///      namespaced storage in OZ 5.x, leaving slot 0 free for the first user-declared
    ///      state variable — and `saltCounter` is the first such variable declared in
    ///      `AbstractContractFactoryV1` (before `endpoint`, `factoryOwner`,
    ///      `_pendingOwnerOverride`, and the child's `raylsNodeEndpoint`). If a maintainer
    ///      ever prepends a non-namespaced state variable or reorders these, this read
    ///      silently returns the wrong value — adjust the slot index accordingly.
    function _saltCounter() internal view returns (uint256) {
        return uint256(vm.load(address(factory), bytes32(uint256(0))));
    }
}

/// @notice Probe deployed via the factory in the reentrancy test. Slot layout:
///   slot 0: factory address (pre-seeded by the test before the outer deploy)
///   slot 1: didReenter flag
///   slot 2: innerCallSucceeded flag
contract OuterReentryProbe {
    fallback() external payable {
        address factoryAddr;
        assembly { factoryAddr := sload(0) }
        if (factoryAddr == address(0)) return;
        bool already;
        assembly { already := sload(1) }
        if (already) return;
        assembly { sstore(1, 1) }

        // Re-enter factory.deploy with a tiny inner payload - we only care whether the
        // call succeeds, not what gets deployed.
        bytes memory innerBytecode = hex"00";
        (bool ok, ) = factoryAddr.call(
            abi.encodeWithSelector(
                bytes4(keccak256("deploy(bytes,bytes,bytes32)")),
                innerBytecode,
                "",
                bytes32(uint256(0xDEAD))
            )
        );
        if (ok) {
            assembly { sstore(2, 1) }
        }
    }
}
