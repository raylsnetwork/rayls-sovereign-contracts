// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {ITokenRegistry} from "../../../rayls-protocol/TokenRegistry/interfaces/ITokenRegistry.sol";
import {PNTokenRegistryV1} from "../../../rayls-protocol/TokenRegistry/PNTokenRegistryV1.sol";
import {TokenStructs} from "../../../rayls-protocol/TokenRegistry/libraries/TokenStructs.sol";
import {Constants} from "../../../rayls-protocol-sdk/Constants.sol";
import {IRaylsAppV1TokenRegistry} from "../../../rayls-protocol-sdk/interfaces/IRaylsAppV1TokenRegistry.sol";
import {SharedObjects} from "../../../rayls-protocol-sdk/libraries/SharedObjects.sol";

/// @notice Empty endpoint mock used because the facade stores the endpoint address but does not call it in this suite.
contract MockEndpointForPnTokenRegistry {}

/// @notice Minimal RaylsApp-compatible token mock used to verify facade activation sets the token resource ID.
contract MockRegistrableTokenForFacade {
    bytes32 public resourceId;

    /// @notice Records the resource ID assigned by the PN TokenRegistry facade.
    function setResourceId(bytes32 resourceId_) external {
        resourceId = resourceId_;
    }
}

/// @dev Facade-focused test double for PN `PNTokenCoreV1`.
/// It intentionally mirrors the subset of the token-core ABI exposed by `PNTokenRegistryV1`
/// so this suite can assert pure delegation/role-gating behavior without bootstrapping the
/// real module graph.
contract MockTokenCoreForFacade {
    address public lastRegisteredToken;
    address public lastPrivacyNodeStatusToken;
    TokenStructs.PrivacyNodeStatus public lastPrivacyNodeStatus;
    address public lastSubmitToHubToken;
    address public lastSubmitToPublicChainToken;
    bytes32 public lastActivatedResourceId;
    address public lastActivatedToken;
    uint8 public lastActivatedStandard;
    address public lastRejectedToken;
    address public lastPublicTokenAddressToken;
    address public lastPublicTokenAddress;
    address public lastDeprecatedOnPublicChainToken;

    bool public fullOperational = true;
    bool public activeForHub = true;
    bool public activeForPublicChain = false;
    bool public exists = true;
    uint256 public tokenCount = 3;
    uint256 public activeTokenCount = 2;

    TokenStructs.Token internal sampleToken;

    /// @notice Seeds the token record returned by facade query methods.
    constructor() {
        sampleToken = TokenStructs.Token({
            resourceId: keccak256("sample-token"),
            name: "Sample",
            symbol: "SMP",
            uri: "ipfs://sample",
            tokenAddress: address(0x1234),
            publicTokenAddress: address(0x5678),
            issuerChainId: 100,
            ercStandard: SharedObjects.ErcStandard.ERC20,
            privacyNodeStatus: TokenStructs.PrivacyNodeStatus.AUTHORIZED,
            hubStatus: TokenStructs.HubStatus.AUTHORIZED,
            publicChainStatus: TokenStructs.PublicChainStatus.DEPLOYED,
            createdAt: 1,
            updatedAt: 2
        });
    }

    /// @dev Test helper used to control the token record returned by facade queries.
    function setSampleToken(TokenStructs.Token memory token_) external {
        sampleToken = token_;
    }

    /// @dev Test helper used to control the canned boolean query responses.
    function setQueryFlags(bool fullyOperational_, bool activeForHub_, bool activeForPublicChain_, bool exists_)
        external
    {
        fullOperational = fullyOperational_;
        activeForHub = activeForHub_;
        activeForPublicChain = activeForPublicChain_;
        exists = exists_;
    }

    /// @notice Records the token address passed through the facade register path.
    function registerToken(address tokenAddress) external {
        lastRegisteredToken = tokenAddress;
    }

    /// @notice Records the token address and Privacy Node status passed through the facade admin path.
    function updatePrivacyNodeStatus(address tokenAddress, TokenStructs.PrivacyNodeStatus status) external {
        lastPrivacyNodeStatusToken = tokenAddress;
        lastPrivacyNodeStatus = status;
    }

    /// @notice Records the token address submitted to the Hub through the facade admin path.
    function submitToHub(address tokenAddress) external {
        lastSubmitToHubToken = tokenAddress;
    }

    /// @notice Records the token address submitted to the Public Chain through the facade admin path.
    function submitToPublicChain(address tokenAddress) external {
        lastSubmitToPublicChainToken = tokenAddress;
    }

    /// @notice Records activation data delegated from the facade.
    function activateToken(bytes32 resourceId, address tokenAddress, uint8 ercStandard) external {
        lastActivatedResourceId = resourceId;
        lastActivatedToken = tokenAddress;
        lastActivatedStandard = ercStandard;
    }

    /// @notice Records the token address rejected through the facade admin path.
    function rejectToken(address tokenAddress) external {
        lastRejectedToken = tokenAddress;
    }

    /// @notice Records the public token address update delegated from the facade.
    function updatePublicTokenAddress(address tokenAddress, address publicTokenAddress_) external {
        lastPublicTokenAddressToken = tokenAddress;
        lastPublicTokenAddress = publicTokenAddress_;
    }

    /// @notice Records the token address deprecated on the public chain through the facade admin path.
    function deprecateOnPublicChain(address tokenAddress) external {
        lastDeprecatedOnPublicChainToken = tokenAddress;
    }

    /// @notice Returns the configured full-operational query response.
    function isTokenFullyOperational(address) external view returns (bool) {
        return fullOperational;
    }

    /// @notice Returns the configured Hub-active query response.
    function isTokenActiveForHub(address) external view returns (bool) {
        return activeForHub;
    }

    /// @notice Returns the configured Public-Chain-active query response.
    function isTokenActiveForPublicChain(address) external view returns (bool) {
        return activeForPublicChain;
    }

    /// @notice Returns one configured sample token for all-tokens queries.
    function getAllTokens() external view returns (TokenStructs.Token[] memory tokens) {
        tokens = new TokenStructs.Token[](1);
        tokens[0] = sampleToken;
    }

    /// @notice Returns the configured sample token by address.
    function getTokenByAddress(address) external view returns (TokenStructs.Token memory) {
        return sampleToken;
    }

    /// @notice Returns the configured sample token by resource ID.
    function getTokenByResourceId(bytes32) external view returns (TokenStructs.Token memory) {
        return sampleToken;
    }

    /// @notice Returns the configured sample token by symbol.
    function getTokenBySymbol(string memory) external view returns (TokenStructs.Token memory) {
        return sampleToken;
    }

    /// @notice Returns the configured sample token Privacy Node status.
    function getPrivacyNodeStatus(address) external view returns (TokenStructs.PrivacyNodeStatus) {
        return sampleToken.privacyNodeStatus;
    }

    /// @notice Returns the configured sample token Hub status.
    function getHubStatus(address) external view returns (TokenStructs.HubStatus) {
        return sampleToken.hubStatus;
    }

    /// @notice Returns the configured sample token Public Chain status.
    function getPublicChainStatus(address) external view returns (TokenStructs.PublicChainStatus) {
        return sampleToken.publicChainStatus;
    }

    /// @notice Returns one configured sample token for Privacy Node status filtering.
    function getTokensByPrivacyNodeStatus(TokenStructs.PrivacyNodeStatus)
        external
        view
        returns (TokenStructs.Token[] memory tokens)
    {
        tokens = new TokenStructs.Token[](1);
        tokens[0] = sampleToken;
    }

    /// @notice Returns one configured sample token for Hub status filtering.
    function getTokensByHubStatus(TokenStructs.HubStatus) external view returns (TokenStructs.Token[] memory tokens) {
        tokens = new TokenStructs.Token[](1);
        tokens[0] = sampleToken;
    }

    /// @notice Returns the configured token-count query response.
    function getTokenCount() external view returns (uint256) {
        return tokenCount;
    }

    /// @notice Returns the configured active-token-count query response.
    function getActiveTokenCount() external view returns (uint256) {
        return activeTokenCount;
    }

    /// @notice Returns the configured token-existence query response.
    function tokenExists(address) external view returns (bool) {
        return exists;
    }
}

