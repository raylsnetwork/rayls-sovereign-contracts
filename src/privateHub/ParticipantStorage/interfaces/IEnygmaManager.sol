// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../libraries/ParticipantStructs.sol";

/**
 * @title IEnygmaManager
 * @dev Interface for the EnygmaManager module that handles Enygma-related functionality
 */
interface IEnygmaManager {
    /**
     * @notice Sets the Payment spend public key for a participant
     * @param _chainId The chain ID
     * @param _paymentSpendPublicKey The Payment spend public key
     * @param _pnAddresses Array of privacy node addresses
     */
    function setPaymentSpendPublicKey(
        uint256 _chainId,
        uint256 _paymentSpendPublicKey,
        address[] calldata _pnAddresses
    ) external;

    /**
     * @notice Gets the Payment spend public key for a chain ID
     * @param chainId The chain ID
     * @return The Payment spend public key
     */
    function getPaymentSpendPublicKeyByChainId(uint256 chainId) external view returns (uint256);

    /**
     * @notice Gets all Payment spend public keys
     * @return Array of privacy node spend data
     */
    function getAllPaymentSpendPublicKeys() external view returns (ParticipantStructs.PrivacyNodeSpendDataSafeReturn[] memory);

    /**
     * @notice Gets all Enygma participant chain IDs
     * @return Array of chain IDs
     */
    function getEnygmaAllParticipantsChainIds() external view returns (uint256[] memory);

    /**
     * @notice Checks if an Enygma account is allowed
     * @param _address The address to check
     * @return True if the account is allowed, false otherwise
     */
    function checkEnygmaAccountAllowed(address _address) external view returns (bool);

    /**
     * @notice Checks if an Enygma issuer account is allowed for a specific chain
     * @param _address The address to check
     * @param _chainId The chain ID
     * @return True if the issuer account is allowed, false otherwise
     */
    function checkEnygmaIssuerAccountAllowed(address _address, uint256 _chainId) external view returns (bool);

    /**
     * @notice Sets the Enygma PN events address
     * @param _pnEnygmaEvents The address of the PN Enygma events contract
     */
    function setEnygmaPnEventsAddress(address _pnEnygmaEvents) external;

    /**
     * @notice Gets the Enygma PN events address
     * @return The address of the PN Enygma events contract
     */
    function getEnygmaPnEventsAddress() external view returns (address);
} 