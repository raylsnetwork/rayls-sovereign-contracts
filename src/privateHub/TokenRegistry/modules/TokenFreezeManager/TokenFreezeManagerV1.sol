// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '../../interfaces/ITokenFreezeManager.sol';
import '../../interfaces/ITokenRegistry.sol';
import '../../libraries/TokenStructs.sol';
import '../../../../rayls-protocol-sdk/RaylsAppV1.sol';
import '../../../../rayls-protocol-sdk/Constants.sol';
import {ITokenRegistry as IPnTokenRegistry} from '../../../../rayls-protocol/TokenRegistry/interfaces/ITokenRegistry.sol';
import '../../../../privateHub/AccessControl/RaylsAccessManaged.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';

/**
 * @title TokenFreezeManagerV1
 * @dev Module responsible for managing token freezing functionality across the Rayls protocol.
 *
 * This contract handles the freezing and unfreezing of tokens for specific participants (chains).
 * It maintains a registry of frozen tokens and their associated participants, and provides
 * cross-chain communication to synchronize freeze status across all participants.
 *
 * Key features:
 * - Freeze/unfreeze tokens for specific participants
 * - Track frozen tokens and their participants
 * - Broadcast freeze status changes to all participants
 * - Synchronize freeze data with new participants
 *
 */
