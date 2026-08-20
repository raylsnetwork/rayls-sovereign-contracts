// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {ITokenFreezeManager} from "../../../rayls-protocol/TokenRegistry/interfaces/ITokenFreezeManager.sol";
import {PNTokenCoreV1} from "../../../rayls-protocol/TokenRegistry/modules/TokenCore/PNTokenCoreV1.sol";
import {
    PNTokenFreezeManagerV1
} from "../../../rayls-protocol/TokenRegistry/modules/TokenFreezeManager/PNTokenFreezeManagerV1.sol";
import {TokenStructs} from "../../../rayls-protocol/TokenRegistry/libraries/TokenStructs.sol";
import {SharedObjects} from "../../../rayls-protocol-sdk/libraries/SharedObjects.sol";
import {Constants} from "../../../rayls-protocol-sdk/Constants.sol";
import {IRegistrableToken} from "../../../rayls-protocol-sdk/interfaces/IRegistrableToken.sol";

/// @notice Endpoint mock used by dry-run tests to capture outbound messages and resource registrations.
contract MockDryRunEndpoint {
    uint256 public lastSendDstChainId;
    address public lastSendDestination;
    bytes public lastSendPayload;

    uint256 public lastSendToResourceDstChainId;
    bytes32 public lastSendToResourceId;
    bytes public lastSendToResourcePayload;

    mapping(string => address) public privateHubAddresses;
    mapping(bytes32 => address) public resourceIdToAddress;

    uint256 internal chainId;
    uint256 internal privateHubId;
    address internal authorityAddress;

    /// @notice Sets the local chain ID returned by the endpoint mock.
    function setChainId(uint256 newChainId) external {
        chainId = newChainId;
    }

    /// @notice Sets the private hub chain ID returned by the endpoint mock.
    function setPrivateHubId(uint256 newPrivateHubId) external {
        privateHubId = newPrivateHubId;
    }

    /// @notice Sets the authority address returned by the endpoint mock.
    function setAuthority(address newAuthority) external {
        authorityAddress = newAuthority;
    }

    /// @notice Returns the configured local chain ID.
    function getChainId() external view returns (uint256) {
        return chainId;
    }

    /// @notice Returns the configured private hub chain ID.
    function getPrivateHubId() external view returns (uint256) {
        return privateHubId;
    }

    /// @notice Returns the configured authority address.
    function authority() external view returns (address) {
        return authorityAddress;
    }

    /// @notice Returns the configured private hub contract address for a name.
    function getPrivateHubAddress(string calldata name) external view returns (address) {
        return privateHubAddresses[name];
    }

    /// @notice Configures a private hub contract address for a name.
    function setPrivateHubAddress(string calldata name, address addr) external {
        privateHubAddresses[name] = addr;
    }

    /// @notice Returns the address registered for a resource ID.
    function getAddressByResourceId(bytes32 resourceId) external view returns (address) {
        return resourceIdToAddress[resourceId];
    }

    /// @notice Registers an address for a resource ID.
    function registerResourceId(bytes32 resourceId, address implementationAddress) external {
        resourceIdToAddress[resourceId] = implementationAddress;
    }

    /// @notice Captures a direct endpoint send.
    function send(uint256 dstChainId, address destination, bytes calldata payload) external payable returns (bytes32) {
        lastSendDstChainId = dstChainId;
        lastSendDestination = destination;
        lastSendPayload = payload;
        return bytes32(0);
    }

    /// @notice Captures a resource-ID endpoint send.
    function sendToResourceId(uint256 dstChainId, bytes32 resourceId, bytes calldata payload)
        external
        payable
        returns (bytes32)
    {
        lastSendToResourceDstChainId = dstChainId;
        lastSendToResourceId = resourceId;
        lastSendToResourcePayload = payload;
        return bytes32(0);
    }
}

/// @notice ERC20-compatible token mock used as the primary dry-run token.
contract MockDryRunERC20 is IRegistrableToken {
    bytes32 public resourceId;

    /// @notice Returns the mock token name.
    function name() external pure returns (string memory) {
        return "DryRunToken";
    }

    /// @notice Returns the mock token symbol.
    function symbol() external pure returns (string memory) {
        return "DRY";
    }

    /// @notice Returns the mock token decimals.
    function decimals() external pure returns (uint8) {
        return 18;
    }

    /// @notice Returns the mock token total supply.
    function totalSupply() external pure returns (uint256) {
        return 1_000_000e18;
    }

    /// @notice Returns the Rayls ERC standard used by this token.
    function GetERCStandard() external pure returns (uint8) {
        return uint8(SharedObjects.ErcStandard.ERC20);
    }

    /// @notice Records the resource ID assigned to the token.
    function setResourceId(bytes32 newResourceId) external {
        resourceId = newResourceId;
    }
}

