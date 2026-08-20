// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {RaylsContractFactoryV1} from "../../rayls-protocol/RaylsContractFactory/RaylsContractFactoryV1.sol";
import {RaylsNodeMessage, RaylsNodeBridgedTransferMetadata, RaylsNodeNewResourceMetadata, RNSendRequest, RaylsNodeMessageMetadata} from "./RNMessageLib.sol";
import {IMessageDispatcher} from "./interfaces/IMessageDispatcher.sol";
import {IPublicRaylsNodeEndpoint} from "./interfaces/IPublicRaylsNodeEndpoint.sol";
import {RNMessageExecutorV1} from "./RNMessageExecutorV1.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {RaylsAccessManaged} from "../../privateHub/AccessControl/RaylsAccessManaged.sol";

/**
 * @title PublicRNEndpointV1
 * @notice Public chain endpoint for cross-chain messaging in the Rayls Network
 * @dev Implements EIP-5164 compliant cross-chain message dispatching. Replay protection is enforced by RNMessageExecutorV1.
 * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
 */
contract PublicRNEndpointV1 is Initializable, IPublicRaylsNodeEndpoint, UUPSUpgradeable, RaylsAccessManaged {

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error PublicRNEndpointV1__InvalidMessageExecutorAddress();
    error PublicRNEndpointV1__InvalidMessageDispatcherAddress();
    error PublicRNEndpointV1__SourceAndDestinationChainsSame();

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    uint256 public currentChainId;
    RNMessageExecutorV1 public messageExecutor;
    IMessageDispatcher public messageDispatcher;

    /// @notice EIP-5164 compliant nonce and execution tracking
    uint256 public nonce;

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTORS
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the Public RayLS Node Endpoint contract
     * @param _chainId Current chain identifier
     * @param authority_ Address of the RaylsAccessManagerV1 instance
     */
    function initialize(uint256 _chainId, address authority_) public initializer {
        __UUPSUpgradeable_init();
        currentChainId = _chainId;
        _initializeAuthority(authority_);
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Configures contract dependencies
     * @param _messageExecutor Address of the message executor contract
     * @param _messageDispatcher Address of the message dispatcher contract
     */
    function configureContracts(address _messageExecutor, address _messageDispatcher) external virtual restricted {
        if (_messageExecutor == address(0)) revert PublicRNEndpointV1__InvalidMessageExecutorAddress();
        if (_messageDispatcher == address(0)) revert PublicRNEndpointV1__InvalidMessageDispatcherAddress();

        messageExecutor = RNMessageExecutorV1(_messageExecutor);
        messageDispatcher = IMessageDispatcher(_messageDispatcher);
    }

    /// @dev Resolves diamond ambiguity: both IPublicRaylsNodeEndpoint and RaylsAccessManaged declare authority().
    function authority() public view override(IPublicRaylsNodeEndpoint, RaylsAccessManaged) returns (address) {
        return RaylsAccessManaged.authority();
    }

    /**
     * @notice Sends a cross-chain message to a destination address
     * @param _dstChainId Destination chain identifier
     * @param _destination Destination contract address
     * @param _payload Encoded message payload
     * @return messageId Unique identifier for the dispatched message
     */
    function send(uint256 _dstChainId, address _destination, bytes calldata _payload) external virtual override restricted returns (bytes32 messageId)  {
        RaylsNodeNewResourceMetadata memory emptyResourceMetadata;
        RaylsNodeBridgedTransferMetadata memory emptyMetadata;
        return
            _send(
            RNSendRequest({
                dstChainId: _dstChainId,
                destination: _destination,
                payload: _payload,
                newResourceMetadata: emptyResourceMetadata,
                revertData: bytes(''),
                transferMetadata: emptyMetadata
            })
        );
    }

    /**
     * @notice Sends a cross-chain message with token address mapping
     * @dev Sends message from public to private chain
     * @param _dstChainId Destination chain identifier
     * @param _privateChainAddress Private chain token address
     * @param _payload Encoded message payload
     * @param _revertDataPayload Revert data for failed transactions
     * @param transferMetadata Bridged transfer metadata
     * @return messageId Unique identifier for the dispatched message
     */
    function sendToAddress(
        uint256 _dstChainId,
        address _privateChainAddress,
        bytes calldata _payload,
        bytes memory _revertDataPayload,
        RaylsNodeBridgedTransferMetadata memory transferMetadata
    ) external virtual override restricted returns (bytes32 messageId) {

        RaylsNodeNewResourceMetadata memory emptyResourceMetadata;
        return
            _send(
            RNSendRequest({
                dstChainId: _dstChainId,
                destination: _privateChainAddress,  // Use public address as destination
                payload: _payload,
                newResourceMetadata: emptyResourceMetadata,
                revertData: _revertDataPayload,
                transferMetadata: transferMetadata
            })
        );
    }

    /**
     * @notice Receives and executes a cross-chain message
     * @dev Only callable by authorized relayers. Replay protection is enforced by RNMessageExecutorV1.
     * @param _srcChainId Source chain identifier
     * @param _srcAddress Source contract address
     * @param _dstAddress Destination contract address
     * @param _raylsMessage Message payload and metadata
     * @param _messageId Unique message identifier
     */
    function receivePayload(
        uint256 _srcChainId,
        address _srcAddress,
        address _dstAddress,
        RaylsNodeMessage memory _raylsMessage,
        bytes32 _messageId
    ) public virtual override restricted {
        // Replay protection is enforced exclusively by RNMessageExecutorV1.executeMessage,
        // which is the universal funnel (onlyEndpoint) — this keeps a single source of
        // truth for `executed` across endpoint rotations and removes duplicate SSTOREs.
        messageExecutor.executeMessage(_dstAddress, _raylsMessage.payload, _messageId, _srcChainId, _srcAddress);
    }

    /*//////////////////////////////////////////////////////////////
                    EXTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Retrieves the protocol version
     * @return The protocol version string
     */
    function version() external pure virtual returns (string memory) {
        return '2.6';
    }

    /**
     * @notice Returns the contract version
     * @return The contract version number
     */
    function contractVersion() external pure virtual returns (uint256) {
        return 1;
    }

    /**
     * @notice Returns the message dispatcher address
     * @return Address of the message dispatcher contract
     */
    function getMessageDispatcherAddress() external view returns (address) {
        return address(messageDispatcher);
    }

    /**
     * @notice Returns the current chain identifier
     * @return The current chain ID
     */
    function getChainId() external view virtual override returns (uint256) {
        return currentChainId;
    }

    /**
     * @notice Returns the current nonce for message dispatching
     * @return The current nonce value
     */
    function getNonce() external view returns (uint256) {
        return nonce;
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Required by OpenZeppelin UUPS module for upgrade authorization
     * @param newImplementation Address of the new implementation
     */
    /// @dev Upgrade authorization is gated by the access manager (ADMIN required).
    function _authorizeUpgrade(address /*newImplementation*/) internal view override {
        _checkCanCall(msg.sender, msg.sig);
    }

    /**
     * @dev Internal function to send cross-chain messages
     * @param request Send request containing destination and payload details
     * @return Unique message identifier
     */
    function _send(RNSendRequest memory request) internal virtual returns (bytes32) {
        // Increment EIP-5164 compliant nonce
        uint256 currentNonce = ++nonce;

        RaylsNodeMessage memory _messagePayload = RaylsNodeMessage({
            messageMetadata: RaylsNodeMessageMetadata({
            nonce: currentNonce,
            newResourceMetadata: request.newResourceMetadata,
            transferMetadata: request.transferMetadata,
            revertPayloadData: request.revertData
        }),
            payload: request.payload
        });

        if (request.dstChainId == currentChainId) {
            revert PublicRNEndpointV1__SourceAndDestinationChainsSame();
        } else {
            bytes32 messageId = messageDispatcher.dispatchMessage(currentChainId, msg.sender, request.dstChainId, request.destination, _messagePayload);
            return messageId;
        }
    }
}
