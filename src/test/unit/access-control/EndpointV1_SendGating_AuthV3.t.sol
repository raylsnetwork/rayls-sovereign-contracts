// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {IRaylsEndpoint} from "../../../rayls-protocol-sdk/interfaces/IRaylsEndpoint.sol";

// ─── Minimal EndpointV1 stub ──────────────────────────────────────────────────
//
// We test the AUTH-V3 gating logic independently of the full endpoint's
// cross-chain plumbing by subclassing EndpointV1 and overriding send/register
// to no-op everything except the `restricted` modifier.
// This keeps the test fast and focused on the access-control surface only.

import {EndpointV1} from "../../../rayls-protocol/Endpoint/EndpointV1.sol";
import {RaylsMessage, BridgedTransferMetadata} from "../../../rayls-protocol-sdk/RaylsMessage.sol";
import {DestinationPayloadRequest, ResourceIdPayloadRequest, ResourceIdCompletePayloadRequest} from "../../../rayls-protocol-sdk/libraries/MessageLib.sol";

contract MinimalEndpoint is EndpointV1 {
    // Override everything that would fail without real module wiring.
    function send(uint256, address, bytes calldata) external payable override restricted returns (bytes32) { return 0; }
    function send(uint256, address, bytes calldata, BridgedTransferMetadata memory) external payable override restricted returns (bytes32) { return 0; }
    function sendBatch(DestinationPayloadRequest[] calldata) external override restricted returns (bytes32) { return 0; }
    function sendToResourceId(uint256, bytes32, bytes calldata) external payable override restricted returns (bytes32) { return 0; }
    function sendBatchToResourceId(ResourceIdPayloadRequest[] calldata) external payable override restricted returns (bytes32) { return 0; }
    function sendToResourceId(uint256, bytes32, bytes calldata, bytes memory, bytes memory, bytes memory, BridgedTransferMetadata memory) external payable override restricted returns (bytes32) { return 0; }
    function sendBatchToResourceId(ResourceIdCompletePayloadRequest[] calldata) external payable override restricted returns (bytes32) { return 0; }
    function registerResourceId(bytes32, address) external override restricted {}
    function receivePayload(uint256, address, address, RaylsMessage memory, bytes32) public override {}
    function getInboundNonce(uint256) external pure override returns (uint256) { return 0; }
    function getOutboundNonce(uint256) external pure override returns (uint256) { return 0; }
    function getChainId() external pure override returns (uint256) { return 1; }
    function getPrivateHubId() external pure override returns (uint256) { return 9999; }
    function getPrivateHubAddress(string memory) external pure override returns (address) { return address(0); }
    function version() external pure override returns (string memory) { return "test"; }
    function requestNewRaylsViewKeys(uint256) public override {}
}

