// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import './../../rayls-protocol-sdk/RaylsMessage.sol';

/**
 * @title IResourceManager
 * @dev Interface for the ResourceManager contract
 */
interface IResourceManager {
    /**
     * @dev Emitted when a resource ID is registered
     * @param resourceId The resource ID that was registered
     * @param implementationAddress The implementation address associated with the resource ID
     */
    event ResourceIdRegistered(bytes32 indexed resourceId, address indexed implementationAddress);

    /**
     * @dev Emitted when the contract factory is updated
     * @param contractFactory The new contract factory address
     */
    event ContractFactoryUpdated(address indexed contractFactory);

    /**
     * @dev Emitted when the authorized endpoint is set
     * @param endpoint The endpoint address
     */
    event AuthorizedEndpointSet(address indexed endpoint);

    /**
     * @dev Emitted when the authorized endpoint is removed
     * @param endpoint The endpoint address
     */
    event AuthorizedEndpointRemoved(address indexed endpoint);
    
    /**
     * @dev Updates the contract factory address
     * @param _contractFactory Address of the new contract factory
     */
    function setContractFactory(address _contractFactory) external;
    
    /**
     * @dev Registers a resource ID to an implementation address
     * @param _resourceId The resource ID to register
     * @param _implementationAddress The implementation address to associate with the resource ID
     */
    function registerResourceId(bytes32 _resourceId, address _implementationAddress) external;
    
    /**
     * @dev Gets the address associated with a resource ID
     * @param _resourceId The resource ID to look up
     * @return The address associated with the resource ID
     */
    function getAddressByResourceId(bytes32 _resourceId) external view returns (address);
    
    /**
     * @dev Handles resource ID resolution or deployment
     * @param raylsMessageMetadata Metadata containing resource information
     * @param _dstAddress Destination address
     * @return destinationAddress The resolved destination address
     */
    function handleWithResourceId(
        RaylsMessageMetadata memory raylsMessageMetadata, 
        address _dstAddress
    ) external returns (address destinationAddress);
} 