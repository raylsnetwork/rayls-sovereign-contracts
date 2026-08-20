// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {PNTokenRegistryV1} from "../../../rayls-protocol/TokenRegistry/PNTokenRegistryV1.sol";
import {PNTokenCoreV1} from "../../../rayls-protocol/TokenRegistry/modules/TokenCore/PNTokenCoreV1.sol";
import {ITokenCore} from "../../../rayls-protocol/TokenRegistry/interfaces/ITokenCore.sol";
import {ITokenRegistry} from "../../../rayls-protocol/TokenRegistry/interfaces/ITokenRegistry.sol";
import {TokenStructs} from "../../../rayls-protocol/TokenRegistry/libraries/TokenStructs.sol";
import {SharedObjects} from "../../../rayls-protocol-sdk/libraries/SharedObjects.sol";
import {ResourceManager} from "../../../rayls-protocol/modules/ResourceManager.sol";
import {
    RaylsMessageMetadata,
    NewResourceMetadata,
    ResourceDeployType,
    RaylsBridgeableERC
} from "../../../rayls-protocol-sdk/RaylsMessage.sol";

// ─── Mocks ──────────────────────────────────────────────────────────────────

/// @notice Minimal endpoint mock capturing resourceId bindings and reporting a fixed chain id.
contract MockRegisterHubEndpoint {
    mapping(bytes32 => address) public resourceIdToAddress;
    address internal authorityAddress;
    uint256 internal chainId = 100;

    function setAuthority(address a) external { authorityAddress = a; }
    function authority() external view returns (address) { return authorityAddress; }
    function getChainId() external view returns (uint256) { return chainId; }
    function registerResourceId(bytes32 resourceId, address impl) external { resourceIdToAddress[resourceId] = impl; }
    function getAddressByResourceId(bytes32 resourceId) external view returns (address) {
        return resourceIdToAddress[resourceId];
    }
}

/// @notice ERC20-shaped token mock. Symbol is configurable to exercise symbol collisions.
contract MockHubErc20 {
    string internal _name;
    string internal _symbol;
    uint256 internal _supply;

    constructor(string memory n, string memory s, uint256 supply) {
        _name = n;
        _symbol = s;
        _supply = supply;
    }

    function name() external view returns (string memory) { return _name; }
    function symbol() external view returns (string memory) { return _symbol; }
    function decimals() external pure returns (uint8) { return 18; }
    function totalSupply() external view returns (uint256) { return _supply; }
    function GetERCStandard() external pure returns (uint8) { return uint8(SharedObjects.ErcStandard.ERC20); }
}

/// @notice Enygma-shaped token mock used to verify the creation event carries the live supply.
contract MockHubEnygma {
    function name() external pure returns (string memory) { return "HubEnygma"; }
    function symbol() external pure returns (string memory) { return "HENY"; }
    function decimals() external pure returns (uint8) { return 18; }
    function totalSupply() external pure returns (uint256) { return 777e18; }
    function GetERCStandard() external pure returns (uint8) { return uint8(SharedObjects.ErcStandard.Enygma); }
}

/// @notice Captures Enygma/DVP creation callbacks emitted during registration.
contract MockHubEnygmaPNEvents {
    uint256 public creationCalls;
    bytes32 public lastResourceId;
    uint256 public lastInitialSupply;

    function creation(bytes32 resourceId, uint256 initialSupply) external {
        creationCalls++;
        lastResourceId = resourceId;
        lastInitialSupply = initialSupply;
    }

    function dvp721Creation(bytes32) external {}
    function dvp1155Creation(bytes32) external {}
}

