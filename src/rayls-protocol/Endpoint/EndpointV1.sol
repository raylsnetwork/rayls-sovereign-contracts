// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {IRaylsEndpoint} from '../../rayls-protocol-sdk/interfaces/IRaylsEndpoint.sol';
import './../modules/BatchMessageSender.sol';
import './../interfaces/IResourceManager.sol';
import './../interfaces/IParticipantValidator.sol';
import './../interfaces/ITokenRegistryValidator.sol';
import './../interfaces/IMessageSender.sol';
import './../interfaces/IMessageReceiver.sol';
import './../interfaces/IBatchMessageSender.sol';
import './../../rayls-protocol-sdk/libraries/MessageLib.sol';
import '../../privateHub/ParticipantStorage/libraries/ParticipantStructs.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import './../utils/RaylsReentrancyGuardV1.sol';
import '../../rayls-protocol-sdk/RaylsMessage.sol';
import './../RaylsContractFactory/RaylsContractFactoryV1.sol';
import './../RaylsMessageExecutor/RaylsMessageExecutorV1.sol';
import './../ParticipantStorageReplica/ParticipantStorageReplicaV1.sol';
import {IUserGovernance} from '../../rayls-node/rayls-privacy-node/interfaces/IUserGovernanceV1.sol';
import {RaylsAccessManaged} from '../../privateHub/AccessControl/RaylsAccessManaged.sol';


