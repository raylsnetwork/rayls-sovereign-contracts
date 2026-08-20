// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../../rayls-protocol/modules/ResourceManager.sol";
import "../../../rayls-protocol-sdk/RaylsMessage.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";

/**
 * @notice Minimal factory stand-in that records which deploy path the ResourceManager took
 *         and the arguments it forwarded. Exposes the well-known key constants the
 *         ResourceManager reads when mapping a FACTORY-mode template to a registry key.
 */
contract MockContractFactory {
    bytes32 public constant RAYLS_ERC20_KEY = keccak256("RAYLS_ERC20");
    bytes32 public constant RAYLS_ERC721_KEY = keccak256("RAYLS_ERC721");
    bytes32 public constant RAYLS_ERC1155_KEY = keccak256("RAYLS_ERC1155");
    bytes32 public constant RAYLS_ENYGMA_KEY = keccak256("RAYLS_ENYGMA");
    bytes32 public constant RAYLS_ERC721_DVP_KEY = keccak256("RAYLS_ERC721_DVP");
    bytes32 public constant RAYLS_ERC1155_DVP_KEY = keccak256("RAYLS_ERC1155_DVP");

    /// @notice Mirrors AbstractContractFactoryV1's revert when a key has no registered bytecode.
    error FactoryV1__BytecodeNotRegistered(bytes32 key);

    bool public bytecodeCalled;
    bool public registeredCalled;
    bytes32 public lastKey;
    bytes public lastUserArgs;
    bytes public lastBytecode;

    /// @notice When true, deployRegisteredExternal reverts as the real factory does for an unregistered key.
    bool public revertOnRegistered;

    address public immutable deployedStub = address(0xDEAD);

    function setRevertOnRegistered(bool value) external {
        revertOnRegistered = value;
    }

    /// @notice Clears recorded call state so a test (or helper) starts from a known baseline.
    function resetCalls() external {
        bytecodeCalled = false;
        registeredCalled = false;
        lastKey = bytes32(0);
        lastUserArgs = "";
        lastBytecode = "";
    }

    /// @notice Mirrors RNContractFactoryV1.deployExternal — the BYTECODE-mode deploy path the
    ///         ResourceManager routes custom bytecode to (registry recording happens inside the real
    ///         factory, gated on the standard probe).
    function deployExternal(bytes calldata bytecode, bytes calldata userArgs, bytes32)
        external
        returns (address)
    {
        bytecodeCalled = true;
        lastBytecode = bytecode;
        lastUserArgs = userArgs;
        return deployedStub;
    }

    /// @notice Mirrors RNContractFactoryV1.deployRegisteredExternal — the FACTORY-mode deploy path
    ///         the ResourceManager routes to (registry recording happens inside the real factory).
    function deployRegisteredExternal(bytes32 key, bytes calldata userArgs, bytes32)
        external
        returns (address)
    {
        if (revertOnRegistered) revert FactoryV1__BytecodeNotRegistered(key);
        registeredCalled = true;
        lastKey = key;
        lastUserArgs = userArgs;
        return deployedStub;
    }
}

/**
 * @title ResourceManager FACTORY/BYTECODE deploy dispatch
 * @notice Verifies handleWithResourceId routes a new-resource deploy to deployRegisteredExternal
 *         (FACTORY mode, mapping factoryTemplate -> registry key) or deployExternal (BYTECODE mode),
 *         and reverts on a template with no registry key.
 */
