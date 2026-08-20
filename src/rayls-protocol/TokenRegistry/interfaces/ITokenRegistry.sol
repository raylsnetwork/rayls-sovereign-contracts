// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./ITokenCore.sol";
import "./ITokenFreezeManager.sol";
import "../libraries/TokenStructs.sol";

/// @title ITokenRegistry
/// @notice PN-side facade interface for token lifecycle and freeze operations.
/// @dev This facade aggregates `TokenCoreV1` and `TokenFreezeManagerV1` behind one
///      stable registry address and access-controlled ABI.
interface ITokenRegistry {
    // ─── Errors ──────────────────────────────────────────────────────────

    error TokenRegistryV1__InvalidTokenCoreAddress();
    error TokenRegistryV1__InvalidTokenFreezeManagerAddress();
    error TokenRegistryV1__TokenCoreNotConfigured();
    error TokenRegistryV1__TokenFreezeManagerNotConfigured();

    // ─── Events ──────────────────────────────────────────────────────────

    /// @notice Emitted when the PN token-core module address is configured.
    /// @param tokenCore Address of the configured PN `TokenCoreV1` module.
    event TokenCoreSet(address indexed tokenCore);

    /// @notice Emitted when the PN token-freeze manager module address is configured.
    /// @param tokenFreezeManager Address of the configured PN `TokenFreezeManagerV1` module.
    event TokenFreezeManagerSet(address indexed tokenFreezeManager);

    /// @notice Emitted with the current module configuration snapshot after a module setter runs.
    /// @dev One module address may be zero until both `setTokenCore()` and
    ///      `setTokenFreezeManager()` have been executed. Use `TokenCoreSet`
    ///      and `TokenFreezeManagerSet` for independent module wiring history.
    event TokenRegistryModulesConfigured(address indexed tokenCore, address indexed tokenFreezeManager);

    // ─── Module Configuration ─────────────────────────────────────────────

    /// @notice Configures the PN token-core module.
    /// @dev Restricted to callers with `PN_TOKEN_REGISTRY_ADMIN`.
    /// @param tokenCore Address of the PN `TokenCoreV1` module.
    function setTokenCore(address tokenCore) external;

    /// @notice Configures the PN token-freeze manager module.
    /// @dev Restricted to callers with `PN_TOKEN_REGISTRY_ADMIN`.
    /// @param freezeManager Address of the PN `TokenFreezeManagerV1` module.
    function setTokenFreezeManager(address freezeManager) external;

    // ─── Module Getters ───────────────────────────────────────────────────

    /// @notice Returns the currently configured PN token-core module.
    /// @return Reference to the PN `TokenCoreV1` interface.
    function getTokenCore() external view returns (ITokenCore);

    /// @notice Returns the currently configured PN token-freeze manager module.
    /// @return Reference to the PN `TokenFreezeManagerV1` interface.
    function getTokenFreezeManager() external view returns (ITokenFreezeManager);

    // ─── Token Lifecycle ─────────────────────────────────────────────────

    /// @notice Registers a token on the PN-side registry facade.
    /// @dev Restricted to callers with `TOKEN_CREATOR`.
    /// @param tokenAddress Address of the token contract being registered.
    function registerToken(address tokenAddress) external;

    /// @notice Updates the PN-local lifecycle status for a token.
    /// @dev Restricted to callers with `PN_TOKEN_REGISTRY_ADMIN`.
    /// @param tokenAddress Address of the token contract.
    /// @param status New PN status to apply.
    function updatePrivacyNodeStatus(address tokenAddress, TokenStructs.PrivacyNodeStatus status) external;

    /// @notice Submits a PN-authorized token to the private hub approval flow.
    /// @dev Restricted to callers with `PN_TOKEN_REGISTRY_ADMIN`.
    /// @param tokenAddress Address of the token contract.
    function submitToHub(address tokenAddress) external;

    /// @notice Starts the public-chain deployment leg for a token.
    /// @dev Restricted to callers with `PN_TOKEN_REGISTRY_ADMIN`.
    /// @param tokenAddress Address of the token contract.
    function submitToPublicChain(address tokenAddress) external;

