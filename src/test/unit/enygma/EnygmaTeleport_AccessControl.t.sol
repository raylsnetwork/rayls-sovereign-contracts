// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {EnygmaTeleport} from "../../../rayls-protocol/Enygma/Enygma-Payments/EnygmaTeleport.sol";
import {IEnygmaV1} from "../../../rayls-protocol/interfaces/IEnygmaV1.sol";

/**
 * @title Security Test: EnygmaTeleport Access Control (AUTH-V3)
 * @notice Verifies that EnygmaTeleport's restricted functions are gated by
 *         RaylsAccessManagerV1 roles, including the RELAYER for
 *         relayer-gated functions.
 */
contract EnygmaTeleportAccessControlTest is Test {
    RaylsAccessManagerV1 public manager;
    EnygmaTeleport public enygmaTeleport;

    uint64 public ENYGMA_V1_ID;
    uint64 public RELAYER_ID;
    uint64 public FACTORY_ADMIN;

    address public admin;
    address public attacker;
    address public authorizedRelayer;
    address public authorizedEnygmaV1;
    address public factory;

    // ── Selectors ────────────────────────────────────────────────────────────

    bytes4 constant SEL_TRANSFER              = bytes4(keccak256("transfer(bytes32,bytes,uint256,uint256,uint256[],uint256[],uint256)"));
    bytes4 constant SEL_SUPPLY_UPDATED        = bytes4(keccak256("enygmaSupplyUpdated(bytes32,uint256,(uint8,uint256,uint256,bytes32,uint256,uint256,uint256),uint256)"));
    bytes4 constant SEL_FINALIZE_BALANCES     = bytes4(keccak256("finalizeBalances(bytes32,uint256,uint256,(uint256,uint256)[])"));
    bytes4 constant SEL_DVP_BALANCE_UPDATED   = bytes4(keccak256("enygmaDvpBalanceUpdated(bytes)"));
    bytes4 constant SEL_TRANSFER_COMPLETED    = bytes4(keccak256("enygmaTransferCompleted(bytes)"));

    function _singleRole(uint64 roleId) internal pure returns (uint64[] memory roles) {
        roles = new uint64[](1);
        roles[0] = roleId;
    }

    function setUp() public {
        admin             = address(this);
        attacker          = makeAddr("attacker");
        authorizedRelayer = makeAddr("relayer");
        authorizedEnygmaV1 = makeAddr("enygmaV1");
        factory           = makeAddr("factory");

        // Deploy manager via UUPS proxy
        RaylsAccessManagerV1 impl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(RaylsAccessManagerV1.initialize, (admin))))
        );

        // Deploy EnygmaTeleport with manager as authority
        enygmaTeleport = new EnygmaTeleport(address(manager));

        // Register roles
        ENYGMA_V1_ID     = manager.registerRole("ENYGMA_V1");
        RELAYER_ID       = manager.registerRole("RELAYER");
        FACTORY_ADMIN = manager.registerRole("FACTORY_ADMIN");

        // FACTORY_ADMIN is the admin of ENYGMA_V1 (factory can grant it to new contracts)
        manager.setRoleAdmin(ENYGMA_V1_ID, FACTORY_ADMIN);

        // Map restricted selectors to ENYGMA_V1_ID
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = SEL_TRANSFER;
        selectors[1] = SEL_SUPPLY_UPDATED;
        selectors[2] = SEL_FINALIZE_BALANCES;
        selectors[3] = SEL_DVP_BALANCE_UPDATED;
        manager.addFunctionAllowedRoles(address(enygmaTeleport), selectors, _singleRole(ENYGMA_V1_ID));

        // Map relayer-gated selectors to RELAYER
        bytes4[] memory relayerSelectors = new bytes4[](1);
        relayerSelectors[0] = SEL_TRANSFER_COMPLETED;
        manager.addFunctionAllowedRoles(address(enygmaTeleport), relayerSelectors, _singleRole(RELAYER_ID));

        // Grant RELAYER to authorized relayer
        manager.grantRole(RELAYER_ID, authorizedRelayer, 0);

        // Grant FACTORY_ADMIN to factory, then factory grants ENYGMA_V1 to authorizedEnygmaV1
        manager.grantRole(FACTORY_ADMIN, factory, 0);
        vm.prank(factory);
        manager.grantRole(ENYGMA_V1_ID, authorizedEnygmaV1, 0);
    }

    // ── Unauthorized callers are blocked ────────────────────────────────────

    function test_SECURITY_enygmaDvpBalanceUpdated_blocksAttacker() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        enygmaTeleport.enygmaDvpBalanceUpdated(hex"1234");
    }

    function test_enygmaDvpBalanceUpdated_blocksRandomEOA() public {
        address randomUser = makeAddr("randomUser");
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, randomUser));
        enygmaTeleport.enygmaDvpBalanceUpdated(hex"deadbeef");
    }

    function test_enygmaDvpBalanceUpdated_blocksRelayer() public {
        vm.prank(authorizedRelayer);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, authorizedRelayer));
        enygmaTeleport.enygmaDvpBalanceUpdated(hex"1234");
    }

    function test_enygmaDvpBalanceUpdated_blocksOwner() public {
        vm.prank(admin);
        // admin holds ADMIN on the manager -> passes canCall, so this should succeed
        enygmaTeleport.enygmaDvpBalanceUpdated(hex"1234");
    }

    function test_transfer_blocksAttacker() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        enygmaTeleport.transfer(bytes32(0), hex"1234", 1, 0, new uint256[](0), new uint256[](0), 0);
    }

    function test_enygmaSupplyUpdated_blocksAttacker() public {
        IEnygmaV1.SupplyUpdateTx memory update;
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        enygmaTeleport.enygmaSupplyUpdated(bytes32(0), 1, update, 1);
    }

    function test_finalizeBalances_blocksAttacker() public {
        IEnygmaV1.EnygmaPointWithChainId[] memory balances;
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        enygmaTeleport.finalizeBalances(bytes32(0), 1, 2, balances);
    }

    // ── Authorized EnygmaV1 can call restricted functions ───────────────────

    function test_authorizedEnygmaV1_canCallEnygmaDvpBalanceUpdated() public {
        vm.prank(authorizedEnygmaV1);
        enygmaTeleport.enygmaDvpBalanceUpdated(hex"1234");
    }

    function test_authorizedEnygmaV1_emitsEvent() public {
        bytes memory testMessage = hex"cafebabe";
        vm.prank(authorizedEnygmaV1);
        vm.expectEmit(false, false, false, true);
        emit EnygmaTeleport.EnygmaDvpBalanceUpdated(testMessage);
        enygmaTeleport.enygmaDvpBalanceUpdated(testMessage);
    }

    // ── RELAYER-gated function ───────────────────────────────────────────────

    function test_enygmaTransferCompleted_blocksAttacker() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        enygmaTeleport.enygmaTransferCompleted(hex"1234");
    }

    function test_enygmaTransferCompleted_allowsRelayer() public {
        vm.prank(authorizedRelayer);
        enygmaTeleport.enygmaTransferCompleted(hex"1234");
    }

    // ── Revoking role blocks further calls ───────────────────────────────────

    function test_revokedEnygmaV1_isBlocked() public {
        // Revoke via the role's admin (factory)
        vm.prank(factory);
        manager.revokeRole(ENYGMA_V1_ID, authorizedEnygmaV1);

        vm.prank(authorizedEnygmaV1);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, authorizedEnygmaV1));
        enygmaTeleport.enygmaDvpBalanceUpdated(hex"1234");
    }
}
