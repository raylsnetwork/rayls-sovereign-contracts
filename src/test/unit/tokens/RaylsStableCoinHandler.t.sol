// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ProductionStableCoin} from "../../../rayls-protocol/prod-example-contracts/ProductionStableCoin.sol";
import {RaylsStableCoinHandler} from "../../../rayls-protocol-sdk/tokens/RaylsStableCoinHandler.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {Constants} from "../../../rayls-protocol-sdk/Constants.sol";
import {MockRaylsAppTokenRegistry} from "../mocks/MockRaylsAppTokenRegistry.sol";
import "../mocks/MockEndpointForSecurityTest.sol";

/**
 * @title RaylsStableCoinHandler behaviour
 * @notice Exercises the stablecoin surface (pause, blacklist, master-minter/controllers) on a
 *         constructor-deployed {ProductionStableCoin}. The constructor path registers owner-gated
 *         selectors to `msg.sender` (= this test), so `this` acts as TOKEN_OWNER and can call the
 *         restricted compliance functions.
 */
contract RaylsStableCoinHandlerTest is Test {
    ProductionStableCoin internal token;
    MockEndpointForSecurityTest internal endpoint;

    address internal owner;
    address internal minter = makeAddr("minter");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    uint256 constant CHAIN_ID = 12345;
    uint256 constant HUB_CHAIN_ID = 99999;

    function setUp() public {
        owner = address(this);

        endpoint = new MockEndpointForSecurityTest(CHAIN_ID, HUB_CHAIN_ID);
        endpoint.setTrustedExecutor(owner);

        RaylsAccessManagerV1 mgrImpl = new RaylsAccessManagerV1();
        RaylsAccessManagerV1 manager = RaylsAccessManagerV1(address(new ERC1967Proxy(
            address(mgrImpl), abi.encodeCall(RaylsAccessManagerV1.initialize, (owner))
        )));
        manager.registerRole("RELAYER");
        manager.registerRole("MESSAGE_EXECUTOR");
        endpoint.setAuthority(address(manager));

        MockRaylsAppTokenRegistry registry = new MockRaylsAppTokenRegistry();
        endpoint.registerResourceId(Constants.RESOURCE_ID_TOKEN_REGISTRY, address(registry));

        token = new ProductionStableCoin("Rayls USD", "rUSD", address(endpoint), address(0), address(0));

        // Activate the token (non-zero resourceId) for any hub-gated compliance paths.
        vm.prank(address(registry));
        token.setResourceId(bytes32(uint256(1)));

        token.mint(owner, 1_000_000);
    }

    // ── metadata ────────────────────────────────────────────────────────

    function test_metadata() public view {
        assertEq(token.name(), "Rayls USD");
        assertEq(token.symbol(), "rUSD");
        assertEq(token.masterMinter(), owner);
        assertEq(token.pauser(), owner);
        assertEq(token.blacklister(), owner);
    }

    // ── pause ───────────────────────────────────────────────────────────

    function test_pause_blocksTransfers() public {
        token.transfer(alice, 100); // works while unpaused
        token.pause();
        assertTrue(token.paused());

        vm.expectRevert(RaylsStableCoinHandler.RaylsStableCoin__Paused.selector);
        token.transfer(bob, 1);
    }

    function test_unpause_restoresTransfers() public {
        token.pause();
        token.unpause();
        assertFalse(token.paused());
        token.transfer(alice, 100);
        assertEq(token.balanceOf(alice), 100);
    }

    function test_pause_onlyPauser() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RaylsStableCoinHandler.RaylsStableCoin__NotPauser.selector, stranger));
        token.pause();
    }

    // ── blacklist ───────────────────────────────────────────────────────

    function test_blacklist_blocksSendAndReceive() public {
        token.transfer(alice, 100);

        token.blacklist(alice);
        assertTrue(token.isBlacklisted(alice));

        // alice cannot send
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RaylsStableCoinHandler.RaylsStableCoin__Blacklisted.selector, alice));
        token.transfer(bob, 1);

        // nobody can send TO alice
        vm.expectRevert(abi.encodeWithSelector(RaylsStableCoinHandler.RaylsStableCoin__Blacklisted.selector, alice));
        token.transfer(alice, 1);
    }

    function test_unBlacklist_restores() public {
        token.blacklist(alice);
        token.unBlacklist(alice);
        assertFalse(token.isBlacklisted(alice));
        token.transfer(alice, 100);
        assertEq(token.balanceOf(alice), 100);
    }

    function test_blacklist_zeroAddressReverts() public {
        vm.expectRevert(RaylsStableCoinHandler.RaylsStableCoin__ZeroAddress.selector);
        token.blacklist(address(0));
    }

    function test_unBlacklist_zeroAddressReverts() public {
        vm.expectRevert(RaylsStableCoinHandler.RaylsStableCoin__ZeroAddress.selector);
        token.unBlacklist(address(0));
    }

    function test_blacklist_onlyBlacklister() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RaylsStableCoinHandler.RaylsStableCoin__NotBlacklister.selector, stranger));
        token.blacklist(alice);
    }

    // ── master-minter / controllers ─────────────────────────────────────

    function test_configureMinter_grantsAllowance() public {
        token.configureMinter(minter, 500);
        assertTrue(token.isMinter(minter));
        assertEq(token.minterAllowance(minter), 500);
    }

    function test_mintByMinter_decrementsAllowance() public {
        token.configureMinter(minter, 500);

        vm.prank(minter);
        token.mintByMinter(alice, 200);

        assertEq(token.balanceOf(alice), 200);
        assertEq(token.minterAllowance(minter), 300);
    }

    function test_mintByMinter_overAllowanceReverts() public {
        token.configureMinter(minter, 100);

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(
            RaylsStableCoinHandler.RaylsStableCoin__MintAllowanceExceeded.selector, minter, uint256(100), uint256(101)
        ));
        token.mintByMinter(alice, 101);
    }

    function test_mintByMinter_nonMinterReverts() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RaylsStableCoinHandler.RaylsStableCoin__NotMinter.selector, stranger));
        token.mintByMinter(alice, 1);
    }

    function test_removeMinter_revokes() public {
        token.configureMinter(minter, 500);
        token.removeMinter(minter);
        assertFalse(token.isMinter(minter));
        assertEq(token.minterAllowance(minter), 0);

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(RaylsStableCoinHandler.RaylsStableCoin__NotMinter.selector, minter));
        token.mintByMinter(alice, 1);
    }

    function test_configureMinter_onlyMasterMinter() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RaylsStableCoinHandler.RaylsStableCoin__NotMasterMinter.selector, stranger));
        token.configureMinter(minter, 500);
    }

    function test_removeMinter_zeroAddressReverts() public {
        vm.expectRevert(RaylsStableCoinHandler.RaylsStableCoin__ZeroAddress.selector);
        token.removeMinter(address(0));
    }

    // ── blacklist interacts with minting ────────────────────────────────

    // A blacklisted minter must not keep inflating supply: `_update` skips the `from` blacklist check on
    // mints (from == address(0)), so `mintByMinter` guards `msg.sender` itself (Circle FiatToken parity).
    function test_mintByMinter_blockedWhenMinterBlacklisted() public {
        token.configureMinter(minter, 500);
        token.blacklist(minter);

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(RaylsStableCoinHandler.RaylsStableCoin__Blacklisted.selector, minter));
        token.mintByMinter(alice, 1);
    }

    // ── pause interacts with minting ────────────────────────────────────

    function test_mintByMinter_blockedWhilePaused() public {
        token.configureMinter(minter, 500);
        token.pause();

        vm.prank(minter);
        vm.expectRevert(RaylsStableCoinHandler.RaylsStableCoin__Paused.selector);
        token.mintByMinter(alice, 1);
    }

    // ── role reassignment (Circle-style: owner reassigns; new holder self-gates) ──────

    function test_updatePauser_reassignsGate() public {
        // owner (TOKEN_OWNER) reassigns the pauser role to `stranger`.
        token.updatePauser(stranger);
        assertEq(token.pauser(), stranger);

        // The old holder (owner) can no longer pause.
        vm.expectRevert(abi.encodeWithSelector(RaylsStableCoinHandler.RaylsStableCoin__NotPauser.selector, owner));
        token.pause();

        // The new holder can.
        vm.prank(stranger);
        token.pause();
        assertTrue(token.paused());
    }

    function test_updateBlacklister_reassignsGate() public {
        token.updateBlacklister(stranger);
        assertEq(token.blacklister(), stranger);

        vm.expectRevert(abi.encodeWithSelector(RaylsStableCoinHandler.RaylsStableCoin__NotBlacklister.selector, owner));
        token.blacklist(alice);

        vm.prank(stranger);
        token.blacklist(alice);
        assertTrue(token.isBlacklisted(alice));
    }

    function test_updateMasterMinter_reassignsGate() public {
        token.updateMasterMinter(stranger);
        assertEq(token.masterMinter(), stranger);

        vm.expectRevert(abi.encodeWithSelector(RaylsStableCoinHandler.RaylsStableCoin__NotMasterMinter.selector, owner));
        token.configureMinter(minter, 500);

        vm.prank(stranger);
        token.configureMinter(minter, 500);
        assertTrue(token.isMinter(minter));
    }

    function test_updateRole_onlyOwner() public {
        // The update* setters ARE owner-gated (AccessManager TOKEN_OWNER).
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, stranger));
        token.updatePauser(stranger);
    }

    function test_updateRole_zeroAddressReverts() public {
        vm.expectRevert(RaylsStableCoinHandler.RaylsStableCoin__ZeroAddress.selector);
        token.updatePauser(address(0));
    }

    // ── _update ordering: pause is reported BEFORE blacklist (Circle order) ──────────
    // Circle's FiatToken runs `whenNotPaused` before `notBlacklisted(...)`, so when both hold the
    // caller sees the pause error, not the blacklist error.

    function test_update_pauseReportedBeforeBlacklist() public {
        token.transfer(alice, 100);
        token.blacklist(alice);
        token.pause();

        vm.prank(alice);
        vm.expectRevert(RaylsStableCoinHandler.RaylsStableCoin__Paused.selector);
        token.transfer(bob, 1);
    }
}
