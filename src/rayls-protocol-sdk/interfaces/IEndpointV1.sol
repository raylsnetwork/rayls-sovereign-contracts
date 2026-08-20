// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IEndpointV1
/// @notice Standard interface for Rayls protocol endpoint operations
///         Defines message sending, resource management, and cross-chain execution patterns
interface IEndpointV1 {
    // Structs
    /// @notice Request structure for sending cross-chain messages
    struct SendRequest {
        /// @param dstChainId Destination chain identifier
        uint256 dstChainId;
        /// @param destination Recipient address on destination chain
        address destination;
        /// @param payload Message payload to deliver
        bytes payload;
        /// @param resourceId Resource identifier for message routing
        bytes32 resourceId;
        /// @param newResourceMetadata Metadata for new resource registration
        NewResourceMetadata newResourceMetadata;
        /// @param lockData Lock data for message validation
        bytes lockData;
        /// @param revertDataSender Sender-side revert data
        bytes revertDataSender;
        /// @param revertDataReceiver Receiver-side revert data
        bytes revertDataReceiver;
        /// @param transferMetadata Metadata for bridged token transfers
        BridgedTransferMetadata transferMetadata;
    }

    /// @notice Request structure for destination-based payload delivery
    /// @dev Used to send arbitrary payload to a specific address on destination chain
    struct DestinationPayloadRequest {
        /// @dev Target chain identifier (e.g. 1 for Ethereum mainnet)
        uint256 _dstChainId;
        /// @dev Recipient address on destination chain
        address _destination;
        /// @dev Application-specific payload data to deliver
        bytes _payload;
    }

    /// @notice Request structure for resource ID-based payload delivery
    /// @dev Used to send payload to a specific resource handler on destination chain
    struct ResourceIdPayloadRequest {
        /// @dev Target chain identifier
        uint256 _dstChainId;
        /// @dev Resource identifier for the destination contract/handler
        bytes32 _resourceId;
        /// @dev Application-specific payload data to deliver
        bytes _payload;
    }

    /// @notice Complete request structure for resource ID-based message delivery
    /// @dev Contains full message data including revert handling and transfer metadata
    struct ResourceIdCompletePayloadRequest {
        /// @dev Target chain identifier
        uint256 _dstChainId;
        /// @dev Resource identifier for the destination contract/handler
        bytes32 _resourceId;
        /// @dev Application-specific payload data
        bytes _payload;
        /// @dev Locking data for cross-chain validation
        bytes _lockData;
        /// @dev Data to return to sender on revert
        bytes _revertDataSender;
        /// @dev Data to return to receiver on revert
        bytes _revertDataReceiver;
        /// @dev Metadata for bridged token transfers
        BridgedTransferMetadata transferMetadata;
    }

    /// @notice Metadata structure for new resource registration
    /// @dev Contains deployment configuration for new cross-chain resources
    struct NewResourceMetadata {
        /// @dev Validity flag for metadata
        bool valid;
        /// @dev Contract bytecode for deployment
        bytes bytecode;
        /// @dev Initialization parameters for deployed contract
        bytes initializerParams;
    }

    /// @notice Metadata structure for bridged token transfers
    /// @dev Tracks token bridging parameters between chains
    struct BridgedTransferMetadata {
        /// @dev Amount of tokens to bridge
        uint256 amount;
        /// @dev Source token address on originating chain
        address sourceToken;
        /// @dev Destination token address on target chain
        address destinationToken;
    }

    /// @notice Batch message structure for multiple message processing
    /// @dev Used for efficient processing of multiple cross-chain messages
    struct BatchMessage {
        /// @dev Target chain identifier
        uint256 toChainId;
        /// @dev Recipient address on target chain
        address to;
        /// @dev Encoded Rayls message data
        RaylsMessage data;
        /// @dev Unique identifier for message tracking
        bytes32 messageId;
    }