/// @dev Facade-focused test double for PN `PNTokenFreezeManagerV1`.
/// Like `MockTokenCoreForFacade`, this repeats the facade-visible freeze-manager surface so
/// the test can verify selector routing in isolation from the real module implementation.
contract MockTokenFreezeManagerForFacade {
    address public lastPrivacyFreezeToken;
    address public lastPrivacyUnfreezeToken;
    uint256 public lastSyncCount;
    bytes32 public lastSyncResourceId;
    bytes32 public lastUpdatedFrozenResourceId;
    bytes32 public lastRemovedFrozenResourceId;
    address public lastPublicFreezeToken;
    address public lastPublicUnfreezeToken;
    bytes32 public lastValidatedResourceId;
    uint256 public lastValidatedChainId;
    bytes32 public lastFrozenLookupResourceId;
    uint256 public lastFrozenLookupChainId;
    bool public frozenLookupResult;
    uint256 public requestCount;

    /// @notice Sets the result returned by frozen-token participant lookups.
    function setFrozenLookupResult(bool result) external {
        frozenLookupResult = result;
    }

    /// @notice Records the token frozen on the Privacy Node layer.
    function freezeOnPrivacyNode(address tokenAddress) external {
        lastPrivacyFreezeToken = tokenAddress;
    }

    /// @notice Records the token unfrozen on the Privacy Node layer.
    function unfreezeOnPrivacyNode(address tokenAddress) external {
        lastPrivacyUnfreezeToken = tokenAddress;
    }

    /// @notice Records the frozen-token snapshot delegated from the facade.
    function syncFrozenTokens(TokenStructs.FrozenToken[] calldata frozenTokens) external {
        lastSyncCount = frozenTokens.length;
        if (frozenTokens.length != 0) {
            lastSyncResourceId = frozenTokens[0].resourceId;
        }
    }

    /// @notice Records the frozen-token update delegated from the facade.
    function updateFrozenToken(TokenStructs.FrozenToken calldata frozenToken) external {
        lastUpdatedFrozenResourceId = frozenToken.resourceId;
    }

    /// @notice Records the frozen-token removal delegated from the facade.
    function removeFrozenToken(TokenStructs.FrozenToken calldata unfrozenToken) external {
        lastRemovedFrozenResourceId = unfrozenToken.resourceId;
    }

    /// @notice Records the token frozen on the Public Chain layer.
    function freezeOnPublicChain(address tokenAddress) external {
        lastPublicFreezeToken = tokenAddress;
    }

    /// @notice Records the token unfrozen on the Public Chain layer.
    function unfreezeOnPublicChain(address tokenAddress) external {
        lastPublicUnfreezeToken = tokenAddress;
    }

    /// @notice Accepts participant validation calls routed through the facade.
    function validateTokenForParticipant(bytes32 resourceId, uint256 chainId) external pure {
        resourceId;
        chainId;
    }

    /// @notice Returns the configured frozen-token participant lookup result.
    function getFrozenTokenForParticipant(bytes32 resourceId, uint256 chainId) external view returns (bool) {
        resourceId;
        chainId;
        return frozenLookupResult;
    }

    /// @notice Records that the facade requested a frozen-token snapshot from PNH.
    function requestAllFrozenTokensDataFromPrivateHub() external {
        requestCount++;
    }
}

