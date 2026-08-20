// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {IUserGovernance} from "./interfaces/IUserGovernanceV1.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {RaylsAccessManaged} from "../../privateHub/AccessControl/RaylsAccessManaged.sol";

/**
 * @title RNUserGovernanceV1
 * @notice User governance contract for managing address pairs between public and private chains
 * @dev Uses ERC-7201 namespaced storage pattern for upgradeability.
 *      Governance functions are gated by RaylsAccessManagerV1 via the `restricted` modifier.
 */
contract RNUserGovernanceV1 is Initializable, UUPSUpgradeable, RaylsAccessManaged, IUserGovernance {

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error RNUserGovernanceV1__InvalidUserId();
    error RNUserGovernanceV1__UserAlreadyExists();
    error RNUserGovernanceV1__UserDoesNotExist();
    error RNUserGovernanceV1__InvalidPublicAddress();
    error RNUserGovernanceV1__InvalidPrivateAddress();
    error RNUserGovernanceV1__PublicAddressAlreadyMapped();
    error RNUserGovernanceV1__PrivateAddressAlreadyMapped();
    error RNUserGovernanceV1__PublicAddressNotMappedToUser();
    error RNUserGovernanceV1__PrivateAddressNotMappedToUser();
    error RNUserGovernanceV1__UserHasNoAddressPairs();
    error RNUserGovernanceV1__AddressPairNotFound();
    error RNUserGovernanceV1__PrivateAddressNotMapped();
    error RNUserGovernanceV1__PublicAddressNotMapped();
    error RNUserGovernanceV1__AddressPairByPrivateKeyNotFound();

    /*//////////////////////////////////////////////////////////////
                          TYPE DECLARATIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Internal contract storage for UserGovernance
     * @custom:storage-location erc7201:rayls.usergovernance.UserGovernance
     */
    struct UserGovernanceStorage {
        mapping(bytes32 => IUserGovernance.AddressPair[]) userAddressPairs;
        mapping(address => bytes32) publicAddressToUserId;
        mapping(address => bytes32) privateAddressToUserId;
        mapping(bytes32 => bool) userExists;
        bytes32[] userIds;
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @dev keccak256(abi.encode(uint256(keccak256(bytes("rayls.usergovernance.UserGovernance"))) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant USER_GOVERNANCE_STORAGE = 0xe2b86e7bc31042496c32365d0dfa6ad28cbfffada4949d485907b1975509dd00;

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTORS
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the User Governance contract.
     * @param authority_ Address of the deployed RaylsAccessManagerV1.
     */
    function initialize(address authority_) public initializer {
        __UUPSUpgradeable_init();
        _initializeAuthority(authority_);
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates a new user
     * @param userId Unique identifier for the user
     */
    function createUser(bytes32 userId) external restricted {
        UserGovernanceStorage storage $ = _getStorage();
        if (userId == bytes32(0)) revert RNUserGovernanceV1__InvalidUserId();
        if ($.userExists[userId]) revert RNUserGovernanceV1__UserAlreadyExists();

        $.userExists[userId] = true;
        $.userIds.push(userId);

        emit UserCreated(userId);
    }

    /**
     * @notice Adds an address pair for a user
     * @param userId User identifier
     * @param publicAddress Public chain address
     * @param privateAddress Private chain address
     */
    function addAddressPair(
        bytes32 userId,
        address publicAddress,
        address privateAddress
    ) external restricted {
        UserGovernanceStorage storage $ = _getStorage();
        if (!$.userExists[userId]) revert RNUserGovernanceV1__UserDoesNotExist();
        if (publicAddress == address(0)) revert RNUserGovernanceV1__InvalidPublicAddress();
        if (privateAddress == address(0)) revert RNUserGovernanceV1__InvalidPrivateAddress();
        if ($.publicAddressToUserId[publicAddress] != bytes32(0)) revert RNUserGovernanceV1__PublicAddressAlreadyMapped();
        if ($.privateAddressToUserId[privateAddress] != bytes32(0)) revert RNUserGovernanceV1__PrivateAddressAlreadyMapped();

        IUserGovernance.AddressPair memory newPair = IUserGovernance.AddressPair({
            publicAddress: publicAddress,
            privateAddress: privateAddress,
            createdAt: block.timestamp,
            isActive: false,
            approvalStatus: IUserGovernance.ApprovalStatus.PENDING
        });

        $.userAddressPairs[userId].push(newPair);
        $.publicAddressToUserId[publicAddress] = userId;
        $.privateAddressToUserId[privateAddress] = userId;

        emit AddressPairAdded(userId, publicAddress, privateAddress);
    }

    /**
     * @notice Removes an address pair from a user
     * @param userId User identifier
     * @param publicAddress Public chain address to remove
     * @param privateAddress Private chain address to remove
     */
    function removeAddressPair(
        bytes32 userId,
        address publicAddress,
        address privateAddress
    ) external restricted {
        UserGovernanceStorage storage $ = _getStorage();
        if (!$.userExists[userId]) revert RNUserGovernanceV1__UserDoesNotExist();
        if ($.publicAddressToUserId[publicAddress] != userId) revert RNUserGovernanceV1__PublicAddressNotMappedToUser();
        if ($.privateAddressToUserId[privateAddress] != userId) revert RNUserGovernanceV1__PrivateAddressNotMappedToUser();

        IUserGovernance.AddressPair[] storage pairs = $.userAddressPairs[userId];
        uint256 pairsLength = pairs.length;
        for (uint256 i = 0; i < pairsLength; i++) {
            if (pairs[i].publicAddress == publicAddress && pairs[i].privateAddress == privateAddress) {
                pairs[i] = pairs[pairsLength - 1];
                pairs.pop();
                break;
            }
        }

        delete $.publicAddressToUserId[publicAddress];
        delete $.privateAddressToUserId[privateAddress];

        emit AddressPairRemoved(userId, publicAddress, privateAddress);
    }

    /**
     * @notice Approves all pending address pairs for a user
     * @param userId User identifier
     */
    function approveUser(bytes32 userId) external restricted {
        UserGovernanceStorage storage $ = _getStorage();
        if (!$.userExists[userId]) revert RNUserGovernanceV1__UserDoesNotExist();

        IUserGovernance.AddressPair[] storage pairs = $.userAddressPairs[userId];
        uint256 pairsLength = pairs.length;
        if (pairsLength == 0) revert RNUserGovernanceV1__UserHasNoAddressPairs();

        for (uint256 i = 0; i < pairsLength; i++) {
            if (pairs[i].approvalStatus == IUserGovernance.ApprovalStatus.PENDING) {
                IUserGovernance.ApprovalStatus oldStatus = pairs[i].approvalStatus;
                pairs[i].approvalStatus = IUserGovernance.ApprovalStatus.APPROVED;
                pairs[i].isActive = true;

                emit AddressPairApprovalChanged(userId, pairs[i].publicAddress, pairs[i].privateAddress, oldStatus, IUserGovernance.ApprovalStatus.APPROVED);
            }
        }
    }

    /**
     * @notice Rejects all pending address pairs for a user
     * @param userId User identifier
     */
    function rejectUser(bytes32 userId) external restricted {
        UserGovernanceStorage storage $ = _getStorage();
        if (!$.userExists[userId]) revert RNUserGovernanceV1__UserDoesNotExist();

        IUserGovernance.AddressPair[] storage pairs = $.userAddressPairs[userId];
        uint256 pairsLength = pairs.length;
        if (pairsLength == 0) revert RNUserGovernanceV1__UserHasNoAddressPairs();

        for (uint256 i = 0; i < pairsLength; i++) {
            if (pairs[i].approvalStatus == IUserGovernance.ApprovalStatus.PENDING) {
                IUserGovernance.ApprovalStatus oldStatus = pairs[i].approvalStatus;
                pairs[i].approvalStatus = IUserGovernance.ApprovalStatus.REJECTED;
                pairs[i].isActive = false;

                emit AddressPairApprovalChanged(userId, pairs[i].publicAddress, pairs[i].privateAddress, oldStatus, IUserGovernance.ApprovalStatus.REJECTED);
            }
        }
    }

    /**
     * @notice Sets the approval status for a specific address pair
     * @param userId User identifier
     * @param publicAddress Public chain address
     * @param privateAddress Private chain address
     * @param newStatus New approval status
     */
    function setAddressPairApprovalStatus(
        bytes32 userId,
        address publicAddress,
        address privateAddress,
        IUserGovernance.ApprovalStatus newStatus
    ) external restricted {
        UserGovernanceStorage storage $ = _getStorage();
        if (!$.userExists[userId]) revert RNUserGovernanceV1__UserDoesNotExist();
        if ($.publicAddressToUserId[publicAddress] != userId) revert RNUserGovernanceV1__PublicAddressNotMappedToUser();
        if ($.privateAddressToUserId[privateAddress] != userId) revert RNUserGovernanceV1__PrivateAddressNotMappedToUser();

        IUserGovernance.AddressPair[] storage pairs = $.userAddressPairs[userId];
        uint256 pairsLength = pairs.length;
        for (uint256 i = 0; i < pairsLength; i++) {
            if (pairs[i].publicAddress == publicAddress && pairs[i].privateAddress == privateAddress) {
                IUserGovernance.ApprovalStatus oldStatus = pairs[i].approvalStatus;
                pairs[i].approvalStatus = newStatus;

                if (newStatus == IUserGovernance.ApprovalStatus.APPROVED) {
                    pairs[i].isActive = true;
                } else {
                    pairs[i].isActive = false;
                }

                emit AddressPairApprovalChanged(userId, publicAddress, privateAddress, oldStatus, newStatus);
                return;
            }
        }

        revert RNUserGovernanceV1__AddressPairNotFound();
    }

    /**
     * @notice Removes a user and all associated address pairs
     * @param userId User identifier to remove
     */
    function removeUser(bytes32 userId) external restricted {
        UserGovernanceStorage storage $ = _getStorage();
        if (!$.userExists[userId]) revert RNUserGovernanceV1__UserDoesNotExist();

        IUserGovernance.AddressPair[] storage pairs = $.userAddressPairs[userId];
        uint256 pairsLength = pairs.length;
        for (uint256 i = 0; i < pairsLength; i++) {
            delete $.publicAddressToUserId[pairs[i].publicAddress];
            delete $.privateAddressToUserId[pairs[i].privateAddress];
        }
        delete $.userAddressPairs[userId];

        uint256 userIdsLength = $.userIds.length;
        for (uint256 i = 0; i < userIdsLength; i++) {
            if ($.userIds[i] == userId) {
                $.userIds[i] = $.userIds[userIdsLength - 1];
                $.userIds.pop();
                break;
            }
        }

        delete $.userExists[userId];

        emit IUserGovernance.UserRemoved(userId);
    }

    /*//////////////////////////////////////////////////////////////
                    EXTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function userAddressPairs(bytes32 userId) external view returns (IUserGovernance.AddressPair[] memory) {
        return _getStorage().userAddressPairs[userId];
    }

    function publicAddressToUserId(address publicAddress) external view returns (bytes32) {
        return _getStorage().publicAddressToUserId[publicAddress];
    }

    function privateAddressToUserId(address privateAddress) external view returns (bytes32) {
        return _getStorage().privateAddressToUserId[privateAddress];
    }

    function userExists(bytes32 userId) external view returns (bool) {
        return _getStorage().userExists[userId];
    }

    function userIds(uint256 index) external view returns (bytes32) {
        return _getStorage().userIds[index];
    }

    function getUserIdByPublicAddress(address publicAddress) external view returns (bytes32) {
        return _getStorage().publicAddressToUserId[publicAddress];
    }

    function getUserIdByPrivateAddress(address privateAddress) external view returns (bytes32) {
        return _getStorage().privateAddressToUserId[privateAddress];
    }

    function getUserAddressPairs(bytes32 userId) external view returns (IUserGovernance.AddressPair[] memory) {
        UserGovernanceStorage storage $ = _getStorage();
        if (!$.userExists[userId]) revert RNUserGovernanceV1__UserDoesNotExist();
        return $.userAddressPairs[userId];
    }

    function getActiveAddressPairs(bytes32 userId) external view returns (IUserGovernance.AddressPair[] memory) {
        UserGovernanceStorage storage $ = _getStorage();
        if (!$.userExists[userId]) revert RNUserGovernanceV1__UserDoesNotExist();

        IUserGovernance.AddressPair[] memory allPairs = $.userAddressPairs[userId];
        uint256 allPairsLength = allPairs.length;
        uint256 activeCount = 0;

        for (uint256 i = 0; i < allPairsLength; i++) {
            if (allPairs[i].isActive) activeCount++;
        }

        IUserGovernance.AddressPair[] memory activePairs = new IUserGovernance.AddressPair[](activeCount);
        uint256 index = 0;

        for (uint256 i = 0; i < allPairsLength; i++) {
            if (allPairs[i].isActive) {
                activePairs[index] = allPairs[i];
                index++;
            }
        }

        return activePairs;
    }

    function getPublicAddressFromPrivate(address privateAddress) external view returns (address) {
        UserGovernanceStorage storage $ = _getStorage();
        bytes32 userId = $.privateAddressToUserId[privateAddress];
        if (userId == bytes32(0)) revert RNUserGovernanceV1__PrivateAddressNotMapped();

        IUserGovernance.AddressPair[] memory pairs = $.userAddressPairs[userId];
        uint256 pairsLength = pairs.length;
        for (uint256 i = 0; i < pairsLength; i++) {
            if (pairs[i].privateAddress == privateAddress &&
                pairs[i].isActive &&
                pairs[i].approvalStatus == IUserGovernance.ApprovalStatus.APPROVED) {
                return pairs[i].publicAddress;
            }
        }

        return address(0);
    }

    function getPrivateAddressFromPublic(address publicAddress) external view returns (address) {
        UserGovernanceStorage storage $ = _getStorage();
        bytes32 userId = $.publicAddressToUserId[publicAddress];
        if (userId == bytes32(0)) revert RNUserGovernanceV1__PublicAddressNotMapped();

        IUserGovernance.AddressPair[] memory pairs = $.userAddressPairs[userId];
        uint256 pairsLength = pairs.length;
        for (uint256 i = 0; i < pairsLength; i++) {
            if (pairs[i].publicAddress == publicAddress &&
                pairs[i].isActive &&
                pairs[i].approvalStatus == IUserGovernance.ApprovalStatus.APPROVED) {
                return pairs[i].privateAddress;
            }
        }

        return address(0);
    }

    function getAllUsers() external view returns (bytes32[] memory) {
        return _getStorage().userIds;
    }

    function getUserCount() external view returns (uint256) {
        return _getStorage().userIds.length;
    }

    function isAddressPairActive(bytes32 userId, address publicAddress, address privateAddress) external view returns (bool) {
        UserGovernanceStorage storage $ = _getStorage();
        if (!$.userExists[userId]) revert RNUserGovernanceV1__UserDoesNotExist();

        IUserGovernance.AddressPair[] memory pairs = $.userAddressPairs[userId];
        uint256 pairsLength = pairs.length;
        for (uint256 i = 0; i < pairsLength; i++) {
            if (pairs[i].publicAddress == publicAddress && pairs[i].privateAddress == privateAddress) {
                return pairs[i].isActive;
            }
        }

        return false;
    }

    function hasUser(bytes32 userId) external view returns (bool) {
        return _getStorage().userExists[userId];
    }

    function getUserAddressPairCount(bytes32 userId) external view returns (uint256) {
        UserGovernanceStorage storage $ = _getStorage();
        if (!$.userExists[userId]) revert RNUserGovernanceV1__UserDoesNotExist();
        return $.userAddressPairs[userId].length;
    }

    function getActiveAddressPairCount(bytes32 userId) external view returns (uint256) {
        UserGovernanceStorage storage $ = _getStorage();
        if (!$.userExists[userId]) revert RNUserGovernanceV1__UserDoesNotExist();

        IUserGovernance.AddressPair[] memory pairs = $.userAddressPairs[userId];
        uint256 pairsLength = pairs.length;
        uint256 count = 0;

        for (uint256 i = 0; i < pairsLength; i++) {
            if (pairs[i].isActive) count++;
        }

        return count;
    }

    function isPublicAddressMapped(address publicAddress) external view returns (bool) {
        return _getStorage().publicAddressToUserId[publicAddress] != bytes32(0);
    }

    function isPrivateAddressMapped(address privateAddress) external view returns (bool) {
        return _getStorage().privateAddressToUserId[privateAddress] != bytes32(0);
    }

    function getAddressPairsByApprovalStatus(bytes32 userId, IUserGovernance.ApprovalStatus status) public view returns (IUserGovernance.AddressPair[] memory) {
        UserGovernanceStorage storage $ = _getStorage();
        if (!$.userExists[userId]) revert RNUserGovernanceV1__UserDoesNotExist();

        IUserGovernance.AddressPair[] memory allPairs = $.userAddressPairs[userId];
        uint256 allPairsLength = allPairs.length;
        uint256 count = 0;

        for (uint256 i = 0; i < allPairsLength; i++) {
            if (allPairs[i].approvalStatus == status) count++;
        }

        IUserGovernance.AddressPair[] memory filteredPairs = new IUserGovernance.AddressPair[](count);
        uint256 index = 0;

        for (uint256 i = 0; i < allPairsLength; i++) {
            if (allPairs[i].approvalStatus == status) {
                filteredPairs[index] = allPairs[i];
                index++;
            }
        }

        return filteredPairs;
    }

    function getPendingAddressPairs(bytes32 userId) public view returns (IUserGovernance.AddressPair[] memory) {
        return getAddressPairsByApprovalStatus(userId, IUserGovernance.ApprovalStatus.PENDING);
    }

    function getApprovedAddressPairs(bytes32 userId) external view returns (IUserGovernance.AddressPair[] memory) {
        return getAddressPairsByApprovalStatus(userId, IUserGovernance.ApprovalStatus.APPROVED);
    }

    function getRejectedAddressPairs(bytes32 userId) external view returns (IUserGovernance.AddressPair[] memory) {
        return getAddressPairsByApprovalStatus(userId, IUserGovernance.ApprovalStatus.REJECTED);
    }

    function getAllPendingAddressPairs() external view returns (bytes32[] memory, IUserGovernance.AddressPair[][] memory) {
        UserGovernanceStorage storage $ = _getStorage();
        uint256 userCount = $.userIds.length;
        bytes32[] memory usersWithPending = new bytes32[](userCount);
        IUserGovernance.AddressPair[][] memory pendingPairs = new IUserGovernance.AddressPair[][](userCount);
        uint256 resultIndex = 0;

        for (uint256 i = 0; i < userCount; i++) {
            IUserGovernance.AddressPair[] memory userPending = getPendingAddressPairs($.userIds[i]);
            if (userPending.length > 0) {
                usersWithPending[resultIndex] = $.userIds[i];
                pendingPairs[resultIndex] = userPending;
                resultIndex++;
            }
        }

        bytes32[] memory trimmedUsers = new bytes32[](resultIndex);
        IUserGovernance.AddressPair[][] memory trimmedPairs = new IUserGovernance.AddressPair[][](resultIndex);

        for (uint256 i = 0; i < resultIndex; i++) {
            trimmedUsers[i] = usersWithPending[i];
            trimmedPairs[i] = pendingPairs[i];
        }

        return (trimmedUsers, trimmedPairs);
    }

    function getAddressPairApprovalStatus(
        bytes32 userId,
        address publicAddress,
        address privateAddress
    ) external view returns (IUserGovernance.ApprovalStatus) {
        UserGovernanceStorage storage $ = _getStorage();
        if (!$.userExists[userId]) revert RNUserGovernanceV1__UserDoesNotExist();

        IUserGovernance.AddressPair[] memory pairs = $.userAddressPairs[userId];
        uint256 pairsLength = pairs.length;
        for (uint256 i = 0; i < pairsLength; i++) {
            if (pairs[i].publicAddress == publicAddress && pairs[i].privateAddress == privateAddress) {
                return pairs[i].approvalStatus;
            }
        }

        revert RNUserGovernanceV1__AddressPairNotFound();
    }

    function isAddressPairApproved(
        bytes32 userId,
        address publicAddress,
        address privateAddress
    ) external view returns (bool) {
        UserGovernanceStorage storage $ = _getStorage();
        if (!$.userExists[userId]) revert RNUserGovernanceV1__UserDoesNotExist();

        IUserGovernance.AddressPair[] memory pairs = $.userAddressPairs[userId];
        uint256 pairsLength = pairs.length;
        for (uint256 i = 0; i < pairsLength; i++) {
            if (pairs[i].publicAddress == publicAddress && pairs[i].privateAddress == privateAddress) {
                return pairs[i].approvalStatus == IUserGovernance.ApprovalStatus.APPROVED;
            }
        }

        return false;
    }

    function getApprovedAddressPairCount(bytes32 userId) external view returns (uint256) {
        UserGovernanceStorage storage $ = _getStorage();
        if (!$.userExists[userId]) revert RNUserGovernanceV1__UserDoesNotExist();

        IUserGovernance.AddressPair[] memory pairs = $.userAddressPairs[userId];
        uint256 pairsLength = pairs.length;
        uint256 count = 0;

        for (uint256 i = 0; i < pairsLength; i++) {
            if (pairs[i].approvalStatus == IUserGovernance.ApprovalStatus.APPROVED) count++;
        }

        return count;
    }

    function getPendingAddressPairCount(bytes32 userId) external view returns (uint256) {
        UserGovernanceStorage storage $ = _getStorage();
        if (!$.userExists[userId]) revert RNUserGovernanceV1__UserDoesNotExist();

        IUserGovernance.AddressPair[] memory pairs = $.userAddressPairs[userId];
        uint256 pairsLength = pairs.length;
        uint256 count = 0;

        for (uint256 i = 0; i < pairsLength; i++) {
            if (pairs[i].approvalStatus == IUserGovernance.ApprovalStatus.PENDING) count++;
        }

        return count;
    }

    function checkUserIsApprovedByPrivateAddress(address privateAddress) external view returns (bool) {
        UserGovernanceStorage storage $ = _getStorage();
        bytes32 userId = $.privateAddressToUserId[privateAddress];
        if (userId == bytes32(0)) revert RNUserGovernanceV1__PrivateAddressNotMapped();

        IUserGovernance.AddressPair[] memory pairs = $.userAddressPairs[userId];
        uint256 pairsLength = pairs.length;
        for (uint256 i = 0; i < pairsLength; i++) {
            if (pairs[i].privateAddress == privateAddress) {
                return pairs[i].approvalStatus == IUserGovernance.ApprovalStatus.APPROVED;
            }
        }

        revert RNUserGovernanceV1__AddressPairByPrivateKeyNotFound();
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Upgrade authorization is gated by the access manager (ADMIN required).
    function _authorizeUpgrade(address /*newImplementation*/) internal override {
        _checkCanCall(msg.sender, msg.sig);
    }

    function _getStorage() internal pure returns (UserGovernanceStorage storage $) {
        assembly {
            $.slot := USER_GOVERNANCE_STORAGE
        }
    }
}
