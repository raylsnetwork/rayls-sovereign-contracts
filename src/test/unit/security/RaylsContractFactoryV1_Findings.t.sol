// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RaylsContractFactoryV1} from "../../../rayls-protocol/RaylsContractFactory/RaylsContractFactoryV1.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {IRaylsInitializer} from "../../../rayls-protocol-sdk/IRaylsInitializer.sol";
import {IBaseContractFactory} from "../../../rayls-protocol/RaylsContractFactory/interfaces/IBaseContractFactory.sol";
import {InitSpy, MockProtocolEndpoint, FactoryStubLib} from "./factory/FactoryTestUtils.sol";

/// @notice Behavior contract for `RaylsContractFactoryV1.deploy()`.
///         Same scenarios as the RN factory plus those specific to the protocol-side
///         factory (string-vs-custom-error, ENDPOINT_SENDER auto-grant pattern).
contract RaylsContractFactoryV1Test is Test {
    RaylsContractFactoryV1 internal factory;
    RaylsAccessManagerV1 internal manager;
    MockProtocolEndpoint internal endpoint;

    address internal admin = address(this);
    address internal factoryOwner = makeAddr("factoryOwner");
    address internal raylsNodeEndpoint = makeAddr("raylsNodeEndpoint");
    address internal userGov = makeAddr("userGovernance");
    address internal randomUser = makeAddr("randomUser");

    uint64 internal factoryAdminRoleId;
    uint64 internal factoryDeployerRoleId;
    uint64 internal endpointSenderRoleId;

    function setUp() public {
        // AccessManager + endpoint stub + factory proxy + role tree.
        // The role tree mirrors production: ENDPOINT_SENDER's admin is FACTORY_ADMIN, so
        // a contract holding FACTORY_ADMIN can grant ENDPOINT_SENDER. The factory itself
        // gets FACTORY_ADMIN at production deploy time so it can perform the post-deploy
        // role grant on contracts it deploys.
        RaylsAccessManagerV1 mgrImpl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(
            address(mgrImpl),
            abi.encodeCall(mgrImpl.initialize, (admin))
        )));

        endpoint = new MockProtocolEndpoint(userGov, address(manager));

        RaylsContractFactoryV1 facImpl = new RaylsContractFactoryV1();
        factory = RaylsContractFactoryV1(address(new ERC1967Proxy(
            address(facImpl),
            abi.encodeCall(facImpl.initialize, (address(endpoint), raylsNodeEndpoint, factoryOwner, address(manager)))
        )));

        factoryAdminRoleId    = manager.registerRole("FACTORY_ADMIN");
        factoryDeployerRoleId = manager.registerRole("FACTORY_DEPLOYER");
        endpointSenderRoleId  = manager.registerRole("ENDPOINT_SENDER");

        manager.setRoleAdmin(endpointSenderRoleId, factoryAdminRoleId);

        bytes4[] memory sels = new bytes4[](1);
        sels[0] = factory.deploy.selector;
        uint64[] memory roles = new uint64[](2);
        roles[0] = factoryAdminRoleId;
        roles[1] = factoryDeployerRoleId;
        manager.addFunctionAllowedRoles(address(factory), sels, roles);

        manager.grantRole(factoryAdminRoleId, address(factory), 0);
        manager.grantRole(factoryDeployerRoleId, address(this), 0);
    }

    // ─────────────────────────────────────────────────────────────────
    //  Access control
    // ─────────────────────────────────────────────────────────────────

    /// Scenario: a random user tries to call deploy() directly.
    function test_when_callerHasNoFactoryDeployerRole_then_deployReverts() public {
        vm.prank(randomUser);
        vm.expectRevert(
            abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, randomUser)
        );
        factory.deploy(type(InitSpy).runtimeCode, "", bytes32(0));
    }

    // ─────────────────────────────────────────────────────────────────
    //  Bytecode integrity
    // ─────────────────────────────────────────────────────────────────

    function test_when_runtimeIsSixtyBytes_then_factoryStoresItExactly() public {
        bytes memory runtime = FactoryStubLib.buildSentinelRuntime(60);
        address deployed = factory.deploy(runtime, "", bytes32(uint256(0xCAFE)));
        assertEq(deployed.code, runtime, "on-chain runtime differs from bytes supplied to deploy()");
    }

    function test_when_runtimeIsAtSmallPathBoundary_then_factoryStoresItExactly() public {
        bytes memory runtime = FactoryStubLib.buildSentinelRuntime(255);
        address deployed = factory.deploy(runtime, "", bytes32(uint256(0xCAFE)));
        assertEq(deployed.code, runtime,
            "on-chain runtime differs from bytes supplied to deploy() at the small-path boundary");
    }

    function test_when_runtimeIsAtLargePathBoundary_then_factoryStoresItExactly() public {
        bytes memory runtime = FactoryStubLib.buildSentinelRuntime(256);
        address deployed = factory.deploy(runtime, "", bytes32(uint256(0xCAFE)));
        assertEq(deployed.code, runtime,
            "on-chain runtime differs from bytes supplied to deploy() at the large-path boundary");
    }

    // ─────────────────────────────────────────────────────────────────
    //  Empty bytecode
    // ─────────────────────────────────────────────────────────────────

    function test_when_bytecodeIsEmpty_then_deployReverts() public {
        vm.expectRevert(IBaseContractFactory.FactoryV1__EmptyBytecode.selector);
        factory.deploy("", "", bytes32(uint256(0xDEAD)));
    }

    // ─────────────────────────────────────────────────────────────────
    //  Init-call dispatch shape (typed dispatch — fix-asserting)
    //
    //  Factory dispatches `IRaylsInitializer.initialize(bytes,RaylsTrustedInit)` via
    //  `abi.encodeCall`. Caller cannot influence which selector the deployed contract
    //  sees. Trusted addresses arrive as a typed struct, not via fixed-offset calldata
    //  reads. Selector-binding migration.
    // ─────────────────────────────────────────────────────────────────

    /// Scenario: caller writes arbitrary `initializerParams`. Factory must still
    /// dispatch the canonical `IRaylsInitializer.initialize` selector.
    function test_when_callerSuppliesArbitraryInitParams_then_dispatchedSelectorIsCanonical() public {
        bytes memory probe = type(InitSpy).runtimeCode;
        bytes memory params = abi.encode(string("Spy"), string("SPY"), uint8(18));

        address deployed = factory.deploy(probe, params, bytes32(uint256(0xBEEF)));
        bytes4 observed = InitSpy(payable(deployed)).lastSelector();

        assertEq(observed, IRaylsInitializer.initialize.selector,
            "factory must dispatch the canonical IRaylsInitializer.initialize selector regardless of caller bytes");
    }

    /// Scenario: empty `initializerParams`. Selector still matches.
    function test_when_initParamsIsEmpty_then_dispatchedSelectorIsStillCanonical() public {
        bytes memory probe = type(InitSpy).runtimeCode;
        address deployed = factory.deploy(probe, "", bytes32(uint256(0xC0DE)));
        bytes4 observed = InitSpy(payable(deployed)).lastSelector();
        assertEq(observed, IRaylsInitializer.initialize.selector,
            "typed dispatch must produce the canonical selector even when user args are empty");
    }

    // ─────────────────────────────────────────────────────────────────
    //  Reentrancy
    // ─────────────────────────────────────────────────────────────────

    /// Scenario: a third-party integration contract holds FACTORY_DEPLOYER and re-enters
    /// during the post-deploy init-call. Same shape as the RN factory test.
    function test_when_deployedContractReentersDeploy_then_innerCallReverts() public {
        bytes memory probeRuntime = bytes.concat(
            type(OuterReentryProbe).runtimeCode,
            new bytes(300)
        );
        address predicted = FactoryStubLib.predictCreate2(address(factory), probeRuntime, _saltCounter() + 1);
        manager.grantRole(factoryDeployerRoleId, predicted, 0);
        vm.store(predicted, bytes32(uint256(0)), bytes32(uint256(uint160(address(factory)))));

        try factory.deploy(probeRuntime, "", bytes32(uint256(0xBEEF))) returns (address) {} catch {}

        bool innerSucceeded = vm.load(predicted, bytes32(uint256(2))) != bytes32(0);
        assertFalse(innerSucceeded,
            "inner factory.deploy() succeeded inside outer init-call - deploy() is reentrant");
    }

    // ─────────────────────────────────────────────────────────────────
    //  Init-call failure surface
    // ─────────────────────────────────────────────────────────────────

    /// Scenario: the deployed contract's init-call reverts. The factory must surface a
    /// typed custom error (FactoryV1__InitializationFailed) so callers can
    /// catch it without parsing a string. To force the init-call to fail, we deploy a
    /// 257-byte runtime whose first opcode is INVALID (0xfe) - any call to the deployed
    /// contract reverts immediately, and the factory propagates the failure.
    function test_when_initCallReverts_then_factoryRevertsWithCustomError() public {
        bytes memory bc = new bytes(257);
        bc[0] = 0xfe; // INVALID opcode at runtime[0] - any subsequent call reverts
        vm.expectRevert(IBaseContractFactory.FactoryV1__InitializationFailed.selector);
        factory.deploy(bc, "", bytes32(uint256(0xC0DE)));
    }

    // ─────────────────────────────────────────────────────────────────
    //  ENDPOINT_SENDER auto-grant (current behavior sentinel)
    //
    //  After CREATE2 + init-call, the factory grants ENDPOINT_SENDER to the deployed
    //  contract by calling RaylsAccessManager.grantRole. The factory holds FACTORY_ADMIN
    //  (admin role of ENDPOINT_SENDER) at production deploy time, so the call succeeds.
    //
    //  Every deployable RaylsApp template needs ENDPOINT_SENDER to call endpoint.send,
    //  AND the relayer's cross-chain auto-deploy path produces working tokens only
    //  because of this grant — TokenRegistryReplicaV1.activateToken (the alternative
    //  grant site) only runs on the issuer chain, not on auto-deployed-on-receiver.
    //
    //  Test below pins the auto-grant. Removing it requires migrating every cross-chain
    //  auto-deploy consumer to a separate role-grant step.
    // ─────────────────────────────────────────────────────────────────

    /// Scenario: any deploy via this factory atomically grants ENDPOINT_SENDER to the
    /// deployed contract. Pinning the behavior so the auto-grant cannot be removed
    /// without coordinated changes to consumer flows.
    function test_factoryAutoGrantsEndpointSenderToDeployedContract() public {
        bytes memory runtime = type(InitSpy).runtimeCode;
        address deployed = factory.deploy(runtime, hex"abcdef01", bytes32(uint256(0xC0DE)));
        (bool has, ) = manager.hasRole(endpointSenderRoleId, deployed);
        assertTrue(has,
            "auto-grant of ENDPOINT_SENDER on deploy() removed - cross-chain auto-deploy will break");
    }

    // ─────────────────────────────────────────────────────────────────
    //  CREATE2 determinism
    // ─────────────────────────────────────────────────────────────────

    function test_when_predictingCreate2AddressInAdvance_then_matchesActualDeployment() public {
        bytes memory runtime = type(InitSpy).runtimeCode;
        address predicted = FactoryStubLib.predictCreate2(address(factory), runtime, _saltCounter() + 1);
        address deployed = factory.deploy(runtime, "", bytes32(uint256(0xC0DE)));
        assertEq(deployed, predicted,
            "off-chain CREATE2 prediction drifted from on-chain deploy - indexers will mis-target");
    }

    // ─────────────────────────────────────────────────────────────────
    //  Internal helpers
    // ─────────────────────────────────────────────────────────────────

    /// @dev Reads `RaylsContractFactoryV1.saltCounter` directly from storage slot 0.
    ///      ASSUMPTION: every parent contract in the inheritance chain (Initializable,
    ///      UUPSUpgradeable, ReentrancyGuardUpgradeable, RaylsAccessManaged) uses ERC-7201
    ///      namespaced storage in OZ 5.x, leaving slot 0 free for the first user-declared
    ///      state variable. If a maintainer ever prepends a non-namespaced state variable
    ///      to the factory or its parents, this read silently returns the wrong value —
    ///      adjust the slot index accordingly.
    function _saltCounter() internal view returns (uint256) {
        return uint256(vm.load(address(factory), bytes32(uint256(0))));
    }
}

/// @notice Reentrancy probe for RaylsContractFactoryV1. Mirrors the RNContractFactoryV1 probe.
contract OuterReentryProbe {
    fallback() external payable {
        address factoryAddr;
        assembly { factoryAddr := sload(0) }
        if (factoryAddr == address(0)) return;
        bool already;
        assembly { already := sload(1) }
        if (already) return;
        assembly { sstore(1, 1) }

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