    /// @notice Message structure for Rayls protocol communication
    /// @dev Standard format for cross-chain message payloads
    struct RaylsMessage {
        /// @dev Metadata about the message itself
        RaylsMessageMetadata messageMetadata;
        /// @dev Application-specific payload data
        bytes payload;
    }

    /// @notice Metadata structure for Rayls messages
    /// @dev Contains critical parameters for message validation and execution
    struct RaylsMessageMetadata {
        /// @dev Validity flag for message metadata
        bool valid;
        /// @dev Message nonce for replay protection
        uint256 nonce;
        /// @dev Metadata for new resource deployments
        NewResourceMetadata newResourceMetadata;
        /// @dev Resource identifier for message routing
        bytes32 resourceId;
        /// @dev Metadata for token bridging operations
        BridgedTransferMetadata transferMetadata;
        /// @dev Locking data for cross-chain validation
        bytes lockData;
        /// @dev Data to return to sender on revert
        bytes revertPayloadDataSender;
        /// @dev Data to return to receiver on revert
        bytes revertPayloadDataReceiver;
        /// @dev Flag to bypass nonce validation when needed
        bool ignoresNonce;
    }

    // Events
    /// @notice Emitted when a single message is dispatched
    /// @param messageId Unique identifier for the dispatched message
    /// @param from Sender address
    /// @param toChainId Target chain identifier
    /// @param to Recipient address
    /// @param data Message payload
    event MessageDispatched(bytes32 indexed messageId, address indexed from, uint256 indexed toChainId, address to, RaylsMessage data);

    /// @notice Emitted when a batch of messages is dispatched
    /// @param batchId Unique identifier for the message batch
    /// @param from Sender address
    /// @param messages Array of batched messages
    event MessageBatchDispatched(bytes32 indexed batchId, address indexed from, BatchMessage[] messages);

    /// @notice Emitted when Rayls View key update is requested
    /// @param blockNumber Block number triggering key update
    event UpdateRaylsViewKeysRequest(uint256 blockNumber);

    // Functions
    /// @notice Retrieves address associated with a resource identifier
    /// @param _resourceId Resource identifier to lookup
    /// @return Address registered for the resource
    function getAddressByResourceId(bytes32 _resourceId) external view returns (address);

    /// @notice Sends a cross-chain message to a destination address
    /// @param _dstChainId Target chain identifier
    /// @param _destination Recipient address
    /// @param _payload Message payload
    /// @return messageId Unique identifier for the dispatched message
    function send(uint256 _dstChainId, address _destination, bytes calldata _payload) external payable returns (bytes32 messageId);

    /// @notice Sends a batch of destination-based payload requests
    /// @param _destinationPayloadRequests Array of payload requests
    /// @return batchId Unique identifier for the message batch
    function sendBatch(DestinationPayloadRequest[] calldata _destinationPayloadRequests) external returns (bytes32 batchId);

    /// @notice Sends a cross-chain message to a resource identifier
    /// @param _dstChainId Target chain identifier
    /// @param _resourceId Resource identifier to deliver to
    /// @param _payload Message payload
    /// @return messageId Unique identifier for the dispatched message
    function sendToResourceId(uint256 _dstChainId, bytes32 _resourceId, bytes calldata _payload) external payable returns (bytes32 messageId);

    /// @notice Sends a batch of resource ID-based payload requests
    /// @param _resourceIdPayloadRequests Array of payload requests
    /// @return batchId Unique identifier for the message batch
    function sendBatchToResourceId(ResourceIdPayloadRequest[] calldata _resourceIdPayloadRequests) external payable returns (bytes32 batchId);

    /// @notice Sends a cross-chain message with complete metadata
    /// @param _dstChainId Target chain identifier
    /// @param _resourceId Resource identifier to deliver to
    /// @param _payload Message payload
    /// @param _lockData Lock data for message validation
    /// @param _revertDataSender Sender-side revert data
    /// @param _revertDataReceiver Receiver-side revert data
    /// @param transferMetadata Metadata for bridged token transfers
    /// @return messageId Unique identifier for the dispatched message
    function sendToResourceId(
        uint256 _dstChainId,
        bytes32 _resourceId,
        bytes calldata _payload,
        bytes memory _lockData,
        bytes memory _revertDataSender,
        bytes memory _revertDataReceiver,
        BridgedTransferMetadata memory transferMetadata
    ) external payable returns (bytes32 messageId);

