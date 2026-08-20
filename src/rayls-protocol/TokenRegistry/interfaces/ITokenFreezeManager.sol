// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "../libraries/TokenStructs.sol";

interface ITokenFreezeManager {
    // ─── Errors ──────────────────────────────────────────────────────────

    error TokenFreezeManagerV1__UnauthorizedCaller(address caller);
    error TokenFreezeManagerV1__InvalidTokenRegistryAddress();
    error TokenFreezeManagerV1__InvalidTokenCoreAddress();
    error TokenFreezeManagerV1__InvalidEndpointAddress();
    error TokenFreezeManagerV1__EndpointNotConfigured();
    error TokenFreezeManagerV1__TokenCoreNotConfigured();
    error TokenFreezeManagerV1__TokenFrozenOnPrivacyNode(bytes32 resourceId);
    error TokenFreezeManagerV1__TokenFrozenForParticipant(bytes32 resourceId, uint256 chainId);

    // ─── Events ──────────────────────────────────────────────────────────

    event PrivacyNodeFreezeUpdated(address indexed tokenAddress, bool frozen);
    event PublicChainFreezeUpdated(address indexed tokenAddress, bool frozen);
    event HubFrozenTokensSynced(uint256 frozenTokenCount);
    event HubFrozenTokenUpdated(bytes32 indexed resourceId, uint256[] frozenParticipants);
    event HubFrozenTokenRemoved(bytes32 indexed resourceId, uint256[] unfrozenParticipants);
    event FrozenTokensDataRequestedFromPrivateHub();
    event TokenFreezeManagerConfigured(
        address indexed tokenRegistry,
        address indexed tokenCore,
        address indexed endpoint,
        address relayAuthorizationRegistry
    );

    // ─── PN Freeze ────────────────────────────────────────────────────────

    /// @notice Freezes a token at the Privacy Node layer.
    /// @dev PN freeze overrides every other lifecycle layer.
    /// @param tokenAddress Address of the token being frozen.
    function freezeOnPrivacyNode(address tokenAddress) external;

    /// @notice Unfreezes a token at the Privacy Node layer.
    /// @param tokenAddress Address of the token being unfrozen.
    function unfreezeOnPrivacyNode(address tokenAddress) external;

    // ─── Hub Freeze Sync ──────────────────────────────────────────────────

    /// @notice Receives the full frozen-token dataset from the Private Hub.
    /// @param frozenTokens Full list of frozen tokens and participant chain IDs.
    function syncFrozenTokens(TokenStructs.FrozenToken[] calldata frozenTokens) external;

    /// @notice Marks one token as frozen for the provided participant chains.
    /// @param frozenToken Frozen-token payload coming from the Private Hub.
    function updateFrozenToken(TokenStructs.FrozenToken calldata frozenToken) external;

    /// @notice Removes frozen status for one token on the provided participant chains.
    /// @param unfrozenToken Frozen-token payload carrying the chains to unfreeze.
    function removeFrozenToken(TokenStructs.FrozenToken calldata unfrozenToken) external;

    // ─── Public-Chain Freeze ──────────────────────────────────────────────

    /// @notice Freezes a token at the public-chain lifecycle layer.
    /// @param tokenAddress Address of the token being frozen.
    function freezeOnPublicChain(address tokenAddress) external;

    /// @notice Unfreezes a token at the public-chain lifecycle layer.
    /// @param tokenAddress Address of the token being unfrozen.
    function unfreezeOnPublicChain(address tokenAddress) external;

    // ─── Freeze Queries ───────────────────────────────────────────────────

    /// @notice Validates that a token is allowed for the provided participant chain.
    /// @param resourceId Resource ID of the token being validated.
    /// @param chainId Participant chain ID being checked.
    function validateTokenForParticipant(bytes32 resourceId, uint256 chainId) external view;

    /// @notice Returns whether a token is frozen for the provided participant chain.
    /// @param resourceId Resource ID of the token being queried.
    /// @param chainId Participant chain ID being queried.
    /// @return True when the token is frozen for that participant chain.
    function getFrozenTokenForParticipant(bytes32 resourceId, uint256 chainId) external view returns (bool);

    /// @notice Requests a full frozen-token sync from the Private Hub.
    function requestAllFrozenTokensDataFromPrivateHub() external;

    // ─── Configuration ────────────────────────────────────────────────────

    /// @notice Configures the facade address that owns this module.
    /// @param tokenRegistry Address of the PN `TokenRegistryV1` facade.
    function setTokenRegistry(address tokenRegistry) external;

    /// @notice Configures the token-core module used for status updates.
    /// @param tokenCore Address of the PN `TokenCoreV1` module.
    function setTokenCore(address tokenCore) external;

    /// @notice Configures the PN endpoint used for cross-chain messaging.
    /// @param endpoint Address of the PN endpoint.
    function setEndpoint(address endpoint) external;

    /// @notice Configures the relayer authorization registry used by relayer-only flows.
    /// @param relayAuthRegistry Address of the relay authorization registry.
    function setRelayAuthorizationRegistry(address relayAuthRegistry) external;
}
