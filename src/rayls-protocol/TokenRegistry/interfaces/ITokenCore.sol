// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "../libraries/TokenStructs.sol";
import "../../../rayls-protocol-sdk/libraries/SharedObjects.sol";

interface ITokenCore {
    // ─── Errors ──────────────────────────────────────────────────────────

    error TokenCoreV1__UnauthorizedCaller(address caller);
    error TokenCoreV1__UnauthorizedFreezeManager(address caller);
    error TokenCoreV1__InvalidTokenAddress();
    error TokenCoreV1__InvalidTokenRegistryAddress();
    error TokenCoreV1__InvalidTokenFreezeManagerAddress();
    error TokenCoreV1__InvalidEndpointAddress();
    error TokenCoreV1__InvalidEnygmaPNEventsAddress();
    error TokenCoreV1__TokenAlreadyExists();
    error TokenCoreV1__TokenDoesNotExist();
    error TokenCoreV1__TokenSymbolAlreadyExists();
    error TokenCoreV1__ResourceIdAlreadyAssigned(bytes32 resourceId);
    error TokenCoreV1__ResourceIdAlreadySet(address tokenAddress);
    error TokenCoreV1__InvalidPrivacyNodeStatus(TokenStructs.PrivacyNodeStatus status);
    error TokenCoreV1__PrivacyNodeAuthorizationRequired(address tokenAddress);
    error TokenCoreV1__EndpointNotConfigured();
    error TokenCoreV1__TokenRegistryNotConfigured();
    error TokenCoreV1__StatusAlreadySet();
    error TokenCoreV1__HubApprovalNotPending(address tokenAddress, TokenStructs.HubStatus currentStatus);

    // ─── Events ──────────────────────────────────────────────────────────

    event TokenRegistered(
        address indexed tokenAddress, string name, string symbol, SharedObjects.ErcStandard ercStandard
    );
    event PrivacyNodeStatusUpdated(
        address indexed tokenAddress,
        TokenStructs.PrivacyNodeStatus previousStatus,
        TokenStructs.PrivacyNodeStatus newStatus
    );
    event HubStatusUpdated(
        address indexed tokenAddress, TokenStructs.HubStatus previousStatus, TokenStructs.HubStatus newStatus
    );
    event PublicChainStatusUpdated(
        address indexed tokenAddress,
        TokenStructs.PublicChainStatus previousStatus,
        TokenStructs.PublicChainStatus newStatus
    );
    event TokenActivated(
        bytes32 indexed resourceId, address indexed tokenAddress, SharedObjects.ErcStandard ercStandard
    );
    event PublicTokenAddressUpdated(address indexed tokenAddress, address indexed publicTokenAddress);
    event TokenCoreModulesConfigured(
        address indexed tokenRegistry,
        address indexed tokenFreezeManager,
        address indexed endpoint,
        address enygmaPNEvents,
        address relayAuthorizationRegistry
    );

    // ─── Registration ────────────────────────────────────────────────────

    /// @notice Registers a token locally on the Privacy Node.
    /// @dev Sets `privacyNodeStatus` to `WAITING_APPROVAL`.
    /// @param tokenAddress Address of the token contract being registered.
    function registerToken(address tokenAddress) external;

    /// @notice Updates the PN-controlled lifecycle status for a token.
    /// @dev This covers local approval and rejection only. Freeze transitions are handled
    ///      exclusively through `setFreezeStatus()` by the freeze manager.
    /// @param tokenAddress Address of the token whose PN status is changing.
    /// @param status New PN lifecycle status.
    function updatePrivacyNodeStatus(address tokenAddress, TokenStructs.PrivacyNodeStatus status) external;

    /// @notice Initiates hub registration for an already PN-authorized token.
    /// @param tokenAddress Address of the token to submit to the Private Hub.
    function submitToHub(address tokenAddress) external;

    /// @notice Initiates public-chain deployment for an already PN-authorized token.
    /// @param tokenAddress Address of the token to submit to the public-chain flow.
    function submitToPublicChain(address tokenAddress) external;

