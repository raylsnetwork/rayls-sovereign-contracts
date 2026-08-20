// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SharedObjects} from "../../../rayls-protocol-sdk/libraries/SharedObjects.sol";
import {RaylsApp} from "../../../rayls-protocol-sdk/RaylsApp.sol";
import {Constants} from "../../../rayls-protocol-sdk/Constants.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {TokenStructs} from "../../../rayls-protocol/TokenRegistry/libraries/TokenStructs.sol";
import {TokenExample} from "../../../rayls-protocol/test-contracts/TokenExample.sol";
import {RaylsErc721Example} from "../../../rayls-protocol/test-contracts/Erc721Example.sol";
import {RaylsErc1155Example} from "../../../rayls-protocol/test-contracts/Erc1155TokenExample.sol";
import {Erc721DvpExample} from "../../../rayls-protocol/test-contracts/Erc721DvpExample.sol";
import {Erc1155DvpExample} from "../../../rayls-protocol/test-contracts/Erc1155DvpExample.sol";
import {EnygmaTokenExample} from "../../../rayls-protocol/test-contracts/EnygmaTokenExample.sol";
import {MockEndpointForSecurityTest} from "../mocks/MockEndpointForSecurityTest.sol";
import {MockRaylsAppTokenRegistry} from "../mocks/MockRaylsAppTokenRegistry.sol";

contract RaylsAppStatusConstantHarness is RaylsApp {
    constructor() RaylsApp(address(0), address(0), address(0)) {}

    function privacyNodeStatusAuthorized() external pure returns (uint8) {
        return _PRIVACY_NODE_STATUS_AUTHORIZED;
    }

    function privacyNodeStatusFrozen() external pure returns (uint8) {
        return _PRIVACY_NODE_STATUS_FROZEN;
    }
}

/**
 * @title Token Handler Status Guard Tests
 * @notice Verifies that _requirePrivacyNodeActive, _requireHubActive, and _requirePublicChainActive guards
 *         block outbound operations when the PN TokenRegistry signals inactive state.
 *
 * Guards under test:
 *   - _requirePrivacyNodeActive  → local mint/transfer/approve/burn operations
 *   - _requireHubActive          → private-hub teleport/cross-chain/DvP operations
 *   - _requirePublicChainActive  → teleportToPublicChain (ERC20/721/1155)
 *
 * Also covers:
 *   - _getTokenRegistry reverts with RaylsApp__TokenRegistryNotConfigured when unregistered
 *   - setResourceId access control (unauthorized caller rejected)
 */
