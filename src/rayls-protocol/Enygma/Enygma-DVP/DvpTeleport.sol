// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";

/**
 * @title DvpTeleport
 * @notice Contract for emitting DVP-related cross-chain events
 * @dev Access control delegated to RaylsAccessManagerV1 via the `restricted` modifier.
 *      CoinVault contracts must hold COIN_VAULT_ROLE; DVP contracts must hold DVP_CONTRACT_ROLE.
 *      Both roles are granted by holders of FACTORY_ADMIN_ROLE (the shared role admin).
 */
contract DvpTeleport is RaylsAccessManaged {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event ERCDvpBalanceUpdated(bytes encryptedMessage);
    event SwapInitiated(bytes32 indexed sharedId, bytes encryptedData, bytes ctxt, uint256 responderCommitment, uint256 expiresAt);
    event SwapCompleted(bytes32 indexed sharedId, bytes encryptedData);
    event SwapCancelled(bytes32 indexed sharedId);
    event SwapTimedOut(bytes32 indexed sharedId);

    // Dvp vault events
    event Commitments(address indexed tokenAddress, uint256 tokenType, uint256 indexed treeNumber, uint256[] commitments);
    event Nullifiers(address indexed tokenAddress, uint256 tokenType, uint256[] nullifiers);

    constructor(address authority_) {
        _setAuthority(authority_);
    }

    /*//////////////////////////////////////////////////////////////
                      DVP CONTRACT EVENT EMITTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emits ERCDvpBalanceUpdated event
    /// @dev Only callable by authorized DvP contracts
    function ercDvpBalanceUpdated(bytes calldata encryptedMessage) external restricted {
        emit ERCDvpBalanceUpdated(encryptedMessage);
    }

    /// @notice Emits SwapInitiated event after initiateSwap on the Dvp contract
    /// @dev Only callable by authorized DvP contracts
    function emitSwapInitiated(
        bytes32 sharedId,
        bytes calldata encryptedData,
        bytes calldata ctxt,
        uint256 responderCommitment,
        uint256 expiresAt
    ) external restricted {
        emit SwapInitiated(sharedId, encryptedData, ctxt, responderCommitment, expiresAt);
    }

    /// @notice Emits SwapCompleted state change event
    /// @dev Only callable by authorized DvP contracts
    function emitSwapCompleted(bytes32 sharedId, bytes calldata encryptedData) external restricted {
        emit SwapCompleted(sharedId, encryptedData);
    }

    /// @notice Emits SwapReverted event
    /// @dev Only callable by authorized DvP contracts
    function emitSwapCancelled(bytes32 sharedId) external restricted {
        emit SwapCancelled(sharedId);
    }

    /// @notice Emits SwapTimedOut event
    /// @dev Only callable by authorized DvP contracts
    function emitSwapTimedOut(bytes32 sharedId) external restricted {
        emit SwapTimedOut(sharedId);
    }

    /*//////////////////////////////////////////////////////////////
                      COINVAULT EVENT EMITTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emits Commitments event for vault merkle tree updates
    /// @dev Only callable by authorized CoinVault contracts
    function emitCommitments(address tokenAddress, uint256 tokenType, uint256 treeNumber, uint256[] calldata commitments) public restricted {
        emit Commitments(tokenAddress, tokenType, treeNumber, commitments);
    }

    /// @notice Emits Nullifiers event for vault nullifier tracking
    /// @dev Only callable by authorized CoinVault contracts
    function emitNullifiers(address tokenAddress, uint256 tokenType, uint256[] calldata nullifiers) public restricted {
        emit Nullifiers(tokenAddress, tokenType, nullifiers);
    }
}
