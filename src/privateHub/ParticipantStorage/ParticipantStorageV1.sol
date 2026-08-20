// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import './interfaces/IParticipantStorage.sol';
import './interfaces/IParticipantCore.sol';
import './interfaces/IAuditManager.sol';
import './interfaces/IEnygmaManager.sol';
import './libraries/ParticipantStructs.sol';
import '../../rayls-protocol-sdk/RaylsAppV1.sol';
import '../../rayls-protocol-sdk/Constants.sol';
import '../../rayls-protocol/ParticipantStorageReplica/ParticipantStorageReplicaV1.sol';
import '../../rayls-protocol/interfaces/IParticipantValidator.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import '../AccessControl/RaylsAccessManaged.sol';

/**
 * @title ParticipantStorageV1
 * @dev Smart contract for managing a list of participants on the Private Hub using a modular approach.
 * This contract delegates functionality to specialized modules.
 *
 * All governance functions (module configuration, participant management, audit/key-data setters)
 * are gated by RaylsAccessManagerV1 via the `restricted` modifier.
 */
contract ParticipantStorageV1 is Initializable, RaylsAppV1, IParticipantValidator, IParticipantStorage, UUPSUpgradeable, RaylsAccessManaged {
    // Module references
    IParticipantCore private participantCore;
    IAuditManager private auditManager;
    IEnygmaManager private enygmaManager;

    error ParticipantStorageV1__UnauthorizedCaller(address caller);

    event ModulesConfigured(address indexed participantCore, address indexed auditManager, address indexed enygmaManager);

    /**
     * @dev Initializes the contract.
     * @param _endpoint The address of the endpoint contract
     * @param authority_ Address of the deployed RaylsAccessManagerV1.
     */
    function initialize(address _endpoint, address authority_) public initializer {
        __UUPSUpgradeable_init();
        RaylsAppV1.initialize(_endpoint);
        resourceId = Constants.RESOURCE_ID_PARTICIPANT_STORAGE;
        _initializeAuthority(authority_);
    }

    /// @dev Upgrade authorization is gated by the access manager (ADMIN required).
    function _authorizeUpgrade(address /*newImplementation*/) internal override {
        _checkCanCall(msg.sender, msg.sig);
    }

    /**
     * @notice Configures all modules in a single transaction
     */
    function configureModules(address _participantCore, address _auditManager, address _enygmaManager) external restricted {
        require(_participantCore != address(0), 'ParticipantStorageV1: ParticipantCore address cannot be zero');
        require(_auditManager != address(0), 'ParticipantStorageV1: AuditManager address cannot be zero');
        require(_enygmaManager != address(0), 'ParticipantStorageV1: EnygmaManager address cannot be zero');

        participantCore = IParticipantCore(_participantCore);
        auditManager = IAuditManager(_auditManager);
        enygmaManager = IEnygmaManager(_enygmaManager);

        emit ModulesConfigured(_participantCore, _auditManager, _enygmaManager);
    }

    // ========== Module Getters ==========

    /// @inheritdoc IParticipantStorage
    function getParticipantCore() external view override returns (IParticipantCore) {
        return participantCore;
    }

    /// @inheritdoc IParticipantStorage
    function getAuditManager() external view override returns (IAuditManager) {
        return auditManager;
    }

    /// @inheritdoc IParticipantStorage
    function getEnygmaManager() external view override returns (IEnygmaManager) {
        return enygmaManager;
    }

    // ========== Module Setters ==========

    /// @inheritdoc IParticipantStorage
    function setParticipantCore(address _participantCore) external override restricted {
        require(_participantCore != address(0), 'ParticipantStorageV1: ParticipantCore address cannot be zero');
        participantCore = IParticipantCore(_participantCore);
    }

    /// @inheritdoc IParticipantStorage
    function setAuditManager(address _auditManager) external override restricted {
        require(_auditManager != address(0), 'ParticipantStorageV1: AuditManager address cannot be zero');
        auditManager = IAuditManager(_auditManager);
    }

    /// @inheritdoc IParticipantStorage
    function setEnygmaManager(address _enygmaManager) external override restricted {
        require(_enygmaManager != address(0), 'ParticipantStorageV1: EnygmaManager address cannot be zero');
        enygmaManager = IEnygmaManager(_enygmaManager);
    }

    // ========== IParticipantValidator Implementation ==========

    /// @inheritdoc IParticipantValidator
    function validateMessageParticipants(uint256 originChainId, uint256 destinationChainId) external view override {
        require(address(participantCore) != address(0), 'ParticipantStorageV1: ParticipantCore module not set');
        participantCore.validateMessageParticipants(originChainId, destinationChainId);
    }

    /// @inheritdoc IParticipantValidator
    function validateParticipantStatus(uint256 chainId) external view override {
        require(address(participantCore) != address(0), 'ParticipantStorageV1: ParticipantCore module not set');
        participantCore.validateParticipantStatus(chainId);
    }

    /// @inheritdoc IParticipantValidator
    function getAllParticipants() external view override returns (ParticipantStructs.Participant[] memory) {
        require(address(participantCore) != address(0), 'ParticipantStorageV1: ParticipantCore module not set');
        return participantCore.getAllParticipants();
    }

    // ========== Delegated Functions ==========

    function getParticipant(uint256 chainId) external view returns (ParticipantStructs.Participant memory) {
        require(address(participantCore) != address(0), 'ParticipantStorageV1: ParticipantCore module not set');
        return participantCore.getParticipant(chainId);
    }

    function getAllParticipantsChainIds() external view returns (uint256[] memory) {
        require(address(participantCore) != address(0), 'ParticipantStorageV1: ParticipantCore module not set');
        return participantCore.getAllParticipantsChainIds();
    }

    function addParticipant(ParticipantStructs.ParticipantData memory _participant) external restricted {
        require(address(participantCore) != address(0), 'ParticipantStorageV1: ParticipantCore module not set');
        participantCore.addParticipant(_participant);
    }

    function addParticipants(ParticipantStructs.ParticipantData[] memory _participants) external restricted {
        require(address(participantCore) != address(0), 'ParticipantStorageV1: ParticipantCore module not set');
        participantCore.addParticipants(_participants);
    }

    function updateStatus(uint256 chainId, ParticipantStructs.Status status) external restricted {
        require(address(participantCore) != address(0), 'ParticipantStorageV1: ParticipantCore module not set');
        participantCore.updateStatus(chainId, status);
    }

    function updateRole(uint256 chainId, ParticipantStructs.Role role) external restricted {
        require(address(participantCore) != address(0), 'ParticipantStorageV1: ParticipantCore module not set');
        participantCore.updateRole(chainId, role);
    }

    function updateBroadcastMessagesPermission(uint256 chainId, bool allowed) external restricted {
        require(address(participantCore) != address(0), 'ParticipantStorageV1: ParticipantCore module not set');
        participantCore.updateBroadcastMessagesPermission(chainId, allowed);
    }

    function removeParticipant(uint256 chainId) external restricted {
        require(address(participantCore) != address(0), 'ParticipantStorageV1: ParticipantCore module not set');
        participantCore.removeParticipant(chainId);
    }

    function verifyParticipant(uint256 chainId) external view returns (bool) {
        require(address(participantCore) != address(0), 'ParticipantStorageV1: ParticipantCore module not set');
        return participantCore.verifyParticipant(chainId);
    }

    function broadcastCurrentParticipants() external restricted {
        require(address(participantCore) != address(0), 'ParticipantStorageV1: ParticipantCore module not set');
        uint256 fromChainId = RaylsAppV1._getFromChainIdOnReceiveMethod();
        participantCore.broadcastCurrentParticipants(fromChainId);
    }

    function setAuditInfo(uint256 chainId, string calldata raylsViewPublicKey, bytes memory encryptedRaylsViewPrivateKey, bytes memory mac, uint256 blockNumber) external restricted {
        require(address(auditManager) != address(0), 'ParticipantStorageV1: AuditManager module not set');
        auditManager.setAuditInfo(chainId, raylsViewPublicKey, encryptedRaylsViewPrivateKey, mac, blockNumber);
    }

    function getAuditInfo(uint256 chainId) external view returns (ParticipantStructs.AuditInfoData[] memory data) {
        require(address(auditManager) != address(0), 'ParticipantStorageV1: AuditManager module not set');
        return auditManager.getAuditInfo(chainId);
    }

    function setChainViewData(uint256 chainId, string calldata raylsViewPublicKey, uint256 blockNumber) external restricted {
        require(address(auditManager) != address(0), 'ParticipantStorageV1: AuditManager module not set');
        auditManager.setChainViewData(chainId, raylsViewPublicKey, blockNumber);
    }

    function getChainViewData(uint256 chainId) external view returns (ParticipantStructs.PrivacyNodeViewData[] memory data) {
        require(address(auditManager) != address(0), 'ParticipantStorageV1: AuditManager module not set');
        return auditManager.getChainViewData(chainId);
    }

    function initiateKeyAgreement(uint256 initiatorChainId, uint256 responderChainId, bytes calldata ciphertext, bytes calldata digest, uint256 blockNumber) external restricted {
        require(address(auditManager) != address(0), 'ParticipantStorageV1: AuditManager module not set');
        auditManager.initiateKeyAgreement(initiatorChainId, responderChainId, ciphertext, digest, blockNumber);
    }

    function getKeyAgreements(uint256 chainId) external view returns (ParticipantStructs.KeyAgreementData[] memory) {
        require(address(auditManager) != address(0), 'ParticipantStorageV1: AuditManager module not set');
        return auditManager.getKeyAgreements(chainId);
    }

    function getAllPrivacyNodes() external view returns (uint256[] memory) {
        require(address(auditManager) != address(0), 'ParticipantStorageV1: AuditManager module not set');
        return auditManager.getAllPrivacyNodes();
    }

    function getParticipantDataBatch()
        external
        view
        returns (ParticipantStructs.PrivacyNodeViewData[] memory pnViewData, ParticipantStructs.AuditInfoData[] memory auditInfo, uint256[] memory pnChainIds, uint256[] memory auditChainIds)
    {
        require(address(auditManager) != address(0), 'ParticipantStorageV1: AuditManager module not set');
        return auditManager.getParticipantDataBatch();
    }

    /**
     * @notice Sets the Payment spend public key for a participant
     * @param _chainId The chain ID
     * @param _paymentSpendPublicKey The Payment spend public key
     * @param _pnAddresses Array of privacy node addresses
     */
    function setPaymentSpendPublicKey(uint256 _chainId, uint256 _paymentSpendPublicKey, address[] calldata _pnAddresses) external restricted {
        require(address(enygmaManager) != address(0), 'ParticipantStorageV1: EnygmaManager module not set');
        enygmaManager.setPaymentSpendPublicKey(_chainId, _paymentSpendPublicKey, _pnAddresses);
    }

    function getPaymentSpendPublicKeyByChainId(uint256 chainId) external view returns (uint256) {
        require(address(enygmaManager) != address(0), 'ParticipantStorageV1: EnygmaManager module not set');
        return enygmaManager.getPaymentSpendPublicKeyByChainId(chainId);
    }

    function getAllPaymentSpendPublicKeys() external view returns (ParticipantStructs.PrivacyNodeSpendDataSafeReturn[] memory) {
        require(address(enygmaManager) != address(0), 'ParticipantStorageV1: EnygmaManager module not set');
        return enygmaManager.getAllPaymentSpendPublicKeys();
    }

    function getEnygmaAllParticipantsChainIds() external view returns (uint256[] memory) {
        require(address(enygmaManager) != address(0), 'ParticipantStorageV1: EnygmaManager module not set');
        return enygmaManager.getEnygmaAllParticipantsChainIds();
    }

    function checkEnygmaAccountAllowed(address _address) external view returns (bool) {
        require(address(enygmaManager) != address(0), 'ParticipantStorageV1: EnygmaManager module not set');
        return enygmaManager.checkEnygmaAccountAllowed(_address);
    }

    function checkEnygmaIssuerAccountAllowed(address _address, uint256 _chainId) external view returns (bool) {
        require(address(enygmaManager) != address(0), 'ParticipantStorageV1: EnygmaManager module not set');
        return enygmaManager.checkEnygmaIssuerAccountAllowed(_address, _chainId);
    }

    /**
     * @notice Sets the Enygma PN events address
     * @param _pnEnygmaEvents The address of the PN Enygma events contract
     */
    function setEnygmaPnEventsAddress(address _pnEnygmaEvents) external restricted {
        require(address(enygmaManager) != address(0), 'ParticipantStorageV1: EnygmaManager module not set');
        enygmaManager.setEnygmaPnEventsAddress(_pnEnygmaEvents);
    }

    function contractVersion() external pure override returns (uint256) {
        return 1;
    }
}
