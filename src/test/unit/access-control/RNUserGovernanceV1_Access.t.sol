// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RNUserGovernanceV1} from "../../../rayls-node/rayls-privacy-node/RNUserGovernanceV1.sol";
import {IUserGovernance} from "../../../rayls-node/rayls-privacy-node/interfaces/IUserGovernanceV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";

// ─── Mock authority ───────────────────────────────────────────────────────────

contract MockAuthority_UG {
    mapping(address => bool) private _allowed;

    function allow(address who) external { _allowed[who] = true; }
    function deny(address who) external { _allowed[who] = false; }

    function canCall(address caller, address, bytes4) external view returns (bool, uint32, bool) {
        return (_allowed[caller], 0, false);
    }
}

/**
 * @title RNUserGovernanceV1 Access Control Tests
 * @notice Verifies that all seven governance functions are gated by `restricted`
 *         and that the authority bootstrap works correctly.
 */
contract RNUserGovernanceV1AccessTest is Test {
    RNUserGovernanceV1 public gov;
    MockAuthority_UG public auth;

    address public admin;
    address public attacker;

    bytes32 constant USER_ID = keccak256("user1");

    function setUp() public {
        admin    = makeAddr("admin");
        attacker = makeAddr("attacker");
        auth     = new MockAuthority_UG();
        auth.allow(address(this));

        // Deploy through proxy (constructor has _disableInitializers)
        RNUserGovernanceV1 impl = new RNUserGovernanceV1();
        bytes memory initData = abi.encodeCall(RNUserGovernanceV1.initialize, (address(auth)));
        gov = RNUserGovernanceV1(address(new ERC1967Proxy(address(impl), initData)));
    }

    // ─── authority ───────────────────────────────────────────────────────────

    function test_authority_isSet() public view {
        assertEq(gov.authority(), address(auth));
    }

    function test_initialize_cannotBeCalledTwice() public {
        vm.expectRevert();
        gov.initialize(address(auth));
    }

    // ─── createUser ──────────────────────────────────────────────────────────

    function test_createUser_allowed_succeeds() public {
        gov.createUser(USER_ID);
        assertTrue(gov.userExists(USER_ID));
    }

    function test_createUser_denied_reverts() public {
        auth.deny(address(this));
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, address(this)));
        gov.createUser(USER_ID);
    }

    function test_createUser_attacker_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        gov.createUser(USER_ID);
    }

    // ─── addAddressPair ──────────────────────────────────────────────────────

    function test_addAddressPair_allowed_succeeds() public {
        gov.createUser(USER_ID);
        address pub = makeAddr("pub");
        address priv = makeAddr("priv");
        gov.addAddressPair(USER_ID, pub, priv);
        assertEq(gov.getUserAddressPairCount(USER_ID), 1);
    }

    function test_addAddressPair_denied_reverts() public {
        gov.createUser(USER_ID);
        auth.deny(address(this));
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, address(this)));
        gov.addAddressPair(USER_ID, makeAddr("pub"), makeAddr("priv"));
    }

    // ─── removeAddressPair ───────────────────────────────────────────────────

    function test_removeAddressPair_denied_reverts() public {
        address pub = makeAddr("pub2");
        address priv = makeAddr("priv2");
        gov.createUser(USER_ID);
        gov.addAddressPair(USER_ID, pub, priv);

        auth.deny(address(this));
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, address(this)));
        gov.removeAddressPair(USER_ID, pub, priv);
    }

    function test_removeAddressPair_allowed_succeeds() public {
        address pub = makeAddr("pub2");
        address priv = makeAddr("priv2");
        gov.createUser(USER_ID);
        gov.addAddressPair(USER_ID, pub, priv);
        gov.removeAddressPair(USER_ID, pub, priv);
        assertEq(gov.getUserAddressPairCount(USER_ID), 0);
    }

    // ─── approveUser ─────────────────────────────────────────────────────────

    function test_approveUser_allowed_succeeds() public {
        gov.createUser(USER_ID);
        gov.addAddressPair(USER_ID, makeAddr("p"), makeAddr("q"));
        gov.approveUser(USER_ID);
        assertEq(gov.getApprovedAddressPairCount(USER_ID), 1);
    }

    function test_approveUser_denied_reverts() public {
        gov.createUser(USER_ID);
        gov.addAddressPair(USER_ID, makeAddr("p"), makeAddr("q"));

        auth.deny(address(this));
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, address(this)));
        gov.approveUser(USER_ID);
    }

    // ─── rejectUser ──────────────────────────────────────────────────────────

    function test_rejectUser_allowed_succeeds() public {
        gov.createUser(USER_ID);
        gov.addAddressPair(USER_ID, makeAddr("p"), makeAddr("q"));
        gov.rejectUser(USER_ID);
        assertEq(gov.getPendingAddressPairCount(USER_ID), 0);
    }

    function test_rejectUser_denied_reverts() public {
        gov.createUser(USER_ID);
        gov.addAddressPair(USER_ID, makeAddr("p"), makeAddr("q"));

        auth.deny(address(this));
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, address(this)));
        gov.rejectUser(USER_ID);
    }

    // ─── setAddressPairApprovalStatus ────────────────────────────────────────

    function test_setAddressPairApprovalStatus_allowed_succeeds() public {
        address pub = makeAddr("pub3");
        address priv = makeAddr("priv3");
        gov.createUser(USER_ID);
        gov.addAddressPair(USER_ID, pub, priv);
        gov.setAddressPairApprovalStatus(USER_ID, pub, priv, IUserGovernance.ApprovalStatus.APPROVED);
        assertTrue(gov.isAddressPairApproved(USER_ID, pub, priv));
    }

    function test_setAddressPairApprovalStatus_denied_reverts() public {
        address pub = makeAddr("pub3");
        address priv = makeAddr("priv3");
        gov.createUser(USER_ID);
        gov.addAddressPair(USER_ID, pub, priv);

        auth.deny(address(this));
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, address(this)));
        gov.setAddressPairApprovalStatus(USER_ID, pub, priv, IUserGovernance.ApprovalStatus.APPROVED);
    }

    // ─── removeUser ──────────────────────────────────────────────────────────

    function test_removeUser_allowed_succeeds() public {
        gov.createUser(USER_ID);
        gov.removeUser(USER_ID);
        assertFalse(gov.userExists(USER_ID));
    }

    function test_removeUser_denied_reverts() public {
        gov.createUser(USER_ID);

        auth.deny(address(this));
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, address(this)));
        gov.removeUser(USER_ID);
    }

    // ─── View functions are unrestricted ─────────────────────────────────────

    function test_viewFunctions_anyCallerCanRead() public view {
        gov.getUserCount();
        gov.getAllUsers();
        gov.userExists(USER_ID);
        gov.isPublicAddressMapped(address(0xdead));
    }
}
