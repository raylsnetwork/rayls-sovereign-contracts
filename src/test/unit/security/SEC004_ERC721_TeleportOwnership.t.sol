// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../../rayls-protocol/test-contracts/Erc721Example.sol";
import "../mocks/MockEndpointForSecurityTest.sol";
import {RaylsErc721Handler} from "../../../rayls-protocol-sdk/tokens/RaylsErc721Handler.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {Constants} from "../../../rayls-protocol-sdk/Constants.sol";
import {MockRaylsAppTokenRegistry} from "../mocks/MockRaylsAppTokenRegistry.sol";

/**
 * @title SEC-004: ERC721 teleport() / teleportAtomic() Missing Ownership Check
 * @notice Validates that non-owners cannot burn and teleport arbitrary ERC721 tokens.
 *
 * VULNERABILITY (before fix):
 *   teleport() and teleportAtomic() call _burn(id) without checking msg.sender == ownerOf(id).
 *   OZ ERC721._burn(uint256) passes auth=address(0), which skips the ownership check.
 *   Any address could burn and teleport any NFT they did not own.
 *
 * EXPECTED BEHAVIOR (after fix):
 *   Both functions require msg.sender to be the token owner.
 *   Both functions revert if the token is locked (lockedTokens[msg.sender][id]).
 * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
 */
