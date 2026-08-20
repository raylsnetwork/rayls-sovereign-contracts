// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import './../RNMessageLib.sol';

/**
 * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
 */
interface IRaylsNodeEndpoint {
    /**
     * @notice Sends a Rayls message to the specified address at a Rayls endpoint.
     *         Use this method for single message transactions. Ensure the payload format
     *         and gas limits meet the requirements of the destination chain and contract.
     * @param _dstChainId The destination chain identifier.
     * @param _destination The address on the destination chain.
     * @param _payload The verified payload to send to the destination contract.
     */
    function send(uint256 _dstChainId, address _destination, bytes calldata _payload) external returns (bytes32 messageId);

    /**
    * @notice Sends a Rayls message to a token's public address on the destination chain.
     *         This method automatically resolves the private token address to its corresponding
     *         public chain address using TokenGovernance mapping. The token must be registered
     *         and active in TokenGovernance for the operation to succeed.
     *         Use this method for single message transactions. Ensure the payload format
     *         and gas limits meet the requirements of the destination chain and contract.
     * @param _dstChainId The destination chain identifier.
     * @param _privateChainAddress The token contract address on the Privacy Node.
     * @param _payload The verified payload to send to the destination contract.
     * @param _revertDataPayload The revertData for transaction failures
     * @param transferMetadata Metadata for the bridged transfer operation
     * @dev Reverts with TokenNotFound if private address is not registered in TokenGovernance
     * @dev Reverts with TokenNotActive if token is not in ACTIVE status
     * @dev Reverts with NoPublicAddressMapping if no public address is mapped to private address
     */
    function sendToAddress(
        uint256 _dstChainId,
        address _privateChainAddress,
        bytes calldata _payload,
        bytes memory _revertDataPayload,
        RaylsNodeBridgedTransferMetadata memory transferMetadata
    ) external returns (bytes32 messageId);

    /**
     * @notice Used by the messaging library to publish a verified payload to the destination contract.
     *         Typically called by other contracts or endpoints on the same chain.
     *         Ensures message integrity and ordering using the nonce and messageId.
     * @param _srcChainId The source chain identifier.
     * @param _srcAddress The source contract address (as bytes) on the source chain.
     * @param _dstAddress The address on the destination chain.
     * @param _RaylsNodeMessage A message including RaylsNodeMessageMetadataV1 to do validations like nonce and also the metadata
     * @param _messageId The unique identifier of the message.
     */
    function receivePayload(uint256 _srcChainId, address _srcAddress, address _dstAddress, RaylsNodeMessage memory _RaylsNodeMessage, bytes32 _messageId) external;


    /**
     * @notice Retrieves the immutable chain identifier of this Endpoint.
     *         This identifier is unique in the context of multi-chain interactions.
     * @return The chain ID of this endpoint.
     */
    function getChainId() external view returns (uint256);


    /**
     * @notice Returns the address of the RaylsAccessManagerV1 governing this endpoint.
     */
    function authority() external view returns (address);

    /**
     * @notice Retrieves the protocol version.
     * @return The protocol version.
     */
    function version() external pure returns (string memory);

    /**
     * @notice Gets the user governance address
     * @return User governance contract address
     */
    function getUserGovernanceAddress() external view returns (address);

}