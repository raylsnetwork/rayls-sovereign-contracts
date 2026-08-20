// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '../../rayls-protocol-sdk/RaylsAppV1.sol';
import '../../rayls-protocol-sdk/Constants.sol';
import '../../privateHub/ParticipantStorage/libraries/ParticipantStructs.sol';
import '../../privateHub/ParticipantStorage/interfaces/IParticipantStorage.sol';
import './../interfaces/IParticipantValidator.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import '../../privateHub/AccessControl/RaylsAccessManaged.sol';

/**
 * @title ParticipantStorageReplica
 * @dev Smart contract to replicate the participants registered on private hub into Privacy Nodes.
 */
contract ParticipantStorageReplicaV1 is Initializable, RaylsAppV1, IParticipantValidator, UUPSUpgradeable, RaylsAccessManaged {
    error ParticipantStorageReplicaV1__ParticipantNotRegistered(uint256 chainId);
    error ParticipantStorageReplicaV1__ParticipantNotActive(uint256 chainId);
    error ParticipantStorageReplicaV1__NotFromPrivateHub(uint256 fromChainId, uint256 hubId);

    // Array of participants
    ParticipantStructs.Participant[] internal participants;
    // Array of registered chainIds
    uint256[] internal registeredChainIds;
    // Mapping of chainId to index in the participants array + 1
    mapping(uint256 => uint256) internal chainIdToIndex;

    function initialize(address _endpoint, address authority_) public initializer {
        __UUPSUpgradeable_init();
        RaylsAppV1.initialize(_endpoint);
        resourceId = Constants.RESOURCE_ID_PARTICIPANT_STORAGE;
        _initializeAuthority(authority_);
    }

    /**
     * @dev Add multiple Participants
     * @param _participants Array of Participants structs to add
     */
    function addOrUpdateParticipants(ParticipantStructs.Participant[] memory _participants) external virtual restricted {
        // Only the PNH can sync participant data to this PN.
        // fromChainId is appended to calldata by MessageLib.executeMessage().
        uint256 fromChainId = _getFromChainIdOnReceiveMethod();
        uint256 hubId = endpoint.getPrivateHubId();
        if (fromChainId != hubId) {
            revert ParticipantStorageReplicaV1__NotFromPrivateHub(fromChainId, hubId);
        }

        for (uint256 i = 0; i < _participants.length; i++) {
            _addOrUpdateParticipant(_participants[i]);
        }
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(address newImplementation) internal override {
        _checkCanCall(msg.sender, msg.sig);
    }

    /**
     * @dev Internal abstraction function to add or udpate a participant
     * @param _participant Participant struct to add
     */
    function _addOrUpdateParticipant(ParticipantStructs.Participant memory _participant) internal virtual {
        uint256 chainId = _participant.chainId;
        uint256 index = chainIdToIndex[chainId];

        if (index == 0) {
            participants.push(_participant);
            registeredChainIds.push(chainId);
            chainIdToIndex[chainId] = participants.length;
        } else {
            uint256 parsedIndex = index - 1;
            participants[parsedIndex] = _participant;
        }
    }

    /**
     * @dev Function to validate both message participants
     * @param originChainId ChainId of the message origin participant
     * @param destinationChainId ChainId of the message destination participant
     */
    function validateMessageParticipants(uint256 originChainId, uint256 destinationChainId) public view virtual {
        if (destinationChainId == endpoint.getPrivateHubId()) return;
        _validateParticipantStatus(originChainId);
        _validateParticipantStatus(destinationChainId);
    }

    /**
     * @dev Function to validate a single participant status
     * @param chainId ChainId of the participant to validate
     */
    function validateParticipantStatus(uint256 chainId) public view virtual {
        if (chainId == endpoint.getPrivateHubId()) return;
        _validateParticipantStatus(chainId);
    }

    /**
     * @dev Internal abstraction function to validate a participant given a chainId
     * @param chainId ChainId of the participant to validate
     */
    function _validateParticipantStatus(uint256 chainId) internal view virtual {
        if (chainId == 0) return;
        uint256 index = chainIdToIndex[chainId];
        if (index == 0) revert ParticipantStorageReplicaV1__ParticipantNotRegistered(chainId);
        uint256 parsedIndex = index - 1;
        if (participants[parsedIndex].status != ParticipantStructs.Status.ACTIVE) {
            revert ParticipantStorageReplicaV1__ParticipantNotActive(chainId);
        }
    }

    /**
     * @dev Sends a message to private hub requesting all participant data
     */
    function requestAllParticipantsDataFromPrivateHub() public virtual {
        BridgedTransferMetadata memory emptyMetadata;
        _raylsSendToResourceId(
            endpoint.getPrivateHubId(),
            resourceId,
            abi.encodeWithSelector(IParticipantStorage.broadcastCurrentParticipants.selector),
            bytes(''),
            bytes(''),
            bytes(''),
            emptyMetadata
        );
    }

    function getAllParticipants() external view virtual returns (ParticipantStructs.Participant[] memory) {
        return participants;
    }

    ///@dev returns the contract version
    function contractVersion() external pure virtual returns (uint256) {
        return 1;
    }
}
