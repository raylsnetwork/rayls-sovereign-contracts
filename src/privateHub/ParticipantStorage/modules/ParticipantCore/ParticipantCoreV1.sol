// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../interfaces/IParticipantCore.sol";
import "../../../../rayls-protocol-sdk/RaylsAppV1.sol";
import "../../../../rayls-protocol-sdk/Constants.sol";
import "../../libraries/ParticipantStructs.sol";
import "../../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import '../../../../rayls-protocol/ParticipantStorageReplica/ParticipantStorageReplicaV1.sol';

/**
 * @title ParticipantCore
 * @dev Module that handles core participant management functionality
 */
contract ParticipantCoreV1 is Initializable, IParticipantCore, UUPSUpgradeable, RaylsAccessManaged {
    // Array of participants
    ParticipantStructs.Participant[] internal participants;
    
    // Array of registered chainIds
    uint256[] internal registeredChainIds;
    
    // Mapping of chainId to index in the participants array + 1
    mapping(uint256 => uint256) internal chainIdToIndex;

    // Reference to the endpoint
    IRaylsEndpoint public endpoint;

    // Resource ID
    bytes32 public resourceId;
    
    // Address of the ParticipantStorage contract that can call this module
    address public participantStorageAddress;

    error ParticipantCoreV1__UnauthorizedCaller(address caller);

    /**
     * @dev Modifier to restrict functions to be called only by the ParticipantStorage contract
     */
    modifier onlyParticipantStorage() {
        if (msg.sender != participantStorageAddress) {
            revert ParticipantCoreV1__UnauthorizedCaller(msg.sender);
        }
        _;
    }

    /**
     * @notice Initializes the contract
     * @param _endpoint The endpoint address
     * @param authority_ Address of the deployed RaylsAccessManagerV1.
     */
    function initialize(address _endpoint, address authority_) public initializer {
        __UUPSUpgradeable_init();
        endpoint = IRaylsEndpoint(_endpoint);
        resourceId = Constants.RESOURCE_ID_PARTICIPANT_STORAGE;
        _initializeAuthority(authority_);
    }

    /// @dev Upgrade authorization is gated by the access manager (ADMIN required).
    function _authorizeUpgrade(address /*newImplementation*/) internal override {
        _checkCanCall(msg.sender, msg.sig);
    }

    /**
     * @dev Update the ParticipantStorage address
     * @param _participantStorageAddress The new ParticipantStorage address
     */
    function setParticipantStorageAddress(address _participantStorageAddress) external restricted {
        require(_participantStorageAddress != address(0), "ParticipantCore: ParticipantStorage address cannot be zero");
        participantStorageAddress = _participantStorageAddress;
    }

    /**
     * @inheritdoc IParticipantCore
     */
    function getParticipant(uint256 chainId) external view override returns (ParticipantStructs.Participant memory) {
        return getParticipantByChainId(chainId);
    }

    /**
     * @inheritdoc IParticipantCore
     */
    function getAllParticipantsChainIds() external view override returns (uint256[] memory) {
        return registeredChainIds;
    }

    /**
     * @inheritdoc IParticipantCore
     */
    function getAllParticipants() external view override returns (ParticipantStructs.Participant[] memory) {
        return participants;
    }

    /**
     * @inheritdoc IParticipantCore
     */
    function addParticipant(ParticipantStructs.ParticipantData memory _participant) external override onlyParticipantStorage {
        _addParticipant(_participant);
    }

    /**
     * @inheritdoc IParticipantCore
     */
    function addParticipants(ParticipantStructs.ParticipantData[] memory _participants) external override onlyParticipantStorage {
        for (uint256 i = 0; i < _participants.length; i++) {
            _addParticipant(_participants[i]);
        }
    }

    /**
     * @inheritdoc IParticipantCore
     */
    function updateStatus(uint256 chainId, ParticipantStructs.Status status) public override onlyParticipantStorage {
        ParticipantStructs.Participant storage participant = getParticipantByChainId(chainId);

        if (participant.status == status) {
            revert("ParticipantCore: Status already set");
        }

        ParticipantStructs.Participant memory parsedParticipant = ParticipantStructs.Participant({
            chainId: chainId,
            status: status,
            role: participant.role,
            ownerId: participant.ownerId,
            name: participant.name,
            createdAt: participant.createdAt,
            updatedAt: block.timestamp,
            allowedToBroadcast: participant.allowedToBroadcast
        });

        _addOrUpdateParticipant(parsedParticipant);
    }

    /**
     * @inheritdoc IParticipantCore
     */
    function updateRole(uint256 chainId, ParticipantStructs.Role role) external override onlyParticipantStorage {
        ParticipantStructs.Participant storage participant = getParticipantByChainId(chainId);

        if (participant.role == role) {
            revert("ParticipantCore: Role already set");
        }

        ParticipantStructs.Participant memory parsedParticipant = ParticipantStructs.Participant({
            chainId: chainId,
            status: participant.status,
            role: role,
            ownerId: participant.ownerId,
            name: participant.name,
            createdAt: participant.createdAt,
            updatedAt: block.timestamp,
            allowedToBroadcast: participant.allowedToBroadcast
        });

        _addOrUpdateParticipant(parsedParticipant);
    }

    /**
     * @inheritdoc IParticipantCore
     */
    function updateBroadcastMessagesPermission(uint256 chainId, bool allowed) public override onlyParticipantStorage {
        ParticipantStructs.Participant storage participant = getParticipantByChainId(chainId);

        require(participant.allowedToBroadcast != allowed, 'ParticipantCore: Broadcast permission already set to requested value');

        ParticipantStructs.Participant memory parsedParticipant = ParticipantStructs.Participant({
            chainId: chainId,
            status: participant.status,
            role: participant.role,
            ownerId: participant.ownerId,
            name: participant.name,
            createdAt: participant.createdAt,
            updatedAt: block.timestamp,
            allowedToBroadcast: allowed
        });

        _addOrUpdateParticipant(parsedParticipant);
    }

    /**
     * @inheritdoc IParticipantCore
     */
    function removeParticipant(uint256 chainId) external override onlyParticipantStorage {
        updateStatus(chainId, ParticipantStructs.Status.INACTIVE);
    }

    /**
     * @inheritdoc IParticipantCore
     */
    function verifyParticipant(uint256 chainId) public view override returns (bool) {
        uint256 index = chainIdToIndex[chainId];

        if (index == 0) {
            return false;
        }
        uint256 parsedIndex = index - 1;

        if (participants[parsedIndex].status != ParticipantStructs.Status.ACTIVE) {
            return false;
        }

        return true;
    }

    /**
     * @inheritdoc IParticipantCore
     */
    function validateMessageParticipants(uint256 originChainId, uint256 destinationChainId) public view override {
        if (originChainId == endpoint.getPrivateHubId()) return;
        if (destinationChainId == endpoint.getPrivateHubId()) return;
        _validateParticipantStatus(originChainId);
        _validateParticipantStatus(destinationChainId);
    }

    /**
     * @inheritdoc IParticipantCore
     */
    function validateParticipantStatus(uint256 chainId) public view override {
        if (chainId == endpoint.getPrivateHubId()) return;
        _validateParticipantStatus(chainId);
    }

    /**
     * @inheritdoc IParticipantCore
     */
    function broadcastCurrentParticipants(uint256 fromChainId) public override onlyParticipantStorage {
        BridgedTransferMetadata memory emptyMetadata;
        
        _raylsSendToResourceId(
            fromChainId,
            resourceId,
            abi.encodeWithSelector(ParticipantStorageReplicaV1.addOrUpdateParticipants.selector, participants),
            bytes(""),
            bytes(""),
            bytes(""),
            emptyMetadata
        );
    }

    /**
     * @dev Internal function to add a participant
     * @param _participant Participant data to add
     */
    function _addParticipant(ParticipantStructs.ParticipantData memory _participant) internal {
        uint256 chainId = _participant.chainId;
        bool participantExists = verifyParticipant(chainId);

        if (participantExists) {
            revert("ParticipantCore: Participant already exists");
        }

        require(chainId != 0, "ParticipantCore: Chain ID cannot be 0");

        ParticipantStructs.Participant memory parsedParticipant = ParticipantStructs.Participant({
            chainId: chainId,
            status: ParticipantStructs.Status.NEW,
            role: _participant.role,
            ownerId: _participant.ownerId,
            name: _participant.name,
            createdAt: block.timestamp,
            updatedAt: block.timestamp,
            allowedToBroadcast: _participant.allowedToBroadcast
        });

        _addOrUpdateParticipant(parsedParticipant);
    }

    /**
     * @dev Internal function to add or update a participant
     * @param _participant Participant data to add or update
     */
    function _addOrUpdateParticipant(ParticipantStructs.Participant memory _participant) internal {
        uint256 chainId = _participant.chainId;
        uint256 index = chainIdToIndex[chainId];

        if (index == 0) {
            participants.push(_participant);
            registeredChainIds.push(chainId);
            chainIdToIndex[chainId] = participants.length;
            emit ParticipantRegistered(_participant);
        } else {
            uint256 parsedIndex = index - 1;
            participants[parsedIndex] = _participant;
            emit ParticipantUpdated(_participant);
        }

        _broadCastParticipant(_participant);
    }

    /**
     * @dev Internal function to broadcast a participant to all participants
     * @param _participant Participant data to broadcast
     */
    function _broadCastParticipant(ParticipantStructs.Participant memory _participant) internal {
        BridgedTransferMetadata memory emptyMetadata;

        ParticipantStructs.Participant[] memory _crossChainRequest = new ParticipantStructs.Participant[](1);
        _crossChainRequest[0] = _participant;
        
        _raylsSendToResourceId(
            Constants.CHAIN_ID_ALL_PARTICIPANTS,
            resourceId,
            abi.encodeWithSelector(ParticipantStorageReplicaV1.addOrUpdateParticipants.selector, _crossChainRequest),
            bytes(""),
            bytes(""),
            bytes(""),
            emptyMetadata
        );
    }

    /**
     * @dev Internal function to validate a participant's status
     * @param chainId Chain ID of the participant to validate
     */
    function _validateParticipantStatus(uint256 chainId) internal view {
        if (chainId == 0) return;
        uint256 index = chainIdToIndex[chainId];
        require(index > 0, "ParticipantCore: Participant not registered");
        uint256 parsedIndex = index - 1;
        require(
            participants[parsedIndex].status == ParticipantStructs.Status.ACTIVE,
            "ParticipantCore: Participant not in an active status"
        );
    }

    /**
     * @dev Internal function to get a participant by chain ID
     * @param chainId Chain ID of the participant to get
     * @return The participant data
     */
    function getParticipantByChainId(uint256 chainId) internal view returns (ParticipantStructs.Participant storage) {
        uint256 index = chainIdToIndex[chainId];
        require(index > 0, "ParticipantCore: Participant not registered");

        // -1 to get the correct index
        uint256 parsedIndex = index - 1;

        return participants[parsedIndex];
    }
    

    /**
     * @dev Helper function to send a message to a resource ID
     * @param _dstChainId The destination chain ID
     * @param _resourceId The resource ID
     * @param _payload The payload
     * @param _lockData Lock data
     * @param _revertDataSender Revert data for the sender
     * @param _revertDataReceiver Revert data for the receiver
     * @param transferMetadata Transfer metadata
     * @return The message ID
     */
    function _raylsSendToResourceId(
        uint256 _dstChainId,
        bytes32 _resourceId,
        bytes memory _payload,
        bytes memory _lockData,
        bytes memory _revertDataSender,
        bytes memory _revertDataReceiver,
        BridgedTransferMetadata memory transferMetadata
    ) internal returns (bytes32) {
        return endpoint.sendToResourceId(
            _dstChainId,
            _resourceId,
            _payload,
            _lockData,
            _revertDataSender,
            _revertDataReceiver,
            transferMetadata
        );
    }

    /**
     * @dev Returns the contract version
     * @return The version number (1) of this contract implementation
     */
    function contractVersion() external pure virtual returns (uint256) {
        return 1;
    }
} 