contract TokenFreezeManagerV1 is Initializable, ITokenFreezeManager, UUPSUpgradeable, RaylsAccessManaged {
    // ========== Storage Variables ==========

    /// @notice Address of the main TokenRegistry contract
    address public tokenRegistryAddress;

    /// @notice Reference to the Rayls endpoint for cross-chain communication
    IRaylsEndpoint public endpoint;

    /// @notice Array of all frozen tokens and their associated participants
    TokenStructs.FrozenToken[] internal frozenTokens;

    // ========== Events ==========

    /**
    * @notice Emitted when token freeze status changes
    * @param resourceId The resource ID of the token
    * @param chainIds Array of affected chain IDs
    * @param action Whether this is a freeze or unfreeze operation
    */
    event TokenFreezeStatusChanged(
        bytes32 indexed resourceId,
        uint256[] chainIds,
        TokenStructs.FreezeAction action
    );

    // ========== Modifiers ==========

    error TokenFreezeManagerV1__UnauthorizedCaller(address caller);

    /**
     * @dev Modifier to restrict functions to be called only by the TokenRegistry contract
     */
    modifier onlyTokenRegistry() {
        if (msg.sender != tokenRegistryAddress) {
            revert TokenFreezeManagerV1__UnauthorizedCaller(msg.sender);
        }
        _;
    }

    // ========== Initialization ==========

    /**
     * @notice Initializes the TokenFreezeManager contract
     * @dev This function can only be called once during contract deployment
     * @param _endpoint The address of the Rayls endpoint for cross-chain communication
     * @param _tokenRegistryAddress The address of the TokenRegistry contract
     * @param authority_ Address of the deployed RaylsAccessManagerV1.
     */
    function initialize(address _endpoint, address _tokenRegistryAddress, address authority_) public initializer {
        __UUPSUpgradeable_init();
        tokenRegistryAddress = _tokenRegistryAddress;
        endpoint = IRaylsEndpoint(_endpoint);
        _initializeAuthority(authority_);
    }

    /// @dev Upgrade authorization is gated by the access manager.
    function _authorizeUpgrade(address /*newImplementation*/) internal view override {
        _checkCanCall(msg.sender, msg.sig);
    }

    // ========== Module Configuration ==========

    /**
     * @notice Sets the TokenRegistry address
     * @dev Access-controlled via RaylsAccessManager
     * @param _tokenRegistryAddress The address of the TokenRegistry contract
     *
     * Requirements:
     * - Caller must have the appropriate role in the access manager
     * - _tokenRegistryAddress must be non-zero
     */
    function setTokenRegistryAddress(address _tokenRegistryAddress) external virtual restricted {
        require(_tokenRegistryAddress != address(0), 'TokenFreezeManager: TokenRegistry address cannot be zero');
        tokenRegistryAddress = _tokenRegistryAddress;
    }

    /**
     * @notice Sets the endpoint address
     * @dev Access-controlled via RaylsAccessManager
     * @param _endpoint The address of the Rayls endpoint
     *
     * Requirements:
     * - Caller must have the appropriate role in the access manager
     * - _endpoint must be non-zero
     */
    function setEndpoint(address _endpoint) external virtual restricted {
        require(_endpoint != address(0), 'TokenFreezeManager: Endpoint address cannot be zero');
        endpoint = IRaylsEndpoint(_endpoint);
    }

    // ========== Token Freezing Management ==========

    /**
     * @notice Freezes a token for specified participants
     * @dev Adds the specified chain IDs to the frozen participants list for the given token.
     * If the token is already frozen for some participants, new participants are added to the list.
     * @param resourceId The resource ID of the token to freeze
     * @param chainIds Array of chain IDs for which the token should be frozen
     *
     * Requirements:
     * - Caller must be the TokenRegistry contract
     * - resourceId must be valid
     * - chainIds array must not be empty
     */
    function freezeToken(bytes32 resourceId, uint256[] calldata chainIds) external virtual onlyTokenRegistry {
        uint256 frozenTokenIndex;
        bool found = false;

        // Check if the token already exists in the frozen tokens list
        for (uint256 i = 0; i < frozenTokens.length; i++) {
            if (frozenTokens[i].resourceId == resourceId) {
                frozenTokenIndex = i;
                found = true;
                break;
            }
        }

        if (found) {
            // Token already exists - add new frozen participants
            TokenStructs.FrozenToken storage frozenToken = frozenTokens[frozenTokenIndex];
            for (uint256 i = 0; i < chainIds.length; i++) {
                bool alreadyFrozen = false;
                // Check if participant is already frozen
                for (uint256 j = 0; j < frozenToken.frozenParticipants.length; j++) {
                    if (frozenToken.frozenParticipants[j] == chainIds[i]) {
                        alreadyFrozen = true;
                        break;
                    }
                }
                // Add participant if not already frozen
                if (!alreadyFrozen) {
                    frozenToken.frozenParticipants.push(chainIds[i]);
                }
            }
            broadcastFrozenToken(frozenToken);
        } else {
            // Token doesn't exist - create new frozen token entry
            TokenStructs.FrozenToken memory newFrozenToken;
            newFrozenToken.resourceId = resourceId;
            newFrozenToken.frozenParticipants = new uint256[](chainIds.length);
            for (uint256 i = 0; i < chainIds.length; i++) {
                newFrozenToken.frozenParticipants[i] = chainIds[i];
            }
            frozenTokens.push(newFrozenToken);
            broadcastFrozenToken(newFrozenToken);
        }

        // Notify Private Network Hub
        emit TokenFreezeStatusChanged(resourceId, chainIds, TokenStructs.FreezeAction.FREEZE);
    }

    /**
     * @notice Unfreezes a token for specified participants
     * @dev Removes the specified chain IDs from the frozen participants list for the given token.
     * If no participants remain frozen, the token entry is removed from the frozen tokens list.
     * @param resourceId The resource ID of the token to unfreeze
     * @param chainIds Array of chain IDs for which the token should be unfrozen
     *
     * Requirements:
     * - Caller must be the TokenRegistry contract
     * - Token must exist in the frozen tokens list
     */
    function unfreezeToken(bytes32 resourceId, uint256[] memory chainIds) external virtual onlyTokenRegistry {
        uint256 tokenIndex;
        bool found = false;

        // Find the token in the frozen tokens list
        for (uint256 i = 0; i < frozenTokens.length; i++) {
            if (frozenTokens[i].resourceId == resourceId) {
                tokenIndex = i;
                found = true;
                break;
            }
        }
        require(found, 'Token not found');

        TokenStructs.FrozenToken storage frozenToken = frozenTokens[tokenIndex];
        uint256[] storage frozenParticipants = frozenToken.frozenParticipants;

        // Remove the specified chain IDs from frozen participants
        for (uint256 i = 0; i < chainIds.length; i++) {
            for (uint256 j = 0; j < frozenParticipants.length; j++) {
                if (frozenParticipants[j] == chainIds[i]) {
                    // Replace with last element and pop to maintain array integrity
                    frozenParticipants[j] = frozenParticipants[frozenParticipants.length - 1];
                    frozenParticipants.pop();
                    break;
                }
            }
        }

        // If no frozen participants remain, remove the frozen token entry
        if (frozenParticipants.length == 0) {
            frozenTokens[tokenIndex] = frozenTokens[frozenTokens.length - 1];
            frozenTokens.pop();
        }

        // Broadcast the unfreeze event
        broadcastUnfrozenToken(TokenStructs.FrozenToken({resourceId: resourceId, frozenParticipants: chainIds}));

        // Notify Private Network Hub
        emit TokenFreezeStatusChanged(resourceId, chainIds, TokenStructs.FreezeAction.UNFREEZE);
    }

    // ========== Query Functions ==========

    /**
     * @notice Gets all frozen tokens
     * @dev Returns the complete list of frozen tokens and their associated participants
     * @return Array of all frozen tokens with their participants
     */
    function getAllFrozenTokens() external view virtual returns (TokenStructs.FrozenToken[] memory) {
        return frozenTokens;
    }

    /**
     * @notice Checks if a token is frozen for a specific participant
     * @dev Searches through the frozen tokens list to determine if the specified token
     * is frozen for the given participant
     * @param resourceId The resource ID of the token to check
     * @param chainId The chain ID of the participant to check
     * @return True if the token is frozen for the participant, false otherwise
     */
    function isTokenFrozenForParticipant(bytes32 resourceId, uint256 chainId) external view virtual returns (bool) {
        for (uint256 i = 0; i < frozenTokens.length; i++) {
            if (frozenTokens[i].resourceId == resourceId) {
                for (uint256 j = 0; j < frozenTokens[i].frozenParticipants.length; j++) {
                    if (frozenTokens[i].frozenParticipants[j] == chainId) {
                        return true;
                    }
                }
            }
        }
        return false;
    }

    // ========== Cross-Chain Communication ==========

    /**
     * @notice Broadcasts frozen token data to all participants
     * @dev Sends a cross-chain message to all participants informing them about a token
     * that has been frozen. This ensures all participants are synchronized.
     * @param frozenToken The frozen token data containing the token and participant information
     *
     * Requirements:
     * - Caller must be the TokenRegistry contract
     */
    function broadcastFrozenToken(TokenStructs.FrozenToken memory frozenToken) public virtual onlyTokenRegistry {
        BridgedTransferMetadata memory emptyMetadata;
        endpoint.sendToResourceId(
            Constants.CHAIN_ID_ALL_PARTICIPANTS,
            Constants.RESOURCE_ID_TOKEN_REGISTRY,
            abi.encodeWithSelector(IPnTokenRegistry.updateFrozenToken.selector, frozenToken),
            bytes(''),
            bytes(''),
            bytes(''),
            emptyMetadata
        );
    }

    /**
     * @notice Broadcasts unfrozen token data to all participants
     * @dev Sends a cross-chain message to all participants informing them about a token
     * that has been unfrozen. This ensures all participants are synchronized.
     * @param unfrozenToken The unfrozen token data containing the token and participant information
     *
     * Requirements:
     * - Caller must be the TokenRegistry contract
     */
    function broadcastUnfrozenToken(
        TokenStructs.FrozenToken memory unfrozenToken
    ) public virtual onlyTokenRegistry {
        BridgedTransferMetadata memory emptyMetadata;
        endpoint.sendToResourceId(
            Constants.CHAIN_ID_ALL_PARTICIPANTS,
            Constants.RESOURCE_ID_TOKEN_REGISTRY,
            abi.encodeWithSelector(IPnTokenRegistry.removeFrozenToken.selector, unfrozenToken),
            bytes(''),
            bytes(''),
            bytes(''),
            emptyMetadata
        );
    }

    /**
     * @notice Broadcasts current frozen resources to a new participant
     * @dev Sends a cross-chain message to a specific participant with all current
     * frozen token data. This is used when a new participant joins the network.
     * @param chainId The chain ID of the participant to receive the frozen token data
     *
     * Requirements:
     * - Caller must be the TokenRegistry contract
     */
    function broadcastCurrentFrozenResourcesForNewParticipant(uint256 chainId) public virtual onlyTokenRegistry {
        BridgedTransferMetadata memory emptyMetadata;
        endpoint.sendToResourceId(
            chainId,
            Constants.RESOURCE_ID_TOKEN_REGISTRY,
            abi.encodeWithSelector(IPnTokenRegistry.syncFrozenTokens.selector, frozenTokens),
            bytes(''),
            bytes(''),
            bytes(''),
            emptyMetadata
        );
    }
}