contract TokenHandlers_StatusGuardsTest is Test {
    uint8 internal constant PN_AUTHORIZED = 2;
    uint8 internal constant PN_FROZEN     = 4;
    uint8 internal constant PN_PENDING    = 1;

    uint256 internal constant CURRENT_CHAIN = 1001;
    uint256 internal constant DEST_CHAIN    = 3003;
    uint256 internal constant HUB_CHAIN     = 9999;

    bytes32 internal constant RESOURCE_ID = keccak256("TOKEN-RESOURCE");

    RaylsAccessManagerV1        internal manager;
    MockEndpointForSecurityTest internal endpoint;
    MockRaylsAppTokenRegistry   internal registry;

    address internal owner;
    address internal alice;

    function setUp() public {
        owner = address(this);
        alice = makeAddr("alice");

        RaylsAccessManagerV1 mgrImpl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(
            address(mgrImpl), abi.encodeCall(RaylsAccessManagerV1.initialize, (owner))
        )));
        manager.registerRole("MESSAGE_EXECUTOR");
        manager.registerRole("RELAYER");

        endpoint = new MockEndpointForSecurityTest(CURRENT_CHAIN, HUB_CHAIN);
        endpoint.setAuthority(address(manager));
        endpoint.setTrustedExecutor(owner);

        registry = new MockRaylsAppTokenRegistry();
        endpoint.registerResourceId(Constants.RESOURCE_ID_TOKEN_REGISTRY, address(registry));
    }

    // Required so the test contract can receive safe mints from constructors.
    function onERC721Received(address, address, uint256, bytes calldata)
        external pure returns (bytes4)
    {
        return this.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external pure returns (bytes4)
    {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external pure returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    function test_raylsAppPrivacyNodeStatusConstants_matchTokenStructs() public {
        RaylsAppStatusConstantHarness harness = new RaylsAppStatusConstantHarness();

        assertEq(harness.privacyNodeStatusAuthorized(), uint8(TokenStructs.PrivacyNodeStatus.AUTHORIZED));
        assertEq(harness.privacyNodeStatusFrozen(), uint8(TokenStructs.PrivacyNodeStatus.FROZEN));
    }

    /// @dev Activate a token by setting its resourceId via the registry.
    function _activateToken(address token) internal {
        vm.prank(address(registry));
        RaylsApp(token).setResourceId(RESOURCE_ID);
    }

    // ─────────────────────────────────────────────────────────────────
    //  _getTokenRegistry — configuration guard
    // ─────────────────────────────────────────────────────────────────

    function test_getTokenRegistry_revertsWhenNotConfigured() public {
        MockEndpointForSecurityTest bareEndpoint = new MockEndpointForSecurityTest(CURRENT_CHAIN, HUB_CHAIN);
        TokenExample tok = new TokenExample("T", "T", address(bareEndpoint), address(0), address(0));

        vm.expectRevert(abi.encodeWithSelector(RaylsApp.RaylsApp__TokenRegistryNotConfigured.selector));
        vm.prank(address(registry));
        tok.setResourceId(RESOURCE_ID);
    }

    // ─────────────────────────────────────────────────────────────────
    //  setResourceId — access control
    // ─────────────────────────────────────────────────────────────────

    function test_setResourceId_revertsWhenCallerIsNotRegistry() public {
        TokenExample tok = new TokenExample("T", "T", address(endpoint), address(0), address(0));
        vm.expectRevert(abi.encodeWithSelector(
            RaylsApp.RaylsApp__UnauthorizedTokenRegistry.selector,
            address(this),
            address(registry)
        ));
        tok.setResourceId(RESOURCE_ID);
    }

    function test_setResourceId_storesResourceIdWhenCallerIsRegistry() public {
        TokenExample tok = new TokenExample("T", "T", address(endpoint), address(0), address(0));
        vm.prank(address(registry));
        tok.setResourceId(RESOURCE_ID);
        assertEq(tok.resourceId(), RESOURCE_ID);
    }

    // ─────────────────────────────────────────────────────────────────
    //  ERC20 — _requireHubActive on private-hub teleport
    // ─────────────────────────────────────────────────────────────────

    function test_erc20_teleport_revertsWhenPrivacyNodeNotActive() public {
        TokenExample tok = new TokenExample("T", "T", address(endpoint), address(0), address(0));
        _activateToken(address(tok));
        registry.setPrivacyNodeStatus(address(tok), PN_PENDING);

        vm.expectRevert(abi.encodeWithSelector(
            RaylsApp.RaylsApp__HubNotActive.selector,
            address(tok),
            PN_PENDING,
            PN_AUTHORIZED
        ));
        tok.teleport(alice, 1 ether, DEST_CHAIN);
    }

    function test_erc20_teleport_revertsWhenPrivacyNodeFrozen() public {
        TokenExample tok = new TokenExample("T", "T", address(endpoint), address(0), address(0));
        _activateToken(address(tok));
        registry.setPrivacyNodeStatus(address(tok), PN_FROZEN);

        vm.expectRevert(abi.encodeWithSelector(
            RaylsApp.RaylsApp__PrivacyNodeFrozen.selector,
            address(tok)
        ));
        tok.teleport(alice, 1 ether, DEST_CHAIN);
    }

    function test_erc20_mint_revertsWhenPrivacyNodeNotActive() public {
        TokenExample tok = new TokenExample("T", "T", address(endpoint), address(0), address(0));
        _activateToken(address(tok));
        registry.setPrivacyNodeStatus(address(tok), PN_PENDING);

        vm.expectRevert(abi.encodeWithSelector(
            RaylsApp.RaylsApp__PrivacyNodeNotActive.selector,
            address(tok),
            PN_PENDING
        ));
        tok.mint(alice, 1 ether);
    }

    function test_erc20_transferAndApprove_revertWhenPrivacyNodeNotActive() public {
        TokenExample tok = new TokenExample("T", "T", address(endpoint), address(0), address(0));
        _activateToken(address(tok));
        registry.setPrivacyNodeStatus(address(tok), PN_PENDING);

        vm.expectRevert(abi.encodeWithSelector(
            RaylsApp.RaylsApp__PrivacyNodeNotActive.selector,
            address(tok),
            PN_PENDING
        ));
        tok.transfer(alice, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(
            RaylsApp.RaylsApp__PrivacyNodeNotActive.selector,
            address(tok),
            PN_PENDING
        ));
        tok.approve(alice, 1 ether);
    }

    function test_erc20_transferFrom_revertsWhenPrivacyNodeNotActive() public {
        TokenExample tok = new TokenExample("T", "T", address(endpoint), address(0), address(0));
        _activateToken(address(tok));
        tok.approve(alice, 1 ether);
        registry.setPrivacyNodeStatus(address(tok), PN_PENDING);

        vm.expectRevert(abi.encodeWithSelector(
            RaylsApp.RaylsApp__PrivacyNodeNotActive.selector,
            address(tok),
            PN_PENDING
        ));
        vm.prank(alice);
        tok.transferFrom(address(this), alice, 1 ether);
    }

    function test_erc20_burn_revertsWhenPrivacyNodeNotActive() public {
        TokenExample tok = new TokenExample("T", "T", address(endpoint), address(0), address(0));
        _activateToken(address(tok));
        registry.setPrivacyNodeStatus(address(tok), PN_PENDING);

        vm.expectRevert(abi.encodeWithSelector(
            RaylsApp.RaylsApp__PrivacyNodeNotActive.selector,
            address(tok),
            PN_PENDING
        ));
        tok.burn(address(this), 1 ether);
    }

    function test_erc20_teleport_succeedsWhenPrivacyNodeActive() public {
        TokenExample tok = new TokenExample("T", "T", address(endpoint), address(0), address(0));
        _activateToken(address(tok));
        // Default registry returns AUTHORIZED — no status guard revert.
        tok.teleport(alice, 1 ether, DEST_CHAIN);
    }

    // ─────────────────────────────────────────────────────────────────
    //  ERC20 — _requirePublicChainActive on teleportToPublicChain
    // ─────────────────────────────────────────────────────────────────

    function test_erc20_teleportToPublicChain_revertsWhenPublicChainNotActive() public {
        TokenExample tok = new TokenExample("T", "T", address(endpoint), address(0), address(0));
        _activateToken(address(tok));
        registry.setPublicChainActive(address(tok), false);
        // PN remains AUTHORIZED (default), public chain inactive → PublicChainNotActive.
        registry.setPublicChainStatus(address(tok), 1); // status = 1 (pending)

        vm.expectRevert(abi.encodeWithSelector(
            RaylsApp.RaylsApp__PublicChainNotActive.selector,
            address(tok),
            PN_AUTHORIZED,
            uint8(1)
        ));
        tok.teleportToPublicChain(alice, 1 ether, DEST_CHAIN);
    }

    function test_erc20_teleportToPublicChain_revertsWithFrozenWhenPNFrozen() public {
        TokenExample tok = new TokenExample("T", "T", address(endpoint), address(0), address(0));
        _activateToken(address(tok));
        registry.setPublicChainActive(address(tok), false);
        registry.setPrivacyNodeStatus(address(tok), PN_FROZEN);

        vm.expectRevert(abi.encodeWithSelector(
            RaylsApp.RaylsApp__PrivacyNodeFrozen.selector,
            address(tok)
        ));
        tok.teleportToPublicChain(alice, 1 ether, DEST_CHAIN);
    }

    // ─────────────────────────────────────────────────────────────────
    //  ERC721 — _requireHubActive on private-hub teleport
    // ─────────────────────────────────────────────────────────────────

    function test_erc721_teleport_revertsWhenPrivacyNodeNotActive() public {
        RaylsErc721Example tok = new RaylsErc721Example(
            "uri", "NFT721", "N721", address(endpoint), address(0), address(0)
        );
        _activateToken(address(tok));
        registry.setPrivacyNodeStatus(address(tok), PN_PENDING);

        vm.expectRevert(abi.encodeWithSelector(
            RaylsApp.RaylsApp__HubNotActive.selector,
            address(tok),
            PN_PENDING,
            PN_AUTHORIZED
        ));
        tok.teleport(alice, 0, DEST_CHAIN);
    }

    function test_erc721_mintAndApproval_revertWhenPrivacyNodeNotActive() public {
        RaylsErc721Example tok = new RaylsErc721Example(
            "uri", "NFT721", "N721", address(endpoint), address(0), address(0)
        );
        _activateToken(address(tok));
        registry.setPrivacyNodeStatus(address(tok), PN_PENDING);

        vm.expectRevert(abi.encodeWithSelector(
            RaylsApp.RaylsApp__PrivacyNodeNotActive.selector,
            address(tok),
            PN_PENDING
        ));
        tok.mint(alice, 1);

        vm.expectRevert(abi.encodeWithSelector(
            RaylsApp.RaylsApp__PrivacyNodeNotActive.selector,
            address(tok),
            PN_PENDING
        ));
        tok.approve(alice, 0);
    }

    function test_erc721_transferFrom_revertsWhenPrivacyNodeNotActive() public {
        RaylsErc721Example tok = new RaylsErc721Example(
            "uri", "NFT721", "N721", address(endpoint), address(0), address(0)
        );
        _activateToken(address(tok));
        registry.setPrivacyNodeStatus(address(tok), PN_PENDING);

        vm.expectRevert(abi.encodeWithSelector(
            RaylsApp.RaylsApp__PrivacyNodeNotActive.selector,
            address(tok),
            PN_PENDING
        ));
        tok.transferFrom(address(this), alice, 0);
    }

    function test_erc721_burn_revertsWhenPrivacyNodeNotActive() public {
        RaylsErc721Example tok = new RaylsErc721Example(
            "uri", "NFT721", "N721", address(endpoint), address(0), address(0)
        );
        _activateToken(address(tok));
        registry.setPrivacyNodeStatus(address(tok), PN_PENDING);

        vm.expectRevert(abi.encodeWithSelector(
            RaylsApp.RaylsApp__PrivacyNodeNotActive.selector,
            address(tok),
            PN_PENDING
        ));
        tok.burn(0);
    }

    function test_erc721_teleport_succeedsWhenPrivacyNodeActive() public {
        RaylsErc721Example tok = new RaylsErc721Example(
            "uri", "NFT721", "N721", address(endpoint), address(0), address(0)
        );
        _activateToken(address(tok));
        // Default: AUTHORIZED — no status guard revert.
        tok.teleport(alice, 0, DEST_CHAIN);
    }

    // ─────────────────────────────────────────────────────────────────
    //  ERC721 — _requirePublicChainActive on teleportToPublicChain
    // ─────────────────────────────────────────────────────────────────

    function test_erc721_teleportToPublicChain_revertsWhenPublicChainNotActive() public {
        RaylsErc721Example tok = new RaylsErc721Example(
            "uri", "NFT721", "N721", address(endpoint), address(0), address(0)
        );
        _activateToken(address(tok));
        registry.setPublicChainActive(address(tok), false);
        registry.setPublicChainStatus(address(tok), 1);

        vm.expectRevert(abi.encodeWithSelector(
            RaylsApp.RaylsApp__PublicChainNotActive.selector,
            address(tok),
            PN_AUTHORIZED,
            uint8(1)
        ));
        tok.teleportToPublicChain(alice, 0, DEST_CHAIN);
    }

    // ─────────────────────────────────────────────────────────────────
    //  ERC1155 — _requireHubActive on private-hub teleport
    // ─────────────────────────────────────────────────────────────────

    function test_erc1155_teleport_revertsWhenPrivacyNodeNotActive() public {
        RaylsErc1155Example tok = new RaylsErc1155Example(
            "uri", "ERC1155T", address(endpoint), address(0), address(0)
        );
        _activateToken(address(tok));
        registry.setPrivacyNodeStatus(address(tok), PN_PENDING);

        vm.expectRevert(abi.encodeWithSelector(
            RaylsApp.RaylsApp__HubNotActive.selector,
            address(tok),
            PN_PENDING,
            PN_AUTHORIZED
        ));
        tok.teleport(alice, 0, 1, DEST_CHAIN, "");
    }

    function test_erc1155_mintAndApproval_revertWhenPrivacyNodeNotActive() public {
        RaylsErc1155Example tok = new RaylsErc1155Example(
            "uri", "ERC1155T", address(endpoint), address(0), address(0)
        );
        _activateToken(address(tok));
        registry.setPrivacyNodeStatus(address(tok), PN_PENDING);

        vm.expectRevert(abi.encodeWithSelector(
            RaylsApp.RaylsApp__PrivacyNodeNotActive.selector,
            address(tok),
            PN_PENDING
        ));
        tok.mint(alice, 0, 1, "");

        vm.expectRevert(abi.encodeWithSelector(
            RaylsApp.RaylsApp__PrivacyNodeNotActive.selector,
            address(tok),
            PN_PENDING
        ));
        tok.setApprovalForAll(alice, true);
    }

    function test_erc1155_safeTransferFrom_revertsWhenPrivacyNodeNotActive() public {
        RaylsErc1155Example tok = new RaylsErc1155Example(
            "uri", "ERC1155T", address(endpoint), address(0), address(0)
        );
        _activateToken(address(tok));
        registry.setPrivacyNodeStatus(address(tok), PN_PENDING);

        vm.expectRevert(abi.encodeWithSelector(
            RaylsApp.RaylsApp__PrivacyNodeNotActive.selector,
            address(tok),
            PN_PENDING
        ));
        tok.safeTransferFrom(address(this), alice, 0, 1, "");
    }

    function test_erc1155_burn_revertsWhenPrivacyNodeNotActive() public {
        RaylsErc1155Example tok = new RaylsErc1155Example(
            "uri", "ERC1155T", address(endpoint), address(0), address(0)
        );
        _activateToken(address(tok));
        registry.setPrivacyNodeStatus(address(tok), PN_PENDING);

        vm.expectRevert(abi.encodeWithSelector(
            RaylsApp.RaylsApp__PrivacyNodeNotActive.selector,
            address(tok),
            PN_PENDING
        ));
        tok.burn(address(this), 0, 1);
    }

    function test_erc1155_teleport_succeedsWhenPrivacyNodeActive() public {
        RaylsErc1155Example tok = new RaylsErc1155Example(
            "uri", "ERC1155T", address(endpoint), address(0), address(0)
        );
        _activateToken(address(tok));
        // Default: AUTHORIZED — no status guard revert.
        tok.teleport(alice, 0, 1, DEST_CHAIN, "");
    }

    // ─────────────────────────────────────────────────────────────────
    //  ERC1155 — _requirePublicChainActive on teleportToPublicChain
    // ─────────────────────────────────────────────────────────────────

    function test_erc1155_teleportToPublicChain_revertsWhenPublicChainNotActive() public {
        RaylsErc1155Example tok = new RaylsErc1155Example(
            "uri", "ERC1155T", address(endpoint), address(0), address(0)
        );
        _activateToken(address(tok));
        registry.setPublicChainActive(address(tok), false);
        registry.setPublicChainStatus(address(tok), 1);

        vm.expectRevert(abi.encodeWithSelector(
            RaylsApp.RaylsApp__PublicChainNotActive.selector,
            address(tok),
            PN_AUTHORIZED,
            uint8(1)
        ));
        tok.teleportToPublicChain(alice, 0, 1, DEST_CHAIN, "");
    }

    // ─────────────────────────────────────────────────────────────────
    //  Enygma — _requireHubActive on _crossTransferFrom
    // ─────────────────────────────────────────────────────────────────

    function test_enygma_crossTransfer_revertsWhenPrivacyNodeNotActive() public {
        EnygmaTokenExample tok = new EnygmaTokenExample("ENYGMA", "ENY", address(endpoint));
        _activateToken(address(tok));

        address[] memory tos = new address[](1);
        tos[0] = alice;
        uint256[] memory values = new uint256[](1);
        values[0] = 1 ether;
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = DEST_CHAIN;
        SharedObjects.EnygmaProgramData[][] memory programData =
            new SharedObjects.EnygmaProgramData[][](1);
        programData[0] = new SharedObjects.EnygmaProgramData[](0);
        registry.setPrivacyNodeStatus(address(tok), PN_PENDING);

        vm.expectRevert(abi.encodeWithSelector(
            RaylsApp.RaylsApp__HubNotActive.selector,
            address(tok),
            PN_PENDING,
            PN_AUTHORIZED
        ));
        tok.crossTransfer(tos, values, chainIds, programData);
    }

    function test_enygma_crossTransferFrom_revertsWhenPrivacyNodeNotActive() public {
        EnygmaTokenExample tok = new EnygmaTokenExample("ENYGMA", "ENY", address(endpoint));
        _activateToken(address(tok));

        address[] memory tos = new address[](1);
        tos[0] = alice;
        uint256[] memory values = new uint256[](1);
        values[0] = 1 ether;
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = DEST_CHAIN;
        SharedObjects.EnygmaProgramData[][] memory programData =
            new SharedObjects.EnygmaProgramData[][](1);
        programData[0] = new SharedObjects.EnygmaProgramData[](0);

        // Keep allowance valid so the revert isolates the hub status guard.
        vm.prank(alice);
        tok.approve(address(this), type(uint256).max);
        registry.setPrivacyNodeStatus(address(tok), PN_PENDING);

        vm.expectRevert(abi.encodeWithSelector(
            RaylsApp.RaylsApp__HubNotActive.selector,
            address(tok),
            PN_PENDING,
            PN_AUTHORIZED
        ));
        tok.crossTransferFrom(alice, tos, values, chainIds, programData);
    }

    function test_enygma_mintAndTransfer_revertWhenPrivacyNodeNotActive() public {
        EnygmaTokenExample tok = new EnygmaTokenExample("ENYGMA", "ENY", address(endpoint));
        _activateToken(address(tok));
        registry.setPrivacyNodeStatus(address(tok), PN_PENDING);

        vm.expectRevert(abi.encodeWithSelector(
            RaylsApp.RaylsApp__PrivacyNodeNotActive.selector,
            address(tok),
            PN_PENDING
        ));
        tok.mint(alice, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(
            RaylsApp.RaylsApp__PrivacyNodeNotActive.selector,
            address(tok),
            PN_PENDING
        ));
        tok.transfer(alice, 1 ether);
    }

    function test_erc721Dvp_mint_revertsWhenPrivacyNodeNotActive() public {
        Erc721DvpExample tok = new Erc721DvpExample("uri", "DVP721", "D721", address(endpoint));
        _activateToken(address(tok));
        registry.setPrivacyNodeStatus(address(tok), PN_PENDING);

        SharedObjects.Dvp721ExtraData[] memory extraData = new SharedObjects.Dvp721ExtraData[](0);

        vm.expectRevert(abi.encodeWithSelector(
            RaylsApp.RaylsApp__PrivacyNodeNotActive.selector,
            address(tok),
            PN_PENDING
        ));
        tok.mint(alice, 1, extraData);
    }

    function test_erc721Dvp_MintFromSwapDvp_revertsWhenHubNotActive() public {
        Erc721DvpExample tok = new Erc721DvpExample("uri", "DVP721", "D721", address(endpoint));
        _activateToken(address(tok));
        registry.setPrivacyNodeStatus(address(tok), PN_PENDING);

        SharedObjects.Dvp721ExtraData[] memory extraData = new SharedObjects.Dvp721ExtraData[](0);

        vm.expectRevert(abi.encodeWithSelector(
            RaylsApp.RaylsApp__HubNotActive.selector,
            address(tok),
            PN_PENDING,
            PN_AUTHORIZED
        ));
        tok.MintFromSwapDvp(1, alice, extraData);
    }

    function test_erc1155Dvp_mint_revertsWhenPrivacyNodeNotActive() public {
        Erc1155DvpExample tok = new Erc1155DvpExample("uri", "DVP1155", address(endpoint));
        _activateToken(address(tok));
        registry.setPrivacyNodeStatus(address(tok), PN_PENDING);

        SharedObjects.Dvp1155ExtraData[] memory extraData = new SharedObjects.Dvp1155ExtraData[](0);

        vm.expectRevert(abi.encodeWithSelector(
            RaylsApp.RaylsApp__PrivacyNodeNotActive.selector,
            address(tok),
            PN_PENDING
        ));
        tok.mint(alice, 1, 1, "", extraData);
    }

    function test_erc1155Dvp_MintFromSwapDvp_revertsWhenHubNotActive() public {
        Erc1155DvpExample tok = new Erc1155DvpExample("uri", "DVP1155", address(endpoint));
        _activateToken(address(tok));
        registry.setPrivacyNodeStatus(address(tok), PN_PENDING);

        SharedObjects.Dvp1155ExtraData[] memory extraData = new SharedObjects.Dvp1155ExtraData[](0);

        vm.expectRevert(abi.encodeWithSelector(
            RaylsApp.RaylsApp__HubNotActive.selector,
            address(tok),
            PN_PENDING,
            PN_AUTHORIZED
        ));
        tok.MintFromSwapDvp(1, alice, 1, "", extraData);
    }
}
