// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IRNMessageExecutor} from "./interfaces/IRaylsMessageExecutor.sol";

/*//////////////////////////////////////////////////////////////
                          TYPE DECLARATIONS
//////////////////////////////////////////////////////////////*/

/**
 * @notice Send request structure for cross-chain messages
 * @param dstChainId Destination chain identifier
 * @param destination Destination contract address
 * @param payload Encoded message payload
 * @param newResourceMetadata Metadata for new resource deployment
 * @param revertData Revert data for failed transactions
 * @param transferMetadata Metadata from bridged transfer
 */
struct RNSendRequest {
    uint256 dstChainId;
    address destination;
    bytes payload;
    RaylsNodeNewResourceMetadata newResourceMetadata;
    bytes revertData;
    RaylsNodeBridgedTransferMetadata transferMetadata;
}

/**
 * @notice Rayls Node message structure
 * @param messageMetadata Message metadata including nonce and resource info
 * @param payload Encoded message payload
 */
struct RaylsNodeMessage {
    RaylsNodeMessageMetadata messageMetadata;
    bytes payload;
}

/**
 * @notice Message metadata structure
 * @param nonce Message nonce for ordering (EIP-5164 compliant)
 * @param newResourceMetadata Optional metadata for new resource deployment
 * @param revertPayloadData Revert data to execute on sender chain if transaction fails
 * @param transferMetadata Metadata from ERC token transaction
 */
struct RaylsNodeMessageMetadata {
    uint256 nonce;
    RaylsNodeNewResourceMetadata newResourceMetadata;
    bytes revertPayloadData;
    RaylsNodeBridgedTransferMetadata transferMetadata;
}

/**
 * @notice New resource deployment metadata
 * @param resourceDeployType Type of resource deployment (BYTECODE or FACTORY)
 * @param bytecode Contract bytecode when ResourceDeployType == BYTECODE
 * @param factoryTemplate Factory template when ResourceDeployType == FACTORY
 * @param initializerParams Initializer parameters when ResourceDeployType == FACTORY
 */
struct RaylsNodeNewResourceMetadata {
    RaylsNodeResourceDeployType resourceDeployType;
    bytes bytecode;
    RaylsNodeBridgeableERC factoryTemplate;
    bytes initializerParams;
}

/**
 * @notice Bridged transfer metadata
 * @param assetType Type of ERC asset (ERC20, ERC721, ERC1155, ENYGMA, CUSTOM)
 * @param id Token ID (disregard if assetType == ERC20)
 * @param from Sender address
 * @param to Recipient address
 * @param tokenAddress Token contract address
 * @param amount Transfer amount
 */
struct RaylsNodeBridgedTransferMetadata {
    RaylsNodeBridgeableERC assetType;
    uint256 id;
    address from;
    address to;
    address tokenAddress;
    uint256 amount;
}

/**
 * @notice Resource deployment type enumeration
 */
enum RaylsNodeResourceDeployType {
    BYTECODE,
    FACTORY
}

/**
 * @notice Bridgeable ERC token type enumeration
 * @dev Must match RaylsBridgeableERC ordering in rayls-protocol-sdk/RaylsMessage.sol
 */
enum RaylsNodeBridgeableERC {
    CUSTOM,
    ERC20,
    ERC721,
    ERC1155,
    ENYGMA,
    ENYGMA_DVP_ERC721,
    ENYGMA_DVP_ERC1155
}

/**
 * @title RNMessageLib
 * @notice Library to declare and manipulate cross-chain messages
 * @dev Provides utilities for message ID computation and message structures
 * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
 */
library RNMessageLib {

    /*//////////////////////////////////////////////////////////////
                          TYPE DECLARATIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Message data structure for batch operations
     * @param to Address that will be dispatched on the receiving chain
     * @param data Data that will be sent to the `to` address
     */
    struct Message {
        address to;
        bytes data;
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Computes a unique message identifier
     * @param fromChainId Chain ID that dispatched the message
     * @param from Address that dispatched the message
     * @param toChainId Chain ID that will receive the message
     * @param to Address that will receive the message
     * @param nonce EIP-5164 compliant nonce for message uniqueness
     * @param data Data that was dispatched
     * @return bytes32 ID uniquely identifying the dispatched message
     */
    function computeMessageId(
        uint256 fromChainId,
        address from,
        uint256 toChainId,
        address to,
        uint256 nonce,
        bytes memory data
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(fromChainId, from, toChainId, to, nonce, data));
    }

    /**
     * @notice Computes a unique message identifier for a batch of messages
     * @param fromChainId Chain ID that dispatched the messages
     * @param from Address that dispatched the messages
     * @param messages Array of send requests dispatched
     * @return bytes32 ID uniquely identifying the dispatched batch
     */
    function computeMessageBatchId(
        uint256 fromChainId,
        address from,
        RNSendRequest[] memory messages
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(fromChainId, from, messages));
    }
}