/// @notice Second ERC20 mock used to prove TokenCore separates records and statuses across tokens.
contract MockDryRunERC20Second is IRegistrableToken {
    bytes32 public resourceId;

    /// @notice Returns the second mock token name.
    function name() external pure returns (string memory) {
        return "DryRunTokenB";
    }

    /// @notice Returns the second mock token symbol.
    function symbol() external pure returns (string memory) {
        return "DRYB";
    }

    /// @notice Returns the second mock token decimals.
    function decimals() external pure returns (uint8) {
        return 6;
    }

    /// @notice Returns the second mock token total supply.
    function totalSupply() external pure returns (uint256) {
        return 50_000_000;
    }

    /// @notice Returns the Rayls ERC standard used by this token.
    function GetERCStandard() external pure returns (uint8) {
        return uint8(SharedObjects.ErcStandard.ERC20);
    }

    /// @notice Records the resource ID assigned to the token.
    function setResourceId(bytes32 newResourceId) external {
        resourceId = newResourceId;
    }
}

/// @notice Enygma-compatible token mock used to verify TokenCore creation hooks.
contract MockDryRunEnygma is IRegistrableToken {
    bytes32 public resourceId;

    /// @notice Returns the mock Enygma token name.
    function name() external pure returns (string memory) {
        return "DryRunEnygma";
    }

    /// @notice Returns the mock Enygma token symbol.
    function symbol() external pure returns (string memory) {
        return "DENY";
    }

    /// @notice Returns the mock Enygma token decimals.
    function decimals() external pure returns (uint8) {
        return 18;
    }

    /// @notice Returns the mock Enygma token total supply.
    function totalSupply() external pure returns (uint256) {
        return 777e18;
    }

    /// @notice Returns the Rayls ERC standard used by this token.
    function GetERCStandard() external pure returns (uint8) {
        return uint8(SharedObjects.ErcStandard.Enygma);
    }

    /// @notice Records the resource ID assigned to the token.
    function setResourceId(bytes32 newResourceId) external {
        resourceId = newResourceId;
    }
}

/// @notice Enygma PN events mock used to prove creation callbacks are emitted.
contract MockDryRunEnygmaPNEvents {
    uint256 public creationCalls;
    bytes32 public lastResourceId;
    uint256 public lastInitialSupply;

    /// @notice Captures Enygma creation callback arguments.
    function creation(bytes32 resourceId, uint256 initialSupply) external {
        creationCalls++;
        lastResourceId = resourceId;
        lastInitialSupply = initialSupply;
    }

    /// @notice Stub for unused DVP721 creation callback.
    function dvp721Creation(bytes32) external {}

    /// @notice Stub for unused DVP1155 creation callback.
    function dvp1155Creation(bytes32) external {}
}

