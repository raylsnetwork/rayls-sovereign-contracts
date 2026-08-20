// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IEnygmaV1} from '../../interfaces/IEnygmaV1.sol';
import {RaylsAccessManaged} from '../../../privateHub/AccessControl/RaylsAccessManaged.sol';

/**
 * @title EnygmaTeleport
 * @notice Contract for emitting cross-chain Enygma transfer events
 * @dev Access control delegated to RaylsAccessManagerV1 via the `restricted` modifier.
 *      EnygmaV1 contracts must be granted ENYGMA_V1_ROLE on the shared manager by a
 *      caller that holds FACTORY_ADMIN_ROLE (the role admin of ENYGMA_V1_ROLE).
 */
contract EnygmaTeleport is RaylsAccessManaged {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error EnygmaTeleport__InvalidEndpointAddress();

    /*//////////////////////////////////////////////////////////////
                        STATE VARIABLES, EVENTS
    //////////////////////////////////////////////////////////////*/

    event EnygmaTransfer(bytes32 indexed resourceId, bytes encryptedMessage, uint256 messageTag, uint256 blockNumber, uint256[] anonymitySet, uint256[] arrayHashSecrets, uint256 toChainId);
    event EnygmaTransferCompleted(bytes encryptedMessage);
    event BalancesFinalized(bytes32 indexed resourceId, uint256 indexed finalizedBlockNumber, uint256 pendingBlockNumber, IEnygmaV1.EnygmaPointWithChainId[] balances);
    event EnygmaSupplyUpdated(bytes32 indexed resourceId, uint256 indexed blockNumber, IEnygmaV1.SupplyUpdateTx update, uint256 chainId);
    event EnygmaDvpBalanceUpdated(bytes encryptedMessage);

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    constructor(address authority_) {
        _setAuthority(authority_);
    }

    /**
     * @notice Initiates a cross-chain transfer by emitting a transfer event
     * @dev Restricted to ENYGMA_V1_ROLE holders via the shared access manager.
     */
    function transfer(bytes32 resourceId, bytes calldata encryptedMessage, uint256 messageTag, uint256 blockNumber, uint256[] calldata anonymitySet, uint256[] calldata arrayHashSecrets, uint256 toChainId) external restricted {
        emit EnygmaTransfer(resourceId, encryptedMessage, messageTag, blockNumber, anonymitySet, arrayHashSecrets, toChainId);
    }

    /**
     * @notice Signals the completion of an Enygma transfer
     * @dev Emits an event to notify that a transfer has been successfully completed
     */
    function enygmaTransferCompleted(bytes calldata encryptedMessage) external restricted {
        emit EnygmaTransferCompleted(encryptedMessage);
    }

    /**
     * @notice Notifies that the supply has been updated
     * @dev Restricted to ENYGMA_V1_ROLE holders via the shared access manager.
     */
    function enygmaSupplyUpdated(bytes32 resourceId, uint256 blockNumber, IEnygmaV1.SupplyUpdateTx calldata update, uint256 chainId) external restricted {
        emit EnygmaSupplyUpdated(resourceId, blockNumber, update, chainId);
    }

    /**
     * @notice Finalizes balance states for a specific resource at a given block
     * @dev Restricted to ENYGMA_V1_ROLE holders via the shared access manager.
     */
    function finalizeBalances(bytes32 resourceId, uint256 finalizedBlockNumber, uint256 pendingBlockNumber, IEnygmaV1.EnygmaPointWithChainId[] calldata balances) external restricted {
        emit BalancesFinalized(resourceId, finalizedBlockNumber, pendingBlockNumber, balances);
    }

    /**
     * @notice Notifies the Private Network Hub of Dvp balance updates (Enygma side)
     * @dev Restricted to ENYGMA_V1_ROLE holders via the shared access manager.
     */
    function enygmaDvpBalanceUpdated(bytes calldata encryptedMessage) external restricted {
        emit EnygmaDvpBalanceUpdated(encryptedMessage);
    }
}
