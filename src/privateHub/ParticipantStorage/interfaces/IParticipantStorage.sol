// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Primeiro importar a interface base
import "../../../rayls-protocol/interfaces/IParticipantValidator.sol";

// Depois importar as outras interfaces
import "./IParticipantCore.sol";
import "./IAuditManager.sol";
import "./IEnygmaManager.sol";
import "../libraries/ParticipantStructs.sol";

/**
 * @title IParticipantStorageV2
 * @dev Interface for the ParticipantStorageV2 contract that uses composition to delegate to modules
 */
interface IParticipantStorage is IParticipantValidator {
    /**
     * @notice Gets the ParticipantCore module
     * @return The address of the ParticipantCore module
     */
    function getParticipantCore() external view returns (IParticipantCore);
    
    /**
     * @notice Gets the AuditManager module
     * @return The address of the AuditManager module
     */
    function getAuditManager() external view returns (IAuditManager);
    
    /**
     * @notice Gets the EnygmaManager module
     * @return The address of the EnygmaManager module
     */
    function getEnygmaManager() external view returns (IEnygmaManager);
    
    /**
     * @notice Configures all modules in a single transaction
     * @param _participantCore The address of the ParticipantCore module
     * @param _auditManager The address of the AuditManager module
     * @param _enygmaManager The address of the EnygmaManager module
     */
    function configureModules(
        address _participantCore,
        address _auditManager,
        address _enygmaManager
    ) external;
    
    /**
     * @notice Sets the ParticipantCore module
     * @param _participantCore The address of the ParticipantCore module
     */
    function setParticipantCore(address _participantCore) external;
    
    /**
     * @notice Sets the AuditManager module
     * @param _auditManager The address of the AuditManager module
     */
    function setAuditManager(address _auditManager) external;
    
    /**
     * @notice Sets the EnygmaManager module
     * @param _enygmaManager The address of the EnygmaManager module
     */
    function setEnygmaManager(address _enygmaManager) external;

    /**
     * @notice Get Participant by chainId
     * @param chainId ChainId of the participant to get
     */
    function getParticipant(uint256 chainId) external view returns (ParticipantStructs.Participant memory);
    
    /**
     * @notice Gets the contract version
     * @return The contract version
     */    

    function getAllPaymentSpendPublicKeys() external view returns (ParticipantStructs.PrivacyNodeSpendDataSafeReturn[] memory);

    function getEnygmaAllParticipantsChainIds() external view returns (uint256[] memory);

    function checkEnygmaIssuerAccountAllowed(address _address, uint256 _chainId) external view returns (bool);
    
    function checkEnygmaAccountAllowed(address _account) external view returns (bool);

    function broadcastCurrentParticipants() external;

    function contractVersion() external pure returns (uint256);
} 