/// @notice Dry-run smoke tests for TokenCore and TokenFreezeManager module behavior.
contract TokenRegistryModules_DryRun_Test is Test {
    uint256 internal constant LOCAL_CHAIN_ID = 100;
    uint256 internal constant PRIVATE_HUB_ID = 999;
    uint256 internal constant REMOTE_CHAIN_A = 200;
    uint256 internal constant REMOTE_CHAIN_B = 300;

    address internal constant PNH_TOKEN_REGISTRY = address(0xBEEF);

    RaylsAccessManagerV1 internal manager;
    PNTokenCoreV1 internal tokenCore;
    PNTokenFreezeManagerV1 internal freezeManager;
    MockDryRunEndpoint internal endpoint;
    MockDryRunERC20 internal token;

    /// @notice Deploys TokenCore, TokenFreezeManager, and endpoint/token mocks with facade-style wiring.
    function setUp() public {
        // Deploy one access manager and fresh proxy instances for both PN modules.
        RaylsAccessManagerV1 managerImpl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(
            address(
                new ERC1967Proxy(address(managerImpl), abi.encodeCall(RaylsAccessManagerV1.initialize, (address(this))))
            )
        );

        PNTokenCoreV1 tokenCoreImpl = new PNTokenCoreV1();
        tokenCore = PNTokenCoreV1(
            address(
                new ERC1967Proxy(address(tokenCoreImpl), abi.encodeCall(PNTokenCoreV1.initialize, (address(manager))))
            )
        );

        PNTokenFreezeManagerV1 freezeManagerImpl = new PNTokenFreezeManagerV1();
        freezeManager = PNTokenFreezeManagerV1(
            address(
                new ERC1967Proxy(
                    address(freezeManagerImpl), abi.encodeCall(PNTokenFreezeManagerV1.initialize, (address(manager)))
                )
            )
        );

        endpoint = new MockDryRunEndpoint();
        endpoint.setChainId(LOCAL_CHAIN_ID);
        endpoint.setPrivateHubId(PRIVATE_HUB_ID);
        endpoint.setPrivateHubAddress("TokenRegistry", PNH_TOKEN_REGISTRY);

        token = new MockDryRunERC20();

        // Wire both modules the same way the PN TokenRegistry facade is expected to wire them.
        tokenCore.setTokenRegistry(address(this));
        tokenCore.setTokenFreezeManager(address(freezeManager));
        tokenCore.setEndpoint(address(endpoint));

        freezeManager.setTokenRegistry(address(this));
        freezeManager.setTokenCore(address(tokenCore));
        freezeManager.setEndpoint(address(endpoint));
    }

    /// @notice Dry-runs the main TokenCore lifecycle from registration through public-chain removal.
    /// @dev Covers registerToken, status queries, Hub submission, activation, Public Chain deployment, and removal.
    function test_dryRun_tokenCore_basic_lifecycle() public {
        // In production this value is assigned by PNH during registration/approval and then
        // sent back to PN in the activation callback. This dry run bypasses that legacy
        // TokenRegistryReplicaV1-based roundtrip, so we provide a deterministic stand-in.
        bytes32 resourceId = keccak256("dry-run-resource");

        // 1. Register the token locally and inspect the initial PN-side record.
        tokenCore.registerToken(address(token));
        assertTrue(tokenCore.tokenExists(address(token)));
        assertEq(tokenCore.getAllTokens().length, 1);

        TokenStructs.Token memory registered = tokenCore.getTokenByAddress(address(token));
        assertEq(registered.symbol, "DRY");
        assertEq(registered.tokenAddress, address(token));
        assertEq(uint256(registered.privacyNodeStatus), uint256(TokenStructs.PrivacyNodeStatus.WAITING_APPROVAL));
        assertEq(tokenCore.getTokenCount(), 1);

        // 2. Authorize the token locally so hub and public-chain flows are allowed to start.
        tokenCore.updatePrivacyNodeStatus(address(token), TokenStructs.PrivacyNodeStatus.AUTHORIZED);
        assertEq(
            uint256(tokenCore.getPrivacyNodeStatus(address(token))), uint256(TokenStructs.PrivacyNodeStatus.AUTHORIZED)
        );
        assertEq(tokenCore.getActiveTokenCount(), 1);

        // 3. Submit the token to PNH and confirm the outbound endpoint call plus waiting hub state.
        tokenCore.submitToHub(address(token));
        assertEq(endpoint.lastSendDstChainId(), PRIVATE_HUB_ID);
        assertEq(endpoint.lastSendDestination(), PNH_TOKEN_REGISTRY);
        assertEq(uint256(tokenCore.getHubStatus(address(token))), uint256(TokenStructs.HubStatus.WAITING_APPROVAL));

        // 4. Simulate the PNH approval callback and confirm TokenCore records the resourceId on PN.
        // The PN TokenRegistry facade owns the token.setResourceId() call in the full flow.
        tokenCore.activateToken(resourceId, address(token), uint8(SharedObjects.ErcStandard.ERC20));

        TokenStructs.Token memory activated = tokenCore.getTokenByResourceId(resourceId);
        assertEq(activated.tokenAddress, address(token));
        assertEq(tokenCore.getTokenBySymbol("DRY").tokenAddress, address(token));
        assertEq(endpoint.resourceIdToAddress(resourceId), address(token));
        assertEq(uint256(tokenCore.getHubStatus(address(token))), uint256(TokenStructs.HubStatus.AUTHORIZED));
        assertTrue(tokenCore.isTokenActiveForHub(address(token)));

        // 5. Start the public-chain flow and verify the token is only fully operational once deployed.
        tokenCore.submitToPublicChain(address(token));
        assertEq(
            uint256(tokenCore.getPublicChainStatus(address(token))),
            uint256(TokenStructs.PublicChainStatus.PENDING_DEPLOYMENT)
        );
        assertFalse(tokenCore.isTokenActiveForPublicChain(address(token)));
        assertFalse(tokenCore.isTokenFullyOperational(address(token)));

        tokenCore.updatePublicTokenAddress(address(token), address(0xCAFE));
        assertEq(tokenCore.getTokenByAddress(address(token)).publicTokenAddress, address(0xCAFE));
        assertEq(
            uint256(tokenCore.getPublicChainStatus(address(token))), uint256(TokenStructs.PublicChainStatus.DEPLOYED)
        );
        assertTrue(tokenCore.isTokenActiveForPublicChain(address(token)));
        assertTrue(tokenCore.isTokenFullyOperational(address(token)));

        // 6. Deprecate the public-chain side to prove the final lifecycle transition works.
        tokenCore.deprecateOnPublicChain(address(token));
        assertEq(
            uint256(tokenCore.getPublicChainStatus(address(token))), uint256(TokenStructs.PublicChainStatus.DEPRECATED)
        );
    }

    /// @notice Dry-runs the direct PNH rejection callback handled by TokenCore.rejectToken().
    function test_dryRun_tokenCore_reject_path() public {
        tokenCore.registerToken(address(token));
        tokenCore.updatePrivacyNodeStatus(address(token), TokenStructs.PrivacyNodeStatus.AUTHORIZED);

        tokenCore.rejectToken(address(token));

        assertEq(uint256(tokenCore.getHubStatus(address(token))), uint256(TokenStructs.HubStatus.UNAUTHORIZED));
        assertTrue(tokenCore.isTokenActiveForPublicChain(address(token)) == false);
    }

    /// @notice Dry-runs TokenCore query helpers that require more than one token record.
    function test_dryRun_tokenCore_query_helpers() public {
        MockDryRunERC20Second tokenB = new MockDryRunERC20Second();

        tokenCore.registerToken(address(token));
        tokenCore.registerToken(address(tokenB));
        tokenCore.updatePrivacyNodeStatus(address(token), TokenStructs.PrivacyNodeStatus.AUTHORIZED);
        tokenCore.rejectToken(address(tokenB));

        TokenStructs.Token[] memory allTokens = tokenCore.getAllTokens();
        assertEq(allTokens.length, 2);
        assertEq(allTokens[0].tokenAddress, address(token));
        assertEq(allTokens[1].tokenAddress, address(tokenB));

        TokenStructs.Token[] memory authorizedPnTokens =
            tokenCore.getTokensByPrivacyNodeStatus(TokenStructs.PrivacyNodeStatus.AUTHORIZED);
        assertEq(authorizedPnTokens.length, 1);
        assertEq(authorizedPnTokens[0].tokenAddress, address(token));

        TokenStructs.Token[] memory waitingPnTokens =
            tokenCore.getTokensByPrivacyNodeStatus(TokenStructs.PrivacyNodeStatus.WAITING_APPROVAL);
        assertEq(waitingPnTokens.length, 1);
        assertEq(waitingPnTokens[0].tokenAddress, address(tokenB));

        TokenStructs.Token[] memory unauthorizedHubTokens =
            tokenCore.getTokensByHubStatus(TokenStructs.HubStatus.UNAUTHORIZED);
        assertEq(unauthorizedHubTokens.length, 1);
        assertEq(unauthorizedHubTokens[0].tokenAddress, address(tokenB));
    }

    /// @notice Dry-runs TokenCore.setTokenRegistry by swapping the allowed facade and registering from it.
    function test_dryRun_tokenCore_setTokenRegistry_happyPath() public {
        address newRegistry = makeAddr("newRegistry");
        MockDryRunERC20Second tokenB = new MockDryRunERC20Second();

        tokenCore.setTokenRegistry(newRegistry);

        vm.prank(newRegistry);
        tokenCore.registerToken(address(tokenB));

        assertTrue(tokenCore.tokenExists(address(tokenB)));
        assertEq(tokenCore.getTokenBySymbol("DRYB").tokenAddress, address(tokenB));
    }

    /// @notice Dry-runs TokenCore.setTokenFreezeManager and verifies the new manager can drive freeze states.
    function test_dryRun_tokenCore_setTokenFreezeManager_happyPath() public {
        bytes32 resourceId = _registerAuthorizeAndActivateToken();
        address newFreezeManager = makeAddr("newFreezeManager");

        tokenCore.setTokenFreezeManager(newFreezeManager);

        vm.startPrank(newFreezeManager);
        tokenCore.setFreezeStatus(address(token), TokenStructs.FreezeLayer.PRIVACY_NODE, true);
        assertEq(
            uint256(tokenCore.getPrivacyNodeStatus(address(token))), uint256(TokenStructs.PrivacyNodeStatus.FROZEN)
        );

        tokenCore.setFreezeStatus(address(token), TokenStructs.FreezeLayer.PRIVACY_NODE, false);
        assertEq(
            uint256(tokenCore.getPrivacyNodeStatus(address(token))), uint256(TokenStructs.PrivacyNodeStatus.AUTHORIZED)
        );

        tokenCore.setFreezeStatus(address(token), TokenStructs.FreezeLayer.HUB, true);
        assertEq(uint256(tokenCore.getHubStatus(address(token))), uint256(TokenStructs.HubStatus.FROZEN));

        tokenCore.setFreezeStatus(address(token), TokenStructs.FreezeLayer.HUB, false);
        assertEq(uint256(tokenCore.getHubStatus(address(token))), uint256(TokenStructs.HubStatus.AUTHORIZED));

        tokenCore.setFreezeStatus(address(token), TokenStructs.FreezeLayer.PUBLIC_CHAIN, true);
        assertEq(
            uint256(tokenCore.getPublicChainStatus(address(token))), uint256(TokenStructs.PublicChainStatus.FROZEN)
        );

        tokenCore.setFreezeStatus(address(token), TokenStructs.FreezeLayer.PUBLIC_CHAIN, false);
        assertEq(
            uint256(tokenCore.getPublicChainStatus(address(token))), uint256(TokenStructs.PublicChainStatus.UNDEFINED)
        );
        vm.stopPrank();

        assertEq(tokenCore.getTokenByResourceId(resourceId).tokenAddress, address(token));
    }

    /// @notice Dry-runs TokenCore.setEndpoint and verifies registrations and Hub submissions use the new endpoint.
    function test_dryRun_tokenCore_setEndpoint_happyPath() public {
        MockDryRunEndpoint newEndpoint = new MockDryRunEndpoint();
        MockDryRunERC20Second tokenB = new MockDryRunERC20Second();

        newEndpoint.setChainId(321);
        newEndpoint.setPrivateHubId(654);
        newEndpoint.setPrivateHubAddress("TokenRegistry", address(0x1234));

        tokenCore.setEndpoint(address(newEndpoint));
        tokenCore.registerToken(address(tokenB));

        TokenStructs.Token memory registered = tokenCore.getTokenByAddress(address(tokenB));
        assertEq(registered.issuerChainId, 321);

        tokenCore.updatePrivacyNodeStatus(address(tokenB), TokenStructs.PrivacyNodeStatus.AUTHORIZED);
        tokenCore.submitToHub(address(tokenB));

        assertEq(newEndpoint.lastSendDstChainId(), 654);
        assertEq(newEndpoint.lastSendDestination(), address(0x1234));
    }

    /// @notice Dry-runs TokenCore.setEnygmaPNEvents and verifies Enygma activation emits the creation hook.
    function test_dryRun_tokenCore_setEnygmaPnEvents_happyPath() public {
        MockDryRunEnygma enygmaToken = new MockDryRunEnygma();
        MockDryRunEnygmaPNEvents newEvents = new MockDryRunEnygmaPNEvents();
        bytes32 resourceId = keccak256("enygma-dry-run-resource");

        tokenCore.setEnygmaPNEvents(address(newEvents));
        tokenCore.registerToken(address(enygmaToken));
        tokenCore.updatePrivacyNodeStatus(address(enygmaToken), TokenStructs.PrivacyNodeStatus.AUTHORIZED);
        tokenCore.submitToHub(address(enygmaToken));
        tokenCore.activateToken(resourceId, address(enygmaToken), uint8(SharedObjects.ErcStandard.Enygma));

        assertEq(newEvents.creationCalls(), 1);
        assertEq(newEvents.lastResourceId(), resourceId);
        assertEq(newEvents.lastInitialSupply(), enygmaToken.totalSupply());
    }

    /// @notice Dry-runs TokenCore.setRelayAuthorizationRegistry as a configuration-only no-revert check.
    function test_dryRun_tokenCore_setRelayAuthorizationRegistry_happyPath() public {
        tokenCore.setRelayAuthorizationRegistry(address(0x7777));
    }

    /// @notice Dry-runs TokenFreezeManager configuration setters and verifies new dependencies are honored.
    /// @dev Covers setTokenRegistry, setEndpoint, setTokenCore, setRelayAuthorizationRegistry, requests, and PN freeze.
    function test_dryRun_tokenFreezeManager_configuration_happyPaths() public {
        address newRegistry = makeAddr("freezeRegistry");
        MockDryRunEndpoint newEndpoint = new MockDryRunEndpoint();
        newEndpoint.setChainId(LOCAL_CHAIN_ID);
        newEndpoint.setPrivateHubId(555);

        freezeManager.setTokenRegistry(newRegistry);
        assertEq(freezeManager.tokenRegistryAddress(), newRegistry);

        vm.prank(newRegistry);
        freezeManager.requestAllFrozenTokensDataFromPrivateHub();
        assertEq(endpoint.lastSendToResourceDstChainId(), PRIVATE_HUB_ID);

        freezeManager.setEndpoint(address(newEndpoint));
        assertEq(address(freezeManager.endpoint()), address(newEndpoint));

        vm.prank(newRegistry);
        freezeManager.requestAllFrozenTokensDataFromPrivateHub();
        assertEq(newEndpoint.lastSendToResourceDstChainId(), 555);

        PNTokenCoreV1 secondCore = _deployTokenCore();
        secondCore.setTokenRegistry(address(this));
        secondCore.setTokenFreezeManager(address(freezeManager));
        secondCore.setEndpoint(address(endpoint));

        freezeManager.setTokenCore(address(secondCore));

        MockDryRunERC20 secondToken = new MockDryRunERC20();
        secondCore.registerToken(address(secondToken));
        secondCore.updatePrivacyNodeStatus(address(secondToken), TokenStructs.PrivacyNodeStatus.AUTHORIZED);
        secondCore.submitToHub(address(secondToken));
        secondCore.activateToken(
            keccak256("second-freeze-manager-resource"),
            address(secondToken),
            uint8(SharedObjects.ErcStandard.ERC20)
        );

        vm.prank(newRegistry);
        freezeManager.freezeOnPrivacyNode(address(secondToken));
        assertEq(
            uint256(secondCore.getPrivacyNodeStatus(address(secondToken))),
            uint256(TokenStructs.PrivacyNodeStatus.FROZEN)
        );

        freezeManager.setRelayAuthorizationRegistry(address(0x4444));
        assertEq(freezeManager.relayAuthorizationRegistry(), address(0x4444));
    }

    /// @notice Dry-runs the main TokenFreezeManager freeze and unfreeze behavior across all layers.
    /// @dev Covers PN freeze, Hub participant freeze/sync/removal, validation, and Public Chain freeze.
    function test_dryRun_freezeManager_all_layers() public {
        bytes32 resourceId = _registerAuthorizeAndActivateToken();

        // Baseline: after activation the token is locally authorized and hub-authorized.
        assertEq(
            uint256(tokenCore.getPrivacyNodeStatus(address(token))), uint256(TokenStructs.PrivacyNodeStatus.AUTHORIZED)
        );
        assertEq(uint256(tokenCore.getHubStatus(address(token))), uint256(TokenStructs.HubStatus.AUTHORIZED));

        // 1. PN-wide freeze blocks every participant until the PN layer is unfrozen.
        // This changes only the PN layer. Hub status stays AUTHORIZED here.
        freezeManager.freezeOnPrivacyNode(address(token));
        assertEq(
            uint256(tokenCore.getPrivacyNodeStatus(address(token))), uint256(TokenStructs.PrivacyNodeStatus.FROZEN)
        );
        assertEq(uint256(tokenCore.getHubStatus(address(token))), uint256(TokenStructs.HubStatus.AUTHORIZED));
        vm.expectRevert(
            abi.encodeWithSelector(
                ITokenFreezeManager.TokenFreezeManagerV1__TokenFrozenOnPrivacyNode.selector, resourceId
            )
        );
        freezeManager.validateTokenForParticipant(resourceId, REMOTE_CHAIN_A);

        freezeManager.unfreezeOnPrivacyNode(address(token));
        assertEq(
            uint256(tokenCore.getPrivacyNodeStatus(address(token))), uint256(TokenStructs.PrivacyNodeStatus.AUTHORIZED)
        );
        assertEq(uint256(tokenCore.getHubStatus(address(token))), uint256(TokenStructs.HubStatus.AUTHORIZED));

        // 2. Hub participant freeze is participant-specific and mirrored into the local hub layer.
        // Including LOCAL_CHAIN_ID means the PN's hub layer becomes FROZEN even though the PN layer stays AUTHORIZED.
        freezeManager.updateFrozenToken(_frozenToken(resourceId, _twoParticipants(LOCAL_CHAIN_ID, REMOTE_CHAIN_A)));
        assertEq(
            uint256(tokenCore.getPrivacyNodeStatus(address(token))), uint256(TokenStructs.PrivacyNodeStatus.AUTHORIZED)
        );
        assertEq(uint256(tokenCore.getHubStatus(address(token))), uint256(TokenStructs.HubStatus.FROZEN));
        assertTrue(freezeManager.getFrozenTokenForParticipant(resourceId, LOCAL_CHAIN_ID));
        assertTrue(freezeManager.getFrozenTokenForParticipant(resourceId, REMOTE_CHAIN_A));

        // 3. Partial hub unfreeze should remove only the selected participant.
        // Hub status stays FROZEN because LOCAL_CHAIN_ID remains frozen in the hub snapshot.
        freezeManager.removeFrozenToken(_frozenToken(resourceId, _singleParticipant(REMOTE_CHAIN_A)));
        assertFalse(freezeManager.getFrozenTokenForParticipant(resourceId, REMOTE_CHAIN_A));
        assertEq(
            uint256(tokenCore.getPrivacyNodeStatus(address(token))), uint256(TokenStructs.PrivacyNodeStatus.AUTHORIZED)
        );
        assertEq(uint256(tokenCore.getHubStatus(address(token))), uint256(TokenStructs.HubStatus.FROZEN));

        // 4. Full snapshot sync replaces only the hub-freeze dataset and recomputes local hub mirroring.
        // The new snapshot freezes only REMOTE_CHAIN_B, so the local PN is no longer hub-frozen.
        TokenStructs.FrozenToken[] memory snapshot = new TokenStructs.FrozenToken[](1);
        snapshot[0] = _frozenToken(resourceId, _singleParticipant(REMOTE_CHAIN_B));

        freezeManager.syncFrozenTokens(snapshot);
        assertFalse(freezeManager.getFrozenTokenForParticipant(resourceId, LOCAL_CHAIN_ID));
        assertTrue(freezeManager.getFrozenTokenForParticipant(resourceId, REMOTE_CHAIN_B));
        assertEq(
            uint256(tokenCore.getPrivacyNodeStatus(address(token))), uint256(TokenStructs.PrivacyNodeStatus.AUTHORIZED)
        );
        assertEq(uint256(tokenCore.getHubStatus(address(token))), uint256(TokenStructs.HubStatus.AUTHORIZED));

        // 5. Public-chain freeze preserves and later restores the previous public-chain lifecycle state
        // without changing the PN or hub layers.
        tokenCore.submitToPublicChain(address(token));
        freezeManager.freezeOnPublicChain(address(token));
        assertEq(
            uint256(tokenCore.getPrivacyNodeStatus(address(token))), uint256(TokenStructs.PrivacyNodeStatus.AUTHORIZED)
        );
        assertEq(uint256(tokenCore.getHubStatus(address(token))), uint256(TokenStructs.HubStatus.AUTHORIZED));
        assertEq(
            uint256(tokenCore.getPublicChainStatus(address(token))), uint256(TokenStructs.PublicChainStatus.FROZEN)
        );

        freezeManager.unfreezeOnPublicChain(address(token));
        assertEq(
            uint256(tokenCore.getPrivacyNodeStatus(address(token))), uint256(TokenStructs.PrivacyNodeStatus.AUTHORIZED)
        );
        assertEq(uint256(tokenCore.getHubStatus(address(token))), uint256(TokenStructs.HubStatus.AUTHORIZED));
        assertEq(
            uint256(tokenCore.getPublicChainStatus(address(token))),
            uint256(TokenStructs.PublicChainStatus.PENDING_DEPLOYMENT)
        );
    }

    /// @notice Dry-runs the case where Hub freeze data arrives before the PN token is activated.
    /// @dev Proves activation replays deferred local Hub freeze once the resource ID exists on PN.
    function test_dryRun_freezeManager_preActivation_hubFreezeReplay() public {
        bytes32 resourceId = keccak256("pre-activation-dry-run-resource");

        tokenCore.registerToken(address(token));
        tokenCore.updatePrivacyNodeStatus(address(token), TokenStructs.PrivacyNodeStatus.AUTHORIZED);
        tokenCore.submitToHub(address(token));

        // Hub data already says the local PN is frozen, but TokenCore cannot mirror it yet
        // because this token does not have its PNH-assigned resourceId on PN.
        freezeManager.updateFrozenToken(_frozenToken(resourceId, _singleParticipant(LOCAL_CHAIN_ID)));
        assertTrue(freezeManager.getFrozenTokenForParticipant(resourceId, LOCAL_CHAIN_ID));
        assertEq(uint256(tokenCore.getHubStatus(address(token))), uint256(TokenStructs.HubStatus.WAITING_APPROVAL));

        // Once activation assigns the resourceId locally, TokenCore should immediately replay
        // the deferred hub-freeze state and enter HUB.FROZEN.
        tokenCore.activateToken(resourceId, address(token), uint8(SharedObjects.ErcStandard.ERC20));
        assertEq(uint256(tokenCore.getHubStatus(address(token))), uint256(TokenStructs.HubStatus.FROZEN));
        vm.expectRevert(
            abi.encodeWithSelector(
                ITokenFreezeManager.TokenFreezeManagerV1__TokenFrozenForParticipant.selector, resourceId, LOCAL_CHAIN_ID
            )
        );
        freezeManager.validateTokenForParticipant(resourceId, LOCAL_CHAIN_ID);
    }

    /// @notice Dry-runs the cross-chain bootstrap request built by TokenFreezeManager.
    /// @dev Proves the PN module asks PNH TokenRegistry for the legacy frozen-token snapshot.
    function test_dryRun_requestAllFrozenTokensDataFromPrivateHub() public {
        freezeManager.requestAllFrozenTokensDataFromPrivateHub();

        assertEq(endpoint.lastSendToResourceDstChainId(), PRIVATE_HUB_ID);
        assertEq(endpoint.lastSendToResourceId(), Constants.RESOURCE_ID_TOKEN_REGISTRY);
        assertEq(
            keccak256(endpoint.lastSendToResourcePayload()),
            keccak256(abi.encodeWithSignature("broadcastCurrentFrozenResourcesForNewParticipant()"))
        );
    }

    /// @notice Registers, authorizes, and activates the primary token for freeze-manager tests.
    /// @dev The resource ID is synthesized because current CLI flows still use the older PNH replica path.
    function _registerAuthorizeAndActivateToken() internal returns (bytes32) {
        bytes32 resourceId = keccak256("freeze-dry-run-resource");

        tokenCore.registerToken(address(token));
        tokenCore.updatePrivacyNodeStatus(address(token), TokenStructs.PrivacyNodeStatus.AUTHORIZED);
        tokenCore.submitToHub(address(token));
        tokenCore.activateToken(resourceId, address(token), uint8(SharedObjects.ErcStandard.ERC20));

        return resourceId;
    }

    /// @notice Deploys a second TokenCore proxy for configuration tests.
    function _deployTokenCore() internal returns (PNTokenCoreV1) {
        PNTokenCoreV1 tokenCoreImpl = new PNTokenCoreV1();
        PNTokenCoreV1 secondCore = PNTokenCoreV1(
            address(
                new ERC1967Proxy(address(tokenCoreImpl), abi.encodeCall(PNTokenCoreV1.initialize, (address(manager))))
            )
        );

        return secondCore;
    }

    /// @notice Builds a participant list containing one chain ID.
    function _singleParticipant(uint256 participant) internal pure returns (uint256[] memory) {
        uint256[] memory participants = new uint256[](1);
        participants[0] = participant;

        return participants;
    }

    /// @notice Builds a participant list containing two chain IDs.
    function _twoParticipants(uint256 firstParticipant, uint256 secondParticipant)
        internal
        pure
        returns (uint256[] memory)
    {
        uint256[] memory participants = new uint256[](2);
        participants[0] = firstParticipant;
        participants[1] = secondParticipant;

        return participants;
    }

    /// @notice Builds a frozen-token struct for the given resource ID and participants.
    function _frozenToken(bytes32 resourceId, uint256[] memory participants)
        internal
        pure
        returns (TokenStructs.FrozenToken memory)
    {
        TokenStructs.FrozenToken memory frozenToken =
            TokenStructs.FrozenToken({resourceId: resourceId, frozenParticipants: participants});

        return frozenToken;
    }
}
