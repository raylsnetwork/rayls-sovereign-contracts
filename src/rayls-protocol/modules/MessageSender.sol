// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {RaylsAccessManaged} from '../../privateHub/AccessControl/RaylsAccessManaged.sol';
import {RaylsMessage, RaylsMessageMetadata, NewResourceMetadata, BridgedTransferMetadata} from './../../rayls-protocol-sdk/RaylsMessage.sol';
import {IMessageSender, SendRequest} from './../interfaces/IMessageSender.sol';
import {IParticipantValidator} from './../interfaces/IParticipantValidator.sol';
import {ITokenRegistryValidator} from './../interfaces/ITokenRegistryValidator.sol';
import {MessageLib} from './../../rayls-protocol-sdk/libraries/MessageLib.sol';
import {ParticipantStructs} from '../../privateHub/ParticipantStorage/libraries/ParticipantStructs.sol';

/**
 * @title MessageSender
 * @notice Handles the logic for sending and broadcasting messages across chains
 * @dev Validates participants and tokens before sending messages, manages outbound nonce tracking
 */
contract MessageSender is IMessageSender, RaylsAccessManaged {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error MessageSender__ZeroAddress();
    error MessageSender__UnauthorizedEndpoint(address caller);
    error MessageSender__NotAllowedToBroadcast(uint256 chainId);

    /*//////////////////////////////////////////////////////////////
                           STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The ID of the current chain
    uint256 public immutable chainId;

    /// @notice The ID of the private hub (operator chain)
    uint256 public immutable privateHubId;

    /// @notice Validator for participant permissions and status
    IParticipantValidator public participantValidator;

    /// @notice Validator for token registry operations
    ITokenRegistryValidator public tokenValidator;

    /// @notice Operator chain ID constant (chain 0)
    uint256 public constant OPERATOR_CHAIN_ID = 0;

    /// @notice Tracks the next nonce for outgoing messages to each destination chain
    /// @dev Maps dstChainId => next outbound nonce
    mapping(uint256 => uint256) public outboundNonce;

    /// @notice Address authorized to call protected functions (the Endpoint)
    address public authorizedEndpoint;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event AuthorizedEndpointSet(address indexed oldEndpoint, address indexed newEndpoint);

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Restricts function access to only the authorized endpoint
     * @dev Only the endpoint should be able to prepare messages and broadcast
     */
    modifier onlyEndpoint() {
        if (msg.sender != authorizedEndpoint) {
            revert MessageSender__UnauthorizedEndpoint(msg.sender);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the message sender with chain IDs, validators, and endpoint
     * @param _chainId The ID of the current chain
     * @param _privateHubId The ID of the private hub
     * @param _participantValidator Address of the participant validator
     * @param _tokenValidator Address of the token validator
     * @param _endpoint Address of the authorized endpoint
     * @param _owner Address of the contract owner
     * @dev Endpoint is set in constructor for simpler client deployment (no additional setup step required)
     */
    constructor(
        uint256 _chainId,
        uint256 _privateHubId,
        address _participantValidator,
        address _tokenValidator,
        address _endpoint,
        address _owner,
        address _authority
    ) {
        if (_participantValidator == address(0)) {
            revert MessageSender__ZeroAddress();
        }
        if (_tokenValidator == address(0)) {
            revert MessageSender__ZeroAddress();
        }
        if (_endpoint == address(0)) {
            revert MessageSender__ZeroAddress();
        }
        if (_owner == address(0)) {
            revert MessageSender__ZeroAddress();
        }

        chainId = _chainId;
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
     * @notice Sets the authorized endpoint address
     * @param _endpoint Address of the authorized endpoint
     * @dev Only callable by owner
     */
    function setAuthorizedEndpoint(address _endpoint) external restricted {
        if (_endpoint == address(0)) {
            revert MessageSender__ZeroAddress();
        }
        address oldEndpoint = authorizedEndpoint;
        authorizedEndpoint = _endpoint;
        emit AuthorizedEndpointSet(oldEndpoint, _endpoint);
    }

    /**
     * @notice Updates the participant validator
     * @param _participantValidator Address of the new participant validator
     * @dev Only callable by owner. Zero address check to prevent misconfiguration
     */
    function setParticipantValidator(address _participantValidator) external override restricted {
        if (_participantValidator == address(0)) {
            revert MessageSender__ZeroAddress();
        }
        participantValidator = IParticipantValidator(_participantValidator);
        emit ParticipantValidatorUpdated(_participantValidator);
    }

    /**
     * @notice Updates the token validator
     * @param _tokenValidator Address of the new token validator
     * @dev Only callable by owner. Zero address check to prevent misconfiguration
     */
    function setTokenValidator(address _tokenValidator) external override restricted {
        if (_tokenValidator == address(0)) {
            revert MessageSender__ZeroAddress();
        }
        tokenValidator = ITokenRegistryValidator(_tokenValidator);
        emit TokenValidatorUpdated(_tokenValidator);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the next outbound nonce for a destination chain
     * @param _dstChainId The destination chain ID
     * @return The next outbound nonce value
     */
    function getOutboundNonce(uint256 _dstChainId) external view override returns (uint256) {
        return outboundNonce[_dstChainId];
    }

    /*//////////////////////////////////////////////////////////////
                      MESSAGE PREPARATION LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Prepares and validates a message for sending to another chain
     * @param request The send request containing message details
     * @param sender The address sending the message
     * @return messagePayload The prepared message payload with metadata
     * @return messageId The unique identifier for the message
     * @return nonce The nonce used for the message
     * @dev Only callable by the authorized endpoint
     *      Validates participants and tokens before preparing the message
     *      Increments the outbound nonce for the destination chain
     */
    function prepareMessage(
        SendRequest memory request,
        address sender
    ) public override onlyEndpoint returns (RaylsMessage memory messagePayload, bytes32 messageId, uint256 nonce) {
        // Increment nonce for destination chain
        nonce = ++outboundNonce[request.dstChainId];

        // Validate that both source and destination chains are registered participants
        participantValidator.validateMessageParticipants(chainId, request.dstChainId);

        // For non-private hubs, validate token registration on both chains
        if (chainId != privateHubId) {
            tokenValidator.validateTokenForParticipant(request.resourceId, chainId);
            tokenValidator.validateTokenForParticipant(request.resourceId, request.dstChainId);
        }

        // Construct the complete message with metadata
        messagePayload = RaylsMessage({
            messageMetadata: RaylsMessageMetadata({
                valid: true,
                nonce: nonce,
                newResourceMetadata: request.newResourceMetadata,
                resourceId: request.resourceId,
                transferMetadata: request.transferMetadata,
                lockData: request.lockData,
                revertPayloadDataSender: request.revertDataSender,
                revertPayloadDataReceiver: request.revertDataReceiver,
                ignoresNonce: true
            }),
            payload: request.payload
        });

        // Compute unique message ID for tracking
        messageId = MessageLib.computeMessageId(
            address(this),
            chainId,
            sender,
            request.dstChainId,
            request.destination,
            abi.encode(messagePayload)
        );

        return (messagePayload, messageId, nonce);
    }

    /*//////////////////////////////////////////////////////////////
                      BROADCAST LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Broadcasts a message to all active participants in the network
     * @param _resourceId The resource ID associated with the message
     * @param _payload The payload to send
     * @param _sender The sender address
     * @param _chainId The current chain ID
     * @return messageId The ID of the last sent message
     * @dev Only callable by the authorized endpoint
     *      Validates broadcast permission before sending to all active participants
     */
    function broadcastToAllParticipants(
        bytes32 _resourceId,
        bytes calldata _payload,
        address _sender,
        uint256 _chainId
    ) external override onlyEndpoint returns (bytes32 messageId) {
        // Initialize empty metadata structs
        NewResourceMetadata memory emptyResourceMetadata;
        BridgedTransferMetadata memory emptyMetadata;

        // Create broadcast parameters struct to avoid stack too deep error
        BroadcastParams memory params = BroadcastParams({
            resourceId: _resourceId,
            payload: _payload,
            lockData: bytes(''),
            revertDataSender: bytes(''),
            revertDataReceiver: bytes(''),
            transferMetadata: emptyMetadata,
            sender: _sender,
            chainId: _chainId
        });

        // Delegate to internal function that processes the broadcast
        return _broadcastToParticipants(params, emptyResourceMetadata);
    }

    /**
     * @notice Broadcasts a message to all active participants with additional metadata
     * @param params Broadcast parameters encapsulated in a struct
     * @return messageId The ID of the last sent message
     * @dev Only callable by the authorized endpoint
     *      Allows specifying lock data, revert data, and transfer metadata for atomic operations
     */
    function broadcastToAllParticipantsWithData(
        BroadcastParams calldata params
    ) external override onlyEndpoint returns (bytes32 messageId) {
        // Initialize empty resource metadata
        NewResourceMetadata memory emptyResourceMetadata;

        // Delegate to internal function that processes the broadcast
        return _broadcastToParticipants(params, emptyResourceMetadata);
    }

    /*//////////////////////////////////////////////////////////////
                      INTERNAL BROADCAST HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Internal function that orchestrates broadcast to all participants
     * @param params Broadcast parameters containing sender info and message data
     * @param emptyResourceMetadata Empty resource metadata (no new resource deployment)
     * @return messageId ID of the last sent message
     * @dev Validates broadcast permission then sends to all eligible participants
     */
    function _broadcastToParticipants(
        BroadcastParams memory params,
        NewResourceMetadata memory emptyResourceMetadata
    ) internal returns (bytes32 messageId) {
        // Fetch all registered participants
        ParticipantStructs.Participant[] memory participants = participantValidator.getAllParticipants();

        // Verify sender chain has broadcast permission
        bool isAllowedToSend = _checkBroadcastPermission(participants, params.chainId);
        if (!isAllowedToSend) {
            revert MessageSender__NotAllowedToBroadcast(params.chainId);
        }

        // Send to all eligible participants
        return _sendToEligibleParticipants(participants, params, emptyResourceMetadata);
    }

    /**
     * @notice Checks if a participant chain has permission to broadcast messages
     * @param participants List of all participants
     * @param senderChainId Chain ID of the potential sender
     * @return True if the participant is allowed to broadcast, false otherwise
     * @dev Iterates through participants to find matching chain ID and check allowedToBroadcast flag
     */
    function _checkBroadcastPermission(
        ParticipantStructs.Participant[] memory participants,
        uint256 senderChainId
    ) internal pure returns (bool) {
        for (uint256 i = 0; i < participants.length; i++) {
            if (participants[i].chainId == senderChainId) {
                return participants[i].allowedToBroadcast;
            }
        }
        return false;
    }

    /**
     * @notice Sends messages to all eligible (active) participants
     * @param participants List of all participants
     * @param params Message parameters including payload and sender info
     * @param emptyResourceMetadata Empty metadata (no new resource deployment)
     * @return messageId ID of the last sent message
     * @dev Filters out sender's own chain, operator chain, and inactive participants
     */
    function _sendToEligibleParticipants(
        ParticipantStructs.Participant[] memory participants,
        BroadcastParams memory params,
        NewResourceMetadata memory emptyResourceMetadata
    ) internal returns (bytes32 messageId) {
        // Broadcast to all active participants except self and operator
        for (uint256 i = 0; i < participants.length; i++) {
            uint256 participantChainId = participants[i].chainId;

            // Skip our own chain and the operator chain
            if (participantChainId != params.chainId && participantChainId != OPERATOR_CHAIN_ID) {
                // Only send to active participants
                bool isAllowedToReceive = participants[i].status == ParticipantStructs.Status.ACTIVE;

                if (isAllowedToReceive) {
                    messageId = _sendToDstChain(
                        participantChainId,
                        params,
                        emptyResourceMetadata
                    );
                }
            }
        }
        return messageId;
    }

    /**
     * @notice Sends a message to a specific destination chain
     * @param dstChainId Destination chain ID
     * @param params Broadcast parameters
     * @param emptyResourceMetadata Empty metadata (no new resource deployment)
     * @return messageId ID of the sent message
     * @dev Constructs a SendRequest and delegates to prepareMessage
     */
    function _sendToDstChain(
        uint256 dstChainId,
        BroadcastParams memory params,
        NewResourceMetadata memory emptyResourceMetadata
    ) internal returns (bytes32 messageId) {
        // Construct send request for this specific destination
        SendRequest memory request = SendRequest({
            dstChainId: dstChainId,
            destination: address(0),
            payload: params.payload,
            resourceId: params.resourceId,
            newResourceMetadata: emptyResourceMetadata,
            lockData: params.lockData,
            revertDataSender: params.revertDataSender,
            revertDataReceiver: params.revertDataReceiver,
            transferMetadata: params.transferMetadata
        });

        // Prepare message via external call (protected by onlyEndpoint in prepareMessage)
        (, bytes32 msgId, ) = prepareMessage(request, params.sender);
        return msgId;
    }
}