    /// @notice Activates a token after PNH approval via cross-chain callback.
    /// @dev The supply emitted to Enygma is read locally from `tokenAddress`, not forwarded by the PNH.
    /// @param resourceId Resource ID assigned by the Private Hub.
    /// @param tokenAddress Address of the token being activated on the PN.
    /// @param ercStandard Encoded token standard used for activation side-effects.
    function activateToken(bytes32 resourceId, address tokenAddress, uint8 ercStandard) external;

    /// @notice Marks a token as rejected by the Private Hub.
    /// @param tokenAddress Address of the token being rejected.
    function rejectToken(address tokenAddress) external;

    /// @notice Registers and authorizes a token instance auto-deployed on a destination chain.
    /// @dev Called through the PN `TokenRegistryV1` facade (restricted to the `ResourceManager`
    ///      caller via the access manager) immediately after the ResourceManager auto-deploys a
    ///      mirror instance while delivering an inbound cross-chain message (teleport to a
    ///      non-issuer PN). The token is already globally hub-approved on its issuer chain, so it is recorded as
    ///      fully authorized (`privacyNodeStatus` and `hubStatus` = `AUTHORIZED`). Idempotent:
    ///      no-ops when the address is already recorded or when the resourceId is already bound on
    ///      this PN. The ERC standard is derived on-chain from the deployed instance.
    /// @param resourceId Resource ID assigned by the Private Hub for this token.
    /// @param tokenAddress Address of the auto-deployed mirror instance on this PN.
    function registerHubToken(bytes32 resourceId, address tokenAddress) external;

    // ─── Governance / Relayer ─────────────────────────────────────────────

    /// @notice Registers the public-chain mirror address for a token.
    /// @dev Sets `publicChainStatus` to `DEPLOYED`.
    /// @param tokenAddress Address of the PN token.
    /// @param publicTokenAddress Address of the token mirror on the public chain.
    function updatePublicTokenAddress(address tokenAddress, address publicTokenAddress) external;

    /// @notice Deprecates the public-chain lifecycle leg for a token.
    /// @dev Sets `publicChainStatus` to `DEPRECATED`. Does not revoke PN or hub authorization,
    ///      nor remove the token from the registry; the address/resourceId/symbol indexes and
    ///      `getAllTokens()` continue to return it.
    /// @param tokenAddress Address of the token whose public-chain leg is being deprecated.
    function deprecateOnPublicChain(address tokenAddress) external;

    // ─── Internal Freeze Setter ───────────────────────────────────────────

    /// @notice Updates frozen/unfrozen status for a specific lifecycle layer.
    /// @dev Only the configured PN `TokenFreezeManagerV1` should call this function.
    /// @param tokenAddress Address of the token being updated.
    /// @param layer Lifecycle layer being frozen or unfrozen.
    /// @param frozen Whether the layer is entering or leaving its `FROZEN` state.
    function setFreezeStatus(address tokenAddress, TokenStructs.FreezeLayer layer, bool frozen) external;

    // ─── Operational Checks ───────────────────────────────────────────────

    /// @notice Returns whether a token is fully operational across PN, hub, and public chain.
    /// @param tokenAddress Address of the token being queried.
    /// @return True when the token is active and non-frozen on all layers.
    function isTokenFullyOperational(address tokenAddress) external view returns (bool);

    /// @notice Returns whether a token is active for hub-related cross-chain operations.
    /// @param tokenAddress Address of the token being queried.
    /// @return True when the token can participate in hub operations.
    function isTokenActiveForHub(address tokenAddress) external view returns (bool);

    /// @notice Returns whether a token is active for public-chain operations.
    /// @param tokenAddress Address of the token being queried.
    /// @return True when the token can participate in public-chain flows.
    function isTokenActiveForPublicChain(address tokenAddress) external view returns (bool);

    // ─── Queries ─────────────────────────────────────────────────────────

    /// @notice Returns every token registered on the Privacy Node.
    /// @return Array of PN token records.
    function getAllTokens() external view returns (TokenStructs.Token[] memory);

