// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
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

contract MockEndpointForTokenFreezeManager {
    uint256 public lastDstChainId;
    bytes32 public lastResourceId;
    bytes public lastPayload;

    mapping(bytes32 => address) public resourceIdToAddress;

    function getChainId() external pure returns (uint256) {
        return 100;
    }

    function getPrivateHubId() external pure returns (uint256) {
        return 999;
    }

    function getPrivateHubAddress(string calldata) external pure returns (address) {
        return address(0);
    }

    function send(uint256, address, bytes calldata) external payable returns (bytes32) {
        return bytes32(0);
    }

    function authority() external pure returns (address) {
        return address(0);
    }

    function registerResourceId(bytes32 resourceId, address tokenAddress) external {
        resourceIdToAddress[resourceId] = tokenAddress;
    }

    function getAddressByResourceId(bytes32 resourceId) external view returns (address) {
        return resourceIdToAddress[resourceId];
    }

    function sendToResourceId(uint256 dstChainId, bytes32 resourceId, bytes calldata payload)
        external
        payable
        returns (bytes32)
    {
        lastDstChainId = dstChainId;
        lastResourceId = resourceId;
        lastPayload = payload;
        return bytes32(0);
    }
}

contract MockTokenFreezeManagerERC20 is IRegistrableToken {
    bytes32 public resourceId;

    function name() external pure returns (string memory) {
        return "FreezeFlowToken";
    }

    function symbol() external pure returns (string memory) {
        return "FFT";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function totalSupply() external pure returns (uint256) {
        return 1_000_000e18;
    }

    function GetERCStandard() external pure returns (uint8) {
        return uint8(SharedObjects.ErcStandard.ERC20);
    }

    function setResourceId(bytes32 newResourceId) external {
        resourceId = newResourceId;
    }
}

contract TokenFreezeManagerV1_FreezeFlow_Test is Test {
    uint256 internal constant LOCAL_CHAIN_ID = 100;
    uint256 internal constant PRIVATE_HUB_ID = 999;
    uint256 internal constant REMOTE_CHAIN_A = 200;
    uint256 internal constant REMOTE_CHAIN_B = 300;

    RaylsAccessManagerV1 internal manager;
    PNTokenCoreV1 internal tokenCore;
    PNTokenFreezeManagerV1 internal freezeManager;
    MockEndpointForTokenFreezeManager internal endpoint;
    MockTokenFreezeManagerERC20 internal token;

    address internal attacker;

    function setUp() public {
        attacker = makeAddr("attacker");

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

        endpoint = new MockEndpointForTokenFreezeManager();
        token = new MockTokenFreezeManagerERC20();

        tokenCore.setTokenRegistry(address(this));
        tokenCore.setTokenFreezeManager(address(freezeManager));
        tokenCore.setEndpoint(address(endpoint));

        freezeManager.setTokenRegistry(address(this));
        freezeManager.setTokenCore(address(tokenCore));
        freezeManager.setEndpoint(address(endpoint));
    }

    function test_updateFrozenToken_reverts_whenCallerIsNotTokenRegistry() public {
        uint256[] memory participants = _singleParticipant(LOCAL_CHAIN_ID);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(ITokenFreezeManager.TokenFreezeManagerV1__UnauthorizedCaller.selector, attacker)
        );
        freezeManager.updateFrozenToken(_frozenToken(keccak256("unauthorized"), participants));
    }

    function test_setTokenRegistry_reverts_whenAddressIsZero() public {
        vm.expectRevert(ITokenFreezeManager.TokenFreezeManagerV1__InvalidTokenRegistryAddress.selector);
        freezeManager.setTokenRegistry(address(0));
    }

    function test_setTokenCore_reverts_whenAddressIsZero() public {
        vm.expectRevert(ITokenFreezeManager.TokenFreezeManagerV1__InvalidTokenCoreAddress.selector);
        freezeManager.setTokenCore(address(0));
    }

    function test_setEndpoint_reverts_whenAddressIsZero() public {
        vm.expectRevert(ITokenFreezeManager.TokenFreezeManagerV1__InvalidEndpointAddress.selector);
        freezeManager.setEndpoint(address(0));
    }

    function test_freezeOnPrivacyNode_blocks_all_participants_until_unfrozen() public {
        bytes32 resourceId = _registerAuthorizeAndActivateToken();

        freezeManager.freezeOnPrivacyNode(address(token));
        assertEq(
            uint256(tokenCore.getPrivacyNodeStatus(address(token))), uint256(TokenStructs.PrivacyNodeStatus.FROZEN)
        );

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

        freezeManager.validateTokenForParticipant(resourceId, REMOTE_CHAIN_A);
    }

    function test_updateFrozenToken_beforeActivation_replays_local_hub_freeze_on_activate() public {
        bytes32 resourceId = keccak256("pre-activation-freeze-flow-resource");

        tokenCore.registerToken(address(token));
        tokenCore.updatePrivacyNodeStatus(address(token), TokenStructs.PrivacyNodeStatus.AUTHORIZED);
        tokenCore.submitToHub(address(token));

        freezeManager.updateFrozenToken(_frozenToken(resourceId, _singleParticipant(LOCAL_CHAIN_ID)));

        // The token has no resourceId yet, so hub-status mirroring is deferred until activation.
        assertEq(uint256(tokenCore.getHubStatus(address(token))), uint256(TokenStructs.HubStatus.WAITING_APPROVAL));
        assertTrue(freezeManager.getFrozenTokenForParticipant(resourceId, LOCAL_CHAIN_ID));

        tokenCore.activateToken(resourceId, address(token), uint8(SharedObjects.ErcStandard.ERC20));

        assertEq(uint256(tokenCore.getHubStatus(address(token))), uint256(TokenStructs.HubStatus.FROZEN));
        vm.expectRevert(
            abi.encodeWithSelector(
                ITokenFreezeManager.TokenFreezeManagerV1__TokenFrozenForParticipant.selector, resourceId, LOCAL_CHAIN_ID
            )
        );
        freezeManager.validateTokenForParticipant(resourceId, LOCAL_CHAIN_ID);
    }

    function test_activateToken_emitsTokenActivated_beforeDeferredHubFreeze() public {
        bytes32 resourceId = keccak256("emit-order-deferred-freeze-resource");

        tokenCore.registerToken(address(token));
        tokenCore.updatePrivacyNodeStatus(address(token), TokenStructs.PrivacyNodeStatus.AUTHORIZED);
        tokenCore.submitToHub(address(token));

        // Freeze data for the local chain arrives before activation, so it is replayed on activate.
        freezeManager.updateFrozenToken(_frozenToken(resourceId, _singleParticipant(LOCAL_CHAIN_ID)));

        bytes32 hubStatusTopic = keccak256("HubStatusUpdated(address,uint8,uint8)");
        bytes32 tokenActivatedTopic = keccak256("TokenActivated(bytes32,address,uint8)");

        vm.recordLogs();
        tokenCore.activateToken(resourceId, address(token), uint8(SharedObjects.ErcStandard.ERC20));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        int256 authorizedIdx = -1;
        int256 activatedIdx = -1;
        int256 frozenIdx = -1;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 0) continue;
            bytes32 topic0 = logs[i].topics[0];
            if (topic0 == tokenActivatedTopic && activatedIdx == -1) {
                activatedIdx = int256(i);
            } else if (topic0 == hubStatusTopic) {
                (, uint8 newStatus) = abi.decode(logs[i].data, (uint8, uint8));
                if (newStatus == uint8(TokenStructs.HubStatus.AUTHORIZED) && authorizedIdx == -1) {
                    authorizedIdx = int256(i);
                } else if (newStatus == uint8(TokenStructs.HubStatus.FROZEN) && frozenIdx == -1) {
                    frozenIdx = int256(i);
                }
            }
        }

        assertTrue(authorizedIdx >= 0, "missing HubStatusUpdated(AUTHORIZED)");
        assertTrue(activatedIdx >= 0, "missing TokenActivated");
        assertTrue(frozenIdx >= 0, "missing HubStatusUpdated(FROZEN)");
        // TokenActivated must sit between the AUTHORIZED transition and the deferred-freeze
        // transition: activation is signaled before any replayed freeze is applied.
        assertLt(authorizedIdx, activatedIdx, "TokenActivated must follow the AUTHORIZED transition");
        assertLt(activatedIdx, frozenIdx, "deferred hub freeze must follow TokenActivated");
    }

    function test_freezeOnPublicChain_restores_previous_status_on_unfreeze() public {
        _registerAuthorizeAndActivateToken();

        tokenCore.submitToPublicChain(address(token));
        assertEq(
            uint256(tokenCore.getPublicChainStatus(address(token))),
            uint256(TokenStructs.PublicChainStatus.PENDING_DEPLOYMENT)
        );

        freezeManager.freezeOnPublicChain(address(token));
        assertEq(
            uint256(tokenCore.getPublicChainStatus(address(token))), uint256(TokenStructs.PublicChainStatus.FROZEN)
        );

        freezeManager.unfreezeOnPublicChain(address(token));
        assertEq(
            uint256(tokenCore.getPublicChainStatus(address(token))),
            uint256(TokenStructs.PublicChainStatus.PENDING_DEPLOYMENT)
        );
    }

    function test_updateAndRemoveFrozenToken_tracks_participants_and_local_hub_status() public {
        bytes32 resourceId = _registerAuthorizeAndActivateToken();
        uint256[] memory initialParticipants = _twoParticipants(LOCAL_CHAIN_ID, REMOTE_CHAIN_A);

        freezeManager.updateFrozenToken(_frozenToken(resourceId, initialParticipants));

        assertEq(uint256(tokenCore.getHubStatus(address(token))), uint256(TokenStructs.HubStatus.FROZEN));
        assertTrue(freezeManager.getFrozenTokenForParticipant(resourceId, LOCAL_CHAIN_ID));
        assertTrue(freezeManager.getFrozenTokenForParticipant(resourceId, REMOTE_CHAIN_A));

        vm.expectRevert(
            abi.encodeWithSelector(
                ITokenFreezeManager.TokenFreezeManagerV1__TokenFrozenForParticipant.selector, resourceId, LOCAL_CHAIN_ID
            )
        );
        freezeManager.validateTokenForParticipant(resourceId, LOCAL_CHAIN_ID);

        vm.expectRevert(
            abi.encodeWithSelector(
                ITokenFreezeManager.TokenFreezeManagerV1__TokenFrozenForParticipant.selector, resourceId, REMOTE_CHAIN_A
            )
        );
        freezeManager.validateTokenForParticipant(resourceId, REMOTE_CHAIN_A);

        freezeManager.removeFrozenToken(_frozenToken(resourceId, _singleParticipant(REMOTE_CHAIN_A)));

        assertEq(uint256(tokenCore.getHubStatus(address(token))), uint256(TokenStructs.HubStatus.FROZEN));
        assertTrue(freezeManager.getFrozenTokenForParticipant(resourceId, LOCAL_CHAIN_ID));
        assertFalse(freezeManager.getFrozenTokenForParticipant(resourceId, REMOTE_CHAIN_A));

        freezeManager.validateTokenForParticipant(resourceId, REMOTE_CHAIN_A);

        vm.expectRevert(
            abi.encodeWithSelector(
                ITokenFreezeManager.TokenFreezeManagerV1__TokenFrozenForParticipant.selector, resourceId, LOCAL_CHAIN_ID
            )
        );
        freezeManager.validateTokenForParticipant(resourceId, LOCAL_CHAIN_ID);

        freezeManager.removeFrozenToken(_frozenToken(resourceId, _singleParticipant(LOCAL_CHAIN_ID)));

        assertEq(uint256(tokenCore.getHubStatus(address(token))), uint256(TokenStructs.HubStatus.AUTHORIZED));
        assertFalse(freezeManager.getFrozenTokenForParticipant(resourceId, LOCAL_CHAIN_ID));

        freezeManager.validateTokenForParticipant(resourceId, LOCAL_CHAIN_ID);
    }

    function test_syncFrozenTokens_replaces_snapshot_and_unfreezes_removed_local_chain() public {
        bytes32 resourceId = _registerAuthorizeAndActivateToken();

        freezeManager.updateFrozenToken(_frozenToken(resourceId, _singleParticipant(LOCAL_CHAIN_ID)));
        assertEq(uint256(tokenCore.getHubStatus(address(token))), uint256(TokenStructs.HubStatus.FROZEN));

        TokenStructs.FrozenToken[] memory snapshot = new TokenStructs.FrozenToken[](1);
        snapshot[0] = _frozenToken(resourceId, _singleParticipant(REMOTE_CHAIN_B));

        freezeManager.syncFrozenTokens(snapshot);

        assertEq(uint256(tokenCore.getHubStatus(address(token))), uint256(TokenStructs.HubStatus.AUTHORIZED));
        assertFalse(freezeManager.getFrozenTokenForParticipant(resourceId, LOCAL_CHAIN_ID));
        assertTrue(freezeManager.getFrozenTokenForParticipant(resourceId, REMOTE_CHAIN_B));

        freezeManager.validateTokenForParticipant(resourceId, LOCAL_CHAIN_ID);

        vm.expectRevert(
            abi.encodeWithSelector(
                ITokenFreezeManager.TokenFreezeManagerV1__TokenFrozenForParticipant.selector, resourceId, REMOTE_CHAIN_B
            )
        );
        freezeManager.validateTokenForParticipant(resourceId, REMOTE_CHAIN_B);
    }

    /// @notice Requests frozen-token sync through the token registry resource ID.
    function test_requestAllFrozenTokensDataFromPrivateHub_uses_token_registry_resource_call() public {
        freezeManager.requestAllFrozenTokensDataFromPrivateHub();

        assertEq(endpoint.lastDstChainId(), PRIVATE_HUB_ID);
        assertEq(endpoint.lastResourceId(), Constants.RESOURCE_ID_TOKEN_REGISTRY);
        assertEq(
            keccak256(endpoint.lastPayload()),
            keccak256(abi.encodeWithSignature("broadcastCurrentFrozenResourcesForNewParticipant()"))
        );
    }

    /// @notice Allows endpoint system-resource messages when no participant freeze exists.
    function test_validateTokenForParticipant_allows_unregistered_system_resource_when_not_frozen() public view {
        freezeManager.validateTokenForParticipant(Constants.RESOURCE_ID_TOKEN_REGISTRY, LOCAL_CHAIN_ID);
    }

    /// @notice Still blocks endpoint system-resource messages when that participant is frozen.
    function test_validateTokenForParticipant_reverts_for_frozen_unregistered_system_resource() public {
        bytes32 resourceId = Constants.RESOURCE_ID_TOKEN_REGISTRY;

        freezeManager.updateFrozenToken(_frozenToken(resourceId, _singleParticipant(LOCAL_CHAIN_ID)));

        vm.expectRevert(
            abi.encodeWithSelector(
                ITokenFreezeManager.TokenFreezeManagerV1__TokenFrozenForParticipant.selector, resourceId, LOCAL_CHAIN_ID
            )
        );
        freezeManager.validateTokenForParticipant(resourceId, LOCAL_CHAIN_ID);
    }

    function test_syncFrozenTokens_emptyArray_unfreezesAllPreviouslyFrozen() public {
        bytes32 resourceId = _registerAuthorizeAndActivateToken();

        freezeManager.updateFrozenToken(_frozenToken(resourceId, _singleParticipant(LOCAL_CHAIN_ID)));
        assertEq(uint256(tokenCore.getHubStatus(address(token))), uint256(TokenStructs.HubStatus.FROZEN));

        TokenStructs.FrozenToken[] memory empty = new TokenStructs.FrozenToken[](0);
        freezeManager.syncFrozenTokens(empty);

        assertEq(uint256(tokenCore.getHubStatus(address(token))), uint256(TokenStructs.HubStatus.AUTHORIZED));
        assertFalse(freezeManager.getFrozenTokenForParticipant(resourceId, LOCAL_CHAIN_ID));
        freezeManager.validateTokenForParticipant(resourceId, LOCAL_CHAIN_ID);
    }

    function test_syncFrozenTokens_bulk_appliesMultipleResources() public {
        bytes32 activeResourceId = _registerAuthorizeAndActivateToken();
        bytes32 pendingResourceId = keccak256("pending-bulk-resource");

        TokenStructs.FrozenToken[] memory snapshot = new TokenStructs.FrozenToken[](2);
        snapshot[0] = _frozenToken(activeResourceId, _singleParticipant(LOCAL_CHAIN_ID));
        snapshot[1] = _frozenToken(pendingResourceId, _twoParticipants(REMOTE_CHAIN_A, REMOTE_CHAIN_B));

        freezeManager.syncFrozenTokens(snapshot);

        // Local chain is part of the frozen set for the activated token, so its hub layer freezes.
        assertEq(uint256(tokenCore.getHubStatus(address(token))), uint256(TokenStructs.HubStatus.FROZEN));
        assertTrue(freezeManager.getFrozenTokenForParticipant(activeResourceId, LOCAL_CHAIN_ID));
        // The second (not-yet-activated) resource's participant freeze data is retained regardless.
        assertTrue(freezeManager.getFrozenTokenForParticipant(pendingResourceId, REMOTE_CHAIN_A));
        assertTrue(freezeManager.getFrozenTokenForParticipant(pendingResourceId, REMOTE_CHAIN_B));
    }

    function test_hubFreeze_isolatedToSpecificChainId() public {
        bytes32 resourceId = _registerAuthorizeAndActivateToken();

        // Freeze only a remote participant; the local chain must stay operational.
        freezeManager.updateFrozenToken(_frozenToken(resourceId, _singleParticipant(REMOTE_CHAIN_A)));

        assertEq(uint256(tokenCore.getHubStatus(address(token))), uint256(TokenStructs.HubStatus.AUTHORIZED));
        assertFalse(freezeManager.getFrozenTokenForParticipant(resourceId, LOCAL_CHAIN_ID));
        assertTrue(freezeManager.getFrozenTokenForParticipant(resourceId, REMOTE_CHAIN_A));

        freezeManager.validateTokenForParticipant(resourceId, LOCAL_CHAIN_ID);

        vm.expectRevert(
            abi.encodeWithSelector(
                ITokenFreezeManager.TokenFreezeManagerV1__TokenFrozenForParticipant.selector, resourceId, REMOTE_CHAIN_A
            )
        );
        freezeManager.validateTokenForParticipant(resourceId, REMOTE_CHAIN_A);
    }

    function test_freezeOnPrivacyNode_reverts_whenTokenCoreNotConfigured() public {
        PNTokenFreezeManagerV1 freshManager = _deployFreezeManagerWithoutModules();

        vm.expectRevert(ITokenFreezeManager.TokenFreezeManagerV1__TokenCoreNotConfigured.selector);
        freshManager.freezeOnPrivacyNode(address(token));
    }

    function test_syncFrozenTokens_reverts_whenEndpointNotConfigured() public {
        PNTokenFreezeManagerV1 freshManager = _deployFreezeManagerWithoutModules();

        TokenStructs.FrozenToken[] memory empty = new TokenStructs.FrozenToken[](0);
        vm.expectRevert(ITokenFreezeManager.TokenFreezeManagerV1__EndpointNotConfigured.selector);
        freshManager.syncFrozenTokens(empty);
    }

    function test_setRelayAuthorizationRegistry_allowsZeroAddressAndUpdates() public {
        freezeManager.setRelayAuthorizationRegistry(address(0));
        assertEq(freezeManager.relayAuthorizationRegistry(), address(0));

        address relay = makeAddr("relayRegistry");
        freezeManager.setRelayAuthorizationRegistry(relay);
        assertEq(freezeManager.relayAuthorizationRegistry(), relay);
    }

    function test_functions_revert_whenCallerIsNotTokenRegistry() public {
        bytes memory expectedError =
            abi.encodeWithSelector(ITokenFreezeManager.TokenFreezeManagerV1__UnauthorizedCaller.selector, attacker);
        TokenStructs.FrozenToken[] memory empty = new TokenStructs.FrozenToken[](0);

        vm.startPrank(attacker);

        vm.expectRevert(expectedError);
        freezeManager.freezeOnPrivacyNode(address(token));

        vm.expectRevert(expectedError);
        freezeManager.syncFrozenTokens(empty);

        vm.expectRevert(expectedError);
        freezeManager.requestAllFrozenTokensDataFromPrivateHub();

        vm.stopPrank();
    }

    function test_removeFrozenToken_noop_whenParticipantNotFrozen() public {
        bytes32 resourceId = _registerAuthorizeAndActivateToken();

        // Removing a participant that was never frozen leaves state unchanged.
        freezeManager.removeFrozenToken(_frozenToken(resourceId, _singleParticipant(REMOTE_CHAIN_A)));

        assertFalse(freezeManager.getFrozenTokenForParticipant(resourceId, REMOTE_CHAIN_A));
        assertEq(uint256(tokenCore.getHubStatus(address(token))), uint256(TokenStructs.HubStatus.AUTHORIZED));
    }

    /// @dev Deploys a fresh freeze-manager proxy with only the registry set (no token core / endpoint).
    function _deployFreezeManagerWithoutModules() internal returns (PNTokenFreezeManagerV1 freshManager) {
        PNTokenFreezeManagerV1 impl = new PNTokenFreezeManagerV1();
        freshManager = PNTokenFreezeManagerV1(
            address(
                new ERC1967Proxy(address(impl), abi.encodeCall(PNTokenFreezeManagerV1.initialize, (address(manager))))
            )
        );
        freshManager.setTokenRegistry(address(this));
    }

    function _registerAuthorizeAndActivateToken() internal returns (bytes32 resourceId) {
        resourceId = keccak256("freeze-flow-resource");

        tokenCore.registerToken(address(token));
        tokenCore.updatePrivacyNodeStatus(address(token), TokenStructs.PrivacyNodeStatus.AUTHORIZED);
        tokenCore.submitToHub(address(token));
        tokenCore.activateToken(resourceId, address(token), uint8(SharedObjects.ErcStandard.ERC20));
    }

    function _singleParticipant(uint256 participant) internal pure returns (uint256[] memory participants) {
        participants = new uint256[](1);
        participants[0] = participant;
    }

    function _twoParticipants(uint256 firstParticipant, uint256 secondParticipant)
        internal
        pure
        returns (uint256[] memory participants)
    {
        participants = new uint256[](2);
        participants[0] = firstParticipant;
        participants[1] = secondParticipant;
    }

    function _frozenToken(bytes32 resourceId, uint256[] memory participants)
        internal
        pure
        returns (TokenStructs.FrozenToken memory frozenToken)
    {
        frozenToken = TokenStructs.FrozenToken({resourceId: resourceId, frozenParticipants: participants});
    }
}