contract ResourceManagerDeployDispatchTest is Test {
    ResourceManager public resourceManager;
    RaylsAccessManagerV1 public manager;
    MockContractFactory public factory;

    address public owner;
    address public msgReceiver;

    bytes32 constant RESOURCE_ID = keccak256("test-resource");
    bytes constant INIT_PARAMS = hex"abcdef";

    function _singleRole(uint64 roleId) internal pure returns (uint64[] memory roles) {
        roles = new uint64[](1);
        roles[0] = roleId;
    }

    function setUp() public {
        owner = address(this);
        msgReceiver = makeAddr("msgReceiver");
        factory = new MockContractFactory();

        RaylsAccessManagerV1 impl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(
            address(impl), abi.encodeCall(RaylsAccessManagerV1.initialize, (owner))
        )));

        uint64 messageReceiverRoleId = manager.registerRole("MESSAGE_RECEIVER");

        // Mirror production: a receiver-side auto-deploy grants ENDPOINT_SENDER to the new
        // instance (ResourceManager._grantEndpointSender). That needs ENDPOINT_SENDER registered,
        // its admin set to FACTORY_ADMIN, and the ResourceManager holding FACTORY_ADMIN.
        uint64 endpointSenderRoleId = manager.registerRole("ENDPOINT_SENDER");
        uint64 factoryAdminRoleId = manager.registerRole("FACTORY_ADMIN");
        manager.setRoleAdmin(endpointSenderRoleId, factoryAdminRoleId);

        resourceManager = new ResourceManager(address(factory), owner, address(manager));
        resourceManager.setEndpoint(makeAddr("endpoint"));

        bytes4[] memory sels = new bytes4[](1);
        sels[0] = resourceManager.handleWithResourceId.selector;
        manager.addFunctionAllowedRoles(address(resourceManager), sels, _singleRole(messageReceiverRoleId));
        manager.grantRole(messageReceiverRoleId, msgReceiver, 0);
        manager.grantRole(factoryAdminRoleId, address(resourceManager), 0);
    }

    function _metadataForNewResource(NewResourceMetadata memory newResource)
        internal
        pure
        returns (RaylsMessageMetadata memory metadata)
    {
        metadata.resourceId = RESOURCE_ID;
        metadata.newResourceMetadata = newResource;
    }

    function test_factoryMode_routesToDeployRegistered_withMappedKey() public {
        NewResourceMetadata memory newResource;
        newResource.valid = true;
        newResource.resourceDeployType = ResourceDeployType.FACTORY;
        newResource.factoryTemplate = RaylsBridgeableERC.ENYGMA;
        newResource.initializerParams = INIT_PARAMS;
        // bytecode intentionally left empty — FACTORY mode must ignore it.

        vm.prank(msgReceiver);
        address resolved = resourceManager.handleWithResourceId(_metadataForNewResource(newResource), address(0));

        assertEq(resolved, factory.deployedStub());
        assertTrue(factory.registeredCalled());
        assertFalse(factory.bytecodeCalled());
        assertEq(factory.lastKey(), factory.RAYLS_ENYGMA_KEY());
        assertEq(factory.lastUserArgs(), INIT_PARAMS);
        // The resource is registered against the deployed address.
        assertEq(resourceManager.getAddressByResourceId(RESOURCE_ID), factory.deployedStub());
    }

    function test_bytecodeMode_routesToDeploy() public {
        bytes memory code = hex"60016002";
        NewResourceMetadata memory newResource;
        newResource.valid = true;
        newResource.resourceDeployType = ResourceDeployType.BYTECODE;
        newResource.bytecode = code;
        newResource.initializerParams = INIT_PARAMS;

        vm.prank(msgReceiver);
        address resolved = resourceManager.handleWithResourceId(_metadataForNewResource(newResource), address(0));

        assertEq(resolved, factory.deployedStub());
        assertTrue(factory.bytecodeCalled());
        assertFalse(factory.registeredCalled());
        assertEq(factory.lastBytecode(), code);
        assertEq(factory.lastUserArgs(), INIT_PARAMS);
    }

    function test_factoryMode_revertsOnUnsupportedTemplate() public {
        NewResourceMetadata memory newResource;
        newResource.valid = true;
        newResource.resourceDeployType = ResourceDeployType.FACTORY;
        newResource.factoryTemplate = RaylsBridgeableERC.CUSTOM; // no registry key
        newResource.initializerParams = INIT_PARAMS;

        vm.prank(msgReceiver);
        vm.expectRevert(abi.encodeWithSelector(
            ResourceManager.ResourceManager__UnsupportedFactoryTemplate.selector,
            RaylsBridgeableERC.CUSTOM
        ));
        resourceManager.handleWithResourceId(_metadataForNewResource(newResource), address(0));
    }

    function test_factoryMode_mapsEachKnownTemplate() public {
        _assertTemplateMapsToKey(RaylsBridgeableERC.ERC20, factory.RAYLS_ERC20_KEY());
        _assertTemplateMapsToKey(RaylsBridgeableERC.ERC721, factory.RAYLS_ERC721_KEY());
        _assertTemplateMapsToKey(RaylsBridgeableERC.ERC1155, factory.RAYLS_ERC1155_KEY());
        _assertTemplateMapsToKey(RaylsBridgeableERC.ENYGMA, factory.RAYLS_ENYGMA_KEY());
        _assertTemplateMapsToKey(RaylsBridgeableERC.DVPERC721, factory.RAYLS_ERC721_DVP_KEY());
        _assertTemplateMapsToKey(RaylsBridgeableERC.DVPERC1155, factory.RAYLS_ERC1155_DVP_KEY());
    }

    function test_factoryMode_revertsWhenFactoryHasNoBytecodeForKey() public {
        // ENYGMA is a supported template, but the factory has no bytecode registered for its key,
        // so deployRegisteredExternal reverts. The ResourceManager must propagate that revert.
        factory.setRevertOnRegistered(true);

        NewResourceMetadata memory newResource;
        newResource.valid = true;
        newResource.resourceDeployType = ResourceDeployType.FACTORY;
        newResource.factoryTemplate = RaylsBridgeableERC.ENYGMA;
        newResource.initializerParams = INIT_PARAMS;

        vm.prank(msgReceiver);
        vm.expectRevert(abi.encodeWithSelector(
            MockContractFactory.FactoryV1__BytecodeNotRegistered.selector,
            factory.RAYLS_ENYGMA_KEY()
        ));
        resourceManager.handleWithResourceId(_metadataForNewResource(newResource), address(0));
    }

    function _assertTemplateMapsToKey(RaylsBridgeableERC template, bytes32 expectedKey) internal {
        // Start from a clean slate so the helper is self-contained across repeated calls.
        factory.resetCalls();

        NewResourceMetadata memory newResource;
        newResource.valid = true;
        newResource.resourceDeployType = ResourceDeployType.FACTORY;
        newResource.factoryTemplate = template;
        newResource.initializerParams = INIT_PARAMS;

        // Use a distinct resourceId per call so the already-deployed short-circuit doesn't fire.
        RaylsMessageMetadata memory metadata;
        metadata.resourceId = keccak256(abi.encode(template));
        metadata.newResourceMetadata = newResource;

        vm.prank(msgReceiver);
        resourceManager.handleWithResourceId(metadata, address(0));
        assertEq(factory.lastKey(), expectedKey);
        assertTrue(factory.registeredCalled());
        assertFalse(factory.bytecodeCalled());
    }
}
