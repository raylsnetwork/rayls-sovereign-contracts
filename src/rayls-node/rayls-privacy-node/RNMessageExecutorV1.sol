// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {RNReentrancyGuardV1} from "./RNReentrancyGuardV1.sol";
import {IRNMessageExecutor, RNMessageLib} from './RNMessageLib.sol';
import {Initializable} from '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import {UUPSUpgradeable} from '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import {RaylsAccessManaged} from '../../privateHub/AccessControl/RaylsAccessManaged.sol';

/**
 * @title RNMessageExecutorV1
 * @notice Message executor for cross-chain messaging in the Rayls Network
 * @dev Handles message execution with replay protection and reentrancy guards
 * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
 */
contract RNMessageExecutorV1 is Initializable, IRNMessageExecutor, RNReentrancyGuardV1, UUPSUpgradeable, RaylsAccessManaged {

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error RNMessageExecutorV1__MessageIdAlreadyExecuted(bytes32 messageId);
    error RNMessageExecutorV1__MessageFailure(bytes32 messageId, bytes errorData);
    error RNMessageExecutorV1__MessageBatchFailure(bytes32 messageId, uint256 messageIndex, bytes errorData);
    error RNMessageExecutorV1__UnauthorizedEndpoint(address caller);
    error RNMessageExecutorV1__NoContractAtAddress(address contract_address);
    error RNMessageExecutorV1__InvalidEndpointAddress();

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    uint256 public currentChainId;
    address public authorizedEndpoint;

    /// @notice Mapping to uniquely identify the messages that were executed (messageId => boolean)
    /// @dev Ensure that messages cannot be replayed once they have been executed
    mapping(bytes32 => bool) public executed;

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Restricts function access to the authorized endpoint only
     */
    modifier onlyEndpoint() {
        if (msg.sender != authorizedEndpoint) {
            revert RNMessageExecutorV1__UnauthorizedEndpoint(msg.sender);
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
     * @notice Initializes the RN Message Executor contract
     * @param authority_ Address of the deployed RaylsAccessManagerV1.
     */
    function initialize(address authority_) public initializer {
        __UUPSUpgradeable_init();
        RNReentrancyGuardV1.initialize();
        currentChainId = block.chainid;
        _initializeAuthority(authority_);
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set the authorized endpoint that can execute messages
     * @param _authorizedEndpoint Address of the RaylsNodeEndpointV1 contract
     */
    function setAuthorizedEndpoint(address _authorizedEndpoint) external restricted {
        if (_authorizedEndpoint == address(0)) revert RNMessageExecutorV1__InvalidEndpointAddress();
        authorizedEndpoint = _authorizedEndpoint;
    }

    /**
     * @notice Executes a cross-chain message
     * @param to Address of the target contract
     * @param data Encoded message data
     * @param messageId Unique identifier for the message
     * @param fromChainId Source chain identifier
     * @param from Address of the message sender
     */
    function executeMessage(address to, bytes calldata data, bytes32 messageId, uint256 fromChainId, address from) external virtual override onlyEndpoint receiveNonReentrant {
        bool _executedMessageId = executed[messageId];
        executed[messageId] = true;

        if (_executedMessageId) {
            revert RNMessageExecutorV1__MessageIdAlreadyExecuted(messageId);
        }

        _requireContract(to);

        (bool _success, bytes memory _returnData) = to.call(data);

        if (!_success) {
            revert RNMessageExecutorV1__MessageFailure(messageId, _returnData);
        }

        emit MessageIdExecuted(fromChainId, messageId);
    }

    /**
     * @notice Executes a batch of cross-chain messages
     * @param messages Array of messages to execute
     * @param messageId Unique identifier for the batch
     * @param fromChainId Source chain identifier
     * @param from Address of the message sender
     */
    function executeMessageBatch(RNMessageLib.Message[] calldata messages, bytes32 messageId, uint256 fromChainId, address from) external virtual override onlyEndpoint receiveNonReentrant {
        bool _executedMessageId = executed[messageId];
        executed[messageId] = true;

        if (_executedMessageId) {
            revert RNMessageExecutorV1__MessageIdAlreadyExecuted(messageId);
        }

        uint256 _messagesLength = messages.length;

        for (uint256 _messageIndex; _messageIndex < _messagesLength;) {
            RNMessageLib.Message memory _message = messages[_messageIndex];
            _requireContract(_message.to);

            (bool _success, bytes memory _returnData) =
                _message.to.call(abi.encodePacked(_message.data, messageId, fromChainId, from));

            if (!_success) {
                revert RNMessageExecutorV1__MessageBatchFailure(messageId, _messageIndex, _returnData);
            }

            unchecked {
                _messageIndex++;
            }
        }

        emit MessageIdExecuted(fromChainId, messageId);
    }

    /*//////////////////////////////////////////////////////////////
                    EXTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the contract version
     * @return Contract version number
     */
    function contractVersion() external pure virtual returns (uint256) {
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

    /**
     * @dev Checks that the call is being made to a contract
     * @param to Address to check
     */
    function _requireContract(address to) internal view {
        if (to.code.length == 0) {
            revert RNMessageExecutorV1__NoContractAtAddress(to);
        }
    }
}
