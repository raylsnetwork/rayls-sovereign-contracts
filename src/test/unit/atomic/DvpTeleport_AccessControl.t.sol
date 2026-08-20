// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {DvpTeleport} from "../../../rayls-protocol/Enygma/Enygma-DVP/DvpTeleport.sol";

/**
 * @title Security Test: DvpTeleport Access Control (AUTH-V3)
 * @notice Verifies that DvpTeleport's restricted functions are gated by
 *         RaylsAccessManagerV1 roles.
 *
 * Role layout:
 *   FACTORY_ADMIN_ID — admin of COIN_VAULT_ID and DVP_CONTRACT_ID.
 *   COIN_VAULT_ID    — required for emitCommitments / emitNullifiers.
 *   DVP_CONTRACT_ID  — required for emitSwapInitiated, emitSwapCompleted,
 *                       emitSwapCancelled, emitSwapTimedOut, ercDvpBalanceUpdated.
 */
contract DvpTeleportAccessControlTest is Test {
    RaylsAccessManagerV1 public manager;
    DvpTeleport public dvpTeleport;

    uint64 public COIN_VAULT_ID;
    uint64 public DVP_CONTRACT_ID;
    uint64 public FACTORY_ADMIN_ID;

    address public admin;
    address public attacker;
    address public authorizedCoinVault;
    address public authorizedDvpContract;
    address public factory;

    bytes32 constant SHARED_ID = keccak256("test-swap-id");

    // ── Selectors ────────────────────────────────────────────────────────────

    bytes4 constant SEL_EMIT_COMMITMENTS    = bytes4(keccak256("emitCommitments(address,uint256,uint256,uint256[])"));
    bytes4 constant SEL_EMIT_NULLIFIERS     = bytes4(keccak256("emitNullifiers(address,uint256,uint256[])"));
    bytes4 constant SEL_ERC_DVP_BAL_UPDATED = bytes4(keccak256("ercDvpBalanceUpdated(bytes)"));
    bytes4 constant SEL_EMIT_SWAP_INITIATED = bytes4(keccak256("emitSwapInitiated(bytes32,bytes,bytes,uint256,uint256)"));
    bytes4 constant SEL_EMIT_SWAP_COMPLETED = bytes4(keccak256("emitSwapCompleted(bytes32,bytes)"));
    bytes4 constant SEL_EMIT_SWAP_CANCELLED = bytes4(keccak256("emitSwapCancelled(bytes32)"));
    bytes4 constant SEL_EMIT_SWAP_TIMED_OUT = bytes4(keccak256("emitSwapTimedOut(bytes32)"));

    function _singleRole(uint64 roleId) internal pure returns (uint64[] memory roles) {
        roles = new uint64[](1);
        roles[0] = roleId;
    }

    function setUp() public {
        admin               = address(this);
        attacker            = makeAddr("attacker");
        authorizedCoinVault = makeAddr("coinVault");
        authorizedDvpContract = makeAddr("dvpContract");
        factory             = makeAddr("factory");

        // Deploy manager via UUPS proxy
        RaylsAccessManagerV1 impl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(RaylsAccessManagerV1.initialize, (admin))))
        );

        // Deploy DvpTeleport with manager as authority
        dvpTeleport = new DvpTeleport(address(manager));

        // Register roles
        COIN_VAULT_ID    = manager.registerRole("COIN_VAULT");
        DVP_CONTRACT_ID  = manager.registerRole("DVP_CONTRACT");
        FACTORY_ADMIN_ID = manager.registerRole("FACTORY_ADMIN");

        // FACTORY_ADMIN is the admin of both COIN_VAULT and DVP_CONTRACT
        manager.setRoleAdmin(COIN_VAULT_ID,   FACTORY_ADMIN_ID);
        manager.setRoleAdmin(DVP_CONTRACT_ID, FACTORY_ADMIN_ID);

        // Map CoinVault selectors
        bytes4[] memory coinVaultSelectors = new bytes4[](2);
        coinVaultSelectors[0] = SEL_EMIT_COMMITMENTS;
        coinVaultSelectors[1] = SEL_EMIT_NULLIFIERS;
        manager.addFunctionAllowedRoles(address(dvpTeleport), coinVaultSelectors, _singleRole(COIN_VAULT_ID));

        // Map DVP contract selectors
        bytes4[] memory dvpSelectors = new bytes4[](5);
        dvpSelectors[0] = SEL_ERC_DVP_BAL_UPDATED;
        dvpSelectors[1] = SEL_EMIT_SWAP_INITIATED;
        dvpSelectors[2] = SEL_EMIT_SWAP_COMPLETED;
        dvpSelectors[3] = SEL_EMIT_SWAP_CANCELLED;
        dvpSelectors[4] = SEL_EMIT_SWAP_TIMED_OUT;
        manager.addFunctionAllowedRoles(address(dvpTeleport), dvpSelectors, _singleRole(DVP_CONTRACT_ID));

        // Grant FACTORY_ADMIN_ID to factory
        manager.grantRole(FACTORY_ADMIN_ID, factory, 0);

        // Factory grants COIN_VAULT to authorizedCoinVault
        vm.prank(factory);
        manager.grantRole(COIN_VAULT_ID, authorizedCoinVault, 0);

        // Factory grants DVP_CONTRACT to authorizedDvpContract
        vm.prank(factory);
        manager.grantRole(DVP_CONTRACT_ID, authorizedDvpContract, 0);
    }

    // ── DVP_CONTRACT restricted functions block unauthorized callers ─────────

    function test_emitSwapInitiated_blocksAttacker() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        dvpTeleport.emitSwapInitiated(SHARED_ID, bytes("enc"), bytes("ctxt"), 123, 1000);
    }

    function test_emitSwapCompleted_blocksAttacker() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        dvpTeleport.emitSwapCompleted(SHARED_ID, bytes("enc"));
    }

    function test_emitSwapCancelled_blocksAttacker() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        dvpTeleport.emitSwapCancelled(SHARED_ID);
    }

    function test_emitSwapTimedOut_blocksAttacker() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        dvpTeleport.emitSwapTimedOut(SHARED_ID);
    }

    function test_ercDvpBalanceUpdated_blocksAttacker() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        dvpTeleport.ercDvpBalanceUpdated(bytes("fake"));
    }

    // ── COIN_VAULT restricted functions block unauthorized callers ───────────

    function test_SECURITY_emitCommitments_blocksAttacker() public {
        uint256[] memory fakeCommitments = new uint256[](2);
        fakeCommitments[0] = 111111;
        fakeCommitments[1] = 222222;

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        dvpTeleport.emitCommitments(address(0x1234), 1, 0, fakeCommitments);
    }

    function test_SECURITY_emitNullifiers_blocksAttacker() public {
        uint256[] memory nullifiers = new uint256[](1);
        nullifiers[0] = 999999;

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        dvpTeleport.emitNullifiers(address(0x1234), 1, nullifiers);
    }

    // ── Cross-role isolation ────────────────────────────────────────────────

    function test_coinVault_cannotCallDvpContractFunctions() public {
        vm.startPrank(authorizedCoinVault);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, authorizedCoinVault));
        dvpTeleport.emitSwapCancelled(SHARED_ID);
        vm.stopPrank();
    }

    function test_dvpContract_cannotCallCoinVaultFunctions() public {
        uint256[] memory commitments = new uint256[](1);
        commitments[0] = 123;

        vm.startPrank(authorizedDvpContract);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, authorizedDvpContract));
        dvpTeleport.emitCommitments(address(0x1234), 1, 0, commitments);
        vm.stopPrank();
    }

    // ── Authorized actors can call their respective functions ────────────────

    function test_authorizedDvpContract_canEmitSwapEvents() public {
        vm.startPrank(authorizedDvpContract);
        dvpTeleport.emitSwapInitiated(SHARED_ID, bytes("enc"), bytes("ctxt"), 123, 1000);
        dvpTeleport.emitSwapCompleted(SHARED_ID, bytes("enc"));
        dvpTeleport.emitSwapCancelled(SHARED_ID);
        dvpTeleport.emitSwapTimedOut(SHARED_ID);
        dvpTeleport.ercDvpBalanceUpdated(bytes("data"));
        vm.stopPrank();
    }

    function test_authorizedCoinVault_canEmitCommitments() public {
        uint256[] memory commitments = new uint256[](2);
        commitments[0] = 123;
        commitments[1] = 456;

        vm.prank(authorizedCoinVault);
        dvpTeleport.emitCommitments(address(0x1234), 1, 0, commitments);
    }

    function test_authorizedCoinVault_canEmitNullifiers() public {
        uint256[] memory nullifiers = new uint256[](1);
        nullifiers[0] = 789;

        vm.prank(authorizedCoinVault);
        dvpTeleport.emitNullifiers(address(0x1234), 1, nullifiers);
    }

    // ── Revoking role blocks further calls ───────────────────────────────────

    function test_revokedCoinVault_isBlocked() public {
        vm.prank(factory);
        manager.revokeRole(COIN_VAULT_ID, authorizedCoinVault);

        uint256[] memory commitments = new uint256[](1);
        commitments[0] = 1;

        vm.prank(authorizedCoinVault);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, authorizedCoinVault));
        dvpTeleport.emitCommitments(address(0x1234), 1, 0, commitments);
    }

    function test_revokedDvpContract_isBlocked() public {
        vm.prank(factory);
        manager.revokeRole(DVP_CONTRACT_ID, authorizedDvpContract);

        vm.prank(authorizedDvpContract);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, authorizedDvpContract));
        dvpTeleport.emitSwapInitiated(SHARED_ID, bytes("enc"), bytes("ctxt"), 123, 1000);
    }
}
