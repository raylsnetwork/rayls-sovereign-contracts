// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {PNCommunicatorV1} from "../../../rayls-protocol/PNCommunicator/PNCommunicatorV1.sol";

/**
 * @title Security Test: PNCommunicatorV1 Access Control (AUTH-V3)
 * @notice Verifies that addSharedInfo, removeSharedInfo, and removeSharedInfoAt
 *         are gated by AUTH-V3 `restricted`.
 *
 * After the AUTH-V3 migration:
 *   - addSharedInfo: protected by `restricted` — requires ENDPOINT_SENDER_ID or ADMIN.
 *   - removeSharedInfo / removeSharedInfoAt: protected by `restricted` — requires ADMIN.
 *   - Unauthorized callers get RaylsAccessManaged__Unauthorized for all restricted functions.
 */
contract PNCommunicatorV1AccessControlTest is Test {
    RaylsAccessManagerV1 public manager;
    PNCommunicatorV1 public communicator;

    address public admin;  // ADMIN on manager; owns PNCommunicator
    address public caller; // ENDPOINT_SENDER_ID — may call addSharedInfo
    address public attacker;

    bytes32 constant SHARED_ID = bytes32(uint256(42));

    function _singleRole(uint64 roleId) internal pure returns (uint64[] memory roles) {
        roles = new uint64[](1);
        roles[0] = roleId;
    }

    function setUp() public {
        admin    = address(this);
        caller   = makeAddr("caller");
        attacker = makeAddr("attacker");

        // Deploy manager proxy
        RaylsAccessManagerV1 impl = new RaylsAccessManagerV1();
        bytes memory initData = abi.encodeCall(RaylsAccessManagerV1.initialize, (admin));
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(address(impl), initData)));

        // Deploy PNCommunicatorV1 proxy
        PNCommunicatorV1 pnImpl = new PNCommunicatorV1();
        bytes memory pnInit = abi.encodeWithSelector(
            PNCommunicatorV1.initialize.selector,
            address(0), // endpoint not needed for this test
            address(manager)
        );
        communicator = PNCommunicatorV1(address(new ERC1967Proxy(address(pnImpl), pnInit)));

        // Register ENDPOINT_SENDER role, map addSharedInfo selector, grant to caller
        uint64 senderRole = manager.registerRole("ENDPOINT_SENDER");
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PNCommunicatorV1.addSharedInfo.selector;
        manager.addFunctionAllowedRoles(address(communicator), selectors, _singleRole(senderRole));
        manager.grantRole(senderRole, caller, 0);
    }

    // ── addSharedInfo (restricted) ─────────────────────────────────────────

    function test_addSharedInfo_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker)
        );
        communicator.addSharedInfo(SHARED_ID, 1, 0, "test");
    }

    function test_addSharedInfo_roleHolderSucceeds() public {
        vm.prank(caller);
        communicator.addSharedInfo(SHARED_ID, 1, 0, "test");
    }

    function test_addSharedInfo_adminSucceeds() public {
        // admin = address(this), ADMIN bypasses all selector mappings
        communicator.addSharedInfo(SHARED_ID, 1, 0, "admin entry");
    }

    // ── removeSharedInfo / removeSharedInfoAt (restricted) ─────────────────

    function test_removeSharedInfo_attackerReverts() public {
        communicator.addSharedInfo(SHARED_ID, 1, 0, "test");

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        communicator.removeSharedInfo(SHARED_ID);
    }

    function test_removeSharedInfoAt_attackerReverts() public {
        communicator.addSharedInfo(SHARED_ID, 1, 0, "test");

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        communicator.removeSharedInfoAt(SHARED_ID, 0);
    }

    function test_removeSharedInfo_ownerSucceeds() public {
        communicator.addSharedInfo(SHARED_ID, 1, 0, "test");
        communicator.removeSharedInfo(SHARED_ID);
    }

    function test_removeSharedInfoAt_ownerSucceeds() public {
        communicator.addSharedInfo(SHARED_ID, 1, 0, "test");
        communicator.removeSharedInfoAt(SHARED_ID, 0);
    }

    // ── role revocation immediately blocks caller ──────────────────────────

    function test_revokeRole_blocksSubsequentCalls() public {
        vm.prank(caller);
        communicator.addSharedInfo(SHARED_ID, 1, 0, "first");

        uint64 senderRole = manager.getRoleIdByName("ENDPOINT_SENDER");
        manager.revokeRole(senderRole, caller);

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, caller)
        );
        communicator.addSharedInfo(SHARED_ID, 2, 0, "second");
    }
}
