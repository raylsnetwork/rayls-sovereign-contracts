// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import {RaylsAccessManaged} from '../AccessControl/RaylsAccessManaged.sol';
import '../../rayls-protocol-sdk/libraries/SharedObjects.sol';

/**
 * @title ResourceRegistryV1
 * @dev Manages the registration and lookup of resources in the Rayls Protocol.
 *
 * This contract maps resource IDs to their associated metadata including:
 * - ERC standard type (ERC20, ERC721, etc.)
 * - Contract bytecode
 * - Initializer parameters
 *
 * The resource ID serves as a unique identifier that can be used across chains
 * to refer to the same logical resource, even when deployed at different addresses.
 */
contract ResourceRegistryV1 is Initializable, UUPSUpgradeable, RaylsAccessManaged {
    /**
     * @dev Structure representing a resource in the registry
     * @param resourceId Unique identifier for the resource
     * @param standard The ERC standard of the resource (ERC20, ERC721, etc.)
     * @param bytecode The contract bytecode of the resource
     * @param initializerParams Parameters used to initialize the resource contract
     */
    struct Resource {
        bytes32 resourceId;
        SharedObjects.ErcStandard standard;
        bytes bytecode;
        bytes initializerParams;
    }

    /**
     * @dev Storage structure for the ResourceRegistry contract
     * @param tokenRegistryAt Address of the associated TokenRegistry contract
     * @param resources Array of all registered resources
     * @param resourceIndexById Mapping from resource ID to its index in the resources array (1-indexed)
     * @param RESOURCE_COUNTER Counter used to generate unique resource IDs
     */
    struct ResourceRegistryStorage {
        address tokenRegistryAt;
        Resource[] resources;
        mapping(bytes32 => uint256) resourceIndexById;
        uint256 RESOURCE_COUNTER;
    }

    // Storage slot for the ResourceRegistryStorage struct
    // Calculated using: keccak256(abi.encode(uint256(keccak256("rayls.privatenetworkhub.ResourceRegistry")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant RESOURCE_REGISTRY_STORAGE = 0x5f092f6026c66587fbb8d90f812020d9443212d551a1ca8fbb1a34b93d86cc00;

    /**
     * @dev Restricts function access to only the TokenRegistry contract
     * This ensures that only authorized contracts can register resources
     */
    error ResourceRegistryV1__TokenRegistryNotSet();
    error ResourceRegistryV1__UnauthorizedCaller(address caller);

    modifier onlyTokenRegistry() virtual {
        ResourceRegistryStorage storage $ = _getStorage();
        if ($.tokenRegistryAt == address(0)) {
            revert ResourceRegistryV1__TokenRegistryNotSet();
        }

        if (msg.sender != $.tokenRegistryAt) {
            revert ResourceRegistryV1__UnauthorizedCaller(msg.sender);
        }

        _;
    }

    /**
     * @dev Initializes the contract
     * @param authority_ The RaylsAccessManager address.
     */
    function initialize(address authority_) public initializer {
        __UUPSUpgradeable_init();
        _initializeAuthority(authority_);
    }

    /**
     * @dev Authorizes upgrade to a new implementation
     * @param newImplementation Address of the new implementation
     * Required by the OpenZeppelin UUPS module
     */
    function _authorizeUpgrade(address newImplementation) internal override {
        _checkCanCall(msg.sender, msg.sig);
    }

    /**
     * @dev Sets the address of the TokenRegistry contract
     * @param tokenRegistryAt Address of the TokenRegistry contract
     * This relationship is essential as only the TokenRegistry can register resources
     */
    function setTokenRegistry(address tokenRegistryAt) public virtual restricted {
        ResourceRegistryStorage storage $ = _getStorage();
        $.tokenRegistryAt = tokenRegistryAt;
    }

    /**
     * @dev Registers a new resource in the registry
     * @param standard The ERC standard of the resource
     * @param bytecode The contract bytecode of the resource
     * @param initializerParams Parameters used to initialize the resource contract
     * @return resourceId The generated unique identifier for the resource
     *
     * This function can only be called by the TokenRegistry contract.
     * It generates a unique resource ID and stores the resource metadata.
     */
    function registerResource(SharedObjects.ErcStandard standard, bytes memory bytecode, bytes memory initializerParams) public virtual onlyTokenRegistry returns (bytes32) {
        ResourceRegistryStorage storage $ = _getStorage();

        // Generate a unique resource ID
        bytes32 resourceId = _generateResourceId();

        // Ensure the resource ID is not already in use
        require($.resourceIndexById[resourceId] == 0, 'ResourceRegistryV1: Resource already registered');

        // Add the resource to the array
        $.resources.push(Resource({resourceId: resourceId, standard: standard, bytecode: bytecode, initializerParams: initializerParams}));
        
        // Store the index (1-indexed) for fast lookups
        $.resourceIndexById[resourceId] = $.resources.length;

        return resourceId;
    }

    /**
     * @dev Retrieves a resource by its ID
     * @param resourceId The unique identifier of the resource
     * @return Resource struct containing all resource metadata
     */
    function getResourceById(bytes32 resourceId) public view virtual returns (Resource memory) {
        return _getResourceById(resourceId);
    }

    /**
     * @dev Internal function to retrieve a resource by its ID
     * @param resourceId The unique identifier of the resource
     * @return Resource struct (as a storage reference) containing all resource metadata
     * @notice This function reverts if the resource is not found
     */
    function _getResourceById(bytes32 resourceId) internal view virtual returns (Resource storage) {
        ResourceRegistryStorage storage $ = _getStorage();

        // Get the 1-indexed position of the resource
        uint256 resourceIndex = $.resourceIndexById[resourceId];

        // Check if the resource exists
        if (resourceIndex == 0) {
            revert('ResourceRegistryV1: Resource not found');
        }

        // Return the resource (converting from 1-indexed to 0-indexed)
        return $.resources[resourceIndex - 1];
    }

    /**
     * @dev Generates a unique resource ID
     * @return A unique bytes32 identifier based on an incrementing counter
     *
     * The resource ID is generated by hashing the current counter value.
     * This approach ensures uniqueness and prevents collisions.
     */
    function _generateResourceId() internal virtual returns (bytes32) {
        ResourceRegistryStorage storage $ = _getStorage();
        uint256 counter = $.RESOURCE_COUNTER;
        $.RESOURCE_COUNTER += 1;
        return keccak256(abi.encodePacked(counter));
    }

    /**
     * @dev Retrieves a pointer to the contract storage
     * @return $ reference to the ResourceRegistryStorage struct
     *
     * This function uses assembly to access the storage at a specific slot,
     * which allows the contract to have a fixed storage layout even when upgraded.
     */
    function _getStorage() internal pure virtual returns (ResourceRegistryStorage storage $) {
        assembly {
            $.slot := RESOURCE_REGISTRY_STORAGE
        }
    }

    /**
     * @dev Returns the contract version
     * @return The version number (1) of this contract implementation
     */
    function contractVersion() external pure virtual returns (uint256) {
        return 1;
    }
}
