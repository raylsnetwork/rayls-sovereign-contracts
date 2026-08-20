// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {RaylsAccessManaged} from '../../privateHub/AccessControl/RaylsAccessManaged.sol';
import {RaylsMessage, RaylsMessageMetadata, NewResourceMetadata} from './../../rayls-protocol-sdk/RaylsMessage.sol';
import {IBatchMessageSender, SendRequest, BatchMessage} from './../interfaces/IBatchMessageSender.sol';
import {IParticipantValidator} from './../interfaces/IParticipantValidator.sol';
import {ITokenRegistryValidator} from './../interfaces/ITokenRegistryValidator.sol';
import {MessageLib} from './../../rayls-protocol-sdk/libraries/MessageLib.sol';

/**
 * @title BatchMessageSender
 * @notice Handles the logic for sending batches of messages across chains
 * @dev Validates participants and tokens before preparing batch messages
 */
contract BatchMessageSender is IBatchMessageSender, RaylsAccessManaged {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error BatchMessageSender__UnauthorizedEndpoint(address caller);
    error BatchMessageSender__ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                           STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The ID of the private hub for cross-chain operations
    uint256 public immutable privateHubId;

    /// @notice Participant validator for cross-chain participant validation
    IParticipantValidator public participantValidator;

    /// @notice Token validator for token registry validation
    ITokenRegistryValidator public tokenValidator;

    /// @notice Authorized endpoint address that can call prepareBatch
    address public authorizedEndpoint;

    /// @notice Outbound nonce tracking per destination chain
    mapping(uint256 => uint256) public outboundNonce;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event AuthorizedEndpointSet(address indexed oldEndpoint, address indexed newEndpoint);

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Restricts function access to only the authorized endpoint
     * @dev Used for prepareBatch to ensure only endpoint can initiate batch sending
     */
    modifier onlyEndpoint() {
        if (msg.sender != authorizedEndpoint) {
            revert BatchMessageSender__UnauthorizedEndpoint(msg.sender);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the batch message sender
     * @param _privateHubId The ID of the private hub
     * @param _participantValidator Address of the participant validator
     * @param _tokenValidator Address of the token validator
     * @param _endpoint Address of the authorized endpoint
     * @param _owner Address of the contract owner
     * @dev Zero address checks ensure proper initialization
     */
    constructor(
        uint256 _privateHubId,
        address _participantValidator,
        address _tokenValidator,
        address _endpoint,
        address _owner,
        address _authority
    ) {
        if (_participantValidator == address(0)) revert BatchMessageSender__ZeroAddress();
        if (_tokenValidator == address(0)) revert BatchMessageSender__ZeroAddress();
        if (_endpoint == address(0)) revert BatchMessageSender__ZeroAddress();
        if (_owner == address(0)) revert BatchMessageSender__ZeroAddress();

        privateHubId = _privateHubId;
        participantValidator = IParticipantValidator(_participantValidator);
        tokenValidator = ITokenRegistryValidator(_tokenValidator);
        authorizedEndpoint = _endpoint;
        if (_authority != address(0)) {
            _setAuthority(_authority);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates the participant validator
     * @param _participantValidator Address of the new participant validator
     * @dev Only callable by owner. Zero address check to prevent misconfiguration
     */
    function setParticipantValidator(address _participantValidator) external override restricted {
        if (_participantValidator == address(0)) revert BatchMessageSender__ZeroAddress();
        participantValidator = IParticipantValidator(_participantValidator);
        emit ParticipantValidatorUpdated(_participantValidator);
    }

    /**
     * @notice Updates the token validator
     * @param _tokenValidator Address of the new token validator
     * @dev Only callable by owner. Zero address check to prevent misconfiguration
     */
    function setTokenValidator(address _tokenValidator) external override restricted {
        if (_tokenValidator == address(0)) revert BatchMessageSender__ZeroAddress();
        tokenValidator = ITokenRegistryValidator(_tokenValidator);
        emit TokenValidatorUpdated(_tokenValidator);
    }

    /*//////////////////////////////////////////////////////////////
                      BATCH MESSAGE PREPARATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Prepares and validates a batch of messages for sending
     * @param requests Array of send requests containing message details
     * @param sender The address sending the message batch
     * @param chainId The ID of the current chain
     * @return messages The batch messages prepared for dispatch
     * @return batchId The unique identifier for the batch
     * @return nonces The nonces used for each message
     * @dev Only callable by authorized endpoint. Validates all participants and tokens before preparing messages
     */
    function prepareBatch(
        SendRequest[] memory requests,
        address sender,
        uint256 chainId
    ) external override onlyEndpoint returns (
        BatchMessage[] memory messages,
        bytes32 batchId,
        uint256[] memory nonces
    ) {
        // Validate all requests
        for (uint256 i = 0; i < requests.length; i++) {
            participantValidator.validateMessageParticipants(chainId, requests[i].dstChainId);
            tokenValidator.validateTokenForParticipant(requests[i].resourceId, chainId);
            tokenValidator.validateTokenForParticipant(requests[i].resourceId, requests[i].dstChainId);
        }

        messages = new BatchMessage[](requests.length);
        nonces = new uint256[](requests.length);

        // Prepare batch messages
        for (uint256 i = 0; i < requests.length; i++) {
            uint256 internalNonce = ++outboundNonce[requests[i].dstChainId];
            nonces[i] = internalNonce;

            RaylsMessage memory messagePayload = RaylsMessage({
                messageMetadata: RaylsMessageMetadata({
                    valid: true,
                    nonce: internalNonce,
                    newResourceMetadata: requests[i].newResourceMetadata,
                    resourceId: requests[i].resourceId,
                    transferMetadata: requests[i].transferMetadata,
                    lockData: requests[i].lockData,
                    revertPayloadDataSender: requests[i].revertDataSender,
                    revertPayloadDataReceiver: requests[i].revertDataReceiver,
                    ignoresNonce: true
                }),
                payload: requests[i].payload
            });

            bytes32 messageId = MessageLib.computeMessageId(
                address(this),
                chainId,
                sender,
                requests[i].dstChainId,
                requests[i].destination,
                abi.encode(messagePayload)
            );

            messages[i] = BatchMessage({
                toChainId: requests[i].dstChainId,
                to: requests[i].destination,
                data: messagePayload,
                messageId: messageId
            });
        }

        // Compute batch ID
        batchId = MessageLib.computeMessageBatchId(address(this), chainId, sender, requests);
        return (messages, batchId, nonces);
    }
}