/// @notice Upgrade target mock used to prove the upgrader role can replace the facade implementation.
contract TokenRegistryV2Mock is PNTokenRegistryV1 {
    /// @notice Returns a different contract version so the test can verify the upgrade.
    function contractVersion() external pure override returns (uint256) {
        return 2;
    }
}

/// @notice Tests PN TokenRegistry facade access roles, module delegation, and upgrade authorization.
contract TokenRegistryV1_Facade_Access_Test is Test {
    RaylsAccessManagerV1 internal manager;
    PNTokenRegistryV1 internal registry;
    MockEndpointForPnTokenRegistry internal endpoint;
    MockTokenCoreForFacade internal tokenCore;
    MockTokenFreezeManagerForFacade internal freezeManager;

    uint64 internal pnTokenRegistryAdminRoleId;
    uint64 internal pnTokenRegistryUpgraderRoleId;
    uint64 internal tokenCreatorRoleId;
    uint64 internal messageExecutorRoleId;

    address internal defaultAdmin;
    address internal upgrader;
    address internal tokenCreator;
    address internal messageExecutor;
    address internal attacker;

    /// @notice Deploys the facade, mocks, roles, and selector permissions used by the access-control tests.
    function setUp() public {
        defaultAdmin = makeAddr("defaultAdmin");
        upgrader = makeAddr("upgrader");
        tokenCreator = makeAddr("tokenCreator");
        messageExecutor = makeAddr("messageExecutor");
        attacker = makeAddr("attacker");

        RaylsAccessManagerV1 managerImpl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(
            address(
                new ERC1967Proxy(address(managerImpl), abi.encodeCall(RaylsAccessManagerV1.initialize, (address(this))))
            )
        );

        endpoint = new MockEndpointForPnTokenRegistry();
        tokenCore = new MockTokenCoreForFacade();
        freezeManager = new MockTokenFreezeManagerForFacade();

        PNTokenRegistryV1 registryImpl = new PNTokenRegistryV1();
        registry = PNTokenRegistryV1(
            address(
                new ERC1967Proxy(
                    address(registryImpl),
                    abi.encodeCall(PNTokenRegistryV1.initialize, (address(endpoint), address(manager)))
                )
            )
        );

        pnTokenRegistryAdminRoleId = manager.registerRole("PN_TOKEN_REGISTRY_ADMIN");
        pnTokenRegistryUpgraderRoleId = manager.registerRole("PN_TOKEN_REGISTRY_UPGRADER");
        tokenCreatorRoleId = manager.registerRole("TOKEN_CREATOR");
        messageExecutorRoleId = manager.registerRole("MESSAGE_EXECUTOR");

        manager.grantRole(pnTokenRegistryAdminRoleId, defaultAdmin, 0);
        manager.grantRole(pnTokenRegistryUpgraderRoleId, upgrader, 0);
        manager.grantRole(tokenCreatorRoleId, tokenCreator, 0);
        manager.grantRole(messageExecutorRoleId, messageExecutor, 0);

        _mapSelectors(_defaultAdminSelectors(), _singleRole(pnTokenRegistryAdminRoleId));
        _mapSelectors(_tokenCreatorSelectors(), _singleRole(tokenCreatorRoleId));
        _mapSelectors(_messageExecutorSelectors(), _singleRole(messageExecutorRoleId));
        _mapSelectors(_upgraderSelectors(), _singleRole(pnTokenRegistryUpgraderRoleId));

        vm.prank(defaultAdmin);
        registry.setTokenCore(address(tokenCore));
        vm.prank(defaultAdmin);
        registry.setTokenFreezeManager(address(freezeManager));
    }

    /// @notice Verifies facade initialization stores endpoint, resource ID, version, and configured modules.
    function test_initialize_sets_resource_id_endpoint_and_version() public view {
        assertEq(address(registry.endpoint()), address(endpoint));
        assertEq(registry.resourceId(), Constants.RESOURCE_ID_TOKEN_REGISTRY);
        assertEq(registry.contractVersion(), 1);
        assertEq(address(registry.getTokenCore()), address(tokenCore));
        assertEq(address(registry.getTokenFreezeManager()), address(freezeManager));
    }

    /// @notice Verifies module setters are restricted to the PN TokenRegistry admin role.
    function test_setters_revert_for_unauthorized_callers() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        registry.setTokenCore(address(tokenCore));

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        registry.setTokenFreezeManager(address(freezeManager));
    }

    /// @notice Verifies module setters reject zero-address module dependencies.
    function test_setters_revert_for_zero_addresses() public {
        vm.prank(defaultAdmin);
        vm.expectRevert(ITokenRegistry.TokenRegistryV1__InvalidTokenCoreAddress.selector);
        registry.setTokenCore(address(0));

        vm.prank(defaultAdmin);
        vm.expectRevert(ITokenRegistry.TokenRegistryV1__InvalidTokenFreezeManagerAddress.selector);
        registry.setTokenFreezeManager(address(0));
    }

    /// @notice Verifies module setters emit module-specific events plus the current configuration snapshot.
    function test_setters_emit_module_specific_events() public {
        MockTokenCoreForFacade newTokenCore = new MockTokenCoreForFacade();
        MockTokenFreezeManagerForFacade newFreezeManager = new MockTokenFreezeManagerForFacade();

        vm.prank(defaultAdmin);
        vm.expectEmit(true, false, false, true, address(registry));
        emit ITokenRegistry.TokenCoreSet(address(newTokenCore));
        vm.expectEmit(true, true, false, true, address(registry));
        emit ITokenRegistry.TokenRegistryModulesConfigured(address(newTokenCore), address(freezeManager));
        registry.setTokenCore(address(newTokenCore));

        vm.prank(defaultAdmin);
        vm.expectEmit(true, false, false, true, address(registry));
        emit ITokenRegistry.TokenFreezeManagerSet(address(newFreezeManager));
        vm.expectEmit(true, true, false, true, address(registry));
        emit ITokenRegistry.TokenRegistryModulesConfigured(address(newTokenCore), address(newFreezeManager));
        registry.setTokenFreezeManager(address(newFreezeManager));
    }

    /// @notice Verifies token registration is creator-gated and delegates to TokenCore.
    function test_registerToken_is_gated_by_token_creator_and_delegates() public {
        address token = makeAddr("token");

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        registry.registerToken(token);

        vm.prank(tokenCreator);
        registry.registerToken(token);

        assertEq(tokenCore.lastRegisteredToken(), token);
    }

    /// @notice Verifies admin lifecycle methods delegate to TokenCore while activation remains executor-gated.
    function test_default_admin_lifecycle_calls_delegate_to_token_core() public {
        address token = makeAddr("token");
        bytes32 resourceId = keccak256("resource");
        address publicToken = makeAddr("publicToken");

        vm.startPrank(defaultAdmin);
        registry.updatePrivacyNodeStatus(token, TokenStructs.PrivacyNodeStatus.AUTHORIZED);
        registry.submitToHub(token);
        registry.submitToPublicChain(token);
        registry.rejectToken(token);
        registry.updatePublicTokenAddress(token, publicToken);
        registry.deprecateOnPublicChain(token);
        vm.stopPrank();

        assertEq(tokenCore.lastPrivacyNodeStatusToken(), token);
        assertEq(uint256(tokenCore.lastPrivacyNodeStatus()), uint256(TokenStructs.PrivacyNodeStatus.AUTHORIZED));
        assertEq(tokenCore.lastSubmitToHubToken(), token);
        assertEq(tokenCore.lastSubmitToPublicChainToken(), token);
        assertEq(tokenCore.lastRejectedToken(), token);
        assertEq(tokenCore.lastPublicTokenAddressToken(), token);
        assertEq(tokenCore.lastPublicTokenAddress(), publicToken);
        assertEq(tokenCore.lastDeprecatedOnPublicChainToken(), token);

        // activateToken is executor-gated, not admin-gated
        vm.prank(defaultAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, defaultAdmin)
        );
        registry.activateToken(resourceId, token, 1);
    }

    /// @notice Verifies message-executor methods delegate to TokenCore and TokenFreezeManager.
    function test_message_executor_calls_delegate_to_freeze_manager_and_activate() public {
        MockRegistrableTokenForFacade token = new MockRegistrableTokenForFacade();
        bytes32 resourceId = keccak256("frozen");
        uint256[] memory participants = new uint256[](1);
        participants[0] = 100;
        TokenStructs.FrozenToken[] memory snapshot = new TokenStructs.FrozenToken[](1);
        snapshot[0] = TokenStructs.FrozenToken({resourceId: resourceId, frozenParticipants: participants});
        freezeManager.setFrozenLookupResult(true);

        vm.startPrank(messageExecutor);
        registry.activateToken(resourceId, address(token), 7);
        registry.freezeOnPrivacyNode(address(token));
        registry.unfreezeOnPrivacyNode(address(token));
        registry.syncFrozenTokens(snapshot);
        registry.updateFrozenToken(snapshot[0]);
        registry.removeFrozenToken(snapshot[0]);
        registry.freezeOnPublicChain(address(token));
        registry.unfreezeOnPublicChain(address(token));
        registry.validateTokenForParticipant(resourceId, 100);
        assertTrue(registry.getFrozenTokenForParticipant(resourceId, 100));
        registry.requestAllFrozenTokensDataFromPrivateHub();
        vm.stopPrank();

        assertEq(tokenCore.lastActivatedResourceId(), resourceId);
        assertEq(tokenCore.lastActivatedToken(), address(token));
        assertEq(tokenCore.lastActivatedStandard(), 7);
        assertEq(freezeManager.lastPrivacyFreezeToken(), address(token));
        assertEq(freezeManager.lastPrivacyUnfreezeToken(), address(token));
        assertEq(freezeManager.lastSyncCount(), 1);
        assertEq(freezeManager.lastSyncResourceId(), resourceId);
        assertEq(freezeManager.lastUpdatedFrozenResourceId(), resourceId);
        assertEq(freezeManager.lastRemovedFrozenResourceId(), resourceId);
        assertEq(freezeManager.lastPublicFreezeToken(), address(token));
        assertEq(freezeManager.lastPublicUnfreezeToken(), address(token));
        assertEq(freezeManager.requestCount(), 1);
    }

    /// @notice Verifies activation delegates to TokenCore and assigns the token resource ID through the facade.
    function test_activateToken_delegates_and_sets_resource_id_on_token() public {
        MockRegistrableTokenForFacade token = new MockRegistrableTokenForFacade();
        bytes32 resourceId = keccak256("facade-resource-id");

        vm.prank(messageExecutor);
        registry.activateToken(resourceId, address(token), uint8(SharedObjects.ErcStandard.ERC20));

        assertEq(token.resourceId(), resourceId);
        assertEq(tokenCore.lastActivatedResourceId(), resourceId);
        assertEq(tokenCore.lastActivatedToken(), address(token));
    }

    /// @notice Verifies read-only facade methods delegate to the configured modules.
    function test_view_functions_delegate_to_modules() public {
        TokenStructs.Token memory token = TokenStructs.Token({
            resourceId: keccak256("sample"),
            name: "Sample",
            symbol: "SMP",
            uri: "ipfs://sample",
            tokenAddress: address(0x1234),
            publicTokenAddress: address(0x5678),
            issuerChainId: 100,
            ercStandard: SharedObjects.ErcStandard.ERC20,
            privacyNodeStatus: TokenStructs.PrivacyNodeStatus.AUTHORIZED,
            hubStatus: TokenStructs.HubStatus.AUTHORIZED,
            publicChainStatus: TokenStructs.PublicChainStatus.DEPLOYED,
            createdAt: 1,
            updatedAt: 2
        });
        tokenCore.setSampleToken(token);
        tokenCore.setQueryFlags(true, false, true, true);
        freezeManager.setFrozenLookupResult(true);

        assertTrue(registry.isTokenFullyOperational(address(this)));
        assertFalse(registry.isTokenActiveForHub(address(this)));
        assertTrue(registry.isTokenActiveForPublicChain(address(this)));
        assertEq(registry.getAllTokens().length, 1);
        assertEq(registry.getTokenByAddress(address(this)).resourceId, token.resourceId);
        assertEq(registry.getTokenByResourceId(token.resourceId).symbol, token.symbol);
        assertEq(registry.getTokenBySymbol("SMP").tokenAddress, token.tokenAddress);
        assertEq(
            uint256(registry.getPrivacyNodeStatus(address(this))), uint256(TokenStructs.PrivacyNodeStatus.AUTHORIZED)
        );
        assertEq(uint256(registry.getHubStatus(address(this))), uint256(TokenStructs.HubStatus.AUTHORIZED));
        assertEq(
            uint256(registry.getPublicChainStatus(address(this))), uint256(TokenStructs.PublicChainStatus.DEPLOYED)
        );
        assertEq(registry.getTokensByPrivacyNodeStatus(TokenStructs.PrivacyNodeStatus.AUTHORIZED).length, 1);
        assertEq(registry.getTokensByHubStatus(TokenStructs.HubStatus.AUTHORIZED).length, 1);
        assertEq(registry.getTokenCount(), 3);
        assertEq(registry.getActiveTokenCount(), 2);
        assertTrue(registry.tokenExists(address(this)));
    }

    /// @notice Verifies the facade's status-query ABI remains compatible with RaylsApp's uint8 registry view.
    function test_view_status_functions_match_rayls_app_token_registry_abi() public {
        TokenStructs.Token memory token = TokenStructs.Token({
            resourceId: keccak256("sample"),
            name: "Sample",
            symbol: "SMP",
            uri: "ipfs://sample",
            tokenAddress: address(0x1234),
            publicTokenAddress: address(0x5678),
            issuerChainId: 100,
            ercStandard: SharedObjects.ErcStandard.ERC20,
            privacyNodeStatus: TokenStructs.PrivacyNodeStatus.AUTHORIZED,
            hubStatus: TokenStructs.HubStatus.AUTHORIZED,
            publicChainStatus: TokenStructs.PublicChainStatus.DEPLOYED,
            createdAt: 1,
            updatedAt: 2
        });
        tokenCore.setSampleToken(token);
        tokenCore.setQueryFlags(true, true, true, true);

        IRaylsAppV1TokenRegistry appRegistry = IRaylsAppV1TokenRegistry(address(registry));

        assertTrue(appRegistry.isTokenActiveForHub(address(this)));
        assertTrue(appRegistry.isTokenActiveForPublicChain(address(this)));
        assertEq(appRegistry.getPrivacyNodeStatus(address(this)), uint8(TokenStructs.PrivacyNodeStatus.AUTHORIZED));
        assertEq(appRegistry.getHubStatus(address(this)), uint8(TokenStructs.HubStatus.AUTHORIZED));
        assertEq(appRegistry.getPublicChainStatus(address(this)), uint8(TokenStructs.PublicChainStatus.DEPLOYED));
    }

    /// @notice Freeze-status lookups are ungated read-only views: any caller may read them
    function test_freeze_lookup_views_are_open_to_any_caller() public {
        bytes32 resourceId = keccak256("freeze-check");

        // An unprivileged caller can read freeze status without reverting.
        vm.startPrank(attacker);
        registry.validateTokenForParticipant(resourceId, 100);
        registry.getFrozenTokenForParticipant(resourceId, 100);
        vm.stopPrank();
    }

    /// @notice Verifies facade module guards revert with explicit custom errors before delegation.
    function test_unconfigured_module_guards_revert_with_custom_errors() public {
        PNTokenRegistryV1 freshRegistry = PNTokenRegistryV1(
            address(
                new ERC1967Proxy(
                    address(new PNTokenRegistryV1()),
                    abi.encodeCall(PNTokenRegistryV1.initialize, (address(endpoint), address(manager)))
                )
            )
        );

        _mapSelectorsForTarget(address(freshRegistry), _tokenCreatorSelectors(), _singleRole(tokenCreatorRoleId));
        _mapSelectorsForTarget(address(freshRegistry), _messageExecutorSelectors(), _singleRole(messageExecutorRoleId));

        vm.prank(tokenCreator);
        vm.expectRevert(ITokenRegistry.TokenRegistryV1__TokenCoreNotConfigured.selector);
        freshRegistry.registerToken(makeAddr("token"));

        vm.prank(messageExecutor);
        vm.expectRevert(ITokenRegistry.TokenRegistryV1__TokenFreezeManagerNotConfigured.selector);
        freshRegistry.freezeOnPrivacyNode(makeAddr("token"));
    }

    /// @notice Verifies only the upgrader role can upgrade the PN TokenRegistry facade implementation.
    function test_only_upgrader_role_can_upgrade() public {
        TokenRegistryV2Mock newImplementation = new TokenRegistryV2Mock();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        registry.upgradeToAndCall(address(newImplementation), bytes(""));

        vm.prank(upgrader);
        registry.upgradeToAndCall(address(newImplementation), bytes(""));

        assertEq(TokenRegistryV2Mock(address(registry)).contractVersion(), 2);
    }

    /// @notice Builds a one-item role array for AccessManager selector configuration.
    function _singleRole(uint64 roleId) internal pure returns (uint64[] memory roles) {
        roles = new uint64[](1);
        roles[0] = roleId;
    }

    /// @notice Maps selectors to roles for the main PN TokenRegistry facade under test.
    function _mapSelectors(bytes4[] memory selectors, uint64[] memory roles) internal {
        _mapSelectorsForTarget(address(registry), selectors, roles);
    }

    /// @notice Maps selectors to roles for a specific target contract.
    function _mapSelectorsForTarget(address target, bytes4[] memory selectors, uint64[] memory roles) internal {
        manager.addFunctionAllowedRoles(target, selectors, roles);
    }

    /// @notice Returns selectors that require the PN TokenRegistry admin role.
    function _defaultAdminSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](8);
        selectors[0] = ITokenRegistry.setTokenCore.selector;
        selectors[1] = ITokenRegistry.setTokenFreezeManager.selector;
        selectors[2] = ITokenRegistry.updatePrivacyNodeStatus.selector;
        selectors[3] = ITokenRegistry.submitToHub.selector;
        selectors[4] = ITokenRegistry.submitToPublicChain.selector;
        selectors[5] = ITokenRegistry.rejectToken.selector;
        selectors[6] = ITokenRegistry.updatePublicTokenAddress.selector;
        selectors[7] = ITokenRegistry.deprecateOnPublicChain.selector;
    }

    /// @notice Returns selectors that require the token creator role.
    function _tokenCreatorSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = ITokenRegistry.registerToken.selector;
    }

    /// @notice Returns selectors that require the message executor role.
    function _messageExecutorSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](11);
        selectors[0] = ITokenRegistry.activateToken.selector;
        selectors[1] = ITokenRegistry.freezeOnPrivacyNode.selector;
        selectors[2] = ITokenRegistry.unfreezeOnPrivacyNode.selector;
        selectors[3] = ITokenRegistry.syncFrozenTokens.selector;
        selectors[4] = ITokenRegistry.updateFrozenToken.selector;
        selectors[5] = ITokenRegistry.removeFrozenToken.selector;
        selectors[6] = ITokenRegistry.freezeOnPublicChain.selector;
        selectors[7] = ITokenRegistry.unfreezeOnPublicChain.selector;
        selectors[8] = ITokenRegistry.validateTokenForParticipant.selector;
        selectors[9] = ITokenRegistry.getFrozenTokenForParticipant.selector;
        selectors[10] = ITokenRegistry.requestAllFrozenTokensDataFromPrivateHub.selector;
    }

    /// @notice Returns selectors that require the PN TokenRegistry upgrader role.
    function _upgraderSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("upgradeToAndCall(address,bytes)"));
    }
}
