// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {ITokenCore} from "../../../rayls-protocol/TokenRegistry/interfaces/ITokenCore.sol";
import {PNTokenCoreV1} from "../../../rayls-protocol/TokenRegistry/modules/TokenCore/PNTokenCoreV1.sol";
import {TokenStructs} from "../../../rayls-protocol/TokenRegistry/libraries/TokenStructs.sol";
import {SharedObjects} from "../../../rayls-protocol-sdk/libraries/SharedObjects.sol";

contract MockEndpointForTokenCore {
    mapping(string => address) public privateHubAddresses;
    mapping(bytes32 => address) public resourceIdToAddress;

    function getChainId() external pure returns (uint256) {
        return 100;
    }

    function getPrivateHubId() external pure returns (uint256) {
        return 999;
    }

    function getPrivateHubAddress(string calldata name) external view returns (address) {
        return privateHubAddresses[name];
    }

    function setPrivateHubAddress(string calldata name, address addr) external {
        privateHubAddresses[name] = addr;
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
}

contract MockTokenCoreERC20 {
    bytes32 public resourceId;

    function name() external pure returns (string memory) {
        return "MockToken";
    }

    function symbol() external pure returns (string memory) {
        return "MOCK";
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

    function setResourceId(bytes32 _resourceId) external {
        resourceId = _resourceId;
    }
}

contract MockTokenCoreEnygma {
    bytes32 public resourceId;

    function name() external pure returns (string memory) {
        return "MockEnygma";
    }

    function symbol() external pure returns (string memory) {
        return "ENY";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function totalSupply() external pure returns (uint256) {
        return 500_000e18;
    }

    function GetERCStandard() external pure returns (uint8) {
        return uint8(SharedObjects.ErcStandard.Enygma);
    }

    function setResourceId(bytes32 _resourceId) external {
        resourceId = _resourceId;
    }
}

contract MockTokenCoreDvp721 {
    bytes32 public resourceId;

    function name() external pure returns (string memory) {
        return "MockDvp721";
    }

    function symbol() external pure returns (string memory) {
        return "DVP721";
    }

    function GetERCStandard() external pure returns (uint8) {
        return uint8(SharedObjects.ErcStandard.DvpERC721);
    }

    function setResourceId(bytes32 _resourceId) external {
        resourceId = _resourceId;
    }
}

contract MockTokenCoreDvp1155 {
    bytes32 public resourceId;

    function name() external pure returns (string memory) {
        return "MockDvp1155";
    }

    function GetERCStandard() external pure returns (uint8) {
        return uint8(SharedObjects.ErcStandard.DvpERC1155);
    }

    function setResourceId(bytes32 _resourceId) external {
        resourceId = _resourceId;
    }
}

contract MockEnygmaPNEventsForTokenCore {
    uint256 public creationCalls;
    uint256 public dvp721CreationCalls;
    uint256 public dvp1155CreationCalls;
    bytes32 public lastResourceId;
    uint256 public lastInitialSupply;

    function creation(bytes32 resourceId, uint256 initialSupply) external {
        creationCalls++;
        lastResourceId = resourceId;
        lastInitialSupply = initialSupply;
    }

    function dvp721Creation(bytes32 resourceId) external {
        dvp721CreationCalls++;
        lastResourceId = resourceId;
    }

    function dvp1155Creation(bytes32 resourceId) external {
        dvp1155CreationCalls++;
        lastResourceId = resourceId;
    }
}

/// @notice ERC20 mock that intentionally reuses `MockTokenCoreERC20`'s symbol to trigger the
///         duplicate-symbol guard in `registerToken`.
contract MockTokenCoreERC20DuplicateSymbol {
    function name() external pure returns (string memory) {
        return "MockTokenDuplicate";
    }

    function symbol() external pure returns (string memory) {
        return "MOCK";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function totalSupply() external pure returns (uint256) {
        return 1_000e18;
    }

    function GetERCStandard() external pure returns (uint8) {
        return uint8(SharedObjects.ErcStandard.ERC20);
    }
}

/**
 * @title Security Test: PNTokenCoreV1 Lifecycle Access Control
 * @notice Tests freeze-manager gating, PN status preconditions, and activation hook behavior on PNTokenCoreV1.
 */
contract TokenCoreV1AccessControlTest is Test {
    PNTokenCoreV1 public tokenCore;
    RaylsAccessManagerV1 public manager;
    MockEndpointForTokenCore public mockEndpoint;
    MockTokenCoreERC20 public mockToken;
    MockTokenCoreEnygma public enygmaToken;
    MockTokenCoreDvp721 public dvp721Token;
    MockTokenCoreDvp1155 public dvp1155Token;
    MockEnygmaPNEventsForTokenCore public enygmaPNEvents;

    address public admin;
    address public freezeManager;
    address public attacker;
    address public unknownToken;

    function setUp() public {
        admin = address(this);
        freezeManager = makeAddr("freezeManager");
        attacker = makeAddr("attacker");
        unknownToken = makeAddr("unknownToken");

        RaylsAccessManagerV1 managerImpl = new RaylsAccessManagerV1();
        bytes memory managerInitData = abi.encodeCall(RaylsAccessManagerV1.initialize, (admin));
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(address(managerImpl), managerInitData)));

        PNTokenCoreV1 tokenCoreImpl = new PNTokenCoreV1();
        bytes memory tokenCoreInitData = abi.encodeCall(PNTokenCoreV1.initialize, (address(manager)));
        tokenCore = PNTokenCoreV1(address(new ERC1967Proxy(address(tokenCoreImpl), tokenCoreInitData)));

        mockEndpoint = new MockEndpointForTokenCore();
        mockEndpoint.setPrivateHubAddress("TokenRegistry", address(tokenCore));
        mockToken = new MockTokenCoreERC20();
        enygmaToken = new MockTokenCoreEnygma();
        dvp721Token = new MockTokenCoreDvp721();
        dvp1155Token = new MockTokenCoreDvp1155();
        enygmaPNEvents = new MockEnygmaPNEventsForTokenCore();

        tokenCore.setTokenRegistry(address(this));
        tokenCore.setEndpoint(address(mockEndpoint));
        tokenCore.setTokenFreezeManager(freezeManager);
        tokenCore.setEnygmaPNEvents(address(enygmaPNEvents));
    }

    /// @dev Drives a registered token to WAITING_APPROVAL so activateToken's hub precondition is met.
    function _authorizeAndSubmit(address token) internal {
        tokenCore.updatePrivacyNodeStatus(token, TokenStructs.PrivacyNodeStatus.AUTHORIZED);
        tokenCore.submitToHub(token);
    }

    // --- setFreezeStatus() ---

    function test_setFreezeStatus_reverts_whenCallerIsNotFreezeManager() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ITokenCore.TokenCoreV1__UnauthorizedFreezeManager.selector, attacker));
        tokenCore.setFreezeStatus(unknownToken, TokenStructs.FreezeLayer.PRIVACY_NODE, true);
    }

    function test_setFreezeStatus_freezeManagerPassesAuthCheck() public {
        vm.prank(freezeManager);
        vm.expectRevert(ITokenCore.TokenCoreV1__TokenDoesNotExist.selector);
        tokenCore.setFreezeStatus(unknownToken, TokenStructs.FreezeLayer.PRIVACY_NODE, true);
    }

    // --- configuration setters ---

    function test_setTokenRegistry_reverts_whenAddressIsZero() public {
        vm.expectRevert(ITokenCore.TokenCoreV1__InvalidTokenRegistryAddress.selector);
        tokenCore.setTokenRegistry(address(0));
    }

    function test_setTokenFreezeManager_reverts_whenAddressIsZero() public {
        vm.expectRevert(ITokenCore.TokenCoreV1__InvalidTokenFreezeManagerAddress.selector);
        tokenCore.setTokenFreezeManager(address(0));
    }

    function test_setEndpoint_reverts_whenAddressIsZero() public {
        vm.expectRevert(ITokenCore.TokenCoreV1__InvalidEndpointAddress.selector);
        tokenCore.setEndpoint(address(0));
    }

    function test_setEnygmaPNEvents_reverts_whenAddressIsZero() public {
        vm.expectRevert(ITokenCore.TokenCoreV1__InvalidEnygmaPNEventsAddress.selector);
        tokenCore.setEnygmaPNEvents(address(0));
    }

    // --- submitToHub() ---

    function test_submitToHub_reverts_whenPrivacyNodeStatusIsNotAuthorized() public {
        tokenCore.registerToken(address(mockToken));

        vm.expectRevert(
            abi.encodeWithSelector(
                ITokenCore.TokenCoreV1__PrivacyNodeAuthorizationRequired.selector, address(mockToken)
            )
        );
        tokenCore.submitToHub(address(mockToken));
    }

    function test_submitToHub_reverts_whenHubStatusIsAlreadyWaitingApprovalOrAuthorized() public {
        bytes32 authorizedResourceId = keccak256("authorized-submit-resource");

        tokenCore.registerToken(address(mockToken));
        tokenCore.updatePrivacyNodeStatus(address(mockToken), TokenStructs.PrivacyNodeStatus.AUTHORIZED);
        tokenCore.submitToHub(address(mockToken));

        vm.expectRevert(ITokenCore.TokenCoreV1__StatusAlreadySet.selector);
        tokenCore.submitToHub(address(mockToken));

        tokenCore.registerToken(address(dvp721Token));
        tokenCore.updatePrivacyNodeStatus(address(dvp721Token), TokenStructs.PrivacyNodeStatus.AUTHORIZED);
        tokenCore.submitToHub(address(dvp721Token));
        tokenCore.activateToken(authorizedResourceId, address(dvp721Token), uint8(SharedObjects.ErcStandard.DvpERC721));

        vm.expectRevert(ITokenCore.TokenCoreV1__StatusAlreadySet.selector);
        tokenCore.submitToHub(address(dvp721Token));
    }

    // --- activateToken() ---

    function test_activateToken_erc20_doesNotCallEnygmaPnEvents() public {
        bytes32 resourceId = keccak256("erc20-resource");

        tokenCore.registerToken(address(mockToken));
        _authorizeAndSubmit(address(mockToken));
        tokenCore.activateToken(resourceId, address(mockToken), uint8(SharedObjects.ErcStandard.ERC20));

        assertEq(enygmaPNEvents.creationCalls(), 0);
        assertEq(enygmaPNEvents.dvp721CreationCalls(), 0);
        assertEq(enygmaPNEvents.dvp1155CreationCalls(), 0);
    }

    function test_activateToken_reverts_whenResourceIdIsAlreadyAssignedToDifferentToken() public {
        bytes32 resourceId = keccak256("duplicate-resource-id");

        tokenCore.registerToken(address(mockToken));
        _authorizeAndSubmit(address(mockToken));
        tokenCore.activateToken(resourceId, address(mockToken), uint8(SharedObjects.ErcStandard.ERC20));

        tokenCore.registerToken(address(enygmaToken));

        vm.expectRevert(abi.encodeWithSelector(ITokenCore.TokenCoreV1__ResourceIdAlreadyAssigned.selector, resourceId));
        tokenCore.activateToken(resourceId, address(enygmaToken), uint8(SharedObjects.ErcStandard.Enygma));
    }

    function test_activateToken_enygma_callsCreation() public {
        bytes32 resourceId = keccak256("enygma-resource");
        // The activation supply is now read from the token itself (MockTokenCoreEnygma.totalSupply()).
        uint256 totalSupply = 500_000e18;

        tokenCore.registerToken(address(enygmaToken));
        _authorizeAndSubmit(address(enygmaToken));
        tokenCore.activateToken(resourceId, address(enygmaToken), uint8(SharedObjects.ErcStandard.Enygma));

        assertEq(enygmaPNEvents.creationCalls(), 1);
        assertEq(enygmaPNEvents.dvp721CreationCalls(), 0);
        assertEq(enygmaPNEvents.dvp1155CreationCalls(), 0);
        assertEq(enygmaPNEvents.lastResourceId(), resourceId);
        assertEq(enygmaPNEvents.lastInitialSupply(), totalSupply);
    }

    function test_activateToken_dvp721_callsDvp721Creation() public {
        bytes32 resourceId = keccak256("dvp721-resource");

        tokenCore.registerToken(address(dvp721Token));
        _authorizeAndSubmit(address(dvp721Token));
        tokenCore.activateToken(resourceId, address(dvp721Token), uint8(SharedObjects.ErcStandard.DvpERC721));

        assertEq(enygmaPNEvents.creationCalls(), 0);
        assertEq(enygmaPNEvents.dvp721CreationCalls(), 1);
        assertEq(enygmaPNEvents.dvp1155CreationCalls(), 0);
        assertEq(enygmaPNEvents.lastResourceId(), resourceId);
    }

    function test_activateToken_dvp1155_callsDvp1155Creation() public {
        bytes32 resourceId = keccak256("dvp1155-resource");

        tokenCore.registerToken(address(dvp1155Token));
        _authorizeAndSubmit(address(dvp1155Token));
        tokenCore.activateToken(resourceId, address(dvp1155Token), uint8(SharedObjects.ErcStandard.DvpERC1155));

        assertEq(enygmaPNEvents.creationCalls(), 0);
        assertEq(enygmaPNEvents.dvp721CreationCalls(), 0);
        assertEq(enygmaPNEvents.dvp1155CreationCalls(), 1);
        assertEq(enygmaPNEvents.lastResourceId(), resourceId);
    }

    // --- registerToken() ---

    function test_registerToken_reverts_whenTokenAddressIsZero() public {
        vm.expectRevert(ITokenCore.TokenCoreV1__InvalidTokenAddress.selector);
        tokenCore.registerToken(address(0));
    }

    function test_registerToken_reverts_whenTokenAlreadyRegistered() public {
        tokenCore.registerToken(address(mockToken));

        vm.expectRevert(ITokenCore.TokenCoreV1__TokenAlreadyExists.selector);
        tokenCore.registerToken(address(mockToken));
    }

    function test_registerToken_reverts_whenSymbolAlreadyExists() public {
        tokenCore.registerToken(address(mockToken));

        MockTokenCoreERC20DuplicateSymbol duplicate = new MockTokenCoreERC20DuplicateSymbol();
        vm.expectRevert(ITokenCore.TokenCoreV1__TokenSymbolAlreadyExists.selector);
        tokenCore.registerToken(address(duplicate));
    }

    function test_registerToken_reverts_whenEndpointNotConfigured() public {
        PNTokenCoreV1 freshCore = _deployCoreWithoutEndpoint();

        vm.expectRevert(ITokenCore.TokenCoreV1__EndpointNotConfigured.selector);
        freshCore.registerToken(address(mockToken));
    }

    function test_registerToken_setsWaitingApprovalStatus() public {
        tokenCore.registerToken(address(mockToken));

        assertTrue(tokenCore.tokenExists(address(mockToken)));
        assertEq(
            uint256(tokenCore.getPrivacyNodeStatus(address(mockToken))),
            uint256(TokenStructs.PrivacyNodeStatus.WAITING_APPROVAL)
        );
        assertEq(uint256(tokenCore.getHubStatus(address(mockToken))), uint256(TokenStructs.HubStatus.UNDEFINED));
        assertEq(
            uint256(tokenCore.getPublicChainStatus(address(mockToken))),
            uint256(TokenStructs.PublicChainStatus.UNDEFINED)
        );
    }

    // --- updatePrivacyNodeStatus() ---

    function test_updatePrivacyNodeStatus_authorizeThenUnauthorize() public {
        tokenCore.registerToken(address(mockToken));

        tokenCore.updatePrivacyNodeStatus(address(mockToken), TokenStructs.PrivacyNodeStatus.AUTHORIZED);
        assertEq(
            uint256(tokenCore.getPrivacyNodeStatus(address(mockToken))),
            uint256(TokenStructs.PrivacyNodeStatus.AUTHORIZED)
        );

        tokenCore.updatePrivacyNodeStatus(address(mockToken), TokenStructs.PrivacyNodeStatus.UNAUTHORIZED);
        assertEq(
            uint256(tokenCore.getPrivacyNodeStatus(address(mockToken))),
            uint256(TokenStructs.PrivacyNodeStatus.UNAUTHORIZED)
        );
    }

    function test_updatePrivacyNodeStatus_reverts_whenTargetIsFrozen() public {
        tokenCore.registerToken(address(mockToken));

        vm.expectRevert(
            abi.encodeWithSelector(
                ITokenCore.TokenCoreV1__InvalidPrivacyNodeStatus.selector, TokenStructs.PrivacyNodeStatus.FROZEN
            )
        );
        tokenCore.updatePrivacyNodeStatus(address(mockToken), TokenStructs.PrivacyNodeStatus.FROZEN);
    }

    function test_updatePrivacyNodeStatus_reverts_whenStatusUnchanged() public {
        tokenCore.registerToken(address(mockToken));
        tokenCore.updatePrivacyNodeStatus(address(mockToken), TokenStructs.PrivacyNodeStatus.AUTHORIZED);

        vm.expectRevert(ITokenCore.TokenCoreV1__StatusAlreadySet.selector);
        tokenCore.updatePrivacyNodeStatus(address(mockToken), TokenStructs.PrivacyNodeStatus.AUTHORIZED);
    }

    // --- submitToPublicChain() ---

    function test_submitToPublicChain_reverts_whenNotPrivacyNodeAuthorized() public {
        tokenCore.registerToken(address(mockToken));

        vm.expectRevert(
            abi.encodeWithSelector(
                ITokenCore.TokenCoreV1__PrivacyNodeAuthorizationRequired.selector, address(mockToken)
            )
        );
        tokenCore.submitToPublicChain(address(mockToken));
    }

    function test_submitToPublicChain_setsPendingDeployment() public {
        tokenCore.registerToken(address(mockToken));
        tokenCore.updatePrivacyNodeStatus(address(mockToken), TokenStructs.PrivacyNodeStatus.AUTHORIZED);

        tokenCore.submitToPublicChain(address(mockToken));

        assertEq(
            uint256(tokenCore.getPublicChainStatus(address(mockToken))),
            uint256(TokenStructs.PublicChainStatus.PENDING_DEPLOYMENT)
        );
    }

    function test_submitToPublicChain_reverts_whenAlreadySubmitted() public {
        tokenCore.registerToken(address(mockToken));
        tokenCore.updatePrivacyNodeStatus(address(mockToken), TokenStructs.PrivacyNodeStatus.AUTHORIZED);
        tokenCore.submitToPublicChain(address(mockToken));

        vm.expectRevert(ITokenCore.TokenCoreV1__StatusAlreadySet.selector);
        tokenCore.submitToPublicChain(address(mockToken));
    }

    // --- activateToken() ---

    function test_activateToken_reverts_whenEndpointNotConfigured() public {
        PNTokenCoreV1 freshCore = _deployCoreWithoutEndpoint();

        vm.expectRevert(ITokenCore.TokenCoreV1__EndpointNotConfigured.selector);
        freshCore.activateToken(
            keccak256("no-endpoint-resource"), address(mockToken), uint8(SharedObjects.ErcStandard.ERC20)
        );
    }

    function test_activateToken_reverts_whenResourceIdChangesForSameToken() public {
        tokenCore.registerToken(address(mockToken));
        _authorizeAndSubmit(address(mockToken));
        tokenCore.activateToken(
            keccak256("first-resource"), address(mockToken), uint8(SharedObjects.ErcStandard.ERC20)
        );

        vm.expectRevert(
            abi.encodeWithSelector(ITokenCore.TokenCoreV1__ResourceIdAlreadySet.selector, address(mockToken))
        );
        tokenCore.activateToken(
            keccak256("second-resource"), address(mockToken), uint8(SharedObjects.ErcStandard.ERC20)
        );
    }

    function test_activateToken_reverts_whenNeverSubmittedToHub() public {
        bytes32 resourceId = keccak256("never-submitted-resource");
        tokenCore.registerToken(address(mockToken));

        // hubStatus is UNDEFINED: the token was never submitted to the hub, so activation must fail.
        vm.expectRevert(
            abi.encodeWithSelector(
                ITokenCore.TokenCoreV1__HubApprovalNotPending.selector,
                address(mockToken),
                TokenStructs.HubStatus.UNDEFINED
            )
        );
        tokenCore.activateToken(resourceId, address(mockToken), uint8(SharedObjects.ErcStandard.ERC20));
    }

    function test_activateToken_reverts_whenPreviouslyRejected() public {
        bytes32 resourceId = keccak256("rejected-resource");
        tokenCore.registerToken(address(mockToken));
        tokenCore.rejectToken(address(mockToken));

        // hubStatus is UNAUTHORIZED after rejection: a rejected token cannot be activated directly.
        vm.expectRevert(
            abi.encodeWithSelector(
                ITokenCore.TokenCoreV1__HubApprovalNotPending.selector,
                address(mockToken),
                TokenStructs.HubStatus.UNAUTHORIZED
            )
        );
        tokenCore.activateToken(resourceId, address(mockToken), uint8(SharedObjects.ErcStandard.ERC20));
    }

    function test_activateToken_reverts_onReplayAfterActivation() public {
        bytes32 resourceId = keccak256("replay-resource");
        tokenCore.registerToken(address(mockToken));
        _authorizeAndSubmit(address(mockToken));
        tokenCore.activateToken(resourceId, address(mockToken), uint8(SharedObjects.ErcStandard.ERC20));

        // hubStatus is AUTHORIZED: a replayed activation callback for the same token must revert.
        vm.expectRevert(
            abi.encodeWithSelector(
                ITokenCore.TokenCoreV1__HubApprovalNotPending.selector,
                address(mockToken),
                TokenStructs.HubStatus.AUTHORIZED
            )
        );
        tokenCore.activateToken(resourceId, address(mockToken), uint8(SharedObjects.ErcStandard.ERC20));
    }

    // --- rejectToken() ---

    function test_rejectToken_setsHubUnauthorized() public {
        tokenCore.registerToken(address(mockToken));

        tokenCore.rejectToken(address(mockToken));

        assertEq(uint256(tokenCore.getHubStatus(address(mockToken))), uint256(TokenStructs.HubStatus.UNAUTHORIZED));
    }

    // --- updatePublicTokenAddress() ---

    function test_updatePublicTokenAddress_setsAddressAndDeployedStatus() public {
        address publicToken = makeAddr("publicToken");
        tokenCore.registerToken(address(mockToken));

        tokenCore.updatePublicTokenAddress(address(mockToken), publicToken);

        assertEq(
            uint256(tokenCore.getPublicChainStatus(address(mockToken))),
            uint256(TokenStructs.PublicChainStatus.DEPLOYED)
        );
        assertEq(tokenCore.getTokenByAddress(address(mockToken)).publicTokenAddress, publicToken);
    }

    // --- deprecateOnPublicChain() ---

    function test_deprecateOnPublicChain_setsPublicChainDeprecated() public {
        tokenCore.registerToken(address(mockToken));

        tokenCore.deprecateOnPublicChain(address(mockToken));

        assertEq(
            uint256(tokenCore.getPublicChainStatus(address(mockToken))),
            uint256(TokenStructs.PublicChainStatus.DEPRECATED)
        );
    }

    // --- setFreezeStatus() double-freeze branch ---

    function test_setFreezeStatus_reverts_whenLayerAlreadyFrozen() public {
        tokenCore.registerToken(address(mockToken));

        vm.prank(freezeManager);
        tokenCore.setFreezeStatus(address(mockToken), TokenStructs.FreezeLayer.PRIVACY_NODE, true);

        vm.prank(freezeManager);
        vm.expectRevert(ITokenCore.TokenCoreV1__StatusAlreadySet.selector);
        tokenCore.setFreezeStatus(address(mockToken), TokenStructs.FreezeLayer.PRIVACY_NODE, true);
    }

    // --- operational checks ---

    function test_operationalChecks_reflectFullLifecycle() public {
        address publicToken = makeAddr("opsPublicToken");
        bytes32 resourceId = keccak256("ops-resource");

        tokenCore.registerToken(address(mockToken));
        assertFalse(tokenCore.isTokenFullyOperational(address(mockToken)));
        assertFalse(tokenCore.isTokenActiveForHub(address(mockToken)));
        assertFalse(tokenCore.isTokenActiveForPublicChain(address(mockToken)));

        _authorizeAndSubmit(address(mockToken));
        tokenCore.activateToken(resourceId, address(mockToken), uint8(SharedObjects.ErcStandard.ERC20));
        assertTrue(tokenCore.isTokenActiveForHub(address(mockToken)));
        assertFalse(tokenCore.isTokenActiveForPublicChain(address(mockToken)));
        assertFalse(tokenCore.isTokenFullyOperational(address(mockToken)));

        tokenCore.submitToPublicChain(address(mockToken));
        tokenCore.updatePublicTokenAddress(address(mockToken), publicToken);

        assertTrue(tokenCore.isTokenActiveForPublicChain(address(mockToken)));
        assertTrue(tokenCore.isTokenFullyOperational(address(mockToken)));
    }

    // --- access control: onlyTokenRegistry ---

    function test_lifecycleFunctions_revert_whenCallerIsNotTokenRegistry() public {
        bytes memory expectedError =
            abi.encodeWithSelector(ITokenCore.TokenCoreV1__UnauthorizedCaller.selector, attacker);

        vm.startPrank(attacker);

        vm.expectRevert(expectedError);
        tokenCore.registerToken(address(mockToken));

        vm.expectRevert(expectedError);
        tokenCore.updatePrivacyNodeStatus(address(mockToken), TokenStructs.PrivacyNodeStatus.AUTHORIZED);

        vm.expectRevert(expectedError);
        tokenCore.submitToHub(address(mockToken));

        vm.expectRevert(expectedError);
        tokenCore.submitToPublicChain(address(mockToken));

        vm.expectRevert(expectedError);
        tokenCore.activateToken(keccak256("unauth"), address(mockToken), uint8(SharedObjects.ErcStandard.ERC20));

        vm.expectRevert(expectedError);
        tokenCore.rejectToken(address(mockToken));

        vm.expectRevert(expectedError);
        tokenCore.updatePublicTokenAddress(address(mockToken), address(1));

        vm.expectRevert(expectedError);
        tokenCore.deprecateOnPublicChain(address(mockToken));

        vm.stopPrank();
    }

    // --- queries ---

    function test_queries_reflectRegisteredTokens() public {
        tokenCore.registerToken(address(mockToken));
        tokenCore.registerToken(address(enygmaToken));

        assertEq(tokenCore.getTokenCount(), 2);
        assertEq(tokenCore.getAllTokens().length, 2);
        assertEq(
            tokenCore.getTokensByPrivacyNodeStatus(TokenStructs.PrivacyNodeStatus.WAITING_APPROVAL).length, 2
        );
        assertEq(tokenCore.getActiveTokenCount(), 0);

        tokenCore.updatePrivacyNodeStatus(address(mockToken), TokenStructs.PrivacyNodeStatus.AUTHORIZED);
        assertEq(tokenCore.getActiveTokenCount(), 1);
    }

    function test_queries_lookupBySymbolAndResourceId() public {
        bytes32 resourceId = keccak256("lookup-resource");
        tokenCore.registerToken(address(mockToken));
        _authorizeAndSubmit(address(mockToken));
        tokenCore.activateToken(resourceId, address(mockToken), uint8(SharedObjects.ErcStandard.ERC20));

        assertEq(tokenCore.getTokenBySymbol("MOCK").tokenAddress, address(mockToken));
        assertEq(tokenCore.getTokenByResourceId(resourceId).tokenAddress, address(mockToken));
        assertTrue(tokenCore.tokenExistsByResourceId(resourceId));
        assertFalse(tokenCore.tokenExistsByResourceId(keccak256("missing")));
        assertEq(tokenCore.getTokensByHubStatus(TokenStructs.HubStatus.AUTHORIZED).length, 1);
    }

    // --- helpers ---

    /// @dev Deploys a fresh TokenCore proxy with the registry set but no endpoint configured.
    function _deployCoreWithoutEndpoint() internal returns (PNTokenCoreV1 freshCore) {
        PNTokenCoreV1 impl = new PNTokenCoreV1();
        freshCore = PNTokenCoreV1(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(PNTokenCoreV1.initialize, (address(manager)))))
        );
        freshCore.setTokenRegistry(address(this));
    }
}