    /// @notice Activates a token on PN after the private hub assigns its resource ID.
    /// @dev Restricted to callers with `MESSAGE_EXECUTOR`. The activation supply is read locally
    ///      from `tokenAddress` on the PN, not forwarded by the private hub.
    /// @param tokenResourceId Private-hub resource ID assigned to the token.
    /// @param tokenAddress Address of the token contract on PN.
    /// @param ercStandard ERC standard encoded as `SharedObjects.ErcStandard`.
    function activateToken(bytes32 tokenResourceId, address tokenAddress, uint8 ercStandard) external;

    /// @notice Registers and authorizes a destination-chain mirror instance auto-deployed by the
    ///         `ResourceManager` during inbound teleport delivery (teleport to a non-issuer PN).
    /// @dev Restricted to the `ResourceManager` caller (holds `FACTORY_DEPLOYER`); forwards to
    ///      {ITokenCore-registerHubToken}. Idempotent — safe on teleport retries.
    /// @param tokenResourceId Private-hub resource ID assigned to the token.
    /// @param tokenAddress Address of the auto-deployed mirror instance on this PN.
    function registerHubToken(bytes32 tokenResourceId, address tokenAddress) external;

    /// @notice Marks a token as rejected by the private hub.
    /// @dev Restricted to callers with `PN_TOKEN_REGISTRY_ADMIN`.
    /// @param tokenAddress Address of the token contract.
    function rejectToken(address tokenAddress) external;

    /// @notice Stores the public-chain token address once deployment is confirmed.
    /// @dev Restricted to callers with `PN_TOKEN_REGISTRY_ADMIN`.
    /// @param tokenAddress Address of the PN token contract.
    /// @param publicTokenAddress Address of the deployed public-chain token contract.
    function updatePublicTokenAddress(address tokenAddress, address publicTokenAddress) external;

    /// @notice Deprecates the public-chain lifecycle leg for a token.
    /// @dev Restricted to callers with `PN_TOKEN_REGISTRY_ADMIN`.
    /// @param tokenAddress Address of the token contract.
    function deprecateOnPublicChain(address tokenAddress) external;

    // ─── Freeze Management ───────────────────────────────────────────────

    /// @notice Applies a PN-wide freeze to a token.
    /// @dev Restricted to callers with `MESSAGE_EXECUTOR`.
    /// @param tokenAddress Address of the token contract.
    function freezeOnPrivacyNode(address tokenAddress) external;

    /// @notice Removes a PN-wide freeze from a token.
    /// @dev Restricted to callers with `MESSAGE_EXECUTOR`.
    /// @param tokenAddress Address of the token contract.
    function unfreezeOnPrivacyNode(address tokenAddress) external;

    /// @notice Replaces the local hub-freeze snapshot with the authoritative hub snapshot.
    /// @dev Restricted to callers with `MESSAGE_EXECUTOR`.
    /// @param frozenTokens Full frozen-token dataset received from the private hub.
    function syncFrozenTokens(TokenStructs.FrozenToken[] calldata frozenTokens) external;

    /// @notice Applies or refreshes a participant-scoped freeze entry from the private hub.
    /// @dev Restricted to callers with `MESSAGE_EXECUTOR`.
    /// @param frozenToken Frozen-token record to upsert.
    function updateFrozenToken(TokenStructs.FrozenToken calldata frozenToken) external;

    /// @notice Removes participants from a previously frozen-token record.
    /// @dev Restricted to callers with `MESSAGE_EXECUTOR`.
    /// @param unfrozenToken Frozen-token record describing which participants should be removed.
    function removeFrozenToken(TokenStructs.FrozenToken calldata unfrozenToken) external;

    /// @notice Applies a freeze to the token public-chain lifecycle layer.
    /// @dev Restricted to callers with `MESSAGE_EXECUTOR`.
    /// @param tokenAddress Address of the token contract.
    function freezeOnPublicChain(address tokenAddress) external;

    /// @notice Removes a freeze from the token public-chain lifecycle layer.
    /// @dev Restricted to callers with `MESSAGE_EXECUTOR`.
    /// @param tokenAddress Address of the token contract.
    function unfreezeOnPublicChain(address tokenAddress) external;

    /// @notice Reverts when the token is frozen for the given participant chain.
    /// @dev Unrestricted read-only query; freeze state is non-sensitive and callable by anyone.
    /// @param tokenResourceId Resource ID of the token.
    /// @param chainId Participant chain ID being validated.
    function validateTokenForParticipant(bytes32 tokenResourceId, uint256 chainId) external view;

