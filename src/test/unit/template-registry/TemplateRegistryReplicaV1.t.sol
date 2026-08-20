// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RaylsAccessManagerV1}        from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {TemplateRegistryReplicaV1}   from "../../../rayls-protocol/TemplateRegistryReplica/TemplateRegistryReplicaV1.sol";
import {ITemplateRegistry}           from "../../../privateHub/TemplateRegistry/interfaces/ITemplateRegistry.sol";

/// @dev Minimal endpoint stub. The replica only calls `endpoint.getPrivateHubId()`
///      inside its `restricted` write paths.
contract _StubEndpoint {
    uint256 public hubId;
    constructor(uint256 _hubId) { hubId = _hubId; }
    function getPrivateHubId() external view returns (uint256) { return hubId; }
}

/// @dev Trivial deployed contract used to source a stable `extcodehash` for the
///      `check(target, selector)` test — the replica matches against the
///      target's runtime bytecode hash, not its address.
contract _BytecodeSample {
    uint256 public dummy;
    function ping() external { dummy++; }
}

contract TemplateRegistryReplicaV1_Test is Test {
    // ─── personas ────────────────────────────────────────────────────────────
    address admin    = address(this);
    address endpointCaller; // address authorised to invoke replica's restricted methods
    address stranger = makeAddr("stranger");

    // ─── system under test ───────────────────────────────────────────────────
    RaylsAccessManagerV1      manager;
    TemplateRegistryReplicaV1 replica;
    _StubEndpoint             endpointStub;

    uint64  RELAYER_ID;
    uint256 constant HUB_ID = 600;
    uint256 constant OTHER_CHAIN_ID = 42;

    string  constant SIG_MINT = "mint(address,uint256,bytes32)";
    bytes4  immutable SEL_MINT = bytes4(keccak256(bytes(SIG_MINT)));
    bytes32 constant BYTECODE_HASH = keccak256("RaylsEnygma");

    function setUp() public {
        endpointCaller = makeAddr("endpointCaller");

        // ── AccessManager via UUPS proxy ────────────────────────────────────
        RaylsAccessManagerV1 mImpl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(
            address(new ERC1967Proxy(address(mImpl), abi.encodeCall(RaylsAccessManagerV1.initialize, (admin))))
        );
        manager.grantRole(manager.ADMIN(), address(manager), 0);

        // We model the "Endpoint-only" surface as a dedicated role granted to a single
        // address. In production this is wired to the relayer / Endpoint dispatcher;
        // here we use a single test persona to keep the test focused on the
        // replica's own gate (the `fromChainId == hubId` check), not on the
        // AccessManager wiring (which has its own dedicated tests).
        RELAYER_ID = manager.registerRole("ENDPOINT_DISPATCHER");
        manager.grantRole(RELAYER_ID, endpointCaller, 0);

        // ── Replica via UUPS proxy ──────────────────────────────────────────
        endpointStub = new _StubEndpoint(HUB_ID);
        TemplateRegistryReplicaV1 rImpl = new TemplateRegistryReplicaV1();
        replica = TemplateRegistryReplicaV1(
            address(new ERC1967Proxy(
                address(rImpl),
                abi.encodeCall(TemplateRegistryReplicaV1.initialize, (address(endpointStub), address(manager)))
            ))
        );

        // Wire the inbound surface to RELAYER_ID. `restricted` checks the AccessManager;
        // the explicit fromChainId check inside the methods is the second gate.
        bytes4[] memory sels = new bytes4[](2);
        sels[0] = TemplateRegistryReplicaV1.onTemplateApproved.selector;
        sels[1] = TemplateRegistryReplicaV1.onTemplateRevoked.selector;
        uint64[] memory roles = new uint64[](2);
        roles[0] = RELAYER_ID;
        roles[1] = RELAYER_ID;
        manager.addFunctionAllowedRoles(address(replica), sels, roles);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers — simulate the calldata tail (msgId(32) | fromChainId(32) | sender(20))
    // the Endpoint's MessageLib appends on inbound dispatch.
    // ─────────────────────────────────────────────────────────────────────────

    function _callWithTail(bytes memory innerCalldata, uint256 fromChainId, address tailSender)
        internal returns (bool ok, bytes memory ret)
    {
        bytes32 messageId = bytes32(0);
        bytes memory tail = abi.encodePacked(messageId, bytes32(fromChainId), bytes20(uint160(tailSender)));
        bytes memory full = abi.encodePacked(innerCalldata, tail);
        vm.prank(endpointCaller);
        (ok, ret) = address(replica).call(full);
    }

    function _approvedCalldata(bytes32 hash, string memory signature, uint64 approvedAt)
        internal pure returns (bytes memory)
    {
        return abi.encodeCall(
            TemplateRegistryReplicaV1.onTemplateApproved,
            (hash, signature, approvedAt)
        );
    }

    function _revokedCalldata(bytes32 hash, bytes4 selector, uint64 revokedAt)
        internal pure returns (bytes memory)
    {
        return abi.encodeCall(
            TemplateRegistryReplicaV1.onTemplateRevoked,
            (hash, selector, revokedAt)
        );
    }

    function _key(bytes32 hash, bytes4 sel) internal pure returns (bytes32) {
        return keccak256(abi.encode(hash, sel));
    }

    // ─── onTemplateApproved happy path ──────────────────────────────────────

    function test_onTemplateApproved_fromHub_storesTemplate() public {
        (bool ok, ) = _callWithTail(_approvedCalldata(BYTECODE_HASH, SIG_MINT, 100), HUB_ID, address(0xBEEF));
        assertTrue(ok, "call should succeed");

        bytes32 key = _key(BYTECODE_HASH, SEL_MINT);
        ITemplateRegistry.Template memory t = replica.getTemplate(key);
        assertTrue(t.approved);
        assertEq(t.approvedAtBlock,   100);
        assertEq(t.signature,    SIG_MINT);
        assertEq(t.selector,     SEL_MINT);
        assertEq(replica.getLastUpdatedAt(key), 100);
    }

    function test_onTemplateApproved_fromNonHub_reverts() public {
        (bool ok, bytes memory ret) =
            _callWithTail(_approvedCalldata(BYTECODE_HASH, SIG_MINT, 100), OTHER_CHAIN_ID, address(0xBEEF));
        assertFalse(ok, "non-hub origin must revert");

        // selector-prefix check on the revert payload
        bytes4 actual; assembly { actual := mload(add(ret, 0x20)) }
        assertEq(
            actual,
            TemplateRegistryReplicaV1.TemplateRegistryReplicaV1__NotFromPrivateHub.selector,
            "wrong revert selector"
        );
    }

    function test_onTemplateApproved_withoutTail_reverts() public {
        // Direct call with no tail → _getFromChainIdOnReceiveMethod() returns 0,
        // which != HUB_ID → reverts.
        vm.prank(endpointCaller);
        (bool ok, ) = address(replica).call(_approvedCalldata(BYTECODE_HASH, SIG_MINT, 100));
        assertFalse(ok, "tail-less call must revert via the hub-id check");
    }

    function test_onTemplateApproved_revertsWithoutRole() public {
        // stranger does NOT hold RELAYER_ID → `restricted` reverts before the hub-id check.
        bytes memory tail = abi.encodePacked(bytes32(0), bytes32(HUB_ID), bytes20(uint160(address(0))));
        bytes memory full = abi.encodePacked(_approvedCalldata(BYTECODE_HASH, SIG_MINT, 100), tail);
        vm.prank(stranger);
        (bool ok, ) = address(replica).call(full);
        assertFalse(ok, "non-relayer call must revert");
    }

    // ─── staleness ──────────────────────────────────────────────────────────

    function test_onTemplateApproved_staleEventDropped() public {
        (bool ok1, ) = _callWithTail(_approvedCalldata(BYTECODE_HASH, SIG_MINT, 200), HUB_ID, address(0));
        assertTrue(ok1);
        (bool ok2, ) = _callWithTail(_approvedCalldata(BYTECODE_HASH, SIG_MINT, 100), HUB_ID, address(0));
        assertTrue(ok2, "stale event must not revert - just no-op");

        bytes32 key = _key(BYTECODE_HASH, SEL_MINT);
        assertEq(replica.getLastUpdatedAt(key), 200, "newer approvedAt should win");
    }

    function test_onTemplateApproved_sameBlockDropped() public {
        // Spec: drop if approvedAt <= lastUpdatedAt.
        (bool ok1, ) = _callWithTail(_approvedCalldata(BYTECODE_HASH, SIG_MINT, 100), HUB_ID, address(0));
        assertTrue(ok1);
        (bool ok2, ) = _callWithTail(_approvedCalldata(BYTECODE_HASH, SIG_MINT, 100), HUB_ID, address(0));
        assertTrue(ok2, "<= drops");
        // Storage unchanged
        bytes32 key = _key(BYTECODE_HASH, SEL_MINT);
        assertEq(replica.getLastUpdatedAt(key), 100);
    }

    // ─── onTemplateRevoked ──────────────────────────────────────────────────

    function test_onTemplateRevoked_clearsApprovalAndBumpsOrderingToken() public {
        (bool ok1, ) = _callWithTail(_approvedCalldata(BYTECODE_HASH, SIG_MINT, 100), HUB_ID, address(0));
        assertTrue(ok1);

        (bool ok2, ) = _callWithTail(_revokedCalldata(BYTECODE_HASH, SEL_MINT, 200), HUB_ID, address(0));
        assertTrue(ok2);

        bytes32 key = _key(BYTECODE_HASH, SEL_MINT);
        ITemplateRegistry.Template memory t = replica.getTemplate(key);
        assertFalse(t.approved);
        assertEq(t.approvedAtBlock, 200, "ordering token bumped");
        assertEq(t.signature, SIG_MINT, "signature retained for history");
        assertEq(replica.getLastUpdatedAt(key), 200);
    }

    function test_onTemplateRevoked_staleDropped() public {
        (bool ok1, ) = _callWithTail(_approvedCalldata(BYTECODE_HASH, SIG_MINT, 300), HUB_ID, address(0));
        assertTrue(ok1);
        (bool ok2, ) = _callWithTail(_revokedCalldata(BYTECODE_HASH, SEL_MINT, 100), HUB_ID, address(0));
        assertTrue(ok2, "stale revoke must not revert");

        bytes32 key = _key(BYTECODE_HASH, SEL_MINT);
        ITemplateRegistry.Template memory t = replica.getTemplate(key);
        assertTrue(t.approved, "approval still stands");
        assertEq(replica.getLastUpdatedAt(key), 300);
    }

    // ─── check() view ───────────────────────────────────────────────────────

    function test_check_returnsTrueForApprovedBytecode() public {
        _BytecodeSample sample = new _BytecodeSample();
        bytes32 sampleHash = address(sample).codehash;

        (bool ok, ) = _callWithTail(_approvedCalldata(sampleHash, SIG_MINT, 1), HUB_ID, address(0));
        assertTrue(ok);

        assertTrue(replica.check(address(sample), SEL_MINT), "approved match");
    }

    function test_check_returnsFalseForUnknownTarget() public {
        _BytecodeSample sample = new _BytecodeSample();
        assertFalse(replica.check(address(sample), SEL_MINT), "no template means no match");
    }

    function test_check_returnsFalseForRevokedTemplate() public {
        _BytecodeSample sample = new _BytecodeSample();
        bytes32 sampleHash = address(sample).codehash;

        (bool ok1, ) = _callWithTail(_approvedCalldata(sampleHash, SIG_MINT, 1), HUB_ID, address(0));
        assertTrue(ok1);
        (bool ok2, ) = _callWithTail(_revokedCalldata(sampleHash, SEL_MINT, 2), HUB_ID, address(0));
        assertTrue(ok2);

        assertFalse(replica.check(address(sample), SEL_MINT), "revoked means no match");
    }
}
