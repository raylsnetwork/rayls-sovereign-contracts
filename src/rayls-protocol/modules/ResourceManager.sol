// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import {
    RaylsMessage,
    RaylsMessageMetadata,
    NewResourceMetadata,
    ResourceDeployType,
    RaylsBridgeableERC
} from './../../rayls-protocol-sdk/RaylsMessage.sol';
import {RaylsContractFactoryV1} from './../RaylsContractFactory/RaylsContractFactoryV1.sol';
import {FactoryKeys} from './../RaylsContractFactory/FactoryKeys.sol';
import {IResourceManager} from './../interfaces/IResourceManager.sol';
import {RaylsAccessManaged} from './../../privateHub/AccessControl/RaylsAccessManaged.sol';
import {IRaylsAccessManager} from './../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol';

/**
 * @title ResourceManager
 * @notice Manages resource IDs and their associated contract addresses, handles dynamic deployment
 * @dev Central registry for resource ID mapping and contract deployment via factory
 */
contract ResourceManager is IResourceManager, ReentrancyGuard, RaylsAccessManaged {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ResourceManager__UnauthorizedCaller(address caller);
    error ResourceManager__ZeroAddress();
    error ResourceManager__NoValidDestination();
    /// @notice A FACTORY-mode deploy named a template the factory has no registry key for.
    error ResourceManager__UnsupportedFactoryTemplate(RaylsBridgeableERC factoryTemplate);
    /// @notice `getRoleIdByName(...)` returned 0 (PUBLIC_ROLE) — the role wasn't registered on the
    ///         AccessManager. Granting role 0 would broaden access to everyone.
    /// @param roleName The role name that resolved to 0.
    error ResourceManager__RoleNotRegistered(string roleName);

    /*//////////////////////////////////////////////////////////////
                           STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Maps resourceId to contract address for cross-chain resource resolution
    mapping(bytes32 => address) public resourceIdToContractAddress;

    /// @notice Reference to the contract factory for dynamic deployment
    RaylsContractFactoryV1 private contractFactory;

    /// @notice The Endpoint address for additional authorization checks
    /// @dev Used for registerResourceId to allow both endpoint and owner
    address public endpoint;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event EndpointSet(address indexed oldEndpoint, address indexed newEndpoint);

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    // onlyEndpointOrAuthorized removed — use `restricted` modifier instead.
    // The endpoint should hold the appropriate role in the AccessManager.

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the resource manager with contract factory, owner, and access manager
     * @param _contractFactory Address of the contract factory for dynamic deployment (can be placeholder, updated later)
     * @param _owner Address of the contract owner
     * @param _authority Address of the RaylsAccessManagerV1 instance
     * @dev Endpoint must be set after deployment via setEndpoint() due to circular dependency
     *      (Endpoint needs ResourceManager address, ResourceManager needs Endpoint address)
     */
    constructor(
        address _contractFactory,
        address _owner,
        address _authority
    ) {
        if (_owner == address(0)) {
            revert ResourceManager__ZeroAddress();
        }

        // Note: _contractFactory can be a placeholder address that gets updated later
        // This is necessary because RaylsContractFactory may not exist yet during deployment
        contractFactory = RaylsContractFactoryV1(_contractFactory);

        _setAuthority(_authority);
    }

    /*//////////////////////////////////////////////////////////////
                          ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the endpoint address
     * @param _endpoint Address of the Endpoint contract
     * @dev Only callable by owner. Endpoint is used for registerResourceId authorization
     */
    function setEndpoint(address _endpoint) external restricted {
        if (_endpoint == address(0)) {
            revert ResourceManager__ZeroAddress();
        }
        address oldEndpoint = endpoint;
        endpoint = _endpoint;
        emit EndpointSet(oldEndpoint, _endpoint);
    }

    /**
     * @notice Updates the contract factory address
     * @param _contractFactory Address of the new contract factory
     * @dev Only callable by owner. Zero address check to prevent misconfiguration
     */
    function setContractFactory(address _contractFactory) external override restricted {
        if (_contractFactory == address(0)) {
            revert ResourceManager__ZeroAddress();
        }
        contractFactory = RaylsContractFactoryV1(_contractFactory);
        emit ContractFactoryUpdated(_contractFactory);
    }

    /**
     * @notice Registers a resource ID to an implementation address
     * @param _resourceId The resource ID to register
     * @param _implementationAddress The implementation address to associate with the resource ID
     * @dev Only endpoint or owner can register. Endpoint registers during message processing, owner for manual setup
     */
    function registerResourceId(bytes32 _resourceId, address _implementationAddress) external override restricted {
        resourceIdToContractAddress[_resourceId] = _implementationAddress;
        emit ResourceIdRegistered(_resourceId, _implementationAddress);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the address associated with a resource ID
     * @param _resourceId The resource ID to look up
     * @return The address associated with the resource ID, or address(0) if not registered
     */
    function getAddressByResourceId(bytes32 _resourceId) external view override returns (address) {
        return resourceIdToContractAddress[_resourceId];
    }

    /*//////////////////////////////////////////////////////////////
                      RESOURCE RESOLUTION LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Handles resource ID resolution or dynamic contract deployment
     * @param raylsMessageMetadata Metadata containing resource information and deployment data
     * @param _dstAddress Destination address (if already known)
     * @return destinationAddress The resolved or newly deployed destination address
     * @dev Only callable by authorized endpoint (MessageReceiver) during message processing
     *      Can deploy contracts dynamically if newResourceMetadata is provided
     */
    function handleWithResourceId(
        RaylsMessageMetadata memory raylsMessageMetadata,
        address _dstAddress
    ) external override restricted nonReentrant returns (address destinationAddress) {
        // Validate at least one destination method is provided
        if (_dstAddress == address(0) &&
            !raylsMessageMetadata.newResourceMetadata.valid &&
            raylsMessageMetadata.resourceId == bytes32(0)) {
            revert ResourceManager__NoValidDestination();
        }

        // Direct address takes precedence
        if (_dstAddress != address(0)) return _dstAddress;

        // Handle dynamic deployment if requested
        if (raylsMessageMetadata.newResourceMetadata.valid) {
            // Check if already deployed
            address existingAddress = resourceIdToContractAddress[raylsMessageMetadata.resourceId];
            if (existingAddress != address(0)) {
                return existingAddress;
            }

            // Deploy new contract via factory. Two modes:
            //   BYTECODE — issuer-supplied runtime bytecode (legacy / custom standards).
            //   FACTORY  — bytecode pre-registered under a template key. CREATE2 + the seeded
            //              registry produce identical runtime bytecode on every PN, so a single
            //              seeded standard template matches the deployed instance's extcodehash
            //              everywhere. The `bytecode` field is ignored; only `initializerParams`
            //              and `factoryTemplate` are honored.
            NewResourceMetadata memory newResource = raylsMessageMetadata.newResourceMetadata;
            address deployedAddress;
            if (newResource.resourceDeployType == ResourceDeployType.FACTORY) {
                // Standard FACTORY instances are recorded in the PN TokenRegistry by the factory
                // itself (deployRegisteredExternal -> registerHubToken), so the mirror is immediately
                // hub-authorized on this destination chain.
                deployedAddress = contractFactory.deployRegisteredExternal(
                    _keyForTemplate(newResource.factoryTemplate),
                    newResource.initializerParams,
                    raylsMessageMetadata.resourceId
                );
            } else {
                // Custom BYTECODE deploys go through the factory's external deploy too; the factory
                // records the mirror only when the instance is a classifiable Rayls token standard,
                // so a non-standard custom contract is deployed but left unregistered.
                deployedAddress = contractFactory.deployExternal(
                    newResource.bytecode,
                    newResource.initializerParams,
                    raylsMessageMetadata.resourceId
                );
            }

            // Register the newly deployed contract
            _registerResourceIdInternal(raylsMessageMetadata.resourceId, deployedAddress);

            // Grant ENDPOINT_SENDER to the freshly deployed instance so it can call
            // ENDPOINT_SENDER-gated protocol functions (e.g. an Enygma handler's `mint` /
            // `crossTransferRevertBatch` → `EnygmaPNEvents`). Receiver-side auto-deploy (this path)
            // bypasses the PN TokenRegistry/TokenCore activation flow that grants it for issuer-side
            // tokens, so without this the instance reverts with RaylsAccessManaged__Unauthorized on
            // its first events-emitting call. The PN factory deliberately does not auto-grant; the
            // grant lives on the registration path instead. Requires ResourceManager to hold
            // FACTORY_ADMIN (the admin of ENDPOINT_SENDER).
            _grantEndpointSender(deployedAddress);

            return deployedAddress;
        }

        // Lookup existing resource ID mapping
        if (raylsMessageMetadata.resourceId != bytes32(0)) {
            return resourceIdToContractAddress[raylsMessageMetadata.resourceId];
        }

        revert ResourceManager__NoValidDestination();
    }

    /*//////////////////////////////////////////////////////////////
                      INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Maps a bridgeable-asset template to the factory registry key holding its bytecode.
     * @param factoryTemplate The standard template named by a FACTORY-mode deploy.
     * @return key The factory registry key whose bytecode implements the template.
     * @dev Reverts on templates the factory has no well-known key for (CUSTOM must use BYTECODE).
     */
    function _keyForTemplate(RaylsBridgeableERC factoryTemplate) internal pure returns (bytes32 key) {
        if (factoryTemplate == RaylsBridgeableERC.ENYGMA) return FactoryKeys.RAYLS_ENYGMA_KEY;
        if (factoryTemplate == RaylsBridgeableERC.ERC20) return FactoryKeys.RAYLS_ERC20_KEY;
        if (factoryTemplate == RaylsBridgeableERC.ERC721) return FactoryKeys.RAYLS_ERC721_KEY;
        if (factoryTemplate == RaylsBridgeableERC.ERC1155) return FactoryKeys.RAYLS_ERC1155_KEY;
        if (factoryTemplate == RaylsBridgeableERC.DVPERC721) return FactoryKeys.RAYLS_ERC721_DVP_KEY;
        if (factoryTemplate == RaylsBridgeableERC.DVPERC1155) return FactoryKeys.RAYLS_ERC1155_DVP_KEY;
        // Test-only variants resolve to the *Example seeded bytecode. Reached on the receiver when a
        // teleport of a *TEST-tagged token arrives, so the redeployed instance keeps the test surface.
        if (factoryTemplate == RaylsBridgeableERC.ERC20TEST) return FactoryKeys.RAYLS_ERC20_TEST_KEY;
        if (factoryTemplate == RaylsBridgeableERC.ERC721TEST) return FactoryKeys.RAYLS_ERC721_TEST_KEY;
        if (factoryTemplate == RaylsBridgeableERC.ERC1155TEST) return FactoryKeys.RAYLS_ERC1155_TEST_KEY;
        if (factoryTemplate == RaylsBridgeableERC.ENYGMATEST) return FactoryKeys.RAYLS_ENYGMA_TEST_KEY;
        if (factoryTemplate == RaylsBridgeableERC.DVPERC721TEST) return FactoryKeys.RAYLS_ERC721_DVP_TEST_KEY;
        if (factoryTemplate == RaylsBridgeableERC.DVPERC1155TEST) return FactoryKeys.RAYLS_ERC1155_DVP_TEST_KEY;
        revert ResourceManager__UnsupportedFactoryTemplate(factoryTemplate);
    }

    /**
     * @notice Internal function to register a resource ID without access control
     * @param _resourceId The resource ID to register
     * @param _implementationAddress The implementation address to associate with the resource ID
     * @dev Used during dynamic deployment to bypass external access control
     */
    function _registerResourceIdInternal(bytes32 _resourceId, address _implementationAddress) internal {
        resourceIdToContractAddress[_resourceId] = _implementationAddress;
        emit ResourceIdRegistered(_resourceId, _implementationAddress);
    }

    /**
     * @notice Grant ENDPOINT_SENDER to a contract on this PN's AccessManager.
     * @dev Mirrors the PN {TokenCoreV1-activateToken} ENDPOINT_SENDER grant for the receiver-side auto-deploy
     *      path. Requires this ResourceManager to hold FACTORY_ADMIN (the admin of ENDPOINT_SENDER).
     * @param _target Address to grant ENDPOINT_SENDER to.
     */
    function _grantEndpointSender(address _target) internal {
        address mgr = authority();
        if (mgr == address(0)) return;
        uint64 roleId = IRaylsAccessManager(mgr).getRoleIdByName("ENDPOINT_SENDER");
        if (roleId == 0) revert ResourceManager__RoleNotRegistered("ENDPOINT_SENDER");
        IRaylsAccessManager(mgr).grantRole(roleId, _target, 0);
    }
}
