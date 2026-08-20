// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IDeploymentProxyRegistryV1
/// @notice Interface for DeploymentProxyRegistryV1
interface IDeploymentProxyRegistryV1 {
    /// @notice Emitted when a contract is registered
    event ContractRegistered(string indexed name, address indexed contractAddress);
    /// @notice Emitted when a contract is updated
    event ContractUpdated(string indexed name, address indexed oldAddress, address indexed newAddress);
    /// @notice Emitted when a contract is removed
    event ContractRemoved(string indexed name, address indexed contractAddress);

    /// @notice Initializes the contract with the RaylsAccessManager authority
    function initialize(address authority_) external;

    /// @notice Registers a new contract
    function registerContract(string calldata name, address contractAddress) external;

    /// @notice Updates an existing contract address
    function updateContract(string calldata name, address newAddress) external;

    /// @notice Removes a contract from the registry
    function removeContract(string calldata name) external;

    /// @notice Gets the address of a specific contract
    function getContract(string calldata name) external view returns (address);

    /// @notice Gets all registered contract names
    function getAllContractNames() external view returns (string[] memory);

    /// @notice Gets all contracts (names and addresses)
    function getAllContracts() external view returns (string[] memory names, address[] memory addresses);

    /// @notice Registers multiple contracts at once
    function registerContracts(string[] calldata names, address[] calldata contractAddresses) external;
}