contract SEC004_ERC721_TeleportOwnership is Test {
    using stdStorage for StdStorage;

    RaylsErc721Example public token;
    MockEndpointForSecurityTest public mockEndpoint;
    RaylsAccessManagerV1 public manager;

    address public owner;
    address public victim;
    address public attacker;

    uint256 constant CHAIN_ID = 12345;
    uint256 constant DEST_CHAIN_ID = 67890;
    uint256 constant PRIVATE_HUB_CHAIN_ID = 99999;
    uint256 constant TOKEN_ID = 42;

    function setUp() public {
        owner = address(this);
        victim = makeAddr("victim");
        attacker = makeAddr("attacker");

        // Deploy AccessManager
        RaylsAccessManagerV1 managerImpl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(
            address(new ERC1967Proxy(address(managerImpl), abi.encodeCall(RaylsAccessManagerV1.initialize, (owner))))
        );
        manager.registerRole("MESSAGE_EXECUTOR");
        // RaylsErc721Handler._registerAccessControl now maps crossMint/crossBurn to RELAYER, so the
        // role must exist before the token self-registers or selfRegisterManagedContract reverts.
        manager.registerRole("RELAYER");

        // Deploy mock endpoint
        mockEndpoint = new MockEndpointForSecurityTest(CHAIN_ID, PRIVATE_HUB_CHAIN_ID);
        mockEndpoint.setTrustedExecutor(owner);
        mockEndpoint.setAuthority(address(manager));
        MockRaylsAppTokenRegistry registry = new MockRaylsAppTokenRegistry();
        mockEndpoint.registerResourceId(Constants.RESOURCE_ID_TOKEN_REGISTRY, address(registry));

        // Deploy ERC721 token from victim so constructor _safeMint goes to an EOA
        vm.prank(victim);
        token = new RaylsErc721Example(
            "https://test.com/",
            "TestNFT",
            "TNFT",
            address(mockEndpoint),
            address(0),
            address(0)
        );

        // Approve the token at the hub so teleport/teleportAtomic pass the whenHubActive guard
        // and reach the ownership/lock checks these tests exercise.
        vm.prank(address(registry));
        token.setResourceId(bytes32(uint256(1)));

        // Mint TOKEN_ID to victim
        vm.prank(victim);
        token.mint(victim, TOKEN_ID);

        assertEq(token.ownerOf(TOKEN_ID), victim, "Victim should own the token");
    }

    // ═══════════════════════════════════════════════════════════════
    //  teleport() — Ownership Tests
    // ═══════════════════════════════════════════════════════════════

    function test_teleport_attackerCannotTeleportOthersToken() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsErc721Handler.RaylsErc721Handler__NotTokenOwner.selector, attacker, victim));
        token.teleport(attacker, TOKEN_ID, DEST_CHAIN_ID);

        // Token must still exist and belong to victim
        assertEq(token.ownerOf(TOKEN_ID), victim, "Victim should still own the token after failed exploit");
    }

    function test_teleport_attackerCannotBurnOthersToken() public {
        uint256 victimBalanceBefore = token.balanceOf(victim);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsErc721Handler.RaylsErc721Handler__NotTokenOwner.selector, attacker, victim));
        token.teleport(victim, TOKEN_ID, DEST_CHAIN_ID);

        assertEq(token.balanceOf(victim), victimBalanceBefore, "Victim balance should be unchanged");
        assertEq(token.ownerOf(TOKEN_ID), victim, "Victim should still own the token");
    }

    // ═══════════════════════════════════════════════════════════════
    //  teleportAtomic() — Ownership Tests
    // ═══════════════════════════════════════════════════════════════

    function test_teleportAtomic_attackerCannotTeleportOthersToken() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsErc721Handler.RaylsErc721Handler__NotTokenOwner.selector, attacker, victim));
        token.teleportAtomic(attacker, TOKEN_ID, DEST_CHAIN_ID);

        assertEq(token.ownerOf(TOKEN_ID), victim, "Victim should still own the token after failed exploit");
    }

    // ═══════════════════════════════════════════════════════════════
    //  teleport() — Lock Check Tests
    // ═══════════════════════════════════════════════════════════════

    function test_teleport_revertsOnLockedToken() public {
        // Directly set lockedTokens[victim][TOKEN_ID] = true via stdstore
        stdstore
            .target(address(token))
            .sig("isTokenLocked(address,uint256)")
            .with_key(victim)
            .with_key(TOKEN_ID)
            .checked_write(true);
        assertTrue(token.isTokenLocked(victim, TOKEN_ID), "Token should be locked");

        vm.prank(victim);
        vm.expectRevert(RaylsErc721Handler.RaylsErc721Handler__TokenAlreadyLocked.selector);
        token.teleport(victim, TOKEN_ID, DEST_CHAIN_ID);

        assertEq(token.ownerOf(TOKEN_ID), victim, "Victim should still own the locked token");
    }

    function test_teleportAtomic_revertsOnLockedToken() public {
        stdstore
            .target(address(token))
            .sig("isTokenLocked(address,uint256)")
            .with_key(victim)
            .with_key(TOKEN_ID)
            .checked_write(true);
        assertTrue(token.isTokenLocked(victim, TOKEN_ID), "Token should be locked");

        vm.prank(victim);
        vm.expectRevert(RaylsErc721Handler.RaylsErc721Handler__TokenAlreadyLocked.selector);
        token.teleportAtomic(victim, TOKEN_ID, DEST_CHAIN_ID);

        assertEq(token.ownerOf(TOKEN_ID), victim, "Victim should still own the locked token");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Edge Cases
    // ═══════════════════════════════════════════════════════════════

    function test_teleport_attackerCannotTeleportContractHeldToken() public {
        // Mint a fresh token to victim, then transfer to a third-party address
        uint256 freshId = 888;
        vm.prank(victim);
        token.mint(victim, freshId);

        address thirdParty = makeAddr("thirdParty");
        vm.prank(victim);
        token.transferFrom(victim, thirdParty, freshId);
        assertEq(token.ownerOf(freshId), thirdParty);

        // Attacker tries to teleport the third-party's token
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsErc721Handler.RaylsErc721Handler__NotTokenOwner.selector, attacker, thirdParty));
        token.teleport(attacker, freshId, DEST_CHAIN_ID);

        // Token still belongs to third party
        assertEq(token.ownerOf(freshId), thirdParty);
    }

    function test_teleport_approvedSpenderCannotTeleport() public {
        // Victim approves attacker for the token
        vm.prank(victim);
        token.approve(attacker, TOKEN_ID);

        // Approved spender should NOT be able to teleport (teleport != transfer)
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsErc721Handler.RaylsErc721Handler__NotTokenOwner.selector, attacker, victim));
        token.teleport(attacker, TOKEN_ID, DEST_CHAIN_ID);

        assertEq(token.ownerOf(TOKEN_ID), victim);
    }

    function test_teleportAtomic_approvedSpenderCannotTeleport() public {
        vm.prank(victim);
        token.approve(attacker, TOKEN_ID);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsErc721Handler.RaylsErc721Handler__NotTokenOwner.selector, attacker, victim));
        token.teleportAtomic(attacker, TOKEN_ID, DEST_CHAIN_ID);

        assertEq(token.ownerOf(TOKEN_ID), victim);
    }
}
