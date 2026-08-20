// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../../interfaces/ITokenCore.sol";
import "../../interfaces/ITokenFreezeManager.sol";
import "../../libraries/TokenStructs.sol";
import "../../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import "../../../../rayls-protocol-sdk/interfaces/IRaylsEndpoint.sol";
import "../../../../rayls-protocol-sdk/libraries/SharedObjects.sol";
import {PNTokenCoreLib} from "./PNTokenCoreLib.sol";

/**
 * @title PNTokenCoreV1
 * @notice PN-side core module for token registration and lifecycle management.
 * @dev Tracks local token metadata together with PN, hub, and public-chain lifecycle
 *      status. Cross-layer freeze transitions are delegated to `setFreezeStatus()`
 *      and can only be driven by the configured PN `TokenFreezeManagerV1`.
 */
contract PNTokenCoreV1 is Initializable, ITokenCore, UUPSUpgradeable, RaylsAccessManaged {
    // ========== Storage ==========

    TokenStructs.Token[] internal registeredTokensList;
    mapping(address => uint256) internal tokenIndexByAddress;
    mapping(bytes32 => uint256) internal tokenIndexByResourceId;
    mapping(string => uint256) internal tokenIndexBySymbol;

    address public tokenRegistryAddress;
    address public tokenFreezeManager;
    address public enygmaPNEvents;
    address public relayAuthorizationRegistry;
    IRaylsEndpoint public endpoint;

    mapping(address => TokenStructs.PrivacyNodeStatus) internal privacyNodeStatusBeforeFreeze;
    mapping(address => TokenStructs.HubStatus) internal hubStatusBeforeFreeze;
    mapping(address => TokenStructs.PublicChainStatus) internal publicChainStatusBeforeFreeze;

    // ========== Modifiers ==========

    /// @dev Restricts calls to the configured PN `TokenRegistryV1` facade.
    modifier onlyTokenRegistry() {
        if (msg.sender != tokenRegistryAddress) {
            revert TokenCoreV1__UnauthorizedCaller(msg.sender);
        }
        _;
    }

    /// @dev Restricts freeze-state transitions to the configured PN `TokenFreezeManagerV1`.
    modifier onlyFreezeManager() {
        if (msg.sender != tokenFreezeManager) {
            revert TokenCoreV1__UnauthorizedFreezeManager(msg.sender);
        }
        _;
    }

    // ========== Initialization ==========

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the PN token-core module with the shared access manager.
    function initialize(address authority_) external initializer {
        __UUPSUpgradeable_init();
        _initializeAuthority(authority_);
        // Reserve index 0 so missing tokens can be represented by the default mapping value.
        registeredTokensList.push();
    }

    // ========== Token Lifecycle ==========

    /// @inheritdoc ITokenCore
    function registerToken(address tokenAddress) external onlyTokenRegistry {
        if (tokenAddress == address(0)) revert TokenCoreV1__InvalidTokenAddress();
        if (tokenExists(tokenAddress)) revert TokenCoreV1__TokenAlreadyExists();
        if (address(endpoint) == address(0)) revert TokenCoreV1__EndpointNotConfigured();

        SharedObjects.ErcStandard ercStandard = PNTokenCoreLib.getTokenStandard(tokenAddress);
        (string memory tokenName, string memory tokenSymbol, string memory tokenUri) =
            PNTokenCoreLib.readTokenMetadata(tokenAddress, ercStandard);

        if (tokenIndexBySymbol[tokenSymbol] != 0) revert TokenCoreV1__TokenSymbolAlreadyExists();

        registeredTokensList.push(
            TokenStructs.Token({
                resourceId: bytes32(0),
                name: tokenName,
                symbol: tokenSymbol,
                uri: tokenUri,
                tokenAddress: tokenAddress,
                publicTokenAddress: address(0),
                issuerChainId: endpoint.getChainId(),
                ercStandard: ercStandard,
                privacyNodeStatus: TokenStructs.PrivacyNodeStatus.WAITING_APPROVAL,
                hubStatus: TokenStructs.HubStatus.UNDEFINED,
                publicChainStatus: TokenStructs.PublicChainStatus.UNDEFINED,
                createdAt: block.timestamp,
                updatedAt: block.timestamp
            })
        );

        uint256 index = registeredTokensList.length - 1;
        tokenIndexByAddress[tokenAddress] = index;
        tokenIndexBySymbol[tokenSymbol] = index;

        emit TokenRegistered(tokenAddress, tokenName, tokenSymbol, ercStandard);
        emit PrivacyNodeStatusUpdated(
            tokenAddress, TokenStructs.PrivacyNodeStatus.UNDEFINED, TokenStructs.PrivacyNodeStatus.WAITING_APPROVAL
        );
    }

    /// @inheritdoc ITokenCore
    function updatePrivacyNodeStatus(address tokenAddress, TokenStructs.PrivacyNodeStatus status)
        external
        onlyTokenRegistry
    {
        if (status == TokenStructs.PrivacyNodeStatus.FROZEN) {
            revert TokenCoreV1__InvalidPrivacyNodeStatus(status);
        }
        _setPrivacyNodeStatus(_getTokenIndex(tokenAddress), status);
    }

    /// @inheritdoc ITokenCore
    function submitToHub(address tokenAddress) external onlyTokenRegistry {
        if (address(endpoint) == address(0)) revert TokenCoreV1__EndpointNotConfigured();
        if (tokenRegistryAddress == address(0)) revert TokenCoreV1__TokenRegistryNotConfigured();

        uint256 tokenIndex = _getTokenIndex(tokenAddress);
        TokenStructs.Token storage token = registeredTokensList[tokenIndex];
        if (token.privacyNodeStatus != TokenStructs.PrivacyNodeStatus.AUTHORIZED) {
            revert TokenCoreV1__PrivacyNodeAuthorizationRequired(tokenAddress);
        }
        if (
            token.hubStatus == TokenStructs.HubStatus.WAITING_APPROVAL
                || token.hubStatus == TokenStructs.HubStatus.AUTHORIZED
                || token.hubStatus == TokenStructs.HubStatus.FROZEN
        ) {
            revert TokenCoreV1__StatusAlreadySet();
        }

        bytes memory payload = PNTokenCoreLib.buildAddTokenPayload(
            tokenAddress, token.ercStandard, tokenRegistryAddress, token.issuerChainId, token.name, token.symbol, token.uri
        );

        endpoint.send(endpoint.getPrivateHubId(), endpoint.getPrivateHubAddress("TokenRegistry"), payload);

        _setHubStatus(tokenIndex, TokenStructs.HubStatus.WAITING_APPROVAL);
    }

    /// @inheritdoc ITokenCore
    function submitToPublicChain(address tokenAddress) external onlyTokenRegistry {
        uint256 tokenIndex = _getTokenIndex(tokenAddress);
        TokenStructs.Token storage token = registeredTokensList[tokenIndex];
        if (token.privacyNodeStatus != TokenStructs.PrivacyNodeStatus.AUTHORIZED) {
            revert TokenCoreV1__PrivacyNodeAuthorizationRequired(tokenAddress);
        }
        if (
            token.publicChainStatus == TokenStructs.PublicChainStatus.PENDING_DEPLOYMENT
                || token.publicChainStatus == TokenStructs.PublicChainStatus.DEPLOYED
                || token.publicChainStatus == TokenStructs.PublicChainStatus.FROZEN
        ) {
            revert TokenCoreV1__StatusAlreadySet();
        }

        _setPublicChainStatus(tokenIndex, TokenStructs.PublicChainStatus.PENDING_DEPLOYMENT);
    }

    /// @inheritdoc ITokenCore
    function activateToken(bytes32 resourceId, address tokenAddress, uint8 ercStandard)
        external
        onlyTokenRegistry
    {
        if (address(endpoint) == address(0)) revert TokenCoreV1__EndpointNotConfigured();

        uint256 tokenIndex = _getTokenIndex(tokenAddress);
        TokenStructs.Token storage token = registeredTokensList[tokenIndex];

        if (token.resourceId != bytes32(0) && token.resourceId != resourceId) {
            revert TokenCoreV1__ResourceIdAlreadySet(tokenAddress);
        }

        uint256 existingIndex = tokenIndexByResourceId[resourceId];
        if (existingIndex != 0 && existingIndex != tokenIndex) {
            revert TokenCoreV1__ResourceIdAlreadyAssigned(resourceId);
        }

        if (token.hubStatus != TokenStructs.HubStatus.WAITING_APPROVAL) {
            revert TokenCoreV1__HubApprovalNotPending(tokenAddress, token.hubStatus);
        }

        token.resourceId = resourceId;
        tokenIndexByResourceId[resourceId] = tokenIndex;
        token.updatedAt = block.timestamp;

        endpoint.registerResourceId(resourceId, tokenAddress);
        PNTokenCoreLib.grantEndpointSenderRole(endpoint.authority(), tokenAddress);
        // Read the token's authoritative supply on the PN
        uint256 totalSupply = PNTokenCoreLib.readTotalSupply(tokenAddress, SharedObjects.ErcStandard(ercStandard));
        PNTokenCoreLib.emitCreationEvent(enygmaPNEvents, resourceId, SharedObjects.ErcStandard(ercStandard), totalSupply);

        _setHubStatus(tokenIndex, TokenStructs.HubStatus.AUTHORIZED);
        // Signal activation before replaying any deferred freeze so listeners see the
        // natural order: token activated, then a previously-deferred freeze applied as a
        // separate HubStatusUpdated transition. TokenActivated is an activation signal, not
        // an authorization signal — authoritative hub status is tracked via HubStatusUpdated.
        emit TokenActivated(resourceId, tokenAddress, SharedObjects.ErcStandard(ercStandard));
        // Hub freeze data can arrive before PN activation. If a real freeze-manager contract
        // already knows this local chain is frozen for the resourceId, replay that state now.
        _replayDeferredHubFreeze(resourceId, tokenIndex);
    }

    /// @inheritdoc ITokenCore
    function rejectToken(address tokenAddress) external onlyTokenRegistry {
        _setHubStatus(_getTokenIndex(tokenAddress), TokenStructs.HubStatus.UNAUTHORIZED);
    }

    /// @inheritdoc ITokenCore
    function registerHubToken(bytes32 resourceId, address tokenAddress) external onlyTokenRegistry {
        if (address(endpoint) == address(0)) revert TokenCoreV1__EndpointNotConfigured();
        if (tokenAddress == address(0)) revert TokenCoreV1__InvalidTokenAddress();

        if (tokenExists(tokenAddress)) return;
        if (tokenExistsByResourceId(resourceId)) return;

        // The mirror is a standard factory-deployed instance, so its ERC standard is derivable on-chain.
        SharedObjects.ErcStandard ercStandard = PNTokenCoreLib.getTokenStandard(tokenAddress);

        // Bind the resourceId and grant ENDPOINT_SENDER. The ResourceManager auto-deploy path
        // already does both before calling here; these are idempotent and keep the record
        // self-contained for any other caller/ordering.
        endpoint.registerResourceId(resourceId, tokenAddress);
        PNTokenCoreLib.grantEndpointSenderRole(endpoint.authority(), tokenAddress);

        // Record the destination-chain mirror as fully authorized: it is already hub-approved on
        // its issuer chain, so it is immediately operational here. A symbol clash with another
        // teleported token must not block the record — the address/resourceId indexes stay
        // authoritative for isTokenActiveForHub; the first symbol winner is preserved.
        _recordToken(resourceId, tokenAddress, ercStandard);
    }

    /// @inheritdoc ITokenCore
    function updatePublicTokenAddress(address tokenAddress, address publicTokenAddress) external onlyTokenRegistry {
        uint256 tokenIndex = _getTokenIndex(tokenAddress);
        TokenStructs.Token storage token = registeredTokensList[tokenIndex];
        token.publicTokenAddress = publicTokenAddress;
        token.updatedAt = block.timestamp;

        emit PublicTokenAddressUpdated(tokenAddress, publicTokenAddress);
        _setPublicChainStatus(tokenIndex, TokenStructs.PublicChainStatus.DEPLOYED);
    }

    /// @inheritdoc ITokenCore
    /// @notice Deprecates the public-chain lifecycle leg for a token.
    /// @dev This does not revoke PN or hub authorization. It marks only the public-chain
    ///      deployment path as deprecated so PN/hub-side state can be handled separately.
    function deprecateOnPublicChain(address tokenAddress) external onlyTokenRegistry {
        _setPublicChainStatus(_getTokenIndex(tokenAddress), TokenStructs.PublicChainStatus.DEPRECATED);
    }

    // ========== Freeze Hooks ==========

    /// @inheritdoc ITokenCore
    function setFreezeStatus(address tokenAddress, TokenStructs.FreezeLayer layer, bool frozen)
        external
        onlyFreezeManager
    {
        uint256 tokenIndex = _getTokenIndex(tokenAddress);

        if (layer == TokenStructs.FreezeLayer.PRIVACY_NODE) {
            _setLayerPrivacyFreeze(tokenIndex, frozen);
        } else if (layer == TokenStructs.FreezeLayer.HUB) {
            _setLayerHubFreeze(tokenIndex, frozen);
        } else {
            _setLayerPublicFreeze(tokenIndex, frozen);
        }
    }

    // ========== Operational Queries ==========

    /// @inheritdoc ITokenCore
    function isTokenFullyOperational(address tokenAddress) external view returns (bool) {
        TokenStructs.Token storage token = registeredTokensList[_getTokenIndex(tokenAddress)];
        return token.privacyNodeStatus == TokenStructs.PrivacyNodeStatus.AUTHORIZED
            && token.hubStatus == TokenStructs.HubStatus.AUTHORIZED
            && token.publicChainStatus == TokenStructs.PublicChainStatus.DEPLOYED;
    }

    /// @inheritdoc ITokenCore
    function isTokenActiveForHub(address tokenAddress) external view returns (bool) {
        TokenStructs.Token storage token = registeredTokensList[_getTokenIndex(tokenAddress)];
        return token.privacyNodeStatus == TokenStructs.PrivacyNodeStatus.AUTHORIZED
            && token.hubStatus == TokenStructs.HubStatus.AUTHORIZED;
    }

    /// @inheritdoc ITokenCore
    function isTokenActiveForPublicChain(address tokenAddress) external view returns (bool) {
        TokenStructs.Token storage token = registeredTokensList[_getTokenIndex(tokenAddress)];
        return token.privacyNodeStatus == TokenStructs.PrivacyNodeStatus.AUTHORIZED
            && token.publicChainStatus == TokenStructs.PublicChainStatus.DEPLOYED;
    }

    // ========== Registry Queries ==========

    /// @inheritdoc ITokenCore
    function getAllTokens() external view returns (TokenStructs.Token[] memory) {
        uint256 tokenCount = getTokenCount();
        TokenStructs.Token[] memory tokens = new TokenStructs.Token[](tokenCount);
        for (uint256 i = 0; i < tokenCount; i++) {
            tokens[i] = registeredTokensList[i + 1];
        }
        return tokens;
    }

    /// @inheritdoc ITokenCore
    function getTokenByAddress(address tokenAddress) external view returns (TokenStructs.Token memory) {
        return registeredTokensList[_getTokenIndex(tokenAddress)];
    }

    /// @inheritdoc ITokenCore
    function getTokenByResourceId(bytes32 resourceId) external view returns (TokenStructs.Token memory) {
        uint256 tokenIndex = tokenIndexByResourceId[resourceId];
        if (tokenIndex == 0) revert TokenCoreV1__TokenDoesNotExist();
        return registeredTokensList[tokenIndex];
    }

    /// @inheritdoc ITokenCore
    function getTokenBySymbol(string memory symbol) external view returns (TokenStructs.Token memory) {
        uint256 tokenIndex = tokenIndexBySymbol[symbol];
        if (tokenIndex == 0) revert TokenCoreV1__TokenDoesNotExist();
        return registeredTokensList[tokenIndex];
    }

    /// @inheritdoc ITokenCore
    function getPrivacyNodeStatus(address tokenAddress) external view returns (TokenStructs.PrivacyNodeStatus) {
        return registeredTokensList[_getTokenIndex(tokenAddress)].privacyNodeStatus;
    }

    /// @inheritdoc ITokenCore
    function getHubStatus(address tokenAddress) external view returns (TokenStructs.HubStatus) {
        return registeredTokensList[_getTokenIndex(tokenAddress)].hubStatus;
    }

    /// @inheritdoc ITokenCore
    function getPublicChainStatus(address tokenAddress) external view returns (TokenStructs.PublicChainStatus) {
        return registeredTokensList[_getTokenIndex(tokenAddress)].publicChainStatus;
    }

    /// @inheritdoc ITokenCore
    function getTokensByPrivacyNodeStatus(TokenStructs.PrivacyNodeStatus status)
        external
        view
        returns (TokenStructs.Token[] memory)
    {
        uint256 count = 0;
        for (uint256 i = 1; i < registeredTokensList.length; i++) {
            if (registeredTokensList[i].privacyNodeStatus == status) count++;
        }

        TokenStructs.Token[] memory tokens = new TokenStructs.Token[](count);
        uint256 index = 0;
        for (uint256 i = 1; i < registeredTokensList.length; i++) {
            if (registeredTokensList[i].privacyNodeStatus == status) {
                tokens[index] = registeredTokensList[i];
                index++;
            }
        }
        return tokens;
    }

    /// @inheritdoc ITokenCore
    function getTokensByHubStatus(TokenStructs.HubStatus status) external view returns (TokenStructs.Token[] memory) {
        uint256 count = 0;
        for (uint256 i = 1; i < registeredTokensList.length; i++) {
            if (registeredTokensList[i].hubStatus == status) count++;
        }

        TokenStructs.Token[] memory tokens = new TokenStructs.Token[](count);
        uint256 index = 0;
        for (uint256 i = 1; i < registeredTokensList.length; i++) {
            if (registeredTokensList[i].hubStatus == status) {
                tokens[index] = registeredTokensList[i];
                index++;
            }
        }
        return tokens;
    }

    /// @inheritdoc ITokenCore
    function getTokenCount() public view returns (uint256) {
        if (registeredTokensList.length == 0) {
            return 0;
        }
        return registeredTokensList.length - 1;
    }

    /// @inheritdoc ITokenCore
    function getActiveTokenCount() external view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 1; i < registeredTokensList.length; i++) {
            if (registeredTokensList[i].privacyNodeStatus == TokenStructs.PrivacyNodeStatus.AUTHORIZED) {
                count++;
            }
        }
        return count;
    }

    /// @inheritdoc ITokenCore
    function tokenExists(address tokenAddress) public view returns (bool) {
        return tokenIndexByAddress[tokenAddress] != 0;
    }

    /// @inheritdoc ITokenCore
    function tokenExistsByResourceId(bytes32 resourceId) public view returns (bool) {
        return tokenIndexByResourceId[resourceId] != 0;
    }

    // ========== Module Configuration ==========

    /// @inheritdoc ITokenCore
    /// @notice Sets the PN `TokenRegistryV1` facade allowed to call lifecycle entrypoints.
    function setTokenRegistry(address tokenRegistry) external restricted {
        if (tokenRegistry == address(0)) revert TokenCoreV1__InvalidTokenRegistryAddress();
        tokenRegistryAddress = tokenRegistry;
        emit TokenCoreModulesConfigured(
            tokenRegistryAddress, tokenFreezeManager, address(endpoint), enygmaPNEvents, relayAuthorizationRegistry
        );
    }

    /// @inheritdoc ITokenCore
    /// @notice Sets the PN freeze manager allowed to drive `setFreezeStatus()`.
    function setTokenFreezeManager(address freezeManager) external restricted {
        if (freezeManager == address(0)) revert TokenCoreV1__InvalidTokenFreezeManagerAddress();
        tokenFreezeManager = freezeManager;
        emit TokenCoreModulesConfigured(
            tokenRegistryAddress, tokenFreezeManager, address(endpoint), enygmaPNEvents, relayAuthorizationRegistry
        );
    }

    /// @inheritdoc ITokenCore
    /// @notice Sets the PN endpoint used for hub and public-chain messaging.
    function setEndpoint(address endpointAddress) external restricted {
        if (endpointAddress == address(0)) revert TokenCoreV1__InvalidEndpointAddress();
        endpoint = IRaylsEndpoint(endpointAddress);
        emit TokenCoreModulesConfigured(
            tokenRegistryAddress, tokenFreezeManager, address(endpoint), enygmaPNEvents, relayAuthorizationRegistry
        );
    }

    /// @inheritdoc ITokenCore
    /// @notice Sets the PN Enygma events contract used for Enygma and DVP activation hooks.
    function setEnygmaPNEvents(address enygmaPNEventsAddress) external restricted {
        if (enygmaPNEventsAddress == address(0)) revert TokenCoreV1__InvalidEnygmaPNEventsAddress();
        enygmaPNEvents = enygmaPNEventsAddress;
        emit TokenCoreModulesConfigured(
            tokenRegistryAddress, tokenFreezeManager, address(endpoint), enygmaPNEvents, relayAuthorizationRegistry
        );
    }

    /// @inheritdoc ITokenCore
    /// @notice Sets the relay authorization registry address.
    /// @dev This module treats the relay registry as optional, so `address(0)` remains allowed.
    function setRelayAuthorizationRegistry(address relayAuthRegistry) external restricted {
        relayAuthorizationRegistry = relayAuthRegistry;
        emit TokenCoreModulesConfigured(
            tokenRegistryAddress, tokenFreezeManager, address(endpoint), enygmaPNEvents, relayAuthorizationRegistry
        );
    }

    // ========== Internal Helpers ==========

    /// @dev Authorizes UUPS upgrades through the configured Rayls access manager.
    function _authorizeUpgrade(address) internal view override {
        _checkCanCall(msg.sender, msg.sig);
    }

    /// @dev Replays a pre-existing hub freeze for a token activated after freeze data was synced.
    function _replayDeferredHubFreeze(bytes32 resourceId, uint256 tokenIndex) internal {
        if (tokenFreezeManager == address(0) || tokenFreezeManager.code.length == 0) {
            return;
        }

        try ITokenFreezeManager(tokenFreezeManager)
            .getFrozenTokenForParticipant(resourceId, endpoint.getChainId()) returns (bool frozenForLocalParticipant) {
            if (frozenForLocalParticipant) {
                _setLayerHubFreeze(tokenIndex, true);
            }
        } catch {
            // Activation should not fail just because the configured freeze-manager address
            // cannot answer the optional deferred-freeze replay lookup.
        }
    }

    /// @dev Returns the stored token index for a token address or reverts when it is absent.
    function _getTokenIndex(address tokenAddress) internal view returns (uint256) {
        uint256 tokenIndex = tokenIndexByAddress[tokenAddress];
        if (tokenIndex == 0) revert TokenCoreV1__TokenDoesNotExist();
        return tokenIndex;
    }

    /// @dev Sets the Privacy Node lifecycle status and emits the corresponding transition event.
    function _setPrivacyNodeStatus(uint256 tokenIndex, TokenStructs.PrivacyNodeStatus newStatus) internal {
        TokenStructs.Token storage token = registeredTokensList[tokenIndex];
        TokenStructs.PrivacyNodeStatus previousStatus = token.privacyNodeStatus;
        if (previousStatus == newStatus) revert TokenCoreV1__StatusAlreadySet();

        token.privacyNodeStatus = newStatus;
        token.updatedAt = block.timestamp;
        emit PrivacyNodeStatusUpdated(token.tokenAddress, previousStatus, newStatus);
    }

    /// @dev Sets the hub lifecycle status and emits the corresponding transition event.
    function _setHubStatus(uint256 tokenIndex, TokenStructs.HubStatus newStatus) internal {
        TokenStructs.Token storage token = registeredTokensList[tokenIndex];
        TokenStructs.HubStatus previousStatus = token.hubStatus;
        if (previousStatus == newStatus) revert TokenCoreV1__StatusAlreadySet();

        token.hubStatus = newStatus;
        token.updatedAt = block.timestamp;
        emit HubStatusUpdated(token.tokenAddress, previousStatus, newStatus);
    }

    /// @dev Sets the public-chain lifecycle status and emits the corresponding transition event.
    function _setPublicChainStatus(uint256 tokenIndex, TokenStructs.PublicChainStatus newStatus) internal {
        TokenStructs.Token storage token = registeredTokensList[tokenIndex];
        TokenStructs.PublicChainStatus previousStatus = token.publicChainStatus;
        if (previousStatus == newStatus) revert TokenCoreV1__StatusAlreadySet();

        token.publicChainStatus = newStatus;
        token.updatedAt = block.timestamp;
        emit PublicChainStatusUpdated(token.tokenAddress, previousStatus, newStatus);
    }

    /// @dev Applies or removes a PN-layer freeze, preserving the pre-freeze PN status for restoration.
    function _setLayerPrivacyFreeze(uint256 tokenIndex, bool frozen) internal {
        TokenStructs.Token storage token = registeredTokensList[tokenIndex];
        if (frozen) {
            if (token.privacyNodeStatus == TokenStructs.PrivacyNodeStatus.FROZEN) {
                revert TokenCoreV1__StatusAlreadySet();
            }
            privacyNodeStatusBeforeFreeze[token.tokenAddress] = token.privacyNodeStatus;
            _setPrivacyNodeStatus(tokenIndex, TokenStructs.PrivacyNodeStatus.FROZEN);
            return;
        }
        if (token.privacyNodeStatus != TokenStructs.PrivacyNodeStatus.FROZEN) {
            revert TokenCoreV1__StatusAlreadySet();
        }

        _setPrivacyNodeStatus(tokenIndex, privacyNodeStatusBeforeFreeze[token.tokenAddress]);
        delete privacyNodeStatusBeforeFreeze[token.tokenAddress];
    }

    /// @dev Applies or removes a hub-layer freeze, preserving the pre-freeze hub status for restoration.
    function _setLayerHubFreeze(uint256 tokenIndex, bool frozen) internal {
        TokenStructs.Token storage token = registeredTokensList[tokenIndex];
        if (frozen) {
            if (token.hubStatus == TokenStructs.HubStatus.FROZEN) {
                revert TokenCoreV1__StatusAlreadySet();
            }
            hubStatusBeforeFreeze[token.tokenAddress] = token.hubStatus;
            _setHubStatus(tokenIndex, TokenStructs.HubStatus.FROZEN);
            return;
        }
        if (token.hubStatus != TokenStructs.HubStatus.FROZEN) {
            revert TokenCoreV1__StatusAlreadySet();
        }

        _setHubStatus(tokenIndex, hubStatusBeforeFreeze[token.tokenAddress]);
        delete hubStatusBeforeFreeze[token.tokenAddress];
    }

    /// @dev Applies or removes a public-chain-layer freeze, preserving the pre-freeze public-chain status.
    function _setLayerPublicFreeze(uint256 tokenIndex, bool frozen) internal {
        TokenStructs.Token storage token = registeredTokensList[tokenIndex];
        if (frozen) {
            if (token.publicChainStatus == TokenStructs.PublicChainStatus.FROZEN) {
                revert TokenCoreV1__StatusAlreadySet();
            }
            publicChainStatusBeforeFreeze[token.tokenAddress] = token.publicChainStatus;
            _setPublicChainStatus(tokenIndex, TokenStructs.PublicChainStatus.FROZEN);
            return;
        }
        if (token.publicChainStatus != TokenStructs.PublicChainStatus.FROZEN) {
            revert TokenCoreV1__StatusAlreadySet();
        }

        _setPublicChainStatus(tokenIndex, publicChainStatusBeforeFreeze[token.tokenAddress]);
        delete publicChainStatusBeforeFreeze[token.tokenAddress];
    }

    /// @dev Records a token in the local registry and marks it AUTHORIZED on the PN and hub layers.
    ///      Reads metadata from the deployed instance. Preserves getAllTokens() observability.
    ///      Used for destination-chain mirror recording: a symbol clash with another teleported
    ///      token keeps the existing symbol-index winner and the record still lands — the
    ///      address/resourceId indexes remain authoritative for lookups and the hub-active check.
    function _recordToken(bytes32 resourceId, address tokenAddress, SharedObjects.ErcStandard ercStandard) internal {
        (string memory tokenName, string memory tokenSymbol, string memory tokenUri) =
            PNTokenCoreLib.readTokenMetadata(tokenAddress, ercStandard);

        bool symbolTaken = tokenIndexBySymbol[tokenSymbol] != 0;

        registeredTokensList.push(
            TokenStructs.Token({
                resourceId: resourceId,
                name: tokenName,
                symbol: tokenSymbol,
                uri: tokenUri,
                tokenAddress: tokenAddress,
                publicTokenAddress: address(0),
                issuerChainId: endpoint.getChainId(),
                ercStandard: ercStandard,
                privacyNodeStatus: TokenStructs.PrivacyNodeStatus.AUTHORIZED,
                hubStatus: TokenStructs.HubStatus.AUTHORIZED,
                publicChainStatus: TokenStructs.PublicChainStatus.UNDEFINED,
                createdAt: block.timestamp,
                updatedAt: block.timestamp
            })
        );

        uint256 index = registeredTokensList.length - 1;
        tokenIndexByAddress[tokenAddress] = index;
        tokenIndexByResourceId[resourceId] = index;
        if (!symbolTaken) {
            tokenIndexBySymbol[tokenSymbol] = index;
        }

        emit TokenRegistered(tokenAddress, tokenName, tokenSymbol, ercStandard);
        emit TokenActivated(resourceId, tokenAddress, ercStandard);
    }
}
