// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../../interfaces/ITokenCore.sol";
import "../../interfaces/ITokenFreezeManager.sol";
import "../../libraries/TokenStructs.sol";
import "../../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import "../../../../rayls-protocol-sdk/Constants.sol";
import "../../../../rayls-protocol-sdk/interfaces/IRaylsEndpoint.sol";

/**
 * @title PNTokenFreezeManagerV1
 * @notice PN-side freeze coordinator for privacy-node, hub, and public-chain lifecycle layers.
 * @dev Stores participant-specific hub freeze data received from the Private Hub and mirrors
 *      the local chain's hub freeze state into `TokenCoreV1`. Privacy-node and public-chain
 *      freezes remain token-wide and are delegated directly into the core module.
 */
contract PNTokenFreezeManagerV1 is Initializable, ITokenFreezeManager, UUPSUpgradeable, RaylsAccessManaged {
    // ========== Storage ==========

    mapping(bytes32 => mapping(uint256 => bool)) internal frozenParticipants;
    TokenStructs.FrozenToken[] internal hubFrozenTokens;
    mapping(bytes32 => uint256) internal hubFrozenTokenIndexPlusOne;

    ITokenCore internal tokenCore;
    address public tokenRegistryAddress;
    IRaylsEndpoint public endpoint;
    address public relayAuthorizationRegistry;

    // ========== Modifiers ==========

    modifier onlyTokenRegistry() {
        if (msg.sender != tokenRegistryAddress) {
            revert TokenFreezeManagerV1__UnauthorizedCaller(msg.sender);
        }
        _;
    }

    // ========== Initialization ==========

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the PN freeze-manager module with the shared access manager.
    function initialize(address authority_) external initializer {
        __UUPSUpgradeable_init();
        _initializeAuthority(authority_);
    }

    // ========== Token Freeze Controls ==========

    function freezeOnPrivacyNode(address tokenAddress) external onlyTokenRegistry {
        _requireTokenCore();
        tokenCore.setFreezeStatus(tokenAddress, TokenStructs.FreezeLayer.PRIVACY_NODE, true);
        emit PrivacyNodeFreezeUpdated(tokenAddress, true);
    }

    function unfreezeOnPrivacyNode(address tokenAddress) external onlyTokenRegistry {
        _requireTokenCore();
        tokenCore.setFreezeStatus(tokenAddress, TokenStructs.FreezeLayer.PRIVACY_NODE, false);
        emit PrivacyNodeFreezeUpdated(tokenAddress, false);
    }

    // ========== Hub Freeze Synchronization ==========

    function syncFrozenTokens(TokenStructs.FrozenToken[] calldata frozenTokens) external onlyTokenRegistry {
        _requireEndpoint();
        _requireTokenCore();

        // Keep track of the resource IDs that were frozen before this snapshot replacement.
        // After we rebuild local state, some of these tokens may need their hub layer unfrozen.
        bytes32[] memory previousResourceIds = new bytes32[](hubFrozenTokens.length);
        for (uint256 i = 0; i < hubFrozenTokens.length; i++) {
            previousResourceIds[i] = hubFrozenTokens[i].resourceId;
        }

        // This is a full snapshot sync, not an incremental merge, so remove all current
        // hub freeze state before applying the fresh dataset received from PNH.
        _clearHubSnapshot();

        // Rebuild the local participant-freeze snapshot exactly as provided by PNH.
        for (uint256 i = 0; i < frozenTokens.length; i++) {
            bytes32 resourceId = frozenTokens[i].resourceId;
            for (uint256 j = 0; j < frozenTokens[i].frozenParticipants.length; j++) {
                _upsertFrozenParticipant(resourceId, frozenTokens[i].frozenParticipants[j]);
            }
        }

        // First revisit tokens that used to be frozen so entries removed from the snapshot
        // can return their local hub layer from FROZEN back to the correct non-frozen status
        // in TokenCore. Tokens still present in the new snapshot are handled below so we do
        // not emit an unnecessary local unfreeze/re-freeze pair for unchanged resource IDs.
        for (uint256 i = 0; i < previousResourceIds.length; i++) {
            if (_containsResourceId(frozenTokens, previousResourceIds[i])) {
                continue;
            }
            _syncHubLayerStatus(previousResourceIds[i]);
        }

        // Then apply hub-layer mirroring for every token present in the new snapshot so
        // the local chain enters FROZEN whenever it is part of the frozen participant set.
        for (uint256 i = 0; i < frozenTokens.length; i++) {
            _syncHubLayerStatus(frozenTokens[i].resourceId);
        }

        emit HubFrozenTokensSynced(frozenTokens.length);
    }

    function updateFrozenToken(TokenStructs.FrozenToken calldata frozenToken) external onlyTokenRegistry {
        _requireEndpoint();
        _requireTokenCore();

        for (uint256 i = 0; i < frozenToken.frozenParticipants.length; i++) {
            _upsertFrozenParticipant(frozenToken.resourceId, frozenToken.frozenParticipants[i]);
        }

        _syncHubLayerStatus(frozenToken.resourceId);
        emit HubFrozenTokenUpdated(frozenToken.resourceId, frozenToken.frozenParticipants);
    }

    function removeFrozenToken(TokenStructs.FrozenToken calldata unfrozenToken) external onlyTokenRegistry {
        _requireEndpoint();
        _requireTokenCore();

        for (uint256 i = 0; i < unfrozenToken.frozenParticipants.length; i++) {
            _removeFrozenParticipant(unfrozenToken.resourceId, unfrozenToken.frozenParticipants[i]);
        }

        _syncHubLayerStatus(unfrozenToken.resourceId);
        emit HubFrozenTokenRemoved(unfrozenToken.resourceId, unfrozenToken.frozenParticipants);
    }

    // ========== Public-Chain Freeze Controls ==========

    function freezeOnPublicChain(address tokenAddress) external onlyTokenRegistry {
        _requireTokenCore();
        tokenCore.setFreezeStatus(tokenAddress, TokenStructs.FreezeLayer.PUBLIC_CHAIN, true);
        emit PublicChainFreezeUpdated(tokenAddress, true);
    }

    function unfreezeOnPublicChain(address tokenAddress) external onlyTokenRegistry {
        _requireTokenCore();
        tokenCore.setFreezeStatus(tokenAddress, TokenStructs.FreezeLayer.PUBLIC_CHAIN, false);
        emit PublicChainFreezeUpdated(tokenAddress, false);
    }

    // ========== Freeze Queries ==========

    /// @inheritdoc ITokenFreezeManager
    function validateTokenForParticipant(bytes32 resourceId, uint256 chainId) external view {
        _requireTokenCore();

        // System resources travel the same endpoint message path as tokens but are not
        // stored in TokenCore, so we only check the PN freeze status for registered tokens.
        if (tokenCore.tokenExistsByResourceId(resourceId)) {
            TokenStructs.Token memory token = tokenCore.getTokenByResourceId(resourceId);
            if (token.privacyNodeStatus == TokenStructs.PrivacyNodeStatus.FROZEN) {
                revert TokenFreezeManagerV1__TokenFrozenOnPrivacyNode(resourceId);
            }
        }

        if (frozenParticipants[resourceId][chainId]) {
            revert TokenFreezeManagerV1__TokenFrozenForParticipant(resourceId, chainId);
        }
    }

    /// @inheritdoc ITokenFreezeManager
    function getFrozenTokenForParticipant(bytes32 resourceId, uint256 chainId) external view returns (bool) {
        return frozenParticipants[resourceId][chainId];
    }

    // ========== Cross-Chain Synchronization ==========

    /// @inheritdoc ITokenFreezeManager
    function requestAllFrozenTokensDataFromPrivateHub() external onlyTokenRegistry {
        _requireEndpoint();

        // Ask the PNH TokenRegistryV1 resource to broadcast the current frozen-token
        // snapshot back to this PN registry facade.
        endpoint.sendToResourceId(
            endpoint.getPrivateHubId(),
            Constants.RESOURCE_ID_TOKEN_REGISTRY,
            abi.encodeWithSignature("broadcastCurrentFrozenResourcesForNewParticipant()")
        );

        emit FrozenTokensDataRequestedFromPrivateHub();
    }

    // ========== Module Configuration ==========

    /// @notice Sets the PN `TokenRegistryV1` facade allowed to mutate this module.
    function setTokenRegistry(address tokenRegistry) external restricted {
        if (tokenRegistry == address(0)) revert TokenFreezeManagerV1__InvalidTokenRegistryAddress();
        tokenRegistryAddress = tokenRegistry;
        emit TokenFreezeManagerConfigured(
            tokenRegistryAddress, address(tokenCore), address(endpoint), relayAuthorizationRegistry
        );
    }

    /// @notice Sets the PN token-core module used for lifecycle freeze transitions.
    function setTokenCore(address tokenCoreAddress) external restricted {
        if (tokenCoreAddress == address(0)) revert TokenFreezeManagerV1__InvalidTokenCoreAddress();
        tokenCore = ITokenCore(tokenCoreAddress);
        emit TokenFreezeManagerConfigured(
            tokenRegistryAddress, address(tokenCore), address(endpoint), relayAuthorizationRegistry
        );
    }

    /// @notice Sets the PN endpoint used for requesting hub freeze snapshots.
    function setEndpoint(address endpointAddress) external restricted {
        if (endpointAddress == address(0)) revert TokenFreezeManagerV1__InvalidEndpointAddress();
        endpoint = IRaylsEndpoint(endpointAddress);
        emit TokenFreezeManagerConfigured(
            tokenRegistryAddress, address(tokenCore), address(endpoint), relayAuthorizationRegistry
        );
    }

    /// @notice Sets the relay authorization registry address.
    /// @dev This module currently treats the relay registry as optional, so `address(0)` is allowed.
    function setRelayAuthorizationRegistry(address relayAuthRegistry) external restricted {
        relayAuthorizationRegistry = relayAuthRegistry;
        emit TokenFreezeManagerConfigured(
            tokenRegistryAddress, address(tokenCore), address(endpoint), relayAuthorizationRegistry
        );
    }

    // ========== Internal Helpers ==========

    function _authorizeUpgrade(address) internal view override {
        _checkCanCall(msg.sender, msg.sig);
    }

    function _requireEndpoint() internal view {
        if (address(endpoint) == address(0)) {
            revert TokenFreezeManagerV1__EndpointNotConfigured();
        }
    }

    function _requireTokenCore() internal view {
        if (address(tokenCore) == address(0)) {
            revert TokenFreezeManagerV1__TokenCoreNotConfigured();
        }
    }

    // Snapshot entries are stored in an array plus an index mapping so incremental
    // hub updates stay cheap while still allowing full-snapshot replacement.
    function _upsertFrozenParticipant(bytes32 resourceId, uint256 chainId) internal {
        uint256 tokenIndexPlusOne = hubFrozenTokenIndexPlusOne[resourceId];
        if (tokenIndexPlusOne == 0) {
            hubFrozenTokens.push();
            tokenIndexPlusOne = hubFrozenTokens.length;
            hubFrozenTokenIndexPlusOne[resourceId] = tokenIndexPlusOne;
            hubFrozenTokens[tokenIndexPlusOne - 1].resourceId = resourceId;
        }

        if (frozenParticipants[resourceId][chainId]) {
            return;
        }

        frozenParticipants[resourceId][chainId] = true;
        hubFrozenTokens[tokenIndexPlusOne - 1].frozenParticipants.push(chainId);
    }

    function _removeFrozenParticipant(bytes32 resourceId, uint256 chainId) internal {
        if (!frozenParticipants[resourceId][chainId]) {
            return;
        }

        frozenParticipants[resourceId][chainId] = false;

        uint256 tokenIndexPlusOne = hubFrozenTokenIndexPlusOne[resourceId];
        if (tokenIndexPlusOne == 0) {
            return;
        }

        TokenStructs.FrozenToken storage frozenToken = hubFrozenTokens[tokenIndexPlusOne - 1];
        for (uint256 i = 0; i < frozenToken.frozenParticipants.length; i++) {
            if (frozenToken.frozenParticipants[i] == chainId) {
                frozenToken.frozenParticipants[i] =
                    frozenToken.frozenParticipants[frozenToken.frozenParticipants.length - 1];
                frozenToken.frozenParticipants.pop();
                break;
            }
        }

        if (frozenToken.frozenParticipants.length == 0) {
            _removeFrozenTokenEntry(resourceId);
        }
    }

    // Removing an entry compacts the snapshot array and rewrites the moved entry's index.
    function _removeFrozenTokenEntry(bytes32 resourceId) internal {
        uint256 tokenIndexPlusOne = hubFrozenTokenIndexPlusOne[resourceId];
        if (tokenIndexPlusOne == 0) {
            return;
        }

        uint256 tokenIndex = tokenIndexPlusOne - 1;
        uint256 lastIndex = hubFrozenTokens.length - 1;

        if (tokenIndex != lastIndex) {
            TokenStructs.FrozenToken storage lastFrozenToken = hubFrozenTokens[lastIndex];
            TokenStructs.FrozenToken storage targetFrozenToken = hubFrozenTokens[tokenIndex];

            delete targetFrozenToken.frozenParticipants;
            targetFrozenToken.resourceId = lastFrozenToken.resourceId;
            for (uint256 i = 0; i < lastFrozenToken.frozenParticipants.length; i++) {
                targetFrozenToken.frozenParticipants.push(lastFrozenToken.frozenParticipants[i]);
            }
            hubFrozenTokenIndexPlusOne[lastFrozenToken.resourceId] = tokenIndex + 1;
        }

        delete hubFrozenTokenIndexPlusOne[resourceId];
        hubFrozenTokens.pop();
    }

    function _clearHubSnapshot() internal {
        for (uint256 i = 0; i < hubFrozenTokens.length; i++) {
            bytes32 resourceId = hubFrozenTokens[i].resourceId;
            for (uint256 j = 0; j < hubFrozenTokens[i].frozenParticipants.length; j++) {
                frozenParticipants[resourceId][hubFrozenTokens[i].frozenParticipants[j]] = false;
            }
            delete hubFrozenTokenIndexPlusOne[resourceId];
        }

        delete hubFrozenTokens;
    }

    function _containsResourceId(TokenStructs.FrozenToken[] calldata frozenTokens, bytes32 resourceId)
        internal
        pure
        returns (bool)
    {
        for (uint256 i = 0; i < frozenTokens.length; i++) {
            if (frozenTokens[i].resourceId == resourceId) {
                return true;
            }
        }
        return false;
    }

    // The hub can freeze participants independently. PN mirrors only the local chain's
    // participant freeze into TokenCore's hub lifecycle status.
    function _syncHubLayerStatus(bytes32 resourceId) internal {
        uint256 localChainId = endpoint.getChainId();
        bool locallyFrozen = frozenParticipants[resourceId][localChainId];

        try tokenCore.getTokenByResourceId(resourceId) returns (TokenStructs.Token memory token) {
            if (locallyFrozen) {
                if (token.hubStatus != TokenStructs.HubStatus.FROZEN) {
                    tokenCore.setFreezeStatus(token.tokenAddress, TokenStructs.FreezeLayer.HUB, true);
                }
                return;
            }

            if (token.hubStatus == TokenStructs.HubStatus.FROZEN) {
                tokenCore.setFreezeStatus(token.tokenAddress, TokenStructs.FreezeLayer.HUB, false);
            }
        } catch {
            // The hub snapshot is keyed by resourceId and may arrive before the local PN
            // token has been fully activated. In that case we keep the participant freeze
            // data and let TokenCore.activateToken() replay the local hub-freeze state
            // once the token finally exists on this PN.
        }
    }
}
