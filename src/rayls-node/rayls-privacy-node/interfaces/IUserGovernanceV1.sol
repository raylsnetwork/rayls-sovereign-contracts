// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.10;

interface IUserGovernance {
    
    enum ApprovalStatus {
        PENDING,
        APPROVED,
        REJECTED
    }
    
    struct AddressPair {
        address publicAddress;
        address privateAddress;
        uint256 createdAt;
        bool isActive;
        ApprovalStatus approvalStatus;
    }
    
    event UserCreated(bytes32 indexed userId);
    event UserRemoved(bytes32 indexed userId);
    event AddressPairAdded(bytes32 indexed userId, address indexed publicAddress, address indexed privateAddress);
    event AddressPairRemoved(bytes32 indexed userId, address indexed publicAddress, address indexed privateAddress);
    event AddressPairApprovalChanged(bytes32 indexed userId, address indexed publicAddress, address indexed privateAddress, ApprovalStatus oldStatus, ApprovalStatus newStatus);
    
    function createUser(bytes32 userId) external;
    
    function addAddressPair(
        bytes32 userId,
        address publicAddress,
        address privateAddress
    ) external;
    
    function removeAddressPair(
        bytes32 userId,
        address publicAddress,
        address privateAddress
    ) external;
    
    
    function approveUser(bytes32 userId) external;
    
    function rejectUser(bytes32 userId) external;
    
    function setAddressPairApprovalStatus(
        bytes32 userId,
        address publicAddress,
        address privateAddress,
        ApprovalStatus newStatus
    ) external;
    
    function removeUser(bytes32 userId) external;
    
    function getUserIdByPublicAddress(address publicAddress) external view returns (bytes32);
    
    function getUserIdByPrivateAddress(address privateAddress) external view returns (bytes32);
    
    function getUserAddressPairs(bytes32 userId) external view returns (AddressPair[] memory);
    
    function getActiveAddressPairs(bytes32 userId) external view returns (AddressPair[] memory);
    
    function getPublicAddressFromPrivate(address privateAddress) external view returns (address);
    
    function getPrivateAddressFromPublic(address publicAddress) external view returns (address);
    
    function getAllUsers() external view returns (bytes32[] memory);
    
    function getUserCount() external view returns (uint256);
    
    function isAddressPairActive(bytes32 userId, address publicAddress, address privateAddress) external view returns (bool);
    
    function hasUser(bytes32 userId) external view returns (bool);
    
    function getUserAddressPairCount(bytes32 userId) external view returns (uint256);
    
    function getActiveAddressPairCount(bytes32 userId) external view returns (uint256);
    
    function isPublicAddressMapped(address publicAddress) external view returns (bool);
    
    function isPrivateAddressMapped(address privateAddress) external view returns (bool);
    
    function getAddressPairsByApprovalStatus(bytes32 userId, ApprovalStatus status) external view returns (AddressPair[] memory);
    
    function getPendingAddressPairs(bytes32 userId) external view returns (AddressPair[] memory);
    
    function getApprovedAddressPairs(bytes32 userId) external view returns (AddressPair[] memory);
    
    function getRejectedAddressPairs(bytes32 userId) external view returns (AddressPair[] memory);
    
    function getAllPendingAddressPairs() external view returns (bytes32[] memory, AddressPair[][] memory);
    
    function getAddressPairApprovalStatus(
        bytes32 userId,
        address publicAddress,
        address privateAddress
    ) external view returns (ApprovalStatus);
    
    function isAddressPairApproved(
        bytes32 userId,
        address publicAddress,
        address privateAddress
    ) external view returns (bool);
    
    function getApprovedAddressPairCount(bytes32 userId) external view returns (uint256);
    
    function getPendingAddressPairCount(bytes32 userId) external view returns (uint256);
    
    function checkUserIsApprovedByPrivateAddress(address privateAddress) external view returns (bool);
}