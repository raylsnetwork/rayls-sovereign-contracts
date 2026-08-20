//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import '../libraries/SharedObjects.sol';

interface IPNCommunicator {
    // SharedInfo struct definition to be used by implementers
 
    /**
     * @dev Adds a new shared information entry for a specific ID
     * @param _sharedId The unique identifier for the shared information
     * @param _status The status value to store
     * @param _context The context value to store
     * @param _message The message to store
     */
    function addSharedInfo(bytes32 _sharedId, uint256 _status, uint256 _context, string memory _message) external;   

    /**
     * @dev Retrieves all shared information entries for a given ID
     * @param _sharedId The unique identifier for the shared information
     * @return context The context value stored
     * @return Array of CommunicatiorDataHistory structs
     */
    function getAllSharedInfo(bytes32 _sharedId) external view returns (uint256 context, SharedObjects.CommunicatiorDataHistory[] memory);

    /**
     * @dev Retrieves a specific shared information entry at the given index
     * @param _sharedId The unique identifier for the shared information
     * @param _index The position in the array to retrieve
     * @return status The status value stored
     * @return blockNumber The block number when the entry was last updated
     * @return message The message stored
     * @return context The context value stored
     */
    function getSharedInfoAt(bytes32 _sharedId, uint256 _index) external view returns (uint256 status, uint256 blockNumber, string memory message, uint256 context);

    /**
     * @dev Retrieves the most recent shared information entry for a given ID
     * @param _sharedId The unique identifier for the shared information
     * @return status The status value stored
     * @return blockNumber The block number when the entry was last updated
     * @return message The message stored
     * @return context The context value stored
     */
    function getSharedInfo(bytes32 _sharedId) external view returns (uint256 status, uint256 blockNumber, string memory message, uint256 context);

    /**
     * @dev Checks if any shared information exists for a given ID
     * @param _sharedId The unique identifier to check
     * @return Boolean indicating whether any shared information exists
     */
    function hasSharedInfo(bytes32 _sharedId) external view returns (bool);

    /**
     * @dev Gets the number of shared information entries for a given ID
     * @param _sharedId The unique identifier to check
     * @return The count of entries for the given ID
     */
    function getSharedInfoCount(bytes32 _sharedId) external view returns (uint256);

    /**
     * @dev Removes a specific shared information entry at the given index
     * @param _sharedId The unique identifier for the shared information
     * @param _index The position in the array to remove
     */
    function removeSharedInfoAt(bytes32 _sharedId, uint256 _index) external;

    /**
     * @dev Removes all shared information entries for a given ID
     * @param _sharedId The unique identifier for the shared information to remove
     */
    function removeSharedInfo(bytes32 _sharedId) external;

    /**
     * @dev Returns the version of the contract
     * @return The version number as an unsigned integer
     */
    function contractVersion() external pure returns (uint256);
}