    /// @notice Returns whether a token is frozen for a specific participant chain.
    /// @dev Unrestricted read-only query; freeze state is non-sensitive and callable by anyone.
    /// @param tokenResourceId Resource ID of the token.
    /// @param chainId Participant chain ID being queried.
    /// @return True when the token is frozen for that participant.
    function getFrozenTokenForParticipant(bytes32 tokenResourceId, uint256 chainId) external view returns (bool);

    /// @notice Requests the current full frozen-token dataset from the private hub.
    /// @dev Restricted to callers with `MESSAGE_EXECUTOR`.
    function requestAllFrozenTokensDataFromPrivateHub() external;

    // ─── Queries ─────────────────────────────────────────────────────────

    /// @notice Returns whether the token is operational across PN, hub, and public-chain layers.
    /// @param tokenAddress Address of the token contract.
    /// @return True when the token is fully operational.
    function isTokenFullyOperational(address tokenAddress) external view returns (bool);

    /// @notice Returns whether the token is active for private-hub operations.
    /// @param tokenAddress Address of the token contract.
    /// @return True when the token is active for hub interactions.
    function isTokenActiveForHub(address tokenAddress) external view returns (bool);

    /// @notice Returns whether the token is active for public-chain operations.
    /// @param tokenAddress Address of the token contract.
    /// @return True when the token is active on the public-chain leg.
    function isTokenActiveForPublicChain(address tokenAddress) external view returns (bool);

    /// @notice Returns every registered PN token record.
    /// @return Array of token records.
    function getAllTokens() external view returns (TokenStructs.Token[] memory);

    /// @notice Returns a token record by PN token address.
    /// @param tokenAddress Address of the token contract.
    /// @return Token record for that address.
    function getTokenByAddress(address tokenAddress) external view returns (TokenStructs.Token memory);

    /// @notice Returns a token record by resource ID.
    /// @param tokenResourceId Resource ID of the token.
    /// @return Token record for that resource ID.
    function getTokenByResourceId(bytes32 tokenResourceId) external view returns (TokenStructs.Token memory);

    /// @notice Returns a token record by symbol.
    /// @param symbol Token symbol.
    /// @return Token record for that symbol.
    function getTokenBySymbol(string memory symbol) external view returns (TokenStructs.Token memory);

    /// @notice Returns the PN lifecycle status for a token.
    /// @param tokenAddress Address of the token contract.
    /// @return Current PN status.
    function getPrivacyNodeStatus(address tokenAddress) external view returns (TokenStructs.PrivacyNodeStatus);

    /// @notice Returns the hub lifecycle status mirrored on PN for a token.
    /// @param tokenAddress Address of the token contract.
    /// @return Current hub status.
    function getHubStatus(address tokenAddress) external view returns (TokenStructs.HubStatus);

    /// @notice Returns the public-chain lifecycle status for a token.
    /// @param tokenAddress Address of the token contract.
    /// @return Current public-chain status.
    function getPublicChainStatus(address tokenAddress) external view returns (TokenStructs.PublicChainStatus);

    /// @notice Returns all token records with the given PN lifecycle status.
    /// @param status PN status used for filtering.
    /// @return Token records matching the requested PN status.
    function getTokensByPrivacyNodeStatus(TokenStructs.PrivacyNodeStatus status)
        external
        view
        returns (TokenStructs.Token[] memory);

    /// @notice Returns all token records with the given hub lifecycle status.
    /// @param status Hub status used for filtering.
    /// @return Token records matching the requested hub status.
    function getTokensByHubStatus(TokenStructs.HubStatus status) external view returns (TokenStructs.Token[] memory);

    /// @notice Returns the number of registered PN token records.
    /// @return Count of registered tokens.
    function getTokenCount() external view returns (uint256);

    /// @notice Returns the number of PN tokens currently considered active.
    /// @return Count of active tokens.
    function getActiveTokenCount() external view returns (uint256);

    /// @notice Returns whether a token address is registered on PN.
    /// @param tokenAddress Address of the token contract.
    /// @return True when the token exists in the registry.
    function tokenExists(address tokenAddress) external view returns (bool);

    // ─── Version ──────────────────────────────────────────────────────────

    /// @notice Returns the contract version for the PN facade.
    /// @return Semantic contract version encoded as an integer.
    function contractVersion() external pure returns (uint256);
}
