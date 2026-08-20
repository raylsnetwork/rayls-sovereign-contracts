// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "../../interfaces/IAuditManager.sol";
import "../../interfaces/IParticipantCore.sol";
import "../../libraries/ParticipantStructs.sol";
import "../../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title AuditManager
 * @dev Module that handles audit information
 */
contract AuditManagerV1 is Initializable, IAuditManager, UUPSUpgradeable, RaylsAccessManaged {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error AuditManagerV1__BlockNumberLowerThanLatestKeyAgreement();
    error AuditManagerV1__UnauthorizedCaller(address caller);
    error AuditManagerV1__ParticipantNotActive(uint256 chainId);
    error AuditManagerV1__BlockNumberLowerThanLatest(uint256 chainId, uint256 provided, uint256 latest);

    /*//////////////////////////////////////////////////////////////
                        STATE VARIABLES, EVENTS
    //////////////////////////////////////////////////////////////*/

    // Mapping of chain ID to audit info data
    mapping(uint256 => ParticipantStructs.AuditInfoData[]) public auditInfoData;
    
    // Mapping of chain ID to privacy node view data
    mapping(uint256 => ParticipantStructs.PrivacyNodeViewData[]) public privacyNodeViewData;
    
    // Mapping of chainID to array of key agreement data
    mapping(uint256 => ParticipantStructs.KeyAgreementData[]) public keyAgreementData;

    // Mapping of pair of chain IDs to the latest key agreement index(+1) for quick lookup
    mapping(uint256 => mapping(uint256 => uint256)) public pairToKeyAgreementIndex;

    // Array of all audit info chain IDs
    uint256[] public allAuditInfoChainIds;
    
    // Array of all privacy node chain IDs
    uint256[] public allPrivacyNodeChainIds;

    // Reference to the ParticipantCore module
    IParticipantCore public participantCore;

    // Address of the parent ParticipantStorage contract
    address public parentStorage;

    modifier onlyParticipantStorage() {
        if (msg.sender != parentStorage) {
            revert AuditManagerV1__UnauthorizedCaller(msg.sender);
        }
        _;
    }

    /**
     * @notice Initializes the contract
     * @param _participantCore The address of the ParticipantCore module
     * @param _parentStorage The address of the ParticipantStorage contract
     * @param authority_ Address of the deployed RaylsAccessManagerV1.
     */
    function initialize(address _participantCore, address _parentStorage, address authority_) public initializer {
        __UUPSUpgradeable_init();
        participantCore = IParticipantCore(_participantCore);
        parentStorage = _parentStorage;
        _initializeAuthority(authority_);
    }

    /// @dev Upgrade authorization is gated by the access manager (ADMIN required).
    function _authorizeUpgrade(address /*newImplementation*/) internal override {
        _checkCanCall(msg.sender, msg.sig);
    }

    /**
     * @inheritdoc IAuditManager
     */
    function setAuditInfo(
        uint256 chainId,
        string calldata raylsViewPublicKey,
        bytes memory encryptedRaylsViewPrivateKey,
        bytes memory mac,
        uint256 blockNumber
    ) external override onlyParticipantStorage {
        if (!participantCore.verifyParticipant(chainId)) {
            revert AuditManagerV1__ParticipantNotActive(chainId);
        }

        // Verify newer block
        if (auditInfoData[chainId].length > 0) {
            uint256 latestBlock = auditInfoData[chainId][auditInfoData[chainId].length - 1].blockNumber;
            if (latestBlock >= blockNumber) {
                revert AuditManagerV1__BlockNumberLowerThanLatest(chainId, blockNumber, latestBlock);
            }
        }

        // Create new AuditInfoData
        ParticipantStructs.AuditInfoData memory newAuditInfo = ParticipantStructs.AuditInfoData({
            chainId: chainId,
            raylsViewPublicKey: raylsViewPublicKey,
            encryptedRaylsViewPrivateKey: encryptedRaylsViewPrivateKey,
            mac: mac,
            blockNumber: blockNumber
        });

        // Add to the array
        auditInfoData[chainId].push(newAuditInfo);

        // Add chainId to list if it's the first entry
        if (auditInfoData[chainId].length == 1) {
            allAuditInfoChainIds.push(chainId);
        }

        emit NewAuditOrChainInfo();
    }

    /**
     * @inheritdoc IAuditManager
     */
    function getAuditInfo(uint256 chainId) public view override returns (ParticipantStructs.AuditInfoData[] memory data) {
        return auditInfoData[chainId];
    }

    /**
     * @inheritdoc IAuditManager
     */
    function setChainViewData(uint256 chainId, string calldata raylsViewPublicKey, uint256 blockNumber) external override onlyParticipantStorage {
        if (!participantCore.verifyParticipant(chainId)) {
            revert AuditManagerV1__ParticipantNotActive(chainId);
        }

        // Verify newer block
        if (privacyNodeViewData[chainId].length > 0) {
            uint256 latestBlock = privacyNodeViewData[chainId][privacyNodeViewData[chainId].length - 1].blockNumber;
            if (latestBlock >= blockNumber) {
                revert AuditManagerV1__BlockNumberLowerThanLatest(chainId, blockNumber, latestBlock);
            }
        }

        // Create new PrivacyNodeViewData
        ParticipantStructs.PrivacyNodeViewData memory newLedgerViewData =
            ParticipantStructs.PrivacyNodeViewData({chainId: chainId, raylsViewPublicKey: raylsViewPublicKey, blockNumber: blockNumber});

        // Add to the array
        privacyNodeViewData[chainId].push(newLedgerViewData);

        // Add chainId to list if it's the first entry
        if (privacyNodeViewData[chainId].length == 1) {
            allPrivacyNodeChainIds.push(chainId);
        }

        emit NewAuditOrChainInfo();
    }

    /**
     * @inheritdoc IAuditManager
     */
    function getChainViewData(uint256 chainId) public view override returns (ParticipantStructs.PrivacyNodeViewData[] memory data) {
        return privacyNodeViewData[chainId];
    }

    /**
     * @inheritdoc IAuditManager
     */
    function initiateKeyAgreement(uint256 initiatorChainId, uint256 responderChainId, bytes calldata ciphertext, bytes calldata digest, uint256 blockNumber) external override onlyParticipantStorage {
        if (!participantCore.verifyParticipant(initiatorChainId)) {
            revert AuditManagerV1__ParticipantNotActive(initiatorChainId);
        }
        if (!participantCore.verifyParticipant(responderChainId)) {
            revert AuditManagerV1__ParticipantNotActive(responderChainId);
        }

        uint256 initPairLatestIndex = pairToKeyAgreementIndex[initiatorChainId][responderChainId];
        uint256 respPairLatestIndex = pairToKeyAgreementIndex[responderChainId][initiatorChainId];

        // Cannot initiate a key agreement if the block number is lower than the latest key agreement between the same participants.
        if (initPairLatestIndex > 0) {
            if (keyAgreementData[initiatorChainId][initPairLatestIndex - 1].blockNumber >= blockNumber) {
                revert AuditManagerV1__BlockNumberLowerThanLatestKeyAgreement();
            }
        }
        if (respPairLatestIndex > 0) {
            if (keyAgreementData[responderChainId][respPairLatestIndex - 1].blockNumber >= blockNumber) {
                revert AuditManagerV1__BlockNumberLowerThanLatestKeyAgreement();
            }
        }

        ParticipantStructs.KeyAgreementData memory newInitiatorKeyAgreement = ParticipantStructs.KeyAgreementData({
            chainId: responderChainId,
            ciphertext: ciphertext,
            digest: digest,
            blockNumber: blockNumber
        });
        ParticipantStructs.KeyAgreementData memory newResponderKeyAgreement = ParticipantStructs.KeyAgreementData({
            chainId: initiatorChainId,
            ciphertext: ciphertext,
            digest: digest,
            blockNumber: blockNumber
        });

        // Assign the new key agreement to the initiator
        keyAgreementData[initiatorChainId].push(newInitiatorKeyAgreement);
        pairToKeyAgreementIndex[initiatorChainId][responderChainId] = initPairLatestIndex + 1;

        // If the initiator and responder are different, add the key agreement to the responder as well. Skip for the self-initiated key agreement.
        if (initiatorChainId != responderChainId) {
            keyAgreementData[responderChainId].push(newResponderKeyAgreement);
            pairToKeyAgreementIndex[responderChainId][initiatorChainId] = respPairLatestIndex + 1;
        }

        emit KeyAgreementInitiated(initiatorChainId, responderChainId, ciphertext, blockNumber);
    }

    /**
     * @inheritdoc IAuditManager
     */
    function getKeyAgreements(uint256 chainId) public view override returns (ParticipantStructs.KeyAgreementData[] memory data) {
        return keyAgreementData[chainId];
    }

    /**
     * @inheritdoc IAuditManager
     */
    function getAllPrivacyNodes() public view override returns (uint256[] memory) {
        return allPrivacyNodeChainIds;
    }

    /**
     * @inheritdoc IAuditManager
     */
    function getParticipantDataBatch() public view override returns (
        ParticipantStructs.PrivacyNodeViewData[] memory pnViewData,
        ParticipantStructs.AuditInfoData[] memory auditInfo,
        uint256[] memory pnChainIds,
        uint256[] memory auditChainIds
    ) {
        uint256 totalPrivacyNodeEntries = 0;
        uint256 totalAuditInfoEntries = 0;

        // Calculate total entries for privacy nodes
        for (uint256 i = 0; i < allPrivacyNodeChainIds.length; i++) {
            uint256 chainId = allPrivacyNodeChainIds[i];
            totalPrivacyNodeEntries += privacyNodeViewData[chainId].length;
        }

        // Calculate total entries for audit info
        for (uint256 i = 0; i < allAuditInfoChainIds.length; i++) {
            uint256 chainId = allAuditInfoChainIds[i];
            totalAuditInfoEntries += auditInfoData[chainId].length;
        }

        pnViewData = new ParticipantStructs.PrivacyNodeViewData[](totalPrivacyNodeEntries);
        pnChainIds = allPrivacyNodeChainIds;

        auditInfo = new ParticipantStructs.AuditInfoData[](totalAuditInfoEntries);
        auditChainIds = allAuditInfoChainIds;

        // Collect privacy node view data
        uint256 pnIndex = 0;
        for (uint256 i = 0; i < allPrivacyNodeChainIds.length; i++) {
            uint256 chainId = allPrivacyNodeChainIds[i];

            ParticipantStructs.PrivacyNodeViewData[] memory ledgerViewArray = privacyNodeViewData[chainId];
            for (uint256 j = 0; j < ledgerViewArray.length; j++) {
                pnViewData[pnIndex] = ledgerViewArray[j];
                pnIndex++;
            }
        }

        // Collect audit info data
        uint256 auditIndex = 0;
        for (uint256 i = 0; i < allAuditInfoChainIds.length; i++) {
            uint256 chainId = allAuditInfoChainIds[i];

            ParticipantStructs.AuditInfoData[] memory auditArray = auditInfoData[chainId];
            for (uint256 j = 0; j < auditArray.length; j++) {
                auditInfo[auditIndex] = auditArray[j];
                auditIndex++;
            }
        }

        return (pnViewData, auditInfo, pnChainIds, auditChainIds);
    }
    
    /**
     * @dev Returns the contract version
     * @return The version number (1) of this contract implementation
     */
    function contractVersion() external pure virtual returns (uint256) {
        return 1;
    }
} 
