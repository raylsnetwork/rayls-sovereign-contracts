// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Initializable} from '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import {UUPSUpgradeable} from '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import {IMessageDispatcher} from "./interfaces/IMessageDispatcher.sol";
import {IRaylsNodeEndpoint, RNSendRequest} from "./interfaces/IRaylsNodeEndpoint.sol";
import {RNMessageExecutorV1} from './RNMessageExecutorV1.sol';
import {RaylsNodeMessage, RaylsNodeMessageMetadata, RaylsNodeNewResourceMetadata, RaylsNodeBridgedTransferMetadata} from './RNMessageLib.sol';
import {ITokenRegistry} from "../../rayls-protocol/TokenRegistry/interfaces/ITokenRegistry.sol";
import {IUserGovernance} from "./interfaces/IUserGovernanceV1.sol";
import {RaylsAccessManaged} from "../../privateHub/AccessControl/RaylsAccessManaged.sol";

/**
 * @title RNEndpointV1
 * @notice Privacy Node endpoint for cross-chain messaging in the Rayls Network
 * @dev Implements EIP-5164 compliant cross-chain message dispatching. Replay protection is enforced by RNMessageExecutorV1.
 * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
 */
contract RNEndpointV1 is Initializable, IRaylsNodeEndpoint, UUPSUpgradeable, RaylsAccessManaged {

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    uint256 public currentChainId;
    uint256 public publicChainId;
    uint256 public nonce;

    RNMessageExecutorV1 public messageExecutor;
    ITokenRegistry public tokenRegistry;
    IUserGovernance public userGovernance;
    IMessageDispatcher public messageDispatcher;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error RNEndpointV1__TokenUnauthorizedAccount(address account);
    error RNEndpointV1__CalledByUnauthorizedAddress(address account);
    error RNEndpointV1__TokenNotFound(address privateAddress);
    error RNEndpointV1__TokenNotActive(address privateAddress);
    error RNEndpointV1__NoPublicAddressMapping(address privateAddress);
    error RNEndpointV1__InvalidMessageExecutorAddress();
    error RNEndpointV1__InvalidTokenRegistryAddress();
    error RNEndpointV1__InvalidUserGovernanceAddress();
    error RNEndpointV1__InvalidMessageDispatcherAddress();
    error RNEndpointV1__SourceAndDestinationChainsSame();

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Restricts function access to active token contracts only
     */
    modifier onlyAuthorizedTokens() {
        if (!tokenRegistry.tokenExists(msg.sender) || !tokenRegistry.isTokenActiveForPublicChain(msg.sender)) {
            revert RNEndpointV1__TokenUnauthorizedAccount(msg.sender);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the RayLS Node Endpoint contract
     * @param _chainId Current chain identifier
     * @param _publicChainId Public chain identifier for bridging
     * @param authority_ Address of the RaylsAccessManager contract
     */
    function initialize(
        uint256 _chainId,
        uint256 _publicChainId,
        address authority_
    ) public initializer {
        __UUPSUpgradeable_init();
        currentChainId = _chainId;
        publicChainId = _publicChainId;
        _initializeAuthority(authority_);
    }

    /// @dev Resolves diamond ambiguity: both IRaylsNodeEndpoint and RaylsAccessManaged declare authority().
    function authority() public view override(IRaylsNodeEndpoint, RaylsAccessManaged) returns (address) {
        return RaylsAccessManaged.authority();
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Configures contract dependencies
     * @param _messageExecutor Address of the message executor contract
     * @param _tokenRegistry Address of the PN token registry contract
     * @param _userGovernance Address of the user governance contract
     * @param _messageDispatcher Address of the message dispatcher contract
     */
    function configureContracts(
        address _messageExecutor,
        address _tokenRegistry,
        address _userGovernance,
        address _messageDispatcher
    ) external virtual restricted {
        if (_messageExecutor == address(0)) revert RNEndpointV1__InvalidMessageExecutorAddress();
        if (_tokenRegistry == address(0)) revert RNEndpointV1__InvalidTokenRegistryAddress();
        if (_userGovernance == address(0)) revert RNEndpointV1__InvalidUserGovernanceAddress();
        if (_messageDispatcher == address(0)) revert RNEndpointV1__InvalidMessageDispatcherAddress();

        messageExecutor = RNMessageExecutorV1(_messageExecutor);
        tokenRegistry = ITokenRegistry(_tokenRegistry);
        userGovernance = IUserGovernance(_userGovernance);
        messageDispatcher = IMessageDispatcher(_messageDispatcher);
    }

    /**
     * @notice Sends a cross-chain message to a destination address
     * @param _dstChainId Destination chain identifier
     * @param _destination Destination contract address
     * @param _payload Encoded message payload
     * @return messageId Unique identifier for the dispatched message
     */
    function send(
        uint256 _dstChainId,
        address _destination,
        bytes calldata _payload
    ) external virtual override onlyAuthorizedTokens returns (bytes32 messageId) {
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
     * @dev Resolves private chain address to public chain address before sending
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
    ) external virtual override onlyAuthorizedTokens returns (bytes32 messageId) {
        if (!tokenRegistry.tokenExists(_privateChainAddress)) {
            revert RNEndpointV1__TokenNotFound(_privateChainAddress);
        }

        if (!tokenRegistry.isTokenActiveForPublicChain(_privateChainAddress)) {
            revert RNEndpointV1__TokenNotActive(_privateChainAddress);
        }

        address publicAddress = tokenRegistry.getTokenByAddress(_privateChainAddress).publicTokenAddress;

        if (publicAddress == address(0)) {
            revert RNEndpointV1__NoPublicAddressMapping(_privateChainAddress);
        }

        RaylsNodeNewResourceMetadata memory emptyResourceMetadata;
        return
            _send(
            RNSendRequest({
                dstChainId: _dstChainId,
                destination: publicAddress,
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
     * @notice Returns the protocol version
     * @return Protocol version string
     */
    function version() external pure virtual returns (string memory) {
        return '2.6';
    }

    /**
     * @notice Returns the contract version
     * @return Contract version number
     */
    function contractVersion() external pure virtual returns (uint256) {
        return 1;
    }

    /**
     * @notice Returns the PN token registry contract address
     * @return Address of the token registry contract
     */
    function getTokenRegistryAddress() external view returns (address) {
        return address(tokenRegistry);
    }

    /**
     * @notice Returns the user governance contract address
     * @return Address of the user governance contract
     */
    function getUserGovernanceAddress() external view returns (address) {
        return address(userGovernance);
    }

    /**
     * @notice Returns the message dispatcher contract address
     * @return Address of the message dispatcher contract
     */
    function getMessageDispatcherAddress() external view returns (address) {
        return address(messageDispatcher);
    }

    /**
     * @notice Returns the current chain identifier
     * @return Current chain ID
     */
    function getChainId() external view virtual override returns (uint256) {
        return currentChainId;
    }

    /**
     * @notice Returns the current nonce for message dispatching
     * @return Current nonce value
     */
    function getNonce() external view returns (uint256) {
        return nonce;
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

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
            revert RNEndpointV1__SourceAndDestinationChainsSame();
        } else {
            bytes32 messageId = messageDispatcher.dispatchMessage(currentChainId, msg.sender, request.dstChainId, request.destination, _messagePayload);
            return messageId;
        }
    }
}
