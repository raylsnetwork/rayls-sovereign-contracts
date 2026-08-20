// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {RaylsAccessManaged} from '../../privateHub/AccessControl/RaylsAccessManaged.sol';
import {RaylsMessage, RaylsMessageMetadata} from './../../rayls-protocol-sdk/RaylsMessage.sol';
import {IMessageReceiver} from './../interfaces/IMessageReceiver.sol';
import {IResourceManager} from './../interfaces/IResourceManager.sol';
import {IRaylsMessageExecutor} from './../../rayls-protocol-sdk/interfaces/IRaylsMessageExecutor.sol';

/**
 * @title MessageReceiver
 * @notice Handles receiving and validating cross-chain messages from other chains
 * @dev Acts as the entry point for all incoming messages, validates nonces, and delegates execution
 */
contract MessageReceiver is IMessageReceiver, RaylsAccessManaged {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error MessageReceiver__UnauthorizedEndpoint(address caller);
    error MessageReceiver__ZeroAddress();
    error MessageReceiver__WrongNonce(uint256 expected, uint256 received);
    error MessageReceiver__UnauthorizedCaller(address caller);

    /*//////////////////////////////////////////////////////////////
                           STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Tracks the next expected nonce for each source chain to prevent message replay and reordering
    /// @dev Maps srcChainId => next expected nonce
    mapping(uint256 => uint256) public inboundNonce;

    /// @notice Resource manager handles resource ID resolution and dynamic contract deployment
    IResourceManager public resourceManager;

    /// @notice Message executor handles the actual execution of validated messages
    IRaylsMessageExecutor public messageExecutor;

    /// @notice Only this address (the Endpoint) can call receivePayload
    address public authorizedEndpoint;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event AuthorizedEndpointSet(address indexed oldEndpoint, address indexed newEndpoint);
    event AuthorizedEndpointRemoved(address indexed endpoint);

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Restricts function access to only the authorized endpoint
     * @dev The endpoint is the only contract that should be able to trigger message reception
     */
    modifier onlyEndpoint() {
        if (msg.sender != authorizedEndpoint) {
            revert MessageReceiver__UnauthorizedEndpoint(msg.sender);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the message receiver with required dependencies and endpoint
     * @param _resourceManager Address of the resource manager
     * @param _messageExecutor Address of the message executor
     * @param _endpoint Address of the authorized endpoint
     * @param _owner Address of the contract owner
     * @dev Endpoint is set in constructor for simpler client deployment (no additional setup step required)
     */
    constructor(
        address _resourceManager,
        address _messageExecutor,
        address _endpoint,
        address _owner,
        address _authority
    ) {
        if (_resourceManager == address(0)) {
            revert MessageReceiver__ZeroAddress();
        }
        if (_messageExecutor == address(0)) {
            revert MessageReceiver__ZeroAddress();
        }
        if (_endpoint == address(0)) {
            revert MessageReceiver__ZeroAddress();
        }
        if (_owner == address(0)) {
            revert MessageReceiver__ZeroAddress();
        }

        resourceManager = IResourceManager(_resourceManager);
        messageExecutor = IRaylsMessageExecutor(_messageExecutor);
        authorizedEndpoint = _endpoint;
        if (_authority != address(0)) {
            _setAuthority(_authority);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the authorized endpoint address that can send messages
     * @param _endpoint Address of the authorized endpoint
     * @dev Only callable by owner. Emits event with old and new endpoint for traceability
     */
    function setAuthorizedEndpoint(address _endpoint) external restricted {
        if (_endpoint == address(0)) {
            revert MessageReceiver__ZeroAddress();
        }
        address oldEndpoint = authorizedEndpoint;
        authorizedEndpoint = _endpoint;
        emit AuthorizedEndpointSet(oldEndpoint, _endpoint);
    }

    /**
     * @notice Removes the authorized endpoint address
     * @dev Only callable by owner. Should be used with extreme caution as it will block all incoming messages
     */
    function removeAuthorizedEndpoint() external restricted {
        address removedEndpoint = authorizedEndpoint;
        authorizedEndpoint = address(0);
        emit AuthorizedEndpointRemoved(removedEndpoint);
    }

    /**
     * @notice Updates the resource manager
     * @param _resourceManager Address of the new resource manager
     * @dev Only callable by owner. Zero address check to prevent accidental misconfiguration
     */
    function setResourceManager(address _resourceManager) external override restricted {
        if (_resourceManager == address(0)) {
            revert MessageReceiver__ZeroAddress();
        }
        resourceManager = IResourceManager(_resourceManager);
        emit ResourceManagerUpdated(_resourceManager);
    }

    /**
     * @notice Updates the message executor
     * @param _messageExecutor Address of the new message executor
     * @dev Only callable by owner. Zero address check to prevent accidental misconfiguration
     */
    function setMessageExecutor(address _messageExecutor) external override restricted {
        if (_messageExecutor == address(0)) {
            revert MessageReceiver__ZeroAddress();
        }
        messageExecutor = IRaylsMessageExecutor(_messageExecutor);
        emit MessageExecutorUpdated(_messageExecutor);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the current message executor address
     * @return The address of the message executor contract
     */
    function getMessageExecutor() external view override returns (address) {
        return address(messageExecutor);
    }

    /**
     * @notice Gets the next expected inbound nonce for a source chain
     * @param _srcChainId The source chain ID
     * @return The next expected nonce value
     */
    function getInboundNonce(uint256 _srcChainId) external view override returns (uint256) {
        return inboundNonce[_srcChainId];
    }

    /*//////////////////////////////////////////////////////////////
                      MESSAGE VALIDATION LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Validates a complete Rayls message and extracts its payload
     * @param _srcChainId The source chain ID
     * @param _dstAddress The destination address
     * @param _raylsMessage The complete Rayls message to validate
     * @return payload The message payload bytes
     * @return destinationAddress The resolved destination address (may differ from _dstAddress if using resourceId)
     * @dev This function is called externally by receivePayload via `this.function()` pattern
     *      Access control is enforced via onlyEndpointOrThis modifier
     */
    function validateRaylsMessageAndGetPayload(
        uint256 _srcChainId,
        address _dstAddress,
        RaylsMessage memory _raylsMessage
    ) internal returns (bytes memory payload, address destinationAddress) {
        destinationAddress = validateRaylsMessageMetadata(
            _srcChainId,
            _dstAddress,
            _raylsMessage.messageMetadata
        );
        return (_raylsMessage.payload, destinationAddress);
    }

    /**
     * @notice Validates Rayls message metadata including nonce and resource resolution
     * @param _srcChainId The source chain ID
     * @param _dstAddress The destination address
     * @param _messageMetadata The message metadata to validate
     * @return destinationAddress The resolved destination address
     * @dev Nonce validation ensures message ordering and prevents replay attacks
     *      Resource manager handles dynamic address resolution or contract deployment
     */
    function validateRaylsMessageMetadata(
        uint256 _srcChainId,
        address _dstAddress,
        RaylsMessageMetadata memory _messageMetadata
    ) internal returns (address destinationAddress) {
        // Validate and increment nonce to prevent message shuffling and replay attacks
        if (!_messageMetadata.ignoresNonce) {
            uint256 expectedNonce = inboundNonce[_srcChainId] + 1;
            if (_messageMetadata.nonce != expectedNonce) {
                revert MessageReceiver__WrongNonce(expectedNonce, _messageMetadata.nonce);
            }
            inboundNonce[_srcChainId] = expectedNonce;
        }

        // Resolve destination address via resource manager (may deploy new contracts)
        destinationAddress = resourceManager.handleWithResourceId(_messageMetadata, _dstAddress);

        return destinationAddress;
    }

    /*//////////////////////////////////////////////////////////////
                      MESSAGE RECEPTION LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Receives and processes a cross-chain message payload
     * @param _srcChainId The source chain ID
     * @param _srcAddress The source address on the source chain
     * @param _dstAddress The destination address
     * @param _raylsMessage The complete Rayls message
     * @param _messageId The unique message ID for replay protection
     * @dev This is the main entry point for all incoming messages
     *      Only callable by the authorized endpoint
     *      Validates message then delegates execution to the message executor
     */
    function receivePayload(
        uint256 _srcChainId,
        address _srcAddress,
        address _dstAddress,
        RaylsMessage memory _raylsMessage,
        bytes32 _messageId
    ) external override onlyEndpoint {
        // Validate message and resolve destination address
        (bytes memory payload, address destinationAddress) = validateRaylsMessageAndGetPayload(
            _srcChainId,
            _dstAddress,
            _raylsMessage
        );

        // Delegate execution to the message executor
        messageExecutor.executeMessage(
            destinationAddress,
            payload,
            _messageId,
            _srcChainId,
            _srcAddress
        );
    }
}