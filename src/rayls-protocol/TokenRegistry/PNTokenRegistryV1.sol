// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/ITokenCore.sol";
import "./interfaces/ITokenFreezeManager.sol";
import "./interfaces/ITokenRegistry.sol";
import "./libraries/TokenStructs.sol";
import "../../privateHub/AccessControl/RaylsAccessManaged.sol";
import "../../rayls-protocol-sdk/Constants.sol";
import "../../rayls-protocol-sdk/RaylsAppV1.sol";
import "../../rayls-protocol-sdk/interfaces/IRegistrableToken.sol";

/**
 * @title PNTokenRegistryV1
 * @notice PN-side UUPS facade exposing token lifecycle and freeze operations behind a
 *         single stable resource address.
 * @dev Business selectors are intended to be mapped in `RaylsAccessManagerV1`:
 *      - `TOKEN_CREATOR` for token registration
 *      - `MESSAGE_EXECUTOR` for freeze and activation callbacks
 *      - `PN_TOKEN_REGISTRY_ADMIN` for admin/configuration selectors
 *      - `PN_TOKEN_REGISTRY_UPGRADER` for upgrade authorization
 */
contract PNTokenRegistryV1 is Initializable, ITokenRegistry, UUPSUpgradeable, RaylsAppV1, RaylsAccessManaged {
    ITokenCore private tokenCore;
    ITokenFreezeManager private tokenFreezeManager;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the PN registry facade with its endpoint and access authority.
    /// @param endpointAddress Address of the local PN endpoint.
    /// @param authority_ Address of the Rayls access manager used by `restricted`.
    function initialize(address endpointAddress, address authority_) public initializer {
        __UUPSUpgradeable_init();
        RaylsAppV1.initialize(endpointAddress);
        resourceId = Constants.RESOURCE_ID_TOKEN_REGISTRY;
        _initializeAuthority(authority_);
    }

    // ─── Module Configuration ────────────────────────────────────────────

    /// @inheritdoc ITokenRegistry
    function setTokenCore(address tokenCoreAddress) external restricted {
        if (tokenCoreAddress == address(0)) revert TokenRegistryV1__InvalidTokenCoreAddress();
        tokenCore = ITokenCore(tokenCoreAddress);
        emit TokenCoreSet(tokenCoreAddress);
        emit TokenRegistryModulesConfigured(address(tokenCore), address(tokenFreezeManager));
    }

    /// @inheritdoc ITokenRegistry
    function setTokenFreezeManager(address freezeManagerAddress) external restricted {
        if (freezeManagerAddress == address(0)) revert TokenRegistryV1__InvalidTokenFreezeManagerAddress();
        tokenFreezeManager = ITokenFreezeManager(freezeManagerAddress);
        emit TokenFreezeManagerSet(freezeManagerAddress);
        emit TokenRegistryModulesConfigured(address(tokenCore), address(tokenFreezeManager));
    }

    /// @inheritdoc ITokenRegistry
    function getTokenCore() external view returns (ITokenCore) {
        return tokenCore;
    }

    /// @inheritdoc ITokenRegistry
    function getTokenFreezeManager() external view returns (ITokenFreezeManager) {
        return tokenFreezeManager;
    }

    // ─── Token Lifecycle ─────────────────────────────────────────────────

    /// @inheritdoc ITokenRegistry
    function registerToken(address tokenAddress) external restricted {
        _requireTokenCore().registerToken(tokenAddress);
    }

    /// @inheritdoc ITokenRegistry
    function updatePrivacyNodeStatus(address tokenAddress, TokenStructs.PrivacyNodeStatus status) external restricted {
        _requireTokenCore().updatePrivacyNodeStatus(tokenAddress, status);
    }

    /// @inheritdoc ITokenRegistry
    function submitToHub(address tokenAddress) external restricted {
        _requireTokenCore().submitToHub(tokenAddress);
    }

    /// @inheritdoc ITokenRegistry
    function submitToPublicChain(address tokenAddress) external restricted {
        _requireTokenCore().submitToPublicChain(tokenAddress);
    }

    /// @inheritdoc ITokenRegistry
    function activateToken(bytes32 tokenResourceId, address tokenAddress, uint8 ercStandard) external restricted {
        IRegistrableToken(tokenAddress).setResourceId(tokenResourceId);
        ITokenCore core = _requireTokenCore();
        core.activateToken(tokenResourceId, tokenAddress, ercStandard);
    }

    /// @inheritdoc ITokenRegistry
    function registerHubToken(bytes32 tokenResourceId, address tokenAddress) external restricted {
        _requireTokenCore().registerHubToken(tokenResourceId, tokenAddress);
    }

    /// @inheritdoc ITokenRegistry
    function rejectToken(address tokenAddress) external restricted {
        _requireTokenCore().rejectToken(tokenAddress);
    }

    /// @inheritdoc ITokenRegistry
    function updatePublicTokenAddress(address tokenAddress, address publicTokenAddress) external restricted {
        _requireTokenCore().updatePublicTokenAddress(tokenAddress, publicTokenAddress);
    }

    /// @inheritdoc ITokenRegistry
    function deprecateOnPublicChain(address tokenAddress) external restricted {
        _requireTokenCore().deprecateOnPublicChain(tokenAddress);
    }

    // ─── Freeze Management ───────────────────────────────────────────────

    /// @inheritdoc ITokenRegistry
    function freezeOnPrivacyNode(address tokenAddress) external restricted {
        _requireTokenFreezeManager().freezeOnPrivacyNode(tokenAddress);
    }

    /// @inheritdoc ITokenRegistry
    function unfreezeOnPrivacyNode(address tokenAddress) external restricted {
        _requireTokenFreezeManager().unfreezeOnPrivacyNode(tokenAddress);
    }

    /// @inheritdoc ITokenRegistry
    function syncFrozenTokens(TokenStructs.FrozenToken[] calldata frozenTokens) external restricted {
        _requireTokenFreezeManager().syncFrozenTokens(frozenTokens);
    }

    /// @inheritdoc ITokenRegistry
    function updateFrozenToken(TokenStructs.FrozenToken calldata frozenToken) external restricted {
        _requireTokenFreezeManager().updateFrozenToken(frozenToken);
    }

    /// @inheritdoc ITokenRegistry
    function removeFrozenToken(TokenStructs.FrozenToken calldata unfrozenToken) external restricted {
        _requireTokenFreezeManager().removeFrozenToken(unfrozenToken);
    }

    /// @inheritdoc ITokenRegistry
    function freezeOnPublicChain(address tokenAddress) external restricted {
        _requireTokenFreezeManager().freezeOnPublicChain(tokenAddress);
    }

    /// @inheritdoc ITokenRegistry
    function unfreezeOnPublicChain(address tokenAddress) external restricted {
        _requireTokenFreezeManager().unfreezeOnPublicChain(tokenAddress);
    }

    /// @inheritdoc ITokenRegistry
    function validateTokenForParticipant(bytes32 tokenResourceId, uint256 chainId) external view {
        _requireTokenFreezeManager().validateTokenForParticipant(tokenResourceId, chainId);
    }

    /// @inheritdoc ITokenRegistry
    function getFrozenTokenForParticipant(bytes32 tokenResourceId, uint256 chainId) external view returns (bool) {
        return _requireTokenFreezeManager().getFrozenTokenForParticipant(tokenResourceId, chainId);
    }

    /// @inheritdoc ITokenRegistry
    function requestAllFrozenTokensDataFromPrivateHub() external restricted {
        _requireTokenFreezeManager().requestAllFrozenTokensDataFromPrivateHub();
    }

    // ─── Queries ─────────────────────────────────────────────────────────

    /// @inheritdoc ITokenRegistry
    function isTokenFullyOperational(address tokenAddress) external view returns (bool) {
        return _requireTokenCore().isTokenFullyOperational(tokenAddress);
    }

    /// @inheritdoc ITokenRegistry
    function isTokenActiveForHub(address tokenAddress) external view returns (bool) {
        return _requireTokenCore().isTokenActiveForHub(tokenAddress);
    }

    /// @inheritdoc ITokenRegistry
    function isTokenActiveForPublicChain(address tokenAddress) external view returns (bool) {
        return _requireTokenCore().isTokenActiveForPublicChain(tokenAddress);
    }

    /// @inheritdoc ITokenRegistry
    function getAllTokens() external view returns (TokenStructs.Token[] memory) {
        return _requireTokenCore().getAllTokens();
    }

    /// @inheritdoc ITokenRegistry
    function getTokenByAddress(address tokenAddress) external view returns (TokenStructs.Token memory) {
        return _requireTokenCore().getTokenByAddress(tokenAddress);
    }

    /// @inheritdoc ITokenRegistry
    function getTokenByResourceId(bytes32 tokenResourceId) external view returns (TokenStructs.Token memory) {
        return _requireTokenCore().getTokenByResourceId(tokenResourceId);
    }

    /// @inheritdoc ITokenRegistry
    function getTokenBySymbol(string memory symbol) external view returns (TokenStructs.Token memory) {
        return _requireTokenCore().getTokenBySymbol(symbol);
    }

    /// @inheritdoc ITokenRegistry
    function getPrivacyNodeStatus(address tokenAddress) external view returns (TokenStructs.PrivacyNodeStatus) {
        return _requireTokenCore().getPrivacyNodeStatus(tokenAddress);
    }

    /// @inheritdoc ITokenRegistry
    function getHubStatus(address tokenAddress) external view returns (TokenStructs.HubStatus) {
        return _requireTokenCore().getHubStatus(tokenAddress);
    }

    /// @inheritdoc ITokenRegistry
    function getPublicChainStatus(address tokenAddress) external view returns (TokenStructs.PublicChainStatus) {
        return _requireTokenCore().getPublicChainStatus(tokenAddress);
    }

    /// @inheritdoc ITokenRegistry
    function getTokensByPrivacyNodeStatus(TokenStructs.PrivacyNodeStatus status)
        external
        view
        returns (TokenStructs.Token[] memory)
    {
        return _requireTokenCore().getTokensByPrivacyNodeStatus(status);
    }

    /// @inheritdoc ITokenRegistry
    function getTokensByHubStatus(TokenStructs.HubStatus status) external view returns (TokenStructs.Token[] memory) {
        return _requireTokenCore().getTokensByHubStatus(status);
    }

    /// @inheritdoc ITokenRegistry
    function getTokenCount() external view returns (uint256) {
        return _requireTokenCore().getTokenCount();
    }

    /// @inheritdoc ITokenRegistry
    function getActiveTokenCount() external view returns (uint256) {
        return _requireTokenCore().getActiveTokenCount();
    }

    /// @inheritdoc ITokenRegistry
    function tokenExists(address tokenAddress) external view returns (bool) {
        return _requireTokenCore().tokenExists(tokenAddress);
    }

    // ─── Version / Upgrade ───────────────────────────────────────────────

    /// @inheritdoc ITokenRegistry
    function contractVersion() external pure virtual returns (uint256) {
        return 1;
    }

    /// @dev Authorizes UUPS upgrades through the configured Rayls access manager.
    function _authorizeUpgrade(address) internal view override {
        _checkCanCall(msg.sender, msg.sig);
    }

    // ─── Internal Helpers ────────────────────────────────────────────────

    /// @dev Returns the configured token-core module or reverts if it is not set.
    function _requireTokenCore() internal view returns (ITokenCore core) {
        core = tokenCore;
        if (address(core) == address(0)) revert TokenRegistryV1__TokenCoreNotConfigured();
    }

    /// @dev Returns the configured token-freeze manager module or reverts if it is not set.
    function _requireTokenFreezeManager() internal view returns (ITokenFreezeManager freezeManager) {
        freezeManager = tokenFreezeManager;
        if (address(freezeManager) == address(0)) revert TokenRegistryV1__TokenFreezeManagerNotConfigured();
    }
}
