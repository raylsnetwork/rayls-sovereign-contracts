// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import '../../rayls-protocol-sdk/RaylsAppV1.sol';
import '../../rayls-protocol-sdk/libraries/SharedObjects.sol';
import "../../rayls-protocol-sdk/Constants.sol";
import {RaylsAccessManaged} from '../../privateHub/AccessControl/RaylsAccessManaged.sol';

contract PNCommunicatorV1 is Initializable, UUPSUpgradeable, RaylsAppV1, RaylsAccessManaged {

    mapping(bytes32 => SharedObjects.CommunicatiorData) private sharedInfos;

    event SharedInfoAdded(bytes32 sharedId, uint256 status, uint256 blockNumber, string message, uint256 index);    
    event SharedInfoRemoved(bytes32 sharedId, uint256 index);

    /// @notice Initializes the contract with the provided endpoint address and access manager
    /// @dev Required by the upgradeable pattern
    /// @param _endpointAddress The address of the endpoint contract
    /// @param authority_ Address of the deployed RaylsAccessManagerV1
    function initialize(address _endpointAddress, address authority_) public virtual initializer {
        __UUPSUpgradeable_init();
         RaylsAppV1.initialize(_endpointAddress);
         resourceId = Constants.RESOURCE_ID_PN_COMMUNICATOR;
        _initializeAuthority(authority_);
    }

    /// @notice Authorizes an upgrade to a new implementation
    /// @dev Required override for UUPSUpgradeable. Can only be called by the owner
    /// @param _newImplementation Address of the new implementation contract
    function _authorizeUpgrade(address _newImplementation) virtual internal override {
        _checkCanCall(msg.sender, msg.sig);
    }

    /// @notice Adds a new shared information entry for a specific ID
    /// @dev Creates a new SharedInfo struct and appends it to the array
    /// @param _sharedId The unique identifier for the shared information
    /// @param _status The status value to store
    /// @param _context The context value to store
    /// @param _message The message to store
    function addSharedInfo(bytes32 _sharedId, uint256 _status, uint256 _context, string memory _message) virtual external restricted {
        SharedObjects.CommunicatiorDataHistory memory newHistory = SharedObjects.CommunicatiorDataHistory({
            status: _status,
            blockNumber: block.number,
            message: _message
        });
        
        if (sharedInfos[_sharedId].History.length == 0) {
            sharedInfos[_sharedId].context = _context;
        }
        
        sharedInfos[_sharedId].History.push(newHistory);
        
        emit SharedInfoAdded(_sharedId, _status, block.number, _message, sharedInfos[_sharedId].History.length - 1);
    }
   

    /// @notice Retrieves all shared information entries for a given ID
    /// @dev Returns the entire array of SharedInfo structs
    /// @param _sharedId The unique identifier for the shared information
    /// @return context The context value stored
    /// @return Array of SharedInfo structs 
    function getAllSharedInfo(bytes32 _sharedId) virtual external view returns (uint256 context, SharedObjects.CommunicatiorDataHistory[] memory) {
        return (sharedInfos[_sharedId].context, sharedInfos[_sharedId].History);
    }
    
    /// @notice Retrieves a specific shared information entry at the given index
    /// @dev Returns the status, blockNumber, message and context for the specified entry
    /// @param _sharedId The unique identifier for the shared information
    /// @param _index The position in the array to retrieve
    /// @return status The status value stored
    /// @return blockNumber The block number when the entry was last updated
    /// @return message The message stored
    /// @return context The context value stored
    function getSharedInfoAt(bytes32 _sharedId, uint256 _index) virtual external view returns (uint256 status, uint256 blockNumber, string memory message, uint256 context) {
        require(_index < sharedInfos[_sharedId].History.length, "Index out of bounds");
        
        SharedObjects.CommunicatiorDataHistory memory info = sharedInfos[_sharedId].History[_index];
        return (info.status, info.blockNumber, info.message, sharedInfos[_sharedId].context);
    }

    /// @notice Retrieves the most recent shared information entry for a given ID
    /// @dev For compatibility with previous versions, returns the last entry in the array
    /// @param _sharedId The unique identifier for the shared information
    /// @return status The status value stored
    /// @return blockNumber The block number when the entry was last updated
    /// @return message The message stored
    /// @return context The context value stored
    function getSharedInfo(bytes32 _sharedId) virtual external view returns (uint256 status, uint256 blockNumber, string memory message, uint256 context) {
        require(sharedInfos[_sharedId].History.length > 0, "No shared info exists");
        
        SharedObjects.CommunicatiorDataHistory memory info = sharedInfos[_sharedId].History[sharedInfos[_sharedId].History.length - 1];
        return (info.status, info.blockNumber, info.message, sharedInfos[_sharedId].context);
    }

    /// @notice Checks if any shared information exists for a given ID
    /// @dev Returns true if the array has at least one entry
    /// @param _sharedId The unique identifier to check
    /// @return Boolean indicating whether any shared information exists
    function hasSharedInfo(bytes32 _sharedId) virtual external view returns (bool) {
        return sharedInfos[_sharedId].History.length > 0;
    }
    
    /// @notice Gets the number of shared information entries for a given ID
    /// @dev Returns the length of the array for the specified ID
    /// @param _sharedId The unique identifier to check
    /// @return The count of entries for the given ID
    function getSharedInfoCount(bytes32 _sharedId) virtual external view returns (uint256) {
        return sharedInfos[_sharedId].History.length;
    }

    /// @notice Removes a specific shared information entry at the given index
    /// @dev Replaces the entry at the specified index with the last entry and then removes the last entry
    /// @param _sharedId The unique identifier for the shared information
    /// @param _index The position in the array to remove
    function removeSharedInfoAt(bytes32 _sharedId, uint256 _index) virtual external restricted {
        require(_index < sharedInfos[_sharedId].History.length, "Index out of bounds");
        
        if (_index < sharedInfos[_sharedId].History.length - 1) {
            sharedInfos[_sharedId].History[_index] = sharedInfos[_sharedId].History[sharedInfos[_sharedId].History.length - 1];
        }
        
        sharedInfos[_sharedId].History.pop();
        
        emit SharedInfoRemoved(_sharedId, _index);
    }

    /// @notice Removes all shared information entries for a given ID
    /// @dev For compatibility with previous versions, deletes the entire array
    /// @param _sharedId The unique identifier for the shared information to remove
    function removeSharedInfo(bytes32 _sharedId) virtual external restricted {
        delete sharedInfos[_sharedId];
    }

    /// @notice Returns the version of the contract
    /// @dev Used to identify contract version for upgrades
    /// @return The version number as an unsigned integer
    function contractVersion() external pure virtual returns (uint256) {
        return 1;
    }
}
