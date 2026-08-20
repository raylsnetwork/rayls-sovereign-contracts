// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import "../../../privateHub/TokenRegistry/TokenRegistryV1.sol";
import {TokenCoreV1} from "../../../privateHub/TokenRegistry/modules/TokenCore/TokenCoreV1.sol";
import {TokenStructs} from "../../../privateHub/TokenRegistry/libraries/TokenStructs.sol";
import {ParticipantStructs} from "../../../privateHub/ParticipantStorage/libraries/ParticipantStructs.sol";
import "../mocks/MockEndpointForSecurityTest.sol";
import {RaylsAppV1} from "../../../rayls-protocol-sdk/RaylsAppV1.sol";
import {SharedObjects} from "../../../rayls-protocol-sdk/libraries/SharedObjects.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";

/**
 * @title Security Test: TokenRegistryV1 Access Control
 * @notice Tests that addToken() and updateTokenBalance() are protected by receiveMethod.
 */
contract TokenRegistryV1AccessControlTest is Test {
    TokenRegistryV1 public tokenRegistry;
    MockEndpointForSecurityTest public mockEndpoint;
    RaylsAccessManagerV1 public manager;

    address public owner;
    address public attacker;

    uint256 constant CHAIN_ID = 12345;
    uint256 constant PRIVATE_HUB_CHAIN_ID = 99999;

    function setUp() public {
        owner = address(this);
        attacker = makeAddr("attacker");

        // Deploy AccessManager
        RaylsAccessManagerV1 managerImpl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(
            address(new ERC1967Proxy(address(managerImpl), abi.encodeCall(RaylsAccessManagerV1.initialize, (owner))))
        );
        manager.registerRole("RELAYER");
        manager.registerRole("MESSAGE_EXECUTOR");

        mockEndpoint = new MockEndpointForSecurityTest(CHAIN_ID, PRIVATE_HUB_CHAIN_ID);
        mockEndpoint.setTrustedExecutor(owner);
        mockEndpoint.setAuthority(address(manager));

        tokenRegistry = new TokenRegistryV1();
        tokenRegistry.initialize(address(mockEndpoint), address(manager));
    }

    // ========== addToken() ==========

    function test_addToken_attackerReverts() public {
        SharedObjects.TokenRegistrationData memory tokenData = _buildFakeTokenData();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        tokenRegistry.addToken(tokenData);
    }

    function test_addToken_ownerReverts_whenNoAuthority() public {
        // Deploying a TokenRegistryV1 with authority_=address(0) must revert during initialization.
        // _initializeAuthority → _setAuthority rejects address(0), preventing a registry without access control.
        MockEndpointForSecurityTest separateEndpoint = new MockEndpointForSecurityTest(CHAIN_ID, PRIVATE_HUB_CHAIN_ID);
        separateEndpoint.setTrustedExecutor(makeAddr("realExecutor"));

        TokenRegistryV1 registryImpl = new TokenRegistryV1();
        vm.expectRevert(
            abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__InvalidAuthority.selector, address(0))
        );
        new ERC1967Proxy(
            address(registryImpl), abi.encodeCall(TokenRegistryV1.initialize, (address(separateEndpoint), address(0)))
        );
    }

    function test_addToken_trustedExecutorDoesNotRevertOnAccessControl() public {
        // When called by trusted executor, it should pass the receiveMethod check.
        // It may revert deeper in the call (e.g. tokenCore not set), but NOT on access control.
        SharedObjects.TokenRegistrationData memory tokenData = _buildFakeTokenData();

        // owner IS the trusted executor in setUp()
        vm.prank(owner);
        // Expect it to NOT revert with UnauthorizedExecutor.
        // It will revert for another reason (tokenCore module not configured), which is fine.
        try tokenRegistry.addToken(tokenData) {}
        catch (bytes memory reason) {
            // Ensure the revert is NOT the access control error
            assertTrue(
                keccak256(reason)
                    != keccak256(
                        abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, owner)
                    ),
                "Should not revert with UnauthorizedExecutor when caller is trusted executor"
            );
        }
    }

    // ========== updateTokenBalance() ==========

    function test_updateTokenBalance_attackerReverts() public {
        bytes32 fakeResourceId = keccak256("fakeResource");

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        tokenRegistry.updateTokenBalance(
            CHAIN_ID, fakeResourceId, SharedObjects.BalanceUpdateType.MINT, abi.encode(100)
        );
    }

    function test_updateTokenBalance_ownerReverts_whenNoAuthority() public {
        // Same as addToken test: deploying with authority_=address(0) must revert during initialization.
        // This proves updateTokenBalance can never be called on a registry without access control,
        // because such a registry cannot be deployed in the first place.
        MockEndpointForSecurityTest separateEndpoint = new MockEndpointForSecurityTest(CHAIN_ID, PRIVATE_HUB_CHAIN_ID);
        separateEndpoint.setTrustedExecutor(makeAddr("realExecutor"));

        TokenRegistryV1 registryImpl = new TokenRegistryV1();
        vm.expectRevert(
            abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__InvalidAuthority.selector, address(0))
        );
        new ERC1967Proxy(
            address(registryImpl), abi.encodeCall(TokenRegistryV1.initialize, (address(separateEndpoint), address(0)))
        );
    }

    function test_updateTokenBalance_trustedExecutorDoesNotRevertOnAccessControl() public {
        bytes32 fakeResourceId = keccak256("fakeResource");

        // owner IS the trusted executor in setUp()
        vm.prank(owner);
        try tokenRegistry.updateTokenBalance(
            CHAIN_ID, fakeResourceId, SharedObjects.BalanceUpdateType.MINT, abi.encode(100)
        ) {}
        catch (bytes memory reason) {
            assertTrue(
                keccak256(reason)
                    != keccak256(
                        abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, owner)
                    ),
                "Should not revert with UnauthorizedExecutor when caller is trusted executor"
            );
        }
    }

    function test_privateHubActivationPath_sendsActivateToken_toPnRegistryAddress() public {
        address participantStorage = makeAddr("participantStorage");
        address resourceRegistry = makeAddr("resourceRegistry");
        address enygmaTokenManager = makeAddr("enygmaTokenManager");
        address callbackToken = makeAddr("callbackToken");
        address issuerImplementation = makeAddr("issuerImplementation");
        address pnRegistryAddress = makeAddr("pnRegistry");
        bytes32 resourceId = keccak256("private-hub-token-core-resource");
        uint256 totalSupply = 1_000_000e18;
        uint256 issuerChainId = 77;

        ParticipantStructs.Participant memory activeIssuer = ParticipantStructs.Participant({
            chainId: issuerChainId,
            role: ParticipantStructs.Role.ISSUER,
            status: ParticipantStructs.Status.ACTIVE,
            ownerId: "issuer",
            name: "Issuer",
            createdAt: 1,
            updatedAt: 1,
            allowedToBroadcast: true
        });

        vm.mockCall(
            participantStorage,
            abi.encodeWithSignature("getParticipant(uint256)", issuerChainId),
            abi.encode(activeIssuer)
        );
        bytes memory initializerParams = abi.encode("FakeToken", "FAKE", uint8(18));
        vm.mockCall(
            resourceRegistry,
            abi.encodeWithSignature(
                "registerResource(uint8,bytes,bytes)",
                uint8(SharedObjects.ErcStandard.ERC20),
                hex"00",
                initializerParams
            ),
            abi.encode(resourceId)
        );
        vm.mockCall(callbackToken, abi.encodeWithSignature("totalSupply()"), abi.encode(totalSupply));

        TokenCoreV1 tokenCore = new TokenCoreV1();
        tokenCore.initialize(
            address(this),
            participantStorage,
            resourceRegistry,
            enygmaTokenManager,
            address(mockEndpoint),
            makeAddr("enygmaFactorySettings"),
            makeAddr("dvpSettings"),
            address(manager)
        );

        tokenCore.addToken(
            SharedObjects.TokenRegistrationData({
                name: "FakeToken",
                symbol: "FAKE",
                uri: "",
                totalSupply: abi.encode(totalSupply),
                issuerChainId: issuerChainId,
                pnRegistryAddress: pnRegistryAddress,
                bytecode: hex"00",
                initializerParams: initializerParams,
                isFungible: true,
                ercStandard: SharedObjects.ErcStandard.ERC20,
                isCustom: false,
                tokenAddress: callbackToken
            }),
            issuerImplementation
        );

        tokenCore.updateStatus(resourceId, TokenStructs.TokenStatus.ACTIVE);

        assertEq(mockEndpoint.lastSendDstChainId(), issuerChainId);
        assertEq(mockEndpoint.lastSendDestination(), pnRegistryAddress);
        assertEq(
            keccak256(mockEndpoint.lastSendPayload()),
            keccak256(
                abi.encodeWithSignature(
                    "activateToken(bytes32,address,uint8)",
                    resourceId,
                    callbackToken,
                    uint8(SharedObjects.ErcStandard.ERC20)
                )
            )
        );
    }

    // ========== Helpers ==========

    function _buildFakeTokenData() internal pure returns (SharedObjects.TokenRegistrationData memory) {
        return SharedObjects.TokenRegistrationData({
            name: "FakeToken",
            symbol: "FAKE",
            uri: "",
            totalSupply: abi.encode(0),
            issuerChainId: CHAIN_ID,
            pnRegistryAddress: address(0xBEEF),
            bytecode: hex"00",
            initializerParams: hex"00",
            isFungible: true,
            ercStandard: SharedObjects.ErcStandard.ERC20,
            isCustom: false,
            tokenAddress: address(0x1234)
        });
    }
}