    /// @notice Returns a token by its PN token address.
    /// @param tokenAddress Address of the token being queried.
    /// @return Token record for the given address.
    function getTokenByAddress(address tokenAddress) external view returns (TokenStructs.Token memory);

    /// @notice Returns a token by its assigned resource ID.
    /// @param resourceId Resource ID being queried.
    /// @return Token record for the given resource ID.
    function getTokenByResourceId(bytes32 resourceId) external view returns (TokenStructs.Token memory);

    /// @notice Returns a token by its symbol.
    /// @param symbol Token symbol being queried.
    /// @return Token record for the given symbol.
    function getTokenBySymbol(string memory symbol) external view returns (TokenStructs.Token memory);

    /// @notice Returns the PN lifecycle status for a token.
    /// @param tokenAddress Address of the token being queried.
    /// @return Current `privacyNodeStatus`.
    function getPrivacyNodeStatus(address tokenAddress) external view returns (TokenStructs.PrivacyNodeStatus);

    /// @notice Returns the hub lifecycle status for a token.
    /// @param tokenAddress Address of the token being queried.
    /// @return Current `hubStatus`.
    function getHubStatus(address tokenAddress) external view returns (TokenStructs.HubStatus);

    /// @notice Returns the public-chain lifecycle status for a token.
    /// @param tokenAddress Address of the token being queried.
    /// @return Current `publicChainStatus`.
    function getPublicChainStatus(address tokenAddress) external view returns (TokenStructs.PublicChainStatus);

    /// @notice Returns all tokens with the requested PN lifecycle status.
    /// @param status PN lifecycle status to filter by.
    /// @return Array of tokens currently in that PN status.
    function getTokensByPrivacyNodeStatus(TokenStructs.PrivacyNodeStatus status)
        external
        view
        returns (TokenStructs.Token[] memory);

    /// @notice Returns all tokens with the requested hub lifecycle status.
    /// @param status Hub lifecycle status to filter by.
    /// @return Array of tokens currently in that hub status.
    function getTokensByHubStatus(TokenStructs.HubStatus status) external view returns (TokenStructs.Token[] memory);

    /// @notice Returns the total number of tokens registered on the PN.
    /// @return Token count.
    function getTokenCount() external view returns (uint256);

    /// @notice Returns the number of currently active tokens on the PN.
    /// @return Count of active tokens.
    function getActiveTokenCount() external view returns (uint256);

    /// @notice Returns whether a token exists in the PN registry.
    /// @param tokenAddress Address of the token being queried.
    /// @return True when the token has been registered.
    function tokenExists(address tokenAddress) external view returns (bool);

    /// @notice Returns whether a token with the given resource ID exists in the PN registry.
    /// @param resourceId Resource ID being queried.
    /// @return True when a token with that resource ID has been registered.
    function tokenExistsByResourceId(bytes32 resourceId) external view returns (bool);

    // ─── Configuration ────────────────────────────────────────────────────

    /// @notice Configures the facade address that owns this module.
    /// @param tokenRegistry Address of the PN `TokenRegistryV1` facade.
    function setTokenRegistry(address tokenRegistry) external;

    /// @notice Configures the PN freeze manager allowed to call `setFreezeStatus()`.
    /// @param freezeManager Address of the PN `TokenFreezeManagerV1` module.
    function setTokenFreezeManager(address freezeManager) external;

    /// @notice Configures the PN endpoint used for cross-chain messaging.
    /// @param endpoint Address of the PN endpoint.
    function setEndpoint(address endpoint) external;

    /// @notice Configures the PN Enygma events contract.
    /// @param enygmaPNEvents Address of the PN Enygma events contract.
    function setEnygmaPNEvents(address enygmaPNEvents) external;

    /// @notice Configures the relayer authorization registry used by relayer-only flows.
    /// @param relayAuthRegistry Address of the relay authorization registry.
    function setRelayAuthorizationRegistry(address relayAuthRegistry) external;
}