contract EndpointV1 is Initializable, IRaylsEndpoint, UUPSUpgradeable, RaylsAccessManaged {
    error Endpoint__InvalidPrivateHubAddress();
    error Endpoint__EmptyContractName();

    uint256 public chainId;
    uint256 public privateHubId;
    RaylsMessageExecutorV1 messageExecutor;
    RaylsContractFactoryV1 contractFactory;
    IParticipantValidator participantStorageReplica;
    ITokenRegistryValidator tokenRegistry;
    IUserGovernance userGovernance;
    uint256 private maxBatchMessages;

    mapping(string => address) public privateHubAddress;

    IResourceManager public resourceManager;

    /// @notice Module for sending messages to other chains
    IMessageSender public messageSender;

    /// @notice Module for receiving messages from other chains
    IMessageReceiver public messageReceiver;

    /// @notice Module for sending batched messages
    IBatchMessageSender public batchMessageSender;

    event UpdateRaylsViewKeysRequest(uint256 blockNumber);
    event PrivateHubAddressRegistered(string indexed contractName, address indexed contractAddress);

    /// @notice Emitted when a resource ID is registered
    /// @param resourceId The resource ID that was registered
    /// @param implementationAddress The address of the implementation contract
    event ResourceIdRegistered(bytes32 indexed resourceId, address indexed implementationAddress);

    /// @notice Emitted when modules are configured
    /// @param resourceManager Address of the ResourceManager module
    /// @param messageSender Address of the MessageSender module
    /// @param messageReceiver Address of the MessageReceiver module
    /// @param batchMessageSender Address of the BatchMessageSender module
    event ModulesConfigured(
        address resourceManager, address messageSender, address messageReceiver, address batchMessageSender
    );

    /// @notice Emitted when endpoint is configured
    /// @param contractFactory Address of the contract factory
    /// @param participantStorageReplica Address of the participant storage replica
    /// @param tokenRegistry Address of the PN token registry
    /// @param resourceManager Address of the ResourceManager module
    /// @param messageSender Address of the MessageSender module
    /// @param messageReceiver Address of the MessageReceiver module
    /// @param batchMessageSender Address of the BatchMessageSender module
    event EndpointConfigured(
        address contractFactory,
        address participantStorageReplica,
        address tokenRegistry,
        address resourceManager,
        address messageSender,
        address messageReceiver,
        address batchMessageSender
    );

    /// @notice Emitted when a cross-chain message is dispatched
    /// @param messageId Unique identifier for the dispatched message
    /// @param from Address of the message sender
    /// @param toChainId Destination chain identifier where the message will be delivered
    /// @param to Recipient address on the destination chain
    /// @param data The RaylsMessage payload containing metadata and application data
    event MessageDispatched(
        bytes32 indexed messageId, address indexed from, uint256 indexed toChainId, address to, RaylsMessage data
    );

    /// @notice Emitted when a batch of cross-chain messages is dispatched
    /// @param batchId Unique identifier for the message batch
    /// @param from Address of the batch sender
    /// @param messages Array of BatchMessage structs containing the batched messages
    event MessageBatchDispatched(bytes32 batchId, address from, BatchMessage[] messages);

    function initialize(uint256 _chainId, uint256 _privateHubId, uint256 _maxBatchMessages, address authority_)
        public
        initializer
    {
        __UUPSUpgradeable_init();
        privateHubId = _privateHubId;
        chainId = _chainId;
        maxBatchMessages = _maxBatchMessages;
        _initializeAuthority(authority_);
    }

    /// @inheritdoc IRaylsEndpoint
    /// @dev Resolves diamond ambiguity: both IRaylsEndpoint and RaylsAccessManaged declare authority().
    function authority() public view override(IRaylsEndpoint, RaylsAccessManaged) returns (address) {
        return RaylsAccessManaged.authority();
    }

    /**
     * @notice Configures the core contracts used by the Endpoint
     * @dev Sets up the legacy contract references. Maintained for backward compatibility.
     * @param _contractFactory Address of the contract factory
     * @param _participantStorageReplica Address of the participant storage replica
     * @param _tokenRegistry Address of the PN token registry
     */
    function configureContracts(
        address _contractFactory,
        address _participantStorageReplica,
        address _tokenRegistry
    ) external virtual restricted {
        contractFactory = RaylsContractFactoryV1(_contractFactory);
        participantStorageReplica = IParticipantValidator(_participantStorageReplica);
        tokenRegistry = ITokenRegistryValidator(_tokenRegistry);
    }

    function setUserGovernance(address _userGovernance) external restricted {
        userGovernance = IUserGovernance(_userGovernance);
    }

    /**
     * @notice Configures the modules of the new architecture
     * @dev Sets up the module references for the modular architecture. Maintained for backward compatibility.
     * @param _resourceManager Address of the resource manager module
     * @param _messageSender Address of the message sender module
     * @param _messageReceiver Address of the message receiver module
     * @param _batchMessageSender Address of the batch message sender module
     */
    function configureModules(
        address _resourceManager,
        address _messageSender,
        address _messageReceiver,
        address _batchMessageSender
    ) external restricted {
        resourceManager = IResourceManager(_resourceManager);
        messageSender = IMessageSender(_messageSender);
        messageReceiver = IMessageReceiver(_messageReceiver);
        batchMessageSender = IBatchMessageSender(_batchMessageSender);
        emit ModulesConfigured(_resourceManager, _messageSender, _messageReceiver, _batchMessageSender);
    }

    /**
     * @notice Gets the address associated with a resource ID
     * @param _resourceId The resource ID to look up
     * @return The address associated with the resource ID
     */
    function getAddressByResourceId(bytes32 _resourceId) external view virtual returns (address) {
        return resourceManager.getAddressByResourceId(_resourceId);
    }

    /**
     * @notice Sends a message to a destination chain
     * @param _dstChainId The ID of the destination chain
     * @param _destination The address on the destination chain
     * @param _payload The data to be sent
     * @return messageId A unique identifier for the message
     */
    function send(uint256 _dstChainId, address _destination, bytes calldata _payload)
        external
        payable
        virtual
        override
        restricted
        returns (bytes32 messageId)
    {
        NewResourceMetadata memory emptyResourceMetadata;
        BridgedTransferMetadata memory emptyMetadata;
        return _send(
            SendRequest({
                dstChainId: _dstChainId,
                destination: _destination,
                payload: _payload,
                resourceId: bytes32(0),
                newResourceMetadata: emptyResourceMetadata,
                lockData: bytes(""),
                revertDataSender: bytes(""),
                revertDataReceiver: bytes(""),
                transferMetadata: emptyMetadata
            })
        );
    }

    /**
     * @notice Sends a message to a destination chain with explicit metadata
     * @param _dstChainId The ID of the destination chain
     * @param _destination The address on the destination chain
     * @param _payload The data to be sent
     * @param transferMetadata The metadata for the transfer
     * @return messageId A unique identifier for the message
     */
    function send(uint256 _dstChainId, address _destination, bytes calldata _payload, BridgedTransferMetadata memory transferMetadata)
        external
        payable
        virtual
        override
        restricted
        returns (bytes32 messageId)
    {
        NewResourceMetadata memory emptyResourceMetadata;
        return _send(
            SendRequest({
                dstChainId: _dstChainId,
                destination: _destination,
                payload: _payload,
                resourceId: bytes32(0),
                newResourceMetadata: emptyResourceMetadata,
                lockData: bytes(""),
                revertDataSender: bytes(""),
                revertDataReceiver: bytes(""),
                transferMetadata: transferMetadata
            })
        );
    }

    /**
     * @notice Sends a batch of messages to different destinations
     * @param _destinationPayloadRequests Array of destination and payload requests
     * @return batchId A unique identifier for the batch
     */
    function sendBatch(DestinationPayloadRequest[] calldata _destinationPayloadRequests)
        external
        virtual
        restricted
        returns (bytes32 batchId)
    {
        require(
            _destinationPayloadRequests.length < getMaxBatchMessages(),
            "EndpointV1: The max number of transactions allowed in a batch has been exceeded"
        );

        SendRequest[] memory request = new SendRequest[](_destinationPayloadRequests.length);

        for (uint256 i = 0; i < _destinationPayloadRequests.length; i++) {
            NewResourceMetadata memory emptyResourceMetadata;
            BridgedTransferMetadata memory emptyMetadata;

            request[i] = SendRequest({
                dstChainId: _destinationPayloadRequests[i]._dstChainId,
                destination: _destinationPayloadRequests[i]._destination,
                payload: _destinationPayloadRequests[i]._payload,
                resourceId: bytes32(0),
                newResourceMetadata: emptyResourceMetadata,
                lockData: bytes(""),
                revertDataSender: bytes(""),
                revertDataReceiver: bytes(""),
                transferMetadata: emptyMetadata
            });
        }

        return _sendBatch(request);
    }

    function sendToResourceId(uint256 _dstChainId, bytes32 _resourceId, bytes calldata _payload)
        external
        payable
        virtual
        restricted
        returns (bytes32 messageId)
    {
        BridgedTransferMetadata memory emptyMetadata;
        NewResourceMetadata memory emptyResourceMetadata;

        if (_dstChainId == 0) {
            ParticipantStructs.Participant[] memory participants = participantStorageReplica.getAllParticipants();

            // Check if we are allowed to broadcast messages
            bool isAllowedToSend;
            for (uint256 i = 0; i < participants.length; i++) {
                if (participants[i].chainId == chainId) {
                    isAllowedToSend = participants[i].allowedToBroadcast;
                }
            }

            require(isAllowedToSend, "Participant is not allowed to broadcast messages");

            if (isAllowedToSend) {
                for (uint256 i = 0; i < participants.length; i++) {
                    uint256 participantChainId = participants[i].chainId;

                    // Check if the current participant chaindId is not ours and not the VEN operator
                    if (participantChainId != chainId && participantChainId != Constants.OPERATOR_CHAIN_ID) {
                        // Check if the participant we are about to send is in active status (1 means it is active)
                        bool isAllowedToReceive = participants[i].status == ParticipantStructs.Status.ACTIVE;
                        if (isAllowedToReceive) {
                            messageId = _send(
                                SendRequest({
                                    dstChainId: participantChainId,
                                    destination: address(0),
                                    payload: _payload,
                                    resourceId: _resourceId,
                                    newResourceMetadata: emptyResourceMetadata,
                                    lockData: bytes(""),
                                    revertDataSender: bytes(""),
                                    revertDataReceiver: bytes(""),
                                    transferMetadata: emptyMetadata
                                })
                            );
                        }
                    }
                }
            }

            return messageId;
        }

        return _send(
            SendRequest({
                dstChainId: _dstChainId,
                destination: address(0),
                payload: _payload,
                resourceId: _resourceId,
                newResourceMetadata: emptyResourceMetadata,
                lockData: bytes(""),
                revertDataSender: bytes(""),
                revertDataReceiver: bytes(""),
                transferMetadata: emptyMetadata
            })
        );
    }

    function sendBatchToResourceId(ResourceIdPayloadRequest[] calldata _resourceIdPayloadRequests)
        external
        payable
        virtual
        restricted
        returns (bytes32 batchId)
    {
        require(
            _resourceIdPayloadRequests.length < getMaxBatchMessages(),
            "The max number of transactions allowed in a batch has been exceeded"
        );

        SendRequest[] memory request = new SendRequest[](_resourceIdPayloadRequests.length);

        for (uint256 i = 0; i < _resourceIdPayloadRequests.length; i++) {
            NewResourceMetadata memory emptyResourceMetadata;
            BridgedTransferMetadata memory emptyMetadata;

            request[i] = SendRequest({
                dstChainId: _resourceIdPayloadRequests[i]._dstChainId,
                destination: address(0),
                payload: _resourceIdPayloadRequests[i]._payload,
                resourceId: _resourceIdPayloadRequests[i]._resourceId,
                newResourceMetadata: emptyResourceMetadata,
                lockData: bytes(""),
                revertDataSender: bytes(""),
                revertDataReceiver: bytes(""),
                transferMetadata: emptyMetadata
            });
        }

        return _sendBatch(request);
    }

    function sendToResourceId(
        uint256 _dstChainId,
        bytes32 _resourceId,
        bytes calldata _payload,
        bytes memory _lockData,
        bytes memory _revertDataSender,
        bytes memory _revertDataReceiver,
        BridgedTransferMetadata memory transferMetadata
    ) external payable virtual restricted returns (bytes32 messageId) {
        NewResourceMetadata memory emptyResourceMetadata;
        return _send(
            SendRequest({
                dstChainId: _dstChainId,
                destination: address(0),
                payload: _payload,
                resourceId: _resourceId,
                newResourceMetadata: emptyResourceMetadata,
                lockData: _lockData,
                revertDataSender: _revertDataSender,
                revertDataReceiver: _revertDataReceiver,
                transferMetadata: transferMetadata
            })
        );
    }

    function sendBatchToResourceId(ResourceIdCompletePayloadRequest[] calldata _resourceIdPayloadRequests)
        external
        payable
        virtual
        restricted
        returns (bytes32 batchId)
    {
        require(
            _resourceIdPayloadRequests.length < getMaxBatchMessages(),
            "The max number of transactions allowed in a batch has been exceeded"
        );

        SendRequest[] memory request = new SendRequest[](_resourceIdPayloadRequests.length);

        for (uint256 i = 0; i < _resourceIdPayloadRequests.length; i++) {
            NewResourceMetadata memory emptyResourceMetadata;

            request[i] = SendRequest({
                dstChainId: _resourceIdPayloadRequests[i]._dstChainId,
                destination: address(0),
                payload: _resourceIdPayloadRequests[i]._payload,
                resourceId: _resourceIdPayloadRequests[i]._resourceId,
                newResourceMetadata: emptyResourceMetadata,
                lockData: _resourceIdPayloadRequests[i]._lockData,
                revertDataSender: _resourceIdPayloadRequests[i]._revertDataSender,
                revertDataReceiver: _resourceIdPayloadRequests[i]._revertDataReceiver,
                transferMetadata: _resourceIdPayloadRequests[i].transferMetadata
            });
        }

        return _sendBatch(request);
    }

    /**
     * @notice Internal function to send a batch of messages
     * @dev Uses the BatchMessageSender module to prepare and send the batch
     * @param request Array of send requests
     * @return The batch ID
     */
    function _sendBatch(SendRequest[] memory request) internal virtual returns (bytes32) {
        require(address(batchMessageSender) != address(0), "EndpointV1: BatchMessageSender module not configured");
        require(address(messageReceiver) != address(0), "EndpointV1: MessageReceiver module not configured");

        // Use the BatchMessageSender to prepare the batch
        (BatchMessage[] memory messages, bytes32 batchId,) =
            batchMessageSender.prepareBatch(request, msg.sender, chainId);

        // Process local messages
        for (uint256 i = 0; i < messages.length; i++) {
            if (messages[i].toChainId == chainId) {
                messageReceiver.receivePayload(
                    chainId, msg.sender, messages[i].to, messages[i].data, messages[i].messageId
                );
            }
        }

        // Send the batch
        bytes32 dispatchedBatchId = dispatchMessageBatch(batchId, msg.sender, messages);
        require(dispatchedBatchId == batchId, "EndpointV1: dispatchMessageBatch should return batchId");

        return batchId;
    }

    /**
     * @notice Internal function to send a message
     * @dev Uses the MessageSender module to prepare and send the message
     * @param request The send request
     * @return The message ID
     */
    function _send(SendRequest memory request) internal virtual returns (bytes32) {
        require(address(messageSender) != address(0), "EndpointV1: MessageSender module not configured");
        require(address(messageReceiver) != address(0), "EndpointV1: MessageReceiver module not configured");

        // Use the MessageSender module
        (RaylsMessage memory messagePayload, bytes32 messageId,) = messageSender.prepareMessage(request, msg.sender);

        if (request.dstChainId == chainId) {
            messageReceiver.receivePayload(chainId, msg.sender, request.destination, messagePayload, messageId);
        } else {
            bytes32 dispatchedMessageId =
                dispatchMessage(messageId, msg.sender, request.dstChainId, request.destination, messagePayload);
            require(dispatchedMessageId == messageId, "EndpointV1: dispatchMessage should return messageId");
        }

        return messageId;
    }

    /**
     * @notice Registers a resource ID with an implementation address
     * @dev Associates a resource ID with a contract address in the ResourceManager
     * @dev Only ENDPOINT_SENDER_ROLE holders (or ADMIN) can register resource IDs
     * @param _resourceId The resource ID to register
     * @param _implementationAddress The address of the implementation contract
     */
    function registerResourceId(bytes32 _resourceId, address _implementationAddress) external virtual restricted {
        require(address(resourceManager) != address(0), "EndpointV1: ResourceManager module not configured");
        resourceManager.registerResourceId(_resourceId, _implementationAddress);
        emit ResourceIdRegistered(_resourceId, _implementationAddress);
    }

    /**
     * @notice Receives a payload from another chain
     * @dev Uses the MessageReceiver module to process the received payload
     * @param _srcChainId The ID of the source chain
     * @param _srcAddress The address on the source chain
     * @param _dstAddress The destination address on this chain
     * @param _raylsMessage The message payload
     * @param _messageId The message ID
     */
    function receivePayload(
        uint256 _srcChainId,
        address _srcAddress,
        address _dstAddress,
        RaylsMessage memory _raylsMessage,
        bytes32 _messageId
    ) public virtual override restricted {
        require(address(messageReceiver) != address(0), "EndpointV1: MessageReceiver module not configured");
        messageReceiver.receivePayload(_srcChainId, _srcAddress, _dstAddress, _raylsMessage, _messageId);
    }

    /**
     * @notice Gets the inbound nonce for a source chain
     * @param _srcChainId The ID of the source chain
     * @return The inbound nonce
     */
    function getInboundNonce(uint256 _srcChainId) external view virtual override returns (uint256) {
        require(address(messageReceiver) != address(0), "EndpointV1: MessageReceiver module not configured");
        return messageReceiver.getInboundNonce(_srcChainId);
    }

    /**
     * @notice Gets the outbound nonce for a destination chain
     * @param _dstChainId The ID of the destination chain
     * @return The outbound nonce
     */
    function getOutboundNonce(uint256 _dstChainId) external view virtual override returns (uint256) {
        require(address(messageSender) != address(0), "EndpointV1: MessageSender module not configured");
        return messageSender.getOutboundNonce(_dstChainId);
    }

    function getChainId() external view virtual override returns (uint256) {
        return chainId;
    }

    function getPrivateHubId() external view virtual override returns (uint256) {
        return privateHubId;
    }

    function registerPrivateHubAddress(string memory _contractName, address _contractAddressOnPrivateHub)
        external
        virtual
        override
        restricted
    {
        if (_contractAddressOnPrivateHub == address(0)) {
            revert Endpoint__InvalidPrivateHubAddress();
        }
        if (bytes(_contractName).length == 0) {
            revert Endpoint__EmptyContractName();
        }
        emit PrivateHubAddressRegistered(_contractName, _contractAddressOnPrivateHub);

        privateHubAddress[_contractName] = _contractAddressOnPrivateHub;
    }

    function setMaxBatchMessages(uint256 _maxBatchMessages) public restricted {
        maxBatchMessages = _maxBatchMessages;
    }

    function getMaxBatchMessages() public view returns (uint256) {
        return maxBatchMessages;
    }

    /**
     * @notice Dispatch a message to another chain and emit the associated event.
     * @param from The address sending the message.
     * @param toChainId The unique identifier to the chain to which the message will be delivered
     * @param to The address on the target chain to which the message will be delivered.
     * @param data The call data to send with the message.
     * @param messageId A unique identifier for the dispatched message.
     * @return messageId A unique identifier for the dispatched message.
     */
    function dispatchMessage(bytes32 messageId, address from, uint256 toChainId, address to, RaylsMessage memory data)
        private
        returns (bytes32)
    {
        emit MessageDispatched(messageId, from, toChainId, to, data);
        return messageId;
    }

    /**
     * @notice Dispatch a message batch to another chain and emit the associated event.
     * @param batchId A unique identifier for the dispatched batch.
     * @param from The address sending the message batch.
     * @param messages The messages being dispatched on the batch.
     * @return batchId A unique identifier for the dispatched batch.
     */
    function dispatchMessageBatch(bytes32 batchId, address from, BatchMessage[] memory messages)
        private
        returns (bytes32)
    {
        emit MessageBatchDispatched(batchId, from, messages);
        return batchId;
    }

    /**
     * @notice Gets a contract address from private hub by it's name
     * @param _contractName The name of the contract
     */
    function getPrivateHubAddress(string memory _contractName) external view virtual override returns (address) {
        require(
            privateHubAddress[_contractName] != (address(0)),
            string(abi.encodePacked("Private hub contract '", _contractName, "' not mapped on endpoint"))
        );
        return privateHubAddress[_contractName];
    }

    /**
     * @notice Retrieves the protocol version .
     * @return The protocol version.
     */
    function version() external pure virtual returns (string memory) {
        return "2.5";
    }

    ///@dev returns the contract version
    function contractVersion() external pure virtual returns (uint256) {
        return 1;
    }

    /// @dev Required by the OZ UUPS module
    /// @param newImplementation Address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal override {
        _checkCanCall(msg.sender, msg.sig);
    }

    /**
     * @notice Configures the Endpoint with all required contracts and modules
     * @dev Sets up both the legacy contracts and the modular architecture components
     * @param _contractFactory Address of the contract factory
     * @param _participantStorageReplica Address of the participant storage replica
     * @param _tokenRegistry Address of the PN token registry
     * @param _resourceManager Address of the ResourceManager module
     * @param _messageSender Address of the MessageSender module
     * @param _messageReceiver Address of the MessageReceiver module
     * @param _batchMessageSender Address of the batch message sender module
     */
    function configureEndpoint(
        address _contractFactory,
        address _participantStorageReplica,
        address _tokenRegistry,
        address _resourceManager,
        address _messageSender,
        address _messageReceiver,
        address _batchMessageSender
    ) external virtual restricted {
        // Configure legacy contracts
        contractFactory = RaylsContractFactoryV1(_contractFactory);
        participantStorageReplica = IParticipantValidator(_participantStorageReplica);
        tokenRegistry = ITokenRegistryValidator(_tokenRegistry);

        // Configure modules
        resourceManager = IResourceManager(_resourceManager);
        messageSender = IMessageSender(_messageSender);
        messageReceiver = IMessageReceiver(_messageReceiver);
        batchMessageSender = IBatchMessageSender(_batchMessageSender);

        emit EndpointConfigured(
            _contractFactory,
            _participantStorageReplica,
            _tokenRegistry,
            _resourceManager,
            _messageSender,
            _messageReceiver,
            _batchMessageSender
        );
    }

    ///@dev Entrypoint for triggering Rayls View key update flow
    function requestNewRaylsViewKeys(uint256 blockNumber) public virtual restricted {
        emit UpdateRaylsViewKeysRequest(blockNumber);
    }

    ///@notice Returns the PN token registry address
    function getTokenRegistry() external view returns (address) {
        return address(tokenRegistry);
    }

    ///@notice Returns the user governance address
    function getUserGovernanceAddress() external view returns (address) {
        return address(userGovernance);
    }
}
