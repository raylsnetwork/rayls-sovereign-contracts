// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../libraries/ParticipantStructs.sol";

/**
 * @title IAuditManager
 * @dev Interface for the AuditManager module that handles audit information
 */
interface IAuditManager {
    /**
     * @dev Emitted when key agreement is initiated
     * Notifies responder to complete the key agreement via decapsulation
     */
    event KeyAgreementInitiated(uint256 fromChainId, uint256 toChainId, bytes ciphertext, uint256 blockNumber);

    /**
     * @dev Emitted when new audit or chain info is added
     */
    event NewAuditOrChainInfo();

    /**
     * @notice Sets audit information for a chain
     * @param chainId The chain ID
     * @param raylsViewPublicKey The Rayls View public key
     * @param encryptedRaylsViewPrivateKey The encrypted Rayls View private key
     * @param mac The MAC
     * @param blockNumber The block number
     */
    function setAuditInfo(
        uint256 chainId,
        string calldata raylsViewPublicKey,
        bytes memory encryptedRaylsViewPrivateKey,
        bytes memory mac,
        uint256 blockNumber
    ) external;

    /**
     * @notice Retrieves audit info of the chain to be used by the VEN Operator
     * @param chainId The ID of the chain
     * @return data The array of AuditInfoData associated with the chain
     */
    function getAuditInfo(uint256 chainId) external view returns (ParticipantStructs.AuditInfoData[] memory data);

    /**
     * @notice Sets the Rayls View key for a participant's chain
     * @param chainId The chain ID
     * @param raylsViewPublicKey The Rayls View public key
     * @param blockNumber The block number
     */
    function setChainViewData(uint256 chainId, string calldata raylsViewPublicKey, uint256 blockNumber) external;

    /**
     * @notice Retrieves the Rayls View key history for a given chainId
     * @param chainId The ID of the chain
     * @return data The array of PrivacyNodeViewData associated with the chainId
     */
    function getChainViewData(uint256 chainId) external view returns (ParticipantStructs.PrivacyNodeViewData[] memory data);

    /**
     * @notice Initiates a key agreement between two participants.
     * @param initiatorChainId The chain ID of the initiator
     * @param responderChainId The chain ID of the responder
     * @param ciphertext The ciphertext of the key agreement
     * @param digest The digest of the shared secret
     * @param blockNumber The block number when the key agreement is initiated
     */
    function initiateKeyAgreement(uint256 initiatorChainId, uint256 responderChainId, bytes calldata ciphertext, bytes calldata digest, uint256 blockNumber) external;

    /**
     * @notice Retrieves the key agreement info for a given initiator chainId
     * @param initiatorChainId The chain ID of the initiator
     * @return data The array of KeyAgreementData associated with the initiator chainId
     */
    function getKeyAgreements(uint256 initiatorChainId) external view returns (ParticipantStructs.KeyAgreementData[] memory data);

    /**
     * @notice Retrieves all privacy nodes
     * @return An array of all privacy node chain IDs
     */
    function getAllPrivacyNodes() external view returns (uint256[] memory);

    /**
     * @notice Retrieves batch data for participants
     * @return pnViewData Array of privacy node view data
     * @return auditInfo Array of audit info data
     * @return pnChainIds Array of privacy node chain IDs
     * @return auditChainIds Array of audit chain IDs
     */
    function getParticipantDataBatch() external view returns (
        ParticipantStructs.PrivacyNodeViewData[] memory pnViewData,
        ParticipantStructs.AuditInfoData[] memory auditInfo,
        uint256[] memory pnChainIds,
        uint256[] memory auditChainIds
    );
} 