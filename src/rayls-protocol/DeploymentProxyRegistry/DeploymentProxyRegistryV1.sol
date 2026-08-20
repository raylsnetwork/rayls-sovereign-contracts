// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import '../../privateHub/AccessControl/RaylsAccessManaged.sol';

/**
 * @title DeploymentProxyRegistryV1
 * @notice A registry contract for tracking and managing deployed contracts in the Rayls Protocol
 * @dev This contract provides a centralized registry to lookup contract addresses by name,
 *      enabling other contracts to find and interact with them without hardcoding addresses.
 *      The contract is upgradeable using the UUPS pattern and uses RaylsAccessManaged for permissions.
 */
contract DeploymentProxyRegistryV1 is
    Initializable,
    UUPSUpgradeable,
    RaylsAccessManaged
{
    // Mapping from contract name to address
    mapping(string => address) private _contracts;
    
    // Array to store all contract names for enumeration
    string[] private _contractNames;

    /**
     * @notice Emitted when a new contract is registered in the registry
     * @param name The name of the registered contract
     * @param contractAddress The address of the registered contract
     */
    event ContractRegistered(string indexed name, address indexed contractAddress);

    /**
     * @notice Emitted when a contract address is updated
     * @param name The name of the updated contract
     * @param oldAddress The previous address of the contract
     * @param newAddress The new address of the contract
     */
    event ContractUpdated(string indexed name, address indexed oldAddress, address indexed newAddress);

    /**
     * @notice Emitted when a contract is removed from the registry
     * @param name The name of the removed contract
     * @param contractAddress The address of the removed contract
     */
    event ContractRemoved(string indexed name, address indexed contractAddress);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract with the RaylsAccessManager authority
     * @dev This replaces the constructor for upgradeable contracts
     * @param authority_ Address of the RaylsAccessManager that governs this contract
     */
    function initialize(address authority_) public initializer {
        __UUPSUpgradeable_init();
        _initializeAuthority(authority_);
    }

    /**
     * @notice Registers a new contract in the registry
     * @dev Only callers authorized by RaylsAccessManager can register contracts
     * @param name The name to identify the contract (must be unique)
     * @param contractAddress The address of the deployed contract
     *
     * Requirements:
     * - Name must not be empty
     * - Address must not be the zero address
     * - Name must not be already registered
     * - Address must contain deployed code (not an EOA)
     */
    function registerContract(string memory name, address contractAddress)
        external
        restricted
    {
        require(bytes(name).length > 0, "DeploymentProxyRegistryV1: Name cannot be empty");
        require(contractAddress != address(0), "DeploymentProxyRegistryV1: Invalid contract address");
        require(_contracts[name] == address(0), "DeploymentProxyRegistryV1: Contract name already registered");
        require(contractAddress.code.length > 0, "DeploymentProxyRegistryV1: Contract bytecode is empty");
        
        // Store the contract address and name
        _contracts[name] = contractAddress;
        _contractNames.push(name);
        
        emit ContractRegistered(name, contractAddress);
    }

    /**
     * @notice Updates the address of an existing contract
     * @dev Only callers authorized by RaylsAccessManager can update contracts
     * @param name The name of the contract to update
     * @param newAddress The new address for the contract
     *
     * Requirements:
     * - Name must not be empty
     * - New address must not be the zero address
     * - Contract with the given name must already be registered
     */
    function updateContract(string memory name, address newAddress)
        external
        restricted
    {
        require(bytes(name).length > 0, "DeploymentProxyRegistryV1: Name cannot be empty");
        require(newAddress != address(0), "DeploymentProxyRegistryV1: Invalid contract address");
        require(_contracts[name] != address(0), "DeploymentProxyRegistryV1: Contract not registered");

        address oldAddress = _contracts[name];
        _contracts[name] = newAddress;
        
        emit ContractUpdated(name, oldAddress, newAddress);
    }

    /**
     * @notice Removes a contract from the registry
     * @dev Only callers authorized by RaylsAccessManager can remove contracts
     * @param name The name of the contract to remove
     *
     * Requirements:
     * - Contract with the given name must be registered
     */
    function removeContract(string memory name)
        external
        restricted
    {
        require(_contracts[name] != address(0), "DeploymentProxyRegistryV1: Contract not registered");

        address oldAddress = _contracts[name];
        delete _contracts[name];

        // Remove the name from the array by replacing it with the last element and then popping
        for (uint i = 0; i < _contractNames.length; i++) {
            if (keccak256(bytes(_contractNames[i])) == keccak256(bytes(name))) {
                _contractNames[i] = _contractNames[_contractNames.length - 1];
                _contractNames.pop();
                break;
            }
        }
        
        emit ContractRemoved(name, oldAddress);
    }

    /**
     * @notice Retrieves the address of a registered contract
     * @dev Returns address(0) if the contract is not found
     * @param name The name of the contract to look up
     * @return The address of the requested contract
     */
    function getContract(string memory name) 
        external 
        view 
        returns (address) 
    {
        return _contracts[name];
    }

    /**
     * @notice Gets a list of all registered contract names
     * @dev Useful for UI interfaces or for iterating through all contracts
     * @return Array containing all contract names currently in the registry
     */
    function getAllContractNames() 
        external 
        view 
        returns (string[] memory) 
    {
        return _contractNames;
    }

    /**
     * @notice Gets all registered contracts with their names and addresses
     * @dev Returns parallel arrays where the address at index i corresponds to the name at index i
     * @return names Array of all contract names
     * @return addresses Array of all contract addresses
     */
    function getAllContracts() 
        external 
        view 
        returns (string[] memory names, address[] memory addresses) 
    {
        uint length = _contractNames.length;
        addresses = new address[](length);
        
        // Fill the addresses array with the addresses corresponding to each name
        for (uint i = 0; i < length; i++) {
            addresses[i] = _contracts[_contractNames[i]];
        }
        
        return (_contractNames, addresses);
    }

    /**
     * @notice Batch registers multiple contracts at once
     * @dev Only callers authorized by RaylsAccessManager can register contracts
     * @param names Array of contract names to register
     * @param contractAddresses Array of contract addresses corresponding to the names
     *
     * Requirements:
     * - Arrays must not be empty
     * - Arrays must have the same length
     * - All individual registration requirements apply to each entry
     */
    function registerContracts(
        string[] memory names,
        address[] memory contractAddresses
    )
        external
        restricted
    {
        require(names.length > 0, "DeploymentProxyRegistryV1: Names array cannot be empty");
        require(names.length == contractAddresses.length, "DeploymentProxyRegistryV1: Arrays must have the same length");

        // Process each contract registration
        for (uint256 i = 0; i < names.length; i++) {
            require(bytes(names[i]).length > 0, "DeploymentProxyRegistryV1: Name cannot be empty");
            require(contractAddresses[i] != address(0), "DeploymentProxyRegistryV1: Invalid contract address");
            require(_contracts[names[i]] == address(0), "DeploymentProxyRegistryV1: Contract name already registered");
            require(contractAddresses[i].code.length > 0, "DeploymentProxyRegistryV1: Contract bytecode is empty");

            _contracts[names[i]] = contractAddresses[i];
            _contractNames.push(names[i]);
            
            emit ContractRegistered(names[i], contractAddresses[i]);
        }
    }

    /**
     * @notice Authorizes a contract upgrade
     * @dev Required by the UUPS pattern. Only callers authorized by RaylsAccessManager can upgrade.
     */
    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(address)
        internal
        view
        override
    {
        _checkCanCall(msg.sender, msg.sig);
    }
}
