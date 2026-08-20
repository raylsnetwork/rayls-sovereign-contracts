// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IRaylsEndpoint} from "../interfaces/IRaylsEndpoint.sol";
import {Constants} from "../Constants.sol";
import {RaylsAccessManaged} from "../../privateHub/AccessControl/RaylsAccessManaged.sol";

/**
 * @title EnygmaPNHEvents
 * @notice Emits cross-chain Enygma events on the private hub.
 * @dev This contract is called via cross-chain messaging by the trusted executor
 * to emit privacy-preserving transfer and mint completion events. Off-chain
 * governance infrastructure listens to these events for audit and tracking.
 *
 * Only the endpoint's trusted executor (MessageExecutor) can invoke the
 * event-emitting functions via the restricted modifier.
 */
contract EnygmaPNHEvents is RaylsAccessManaged {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error EnygmaPNHEvents__UnauthorizedExecutor(address caller);
    error EnygmaPNHEvents__InvalidEndpointAddress();

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The Rayls endpoint for cross-chain communication
    IRaylsEndpoint internal endpoint;

    /// @notice The resource ID identifying this contract in the Rayls network
    bytes32 public immutable resourceId;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the endpoint address is updated
    event EndpointUpdated(address indexed oldEndpoint, address indexed newEndpoint);

    /// @notice Emitted when a cross-chain Enygma transfer is completed on a Privacy Node
    event EnygmaPnTransferCompleted(bytes encryptedMessage);

    /// @notice Emitted when a cross-chain Enygma mint operation is completed
    event MintCompleted(bytes encryptedMessage);

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploys the EnygmaPNHEvents contract
     * @param _endpointAddress The address of the Rayls endpoint
     */
    constructor(address _endpointAddress) {
        if (_endpointAddress == address(0)) {
            revert EnygmaPNHEvents__InvalidEndpointAddress();
        }
        endpoint = IRaylsEndpoint(_endpointAddress);
        resourceId = Constants.RESOURCE_ID_ENYGMA_PNH_EVENTS;

        address mgr = endpoint.authority();
        if (mgr != address(0)) {
            _setAuthority(mgr);
        }
    }

    /**
     * @notice Updates the Rayls endpoint address
     * @dev Only callable by the contract owner. Validates against zero address.
     * @param _endpoint The new endpoint address
     */
    function setEndpoint(address _endpoint) external restricted {
        if (_endpoint == address(0)) {
            revert EnygmaPNHEvents__InvalidEndpointAddress();
        }
        address oldEndpoint = address(endpoint);
        endpoint = IRaylsEndpoint(_endpoint);
        emit EndpointUpdated(oldEndpoint, _endpoint);
    }

    /**
     * @notice Emits an event when an Enygma privacy transfer is completed on a Privacy Node
     * @dev Can only be called by the trusted executor via cross-chain messaging
     * @param encryptedMessage The encrypted transfer data for off-chain governance processing
     */
    function enygmaPnTransferCompleted(bytes calldata encryptedMessage) external restricted {
        emit EnygmaPnTransferCompleted(encryptedMessage);
    }

    /**
     * @notice Emits an event when an Enygma mint operation is completed
     * @dev Can only be called by the trusted executor via cross-chain messaging
     * @param encryptedMessage The encrypted mint data for off-chain governance processing
     */
    function mintCompleted(bytes calldata encryptedMessage) external restricted {
        emit MintCompleted(encryptedMessage);
    }
}