/// @notice Factory stand-in mirroring RNContractFactoryV1: `deployRegisteredExternal` returns a
///         preconfigured token AND records it in the wired TokenRegistry facade via registerHubToken
///         (the inverted dependency). `deployExternal` covers the custom BYTECODE branch.
contract MockTokenReturningFactory {
    address public tokenToReturn;
    ITokenRegistry public tokenRegistry;

    function setToken(address t) external { tokenToReturn = t; }
    function setTokenRegistry(address r) external { tokenRegistry = ITokenRegistry(r); }

    function deployRegisteredExternal(bytes32, bytes calldata, bytes32 resourceId) external returns (address) {
        if (address(tokenRegistry) != address(0)) {
            tokenRegistry.registerHubToken(resourceId, tokenToReturn);
        }
        return tokenToReturn;
    }

    function deployExternal(bytes calldata, bytes calldata, bytes32) external view returns (address) {
        return tokenToReturn;
    }
}

// =============================================================================
// PN PNTokenCoreV1 — registerHubToken (destination-chain mirror registration)
//
// A token that teleports to a non-issuer PN is auto-deployed there by
// ResourceManager.handleWithResourceId. registerHubToken records that mirror in
// the PN TokenRegistry as fully authorized so its first operation
// (receiveTeleport -> _requireHubActive -> isTokenActiveForHub) succeeds.
// =============================================================================
contract TokenCoreV1_RegisterHubToken_Test is Test {
    RaylsAccessManagerV1 internal manager;
    PNTokenCoreV1 internal tokenCore;
    MockRegisterHubEndpoint internal endpoint;

    bytes32 internal constant RESOURCE_ID = keccak256("hub-token-resource");

    event TokenRegistered(
        address indexed tokenAddress, string name, string symbol, SharedObjects.ErcStandard ercStandard
    );
    event TokenActivated(
        bytes32 indexed resourceId, address indexed tokenAddress, SharedObjects.ErcStandard ercStandard
    );

    function setUp() public {
        RaylsAccessManagerV1 managerImpl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(
            address(new ERC1967Proxy(address(managerImpl), abi.encodeCall(RaylsAccessManagerV1.initialize, (address(this)))))
        );

        PNTokenCoreV1 coreImpl = new PNTokenCoreV1();
        tokenCore = PNTokenCoreV1(
            address(new ERC1967Proxy(address(coreImpl), abi.encodeCall(PNTokenCoreV1.initialize, (address(manager)))))
        );

        endpoint = new MockRegisterHubEndpoint();

        // The core accepts registerHubToken only from the configured TokenRegistry facade
        // (onlyTokenRegistry). This test contract stands in as the facade.
        tokenCore.setTokenRegistry(address(this));
        tokenCore.setEndpoint(address(endpoint));
    }

    function _register(bytes32 resourceId, address token) internal {
        // msg.sender is this test contract, registered as the facade in setUp.
        tokenCore.registerHubToken(resourceId, token);
    }

    // ── Happy path ───────────────────────────────────────────────────────────

    function test_registerHubToken_recordsMirrorAsAuthorized() public {
        MockHubErc20 token = new MockHubErc20("HubToken", "HUB", 1_000e18);

        vm.expectEmit(true, true, false, true, address(tokenCore));
        emit TokenRegistered(address(token), "HubToken", "HUB", SharedObjects.ErcStandard.ERC20);
        vm.expectEmit(true, true, false, true, address(tokenCore));
        emit TokenActivated(RESOURCE_ID, address(token), SharedObjects.ErcStandard.ERC20);
        _register(RESOURCE_ID, address(token));

        TokenStructs.Token memory rec = tokenCore.getTokenByAddress(address(token));
        assertEq(rec.tokenAddress, address(token));
        assertEq(rec.resourceId, RESOURCE_ID);
        assertEq(uint256(rec.privacyNodeStatus), uint256(TokenStructs.PrivacyNodeStatus.AUTHORIZED));
        assertEq(uint256(rec.hubStatus), uint256(TokenStructs.HubStatus.AUTHORIZED));

        assertTrue(tokenCore.isTokenActiveForHub(address(token)));
        assertEq(tokenCore.getTokenByResourceId(RESOURCE_ID).tokenAddress, address(token));
        assertEq(tokenCore.getTokenBySymbol("HUB").tokenAddress, address(token));
        assertEq(endpoint.getAddressByResourceId(RESOURCE_ID), address(token), "resourceId must be bound");
        assertEq(tokenCore.getTokenCount(), 1);
    }

    // ── Idempotency ──────────────────────────────────────────────────────────

    function test_registerHubToken_idempotent_sameAddress() public {
        MockHubErc20 token = new MockHubErc20("HubToken", "HUB", 1_000e18);

        _register(RESOURCE_ID, address(token));
        _register(RESOURCE_ID, address(token)); // retry — must be a no-op

        assertEq(tokenCore.getTokenCount(), 1, "no duplicate entry on retry");
    }

    function test_registerHubToken_idempotent_resourceIdBoundToAnotherAddress() public {
        MockHubErc20 tokenA = new MockHubErc20("TokenA", "AAA", 1e18);
        MockHubErc20 tokenB = new MockHubErc20("TokenB", "BBB", 2e18);

        _register(RESOURCE_ID, address(tokenA));
        // Same resourceId, different address → must not create a second AUTHORIZED entry.
        _register(RESOURCE_ID, address(tokenB));

        assertEq(tokenCore.getTokenCount(), 1);
        assertFalse(tokenCore.tokenExists(address(tokenB)));
    }

    // ── Symbol tolerance ─────────────────────────────────────────────────────

    function test_registerHubToken_symbolCollision_bothRecorded() public {
        MockHubErc20 tokenA = new MockHubErc20("First", "DUP", 1e18);
        MockHubErc20 tokenB = new MockHubErc20("Second", "DUP", 2e18);

        _register(keccak256("res-a"), address(tokenA));
        _register(keccak256("res-b"), address(tokenB));

        assertEq(tokenCore.getTokenCount(), 2);
        assertTrue(tokenCore.isTokenActiveForHub(address(tokenA)));
        assertTrue(tokenCore.isTokenActiveForHub(address(tokenB)));
        // Symbol index keeps the first winner; address/resourceId lookups stay authoritative.
        assertEq(tokenCore.getTokenBySymbol("DUP").tokenAddress, address(tokenA));
        assertEq(tokenCore.getTokenByResourceId(keccak256("res-b")).tokenAddress, address(tokenB));
    }

    // ── Creation events ──────────────────────────────────────────────────────

    // registerHubToken does not emit an Enygma/DVP creation callback: the mirror is a
    // destination-chain instance, and creation bookkeeping stays on the issuer-side activation
    // path (consistent with the "remove total supply on token activation" refactor).
    function test_registerHubToken_enygma_emitsNoCreationEvent() public {
        MockHubEnygmaPNEvents events = new MockHubEnygmaPNEvents();
        tokenCore.setEnygmaPNEvents(address(events));
        MockHubEnygma token = new MockHubEnygma();

        _register(RESOURCE_ID, address(token));

        assertEq(events.creationCalls(), 0, "mirror registration must not emit a creation event");
        assertTrue(tokenCore.isTokenActiveForHub(address(token)), "Enygma mirror still hub-active");
    }

    function test_registerHubToken_erc20_emitsNoCreationEvent() public {
        MockHubEnygmaPNEvents events = new MockHubEnygmaPNEvents();
        tokenCore.setEnygmaPNEvents(address(events));
        MockHubErc20 token = new MockHubErc20("HubToken", "HUB", 1_000e18);

        _register(RESOURCE_ID, address(token));

        assertEq(events.creationCalls(), 0, "plain ERC20 must not emit an Enygma creation event");
    }

    // ── Access control ───────────────────────────────────────────────────────

    function test_registerHubToken_revertsForNonTokenRegistry() public {
        MockHubErc20 token = new MockHubErc20("HubToken", "HUB", 1_000e18);
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ITokenCore.TokenCoreV1__UnauthorizedCaller.selector, attacker));
        tokenCore.registerHubToken(RESOURCE_ID, address(token));
    }

    // ── Integration: ResourceManager auto-deploy path records the mirror ───────

    function test_resourceManagerAutoDeploy_recordsMirrorInRegistry() public {
        // Roles required by ResourceManager._grantEndpointSender on the auto-deploy path.
        uint64 messageReceiverRoleId = manager.registerRole("MESSAGE_RECEIVER");
        uint64 endpointSenderRoleId = manager.registerRole("ENDPOINT_SENDER");
        uint64 factoryAdminRoleId = manager.registerRole("FACTORY_ADMIN");
        manager.setRoleAdmin(endpointSenderRoleId, factoryAdminRoleId);

        // The mirror instance the factory "deploys" on the destination chain.
        MockHubErc20 mirror = new MockHubErc20("HubToken", "HUB", 5_000e18);
        MockTokenReturningFactory factory = new MockTokenReturningFactory();
        factory.setToken(address(mirror));

        // PN TokenRegistry facade + core, wired so the ResourceManager can record through it.
        PNTokenRegistryV1 facadeImpl = new PNTokenRegistryV1();
        PNTokenRegistryV1 facade = PNTokenRegistryV1(
            address(new ERC1967Proxy(
                address(facadeImpl),
                abi.encodeCall(PNTokenRegistryV1.initialize, (address(endpoint), address(manager)))
            ))
        );
        facade.setTokenCore(address(tokenCore));
        tokenCore.setTokenRegistry(address(facade));

        // Wire the factory to record through the facade (mirrors SetRNFactoryTokenRegistry). The
        // dependency is inverted: the factory, not the ResourceManager, calls registerHubToken.
        factory.setTokenRegistry(address(facade));

        // ResourceManager under test.
        ResourceManager rm = new ResourceManager(address(factory), address(this), address(manager));
        rm.setEndpoint(makeAddr("rmEndpoint"));

        // Allow msgReceiver to invoke handleWithResourceId; grant the auto-deploy grant authority.
        address msgReceiver = makeAddr("msgReceiver");
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = rm.handleWithResourceId.selector;
        uint64[] memory roles = new uint64[](1);
        roles[0] = messageReceiverRoleId;
        manager.addFunctionAllowedRoles(address(rm), sels, roles);
        manager.grantRole(messageReceiverRoleId, msgReceiver, 0);
        // ResourceManager still grants ENDPOINT_SENDER to auto-deployed instances, so it holds FACTORY_ADMIN.
        manager.grantRole(factoryAdminRoleId, address(rm), 0);

        // The FACTORY records the mirror through the facade's `restricted` registerHubToken. Mirror
        // the production wiring: map that selector to the deployer role and grant it to the factory
        // (FACTORY_ADMIN stands in for FACTORY_DEPLOYER here).
        bytes4[] memory facadeSels = new bytes4[](1);
        facadeSels[0] = facade.registerHubToken.selector;
        uint64[] memory facadeRoles = new uint64[](1);
        facadeRoles[0] = factoryAdminRoleId;
        manager.addFunctionAllowedRoles(address(facade), facadeSels, facadeRoles);
        manager.grantRole(factoryAdminRoleId, address(factory), 0);

        // Simulate an inbound teleport that auto-deploys a FACTORY mirror.
        NewResourceMetadata memory newResource;
        newResource.valid = true;
        newResource.resourceDeployType = ResourceDeployType.FACTORY;
        newResource.factoryTemplate = RaylsBridgeableERC.ERC20;
        newResource.initializerParams = hex"";

        RaylsMessageMetadata memory metadata;
        metadata.resourceId = RESOURCE_ID;
        metadata.newResourceMetadata = newResource;

        vm.prank(msgReceiver);
        address resolved = rm.handleWithResourceId(metadata, address(0));

        assertEq(resolved, address(mirror));
        // The mirror is now registered + authorized on the destination PN.
        assertTrue(tokenCore.tokenExists(address(mirror)));
        assertTrue(tokenCore.isTokenActiveForHub(address(mirror)));
        assertEq(tokenCore.getTokenByResourceId(RESOURCE_ID).tokenAddress, address(mirror));
    }
}
