// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import './interfaces/ITokenRegistry.sol';
import './interfaces/ITokenCore.sol';
import './interfaces/ITokenFreezeManager.sol';
import './interfaces/IEnygmaTokenManager.sol';
import './libraries/TokenStructs.sol';
import '../ParticipantStorage/ParticipantStorageV1.sol';
import '../ResourceRegistry/ResourceRegistryV1.sol';
import '../../rayls-protocol-sdk/RaylsAppV1.sol';
import '../../rayls-protocol-sdk/Constants.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import '../../rayls-protocol-sdk/libraries/SharedObjects.sol';
import '../../rayls-protocol/Enygma/Enygma-Payments/EnygmaFactory.sol';
import '../AccessControl/RaylsAccessManaged.sol';

/**
 * @title TokenRegistryV1
 * @dev Main contract that delegates token management functionality to specialized modules.
 *
 * This contract implements a modular architecture where different aspects of token management
 * are handled by separate modules:
 * - TokenCore: Core token registration and management
 * - TokenFreezeManager: Token freezing/unfreezing functionality
 * - EnygmaTokenManager: Enygma-specific token operations
 *
 * Governance functions and cross-chain receive functions are gated by
 * RaylsAccessManagerV1 via the `restricted` modifier.
 */
contract TokenRegistryV1 is Initializable, RaylsAppV1, ITokenRegistry, UUPSUpgradeable, RaylsAccessManaged {
    // ========== Storage Variables ==========

    /// @notice Reference to the TokenCore module
    ITokenCore private tokenCore;

    /// @notice Reference to the TokenFreezeManager module
    ITokenFreezeManager private tokenFreezeManager;

    /// @notice Reference to the EnygmaTokenManager module
    IEnygmaTokenManager private enygmaTokenManager;

    // ========== Events ==========

    event ModulesConfigured(
        address indexed tokenCore,
        address indexed tokenFreezeManager,
        address indexed enygmaTokenManager
    );

    // ========== Initialization ==========

    /**
     * @notice Initializes the TokenRegistry contract.
     * @param _endpoint The address of the Rayls endpoint for cross-chain communication
     * @param authority_ Address of the deployed RaylsAccessManagerV1.
     */
    function initialize(address _endpoint, address authority_) public initializer {
        __UUPSUpgradeable_init();
        RaylsAppV1.initialize(_endpoint);
        endpoint = IRaylsEndpoint(_endpoint);
        resourceId = Constants.RESOURCE_ID_TOKEN_REGISTRY;
        _initializeAuthority(authority_);
    }

    /// @dev Upgrade authorization is gated by the access manager (ADMIN required).
    function _authorizeUpgrade(address /*newImplementation*/) internal override {
        _checkCanCall(msg.sender, msg.sig);
    }

    // ========== Module Configuration ==========

    /**
     * @notice Configures all modules in a single transaction
     * @param _tokenCore The address of the TokenCore module
     * @param _tokenFreezeManager The address of the TokenFreezeManager module
     * @param _enygmaTokenManager The address of the EnygmaTokenManager module
     */
    function configureModules(
        address _tokenCore,
        address _tokenFreezeManager,
        address _enygmaTokenManager
    ) external virtual restricted {
        require(_tokenCore != address(0), 'TokenRegistryV1: TokenCore address cannot be zero');
        require(_tokenFreezeManager != address(0), 'TokenRegistryV1: TokenFreezeManager address cannot be zero');
        require(_enygmaTokenManager != address(0), 'TokenRegistryV1: EnygmaTokenManager address cannot be zero');

        tokenCore = ITokenCore(_tokenCore);
        tokenFreezeManager = ITokenFreezeManager(_tokenFreezeManager);
        enygmaTokenManager = IEnygmaTokenManager(_enygmaTokenManager);

        emit ModulesConfigured(_tokenCore, _tokenFreezeManager, _enygmaTokenManager);
    }

    function setTokenCore(address _tokenCore) external virtual restricted {
        require(_tokenCore != address(0), 'TokenRegistryV1: TokenCore address cannot be zero');
        tokenCore = ITokenCore(_tokenCore);
    }

    function setTokenFreezeManager(address _tokenFreezeManager) external virtual restricted {
        require(_tokenFreezeManager != address(0), 'TokenRegistryV1: TokenFreezeManager address cannot be zero');
        tokenFreezeManager = ITokenFreezeManager(_tokenFreezeManager);
    }

    function setEnygmaTokenManager(address _enygmaTokenManager) external virtual restricted {
        require(_enygmaTokenManager != address(0), 'TokenRegistryV1: EnygmaTokenManager address cannot be zero');
        enygmaTokenManager = IEnygmaTokenManager(_enygmaTokenManager);
    }

    // ========== Module Getters ==========

    function getTokenCore() external view virtual returns (ITokenCore) {
        return tokenCore;
    }

    function getTokenFreezeManager() external view virtual returns (ITokenFreezeManager) {
        return tokenFreezeManager;
    }

    function getEnygmaTokenManager() external view virtual returns (IEnygmaTokenManager) {
        return enygmaTokenManager;
    }

    // ========== Token Management (Delegated to TokenCore) ==========

    function addToken(SharedObjects.TokenRegistrationData calldata tokenData) external virtual restricted returns (bytes32) {
        return tokenCore.addToken(tokenData, _getMsgSenderOnReceiveMethod());
    }

    function getTokenByResourceId(bytes32 resourceId) external view virtual returns (TokenStructs.Token memory) {
        return tokenCore.getTokenByResourceId(resourceId);
    }

    function getAllTokens() external view virtual returns (TokenStructs.Token[] memory) {
        return tokenCore.getAllTokens();
    }

    function updateStatus(bytes32 resourceId, TokenStructs.TokenStatus status) external virtual restricted {
        tokenCore.updateStatus(resourceId, status);
    }

    function updateTokenBalance(
        uint256 issuerChainId,
        bytes32 resourceId,
        SharedObjects.BalanceUpdateType updateType,
        bytes memory metadata
    ) external virtual restricted {
        tokenCore.updateTokenBalance(issuerChainId, resourceId, updateType, metadata);
    }

    // ========== Token Freezing (Delegated to TokenFreezeManager) ==========

    function freezeToken(bytes32 resourceId, uint256[] calldata chainIds) external virtual restricted {
        tokenFreezeManager.freezeToken(resourceId, chainIds);
    }

    function unfreezeToken(bytes32 resourceId, uint256[] memory chainIds) external virtual restricted {
        tokenFreezeManager.unfreezeToken(resourceId, chainIds);
    }

    // ========== Enygma Token Management (Delegated to EnygmaTokenManager) ==========

    function setEnygmaFactory(address _enygmaFactory) public virtual restricted {
        enygmaTokenManager.setEnygmaFactory(_enygmaFactory);
    }

    function isTokenFrozenForParticipant(bytes32 resourceId, uint256 chainId) external view virtual returns (bool) {
        return tokenFreezeManager.isTokenFrozenForParticipant(resourceId, chainId);
    }

    // ========== Cross-Chain Communication ==========

    function broadcastCurrentFrozenResourcesForNewParticipant() public virtual restricted {
        tokenFreezeManager.broadcastCurrentFrozenResourcesForNewParticipant(_getFromChainIdOnReceiveMethod());
    }

    function broadcastUnfrozenToken(TokenStructs.FrozenToken memory unfrozenToken) public virtual restricted {
        tokenFreezeManager.broadcastUnfrozenToken(unfrozenToken);
    }

    function broadcastFrozenToken(TokenStructs.FrozenToken memory frozenToken) public virtual restricted {
        tokenFreezeManager.broadcastFrozenToken(frozenToken);
    }

    // ========== Contract Information ==========

    function contractVersion() external pure override returns (uint256) {
        return 1;
    }
}
