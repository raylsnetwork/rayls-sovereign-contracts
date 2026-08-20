// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IMessageDispatcher, BatchMessage} from "./interfaces/IMessageDispatcher.sol";
import {RaylsNodeMessage, RNMessageLib} from "./RNMessageLib.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {RaylsAccessManaged} from "../../privateHub/AccessControl/RaylsAccessManaged.sol";

/**
 * @title RNMessageDispatcherV1
 * @notice Message dispatcher for cross-chain messaging in the Rayls Network
 * @dev Handles message dispatching and batch operations
 * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
 */
contract RNMessageDispatcherV1 is Initializable, UUPSUpgradeable, RaylsAccessManaged, IMessageDispatcher {

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Address of the authorized endpoint that can dispatch messages
    address public authorizedEndpoint;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error RNMessageDispatcherV1__UnauthorizedEndpoint(address caller);
    error RNMessageDispatcherV1__InvalidEndpointAddress();

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Restricts function access to the authorized endpoint only
     */
    modifier onlyEndpoint() {
        if (msg.sender != authorizedEndpoint) {
            revert RNMessageDispatcherV1__UnauthorizedEndpoint(msg.sender);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTORS
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the RN Message Dispatcher contract
     * @param authority_ Address of the deployed RaylsAccessManagerV1.
     */
    function initialize(address authority_) public initializer {
        __UUPSUpgradeable_init();
        _initializeAuthority(authority_);
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set the authorized endpoint that can dispatch messages
     * @param _authorizedEndpoint Address of the RaylsNodeEndpointV1 contract
     */
    function setAuthorizedEndpoint(address _authorizedEndpoint) external restricted {
        if (_authorizedEndpoint == address(0)) revert RNMessageDispatcherV1__InvalidEndpointAddress();
        authorizedEndpoint = _authorizedEndpoint;
    }

    /**
     * @notice Dispatch a message to another chain and emit the associated event
     * @param fromChainId The unique identifier of the chain from which the message is being sent
     * @param from The address sending the message
     * @param toChainId The unique identifier to the chain to which the message will be delivered
     * @param to The address on the target chain to which the message will be delivered
     * @param data The call data to send with the message
     * @return messageId A unique identifier for the dispatched message
     */
    function dispatchMessage(uint256 fromChainId, address from, uint256 toChainId, address to, RaylsNodeMessage memory data) external onlyEndpoint returns (bytes32) {
        // EIP-5164 compliant messageId generation including nonce for uniqueness
        bytes32 messageId = RNMessageLib.computeMessageId(fromChainId, from, toChainId, to, data.messageMetadata.nonce, abi.encode(data));
        emit MessageDispatched(messageId, from, toChainId, to, data);
        return messageId;
    }

    /**
     * @notice Dispatch a message batch to another chain and emit the associated event
     * @param batchId A unique identifier for the dispatched batch
     * @param from The address sending the message batch
     * @param messages The messages being dispatched on the batch
     * @return batchId A unique identifier for the dispatched batch
     */
    function dispatchMessageBatch(bytes32 batchId, address from, BatchMessage[] memory messages) external onlyEndpoint returns (bytes32) {
        emit MessageBatchDispatched(batchId, from, messages);
        return batchId;
    }

    /*//////////////////////////////////////////////////////////////
                    EXTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the protocol version
     * @return Protocol version string
     */
    function version() external pure returns (string memory) {
        return "1.0";
    }

    /**
     * @notice Returns the contract version
     * @return Contract version number
     */
    function contractVersion() external pure returns (uint256) {
        return 1;
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Required by OpenZeppelin UUPS module for upgrade authorization
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override {
        _checkCanCall(msg.sender, msg.sig);
    }
}