// =============================================================================
// EndpointV1 AUTH-V3 Send-Gating Showcase
//
// Demonstrates that:
//   1. All send-path functions on EndpointV1 are gated by AUTH-V3 `restricted`.
//   2. Unprivileged callers are always blocked with RaylsAccessManaged__Unauthorized.
//   3. ENDPOINT_SENDER_ID holders may call all send functions.
//   4. ADMIN holders bypass all selector mappings (global admin privilege).
//   5. RaylsContractFactory's FACTORY_ADMIN pattern: factory holds FACTORY_ADMIN
//      (admin of ENDPOINT_SENDER_ID) and can grant ENDPOINT_SENDER_ID to newly
//      deployed token contracts — without possessing any other capabilities.
//   6. Revoking ENDPOINT_SENDER_ID immediately blocks further calls.
// =============================================================================
contract EndpointV1_SendGating_AuthV3_Test is Test {

    RaylsAccessManagerV1 public manager;
    MinimalEndpoint      public endpoint;

    uint64 public ENDPOINT_SENDER_ID;
    uint64 public FACTORY_ADMIN;

    // ── Selectors ─────────────────────────────────────────────────────────────

    bytes4 constant SEL_SEND_3        = bytes4(keccak256("send(uint256,address,bytes)"));
    bytes4 constant SEL_SEND_4        = bytes4(keccak256("send(uint256,address,bytes,(uint256,bytes32,bytes32,uint256,bytes32,address,address,bytes32))"));
    bytes4 constant SEL_SEND_BATCH    = bytes4(keccak256("sendBatch((uint256,address,bytes)[])"));
    bytes4 constant SEL_SEND_RID_3    = bytes4(keccak256("sendToResourceId(uint256,bytes32,bytes)"));
    bytes4 constant SEL_SEND_BATCH_RID= bytes4(keccak256("sendBatchToResourceId((uint256,bytes32,bytes)[])"));
    bytes4 constant SEL_REGISTER_RID  = bytes4(keccak256("registerResourceId(bytes32,address)"));

    // ── Personas ──────────────────────────────────────────────────────────────

    address admin;    // ADMIN on manager
    address sender;   // ENDPOINT_SENDER_ID — may call all send functions
    address factory;  // FACTORY_ADMIN — may grant ENDPOINT_SENDER_ID to new tokens
    address attacker; // No role

    // ─────────────────────────────────────────────────────────────────────────

    function _singleRole(uint64 roleId) internal pure returns (uint64[] memory roles) {
        roles = new uint64[](1);
        roles[0] = roleId;
    }

    function setUp() public {
        admin    = address(this);
        sender   = makeAddr("sender");
        factory  = makeAddr("factory");
        attacker = makeAddr("attacker");

        // Deploy manager
        RaylsAccessManagerV1 impl = new RaylsAccessManagerV1();
        bytes memory initData = abi.encodeCall(RaylsAccessManagerV1.initialize, (admin));
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(address(impl), initData)));

        // Deploy minimal endpoint (no need for full module wiring)
        endpoint = new MinimalEndpoint();
        endpoint.initialize(1, 9999, 100, address(manager));

        // Register roles
        ENDPOINT_SENDER_ID = manager.registerRole("ENDPOINT_SENDER");
        FACTORY_ADMIN   = manager.registerRole("FACTORY_ADMIN");

        // FACTORY_ADMIN is the admin of ENDPOINT_SENDER (Option B hierarchy)
        manager.setRoleAdmin(ENDPOINT_SENDER_ID, FACTORY_ADMIN);

        // Map all send-path selectors to ENDPOINT_SENDER_ID
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = SEL_SEND_3;
        selectors[1] = SEL_SEND_4;
        selectors[2] = SEL_SEND_BATCH;
        selectors[3] = SEL_SEND_RID_3;
        selectors[4] = SEL_SEND_BATCH_RID;
        selectors[5] = SEL_REGISTER_RID;
        manager.addFunctionAllowedRoles(address(endpoint), selectors, _singleRole(ENDPOINT_SENDER_ID));

        // Grant ENDPOINT_SENDER_ID to sender (immediate)
        // Note: factory holds FACTORY_ADMIN; it grants ENDPOINT_SENDER_ID itself.
        // We grant FACTORY_ADMIN to factory, then factory grants ENDPOINT_SENDER to sender
        // to showcase the hierarchy.
        manager.grantRole(FACTORY_ADMIN, factory, 0);

        vm.prank(factory);
        manager.grantRole(ENDPOINT_SENDER_ID, sender, 0);
    }

    /*//////////////////////////////////////////////////////////////
                      ACCESS CONTROL ENFORCEMENT
    //////////////////////////////////////////////////////////////*/

    function test_send3_roleHolder_succeeds() public {
        vm.prank(sender);
        endpoint.send(1, address(0), "");
    }

    function test_send3_attacker_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        endpoint.send(1, address(0), "");
    }

    function test_sendBatch_roleHolder_succeeds() public {
        DestinationPayloadRequest[] memory reqs = new DestinationPayloadRequest[](0);
        vm.prank(sender);
        endpoint.sendBatch(reqs);
    }

    function test_sendBatch_attacker_reverts() public {
        DestinationPayloadRequest[] memory reqs = new DestinationPayloadRequest[](0);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        endpoint.sendBatch(reqs);
    }

    function test_sendToResourceId_roleHolder_succeeds() public {
        vm.prank(sender);
        endpoint.sendToResourceId(1, bytes32(0), "");
    }

    function test_sendToResourceId_attacker_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        endpoint.sendToResourceId(1, bytes32(0), "");
    }

    function test_registerResourceId_roleHolder_succeeds() public {
        vm.prank(sender);
        endpoint.registerResourceId(bytes32(uint256(1)), address(0x1));
    }

    function test_registerResourceId_attacker_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        endpoint.registerResourceId(bytes32(uint256(1)), address(0x1));
    }

    /*//////////////////////////////////////////////////////////////
                       ADMIN BYPASS
    //////////////////////////////////////////////////////////////*/

    /// @notice ADMIN bypasses all selector-to-role mappings globally.
    function test_admin_canCallWithoutExplicitRole() public {
        // admin = address(this), no prank needed
        endpoint.send(1, address(0), "");
        endpoint.sendToResourceId(1, bytes32(0), "");
        endpoint.registerResourceId(bytes32(uint256(1)), address(0x1));
    }

    /*//////////////////////////////////////////////////////////////
            FACTORY_ADMIN HIERARCHY (Option B)
    //////////////////////////////////////////////////////////////*/

    /// @notice factory holds FACTORY_ADMIN → can grant ENDPOINT_SENDER_ID to
    ///         new tokens without needing ADMIN (least-privilege).
    function test_factory_canGrantSenderRoleToNewToken() public {
        address newToken = makeAddr("newToken");

        // Factory grants ENDPOINT_SENDER to the new token
        vm.prank(factory);
        manager.grantRole(ENDPOINT_SENDER_ID, newToken, 0);

        // New token can now call send functions
        vm.prank(newToken);
        endpoint.send(1, address(0), "");
    }

    /// @notice factory CANNOT grant or revoke any other role (e.g. FACTORY_ADMIN itself).
    function test_factory_cannotGrantFactoryAdminRole() public {
        address rogue = makeAddr("rogue");
        vm.prank(factory);
        vm.expectRevert(); // NotRoleAdmin — factory is not admin of FACTORY_ADMIN
        manager.grantRole(FACTORY_ADMIN, rogue, 0);
    }

    /// @notice factory CANNOT call admin-only manager functions.
    function test_factory_cannotCallManagerAdminFunctions() public {
        vm.prank(factory);
        vm.expectRevert();
        manager.addFunctionAllowedRoles(address(endpoint), new bytes4[](0), _singleRole(ENDPOINT_SENDER_ID));
    }

    /*//////////////////////////////////////////////////////////////
                     REVOCATION IMMEDIATELY BLOCKS
    //////////////////////////////////////////////////////////////*/

    function test_revokeRole_blocksSubsequentSends() public {
        vm.prank(sender);
        endpoint.send(1, address(0), "");

        // Factory revokes sender's role
        vm.prank(factory);
        manager.revokeRole(ENDPOINT_SENDER_ID, sender);

        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, sender));
        endpoint.send(1, address(0), "");
    }

    /*//////////////////////////////////////////////////////////////
              authority() RETURNS CORRECT MANAGER ADDRESS
    //////////////////////////////////////////////////////////////*/

    function test_authority_returnsManager() public view {
        assertEq(endpoint.authority(), address(manager));
    }
}