    /// @notice Sends a batch of complete resource ID-based payload requests
    /// @param _resourceIdPayloadRequests Array of complete payload requests
    /// @return batchId Unique identifier for the message batch
    function sendBatchToResourceId(ResourceIdCompletePayloadRequest[] calldata _resourceIdPayloadRequests) external payable returns (bytes32 batchId);

    /// @notice Processes an incoming cross-chain message
    /// @param _srcChainId Source chain identifier
    /// @param _srcAddress Message origin address
    /// @param _dstAddress Recipient address
    /// @param _raylsMessage Encapsulated message data
    /// @param _messageId Unique identifier for the message
    function receivePayload(uint256 _srcChainId, address _srcAddress, address _dstAddress, RaylsMessage memory _raylsMessage, bytes32 _messageId) external;

    /// @notice Retrieves inbound message nonce for a source chain
    /// @param _srcChainId Source chain identifier
    /// @return Current inbound nonce value
    function getInboundNonce(uint256 _srcChainId) external view returns (uint256);

    /// @notice Retrieves outbound message nonce for a destination chain
    /// @param _dstChainId Destination chain identifier
    /// @return Current outbound nonce value
    function getOutboundNonce(uint256 _dstChainId) external view returns (uint256);

    /// @notice Retrieves the current chain identifier
    /// @return Current chain's unique identifier
    function getChainId() external view returns (uint256);

    /// @notice Retrieves the private hub identifier
    /// @return Private hub's unique identifier
    function getPrivateHubId() external view returns (uint256);

    /// @notice Registers a contract address on the private hub
    /// @param _contractName Name of the contract to register
    /// @param _contractAddressOnPrivateHub Address of the contract on private hub
    function registerPrivateHubAddress(string memory _contractName, address _contractAddressOnPrivateHub) external;

    /// @notice Sets the maximum number of messages allowed in a batch
    /// @param _maxBatchMessages New maximum batch size
    function setMaxBatchMessages(uint256 _maxBatchMessages) external;

    /// @notice Retrieves the current maximum batch message limit
    /// @return Maximum allowed messages per batch
    function getMaxBatchMessages() external view returns (uint256);

    /// @notice Dispatches a single message for processing
    /// @param messageId Unique identifier for the message
    /// @param from Sender address
    /// @param toChainId Target chain identifier
    /// @param to Recipient address
    /// @param data Encapsulated message data
    /// @return batchId Unique identifier for the resulting batch (if any)
    function dispatchMessage(bytes32 messageId, address from, uint256 toChainId, address to, RaylsMessage memory data) external payable returns (bytes32);

    /// @notice Dispatches a batch of messages for processing
    /// @param batchId Unique identifier for the message batch
    /// @param from Sender address
    /// @param messages Array of batched messages
    /// @return batchId Unique identifier for the processed batch
    function dispatchMessageBatch(bytes32 batchId, address from, BatchMessage[] memory messages) external returns (bytes32);

    /// @notice Returns the protocol version as a string
    /// @return Version string
    function version() external pure returns (string memory);

    /// @notice Returns the contract version as a uint256
    /// @return Version number
    function contractVersion() external pure returns (uint256);

    /// @notice Requests Rayls View key update at specified block
    /// @param blockNumber Block number triggering the update
    function requestNewRaylsViewKeys(uint256 blockNumber) external;

    /// @notice Retrieves the PN token registry address
    /// @return Address of the PN token registry
    function getTokenRegistry() external view returns (address);

    /// @notice Retrieves a private hub contract address
    /// @param _contractName Name of the contract to lookup
    /// @return Address of the contract on private hub
    function getPrivateHubAddress(string memory _contractName) external view returns (address);
}
