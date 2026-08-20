// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RaylsAccessManagerV1}        from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {TemplateRegistryV1}          from "../../../privateHub/TemplateRegistry/TemplateRegistryV1.sol";
import {ITemplateRegistry}           from "../../../privateHub/TemplateRegistry/interfaces/ITemplateRegistry.sol";
import {TemplateRegistryReplicaV1}   from "../../../rayls-protocol/TemplateRegistryReplica/TemplateRegistryReplicaV1.sol";
import {BridgedTransferMetadata}     from "../../../rayls-protocol-sdk/RaylsMessage.sol";
import {Constants}                   from "../../../rayls-protocol-sdk/Constants.sol";

/// @dev Recording endpoint stub. Implements only the 7-arg `sendToResourceId` overload
///      that `TemplateRegistryV1` calls; everything else on `IRaylsEndpoint` is unused
///      by the registry's Phase 2 paths.
contract _StubEndpoint {
    struct Call {
        uint256 toChainId;
        bytes32 resourceId;
        bytes   payload;
    }
    Call[] private _calls;

    function sendToResourceId(
        uint256 _dstChainId,
        bytes32 _resourceId,
        bytes calldata _payload,
        bytes memory /*_lockData*/,
        bytes memory /*_revertDataPayloadSender*/,
        bytes memory /*_revertDataPayloadReceiver*/,
        BridgedTransferMetadata memory /*transferMetadata*/
    ) external payable returns (bytes32) {
        _calls.push(Call({toChainId: _dstChainId, resourceId: _resourceId, payload: _payload}));
        return bytes32(_calls.length);
    }

    function callCount() external view returns (uint256) { return _calls.length; }

    function callAt(uint256 i) external view returns (Call memory) { return _calls[i]; }

    function lastCall() external view returns (Call memory) {
        require(_calls.length > 0, "no calls");
        return _calls[_calls.length - 1];
    }
}

contract TemplateRegistryV1_Test is Test {
    // ─── personas ────────────────────────────────────────────────────────────
    address admin    = address(this);
    address operator = makeAddr("operator");
    address proposer = makeAddr("proposer");
    address stranger = makeAddr("stranger");

    // ─── system under test ───────────────────────────────────────────────────
    RaylsAccessManagerV1 manager;
    TemplateRegistryV1   registry;
    address              endpointAddr;

    uint64 OPERATOR_ID;

    string  constant SIG_MINT = "mint(address,uint256,bytes32)";
    bytes4  immutable SEL_MINT = bytes4(keccak256(bytes(SIG_MINT)));
    bytes32 constant BYTECODE_HASH = keccak256("RaylsEnygma");

    function setUp() public {
        // ── AccessManager via UUPS proxy ────────────────────────────────────
        RaylsAccessManagerV1 mImpl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(
            address(new ERC1967Proxy(address(mImpl), abi.encodeCall(RaylsAccessManagerV1.initialize, (admin))))
        );
        // Manager → target self-call needs ADMIN on the manager itself for `restricted` paths.
        manager.grantRole(manager.ADMIN(), address(manager), 0);

        OPERATOR_ID = manager.registerRole("PRIVATE_NETWORK_OPERATOR");
        manager.grantRole(OPERATOR_ID, operator, 0);

        // ── Registry via UUPS proxy ─────────────────────────────────────────
        endpointAddr = address(new _StubEndpoint());
        TemplateRegistryV1 rImpl = new TemplateRegistryV1();
        registry = TemplateRegistryV1(
            address(new ERC1967Proxy(
                address(rImpl),
                abi.encodeCall(TemplateRegistryV1.initialize, (endpointAddr, address(manager)))
            ))
        );

        // Wire operator-only selectors to OPERATOR_ID.
        bytes4[] memory sels = new bytes4[](4);
        sels[0] = TemplateRegistryV1.seedStandardTemplate.selector;
        sels[1] = TemplateRegistryV1.approve.selector;
        sels[2] = TemplateRegistryV1.revoke.selector;
        sels[3] = TemplateRegistryV1.reseedStandardTemplate.selector;
        uint64[] memory roles = new uint64[](4);
        roles[0] = OPERATOR_ID;
        roles[1] = OPERATOR_ID;
        roles[2] = OPERATOR_ID;
        roles[3] = OPERATOR_ID;
        manager.addFunctionAllowedRoles(address(registry), sels, roles);
    }

    // ─── helpers ─────────────────────────────────────────────────────────────

    function _key(bytes32 hash, bytes4 sel) internal pure returns (bytes32) {
        return keccak256(abi.encode(hash, sel));
    }

    // ─── seedStandardTemplate ────────────────────────────────────────────────

    function test_seedStandardTemplate_writesApprovedTemplate() public {
        vm.roll(123);
        vm.prank(operator);
        registry.seedStandardTemplate(BYTECODE_HASH, SIG_MINT);

        ITemplateRegistry.Template memory t = registry.getTemplate(_key(BYTECODE_HASH, SEL_MINT));
        assertEq(t.bytecodeHash, BYTECODE_HASH, "bytecodeHash");
        assertEq(t.signature,    SIG_MINT,      "signature");
        assertEq(t.selector,     SEL_MINT,      "selector");
        assertEq(t.approvedAtBlock,   123,           "approvedAt");
        assertTrue(t.approved,                  "approved");
    }

    function test_seedStandardTemplate_revertsIfNotOperator() public {
        vm.prank(stranger);
        vm.expectRevert();
        registry.seedStandardTemplate(BYTECODE_HASH, SIG_MINT);
    }

    function test_seedStandardTemplate_revertsOnEmptyBytecodeHash() public {
        vm.prank(operator);
        vm.expectRevert(TemplateRegistryV1.TemplateRegistryV1__EmptyBytecodeHash.selector);
        registry.seedStandardTemplate(bytes32(0), SIG_MINT);
    }

    function test_seedStandardTemplate_revertsOnEmptySignature() public {
        vm.prank(operator);
        vm.expectRevert(TemplateRegistryV1.TemplateRegistryV1__EmptySignature.selector);
        registry.seedStandardTemplate(BYTECODE_HASH, "");
    }

    function test_seedStandardTemplate_revertsOnDoubleSeed() public {
        vm.startPrank(operator);
        registry.seedStandardTemplate(BYTECODE_HASH, SIG_MINT);
        vm.expectRevert(
            abi.encodeWithSelector(
                TemplateRegistryV1.TemplateRegistryV1__AlreadyRegistered.selector,
                _key(BYTECODE_HASH, SEL_MINT)
            )
        );
        registry.seedStandardTemplate(BYTECODE_HASH, SIG_MINT);
        vm.stopPrank();
    }

    // ─── propose ─────────────────────────────────────────────────────────────

    function test_propose_isOpenToAnyone() public {
        vm.prank(proposer);
        bytes32 key = registry.propose(BYTECODE_HASH, SIG_MINT);
        assertEq(key, _key(BYTECODE_HASH, SEL_MINT), "key");

        ITemplateRegistry.Template memory t = registry.getTemplate(key);
        assertEq(t.bytecodeHash, BYTECODE_HASH);
        assertEq(t.approvedAtBlock,   0, "approvedAt zero until approved");
        assertFalse(t.approved,     "not yet approved");
    }

    function test_propose_revertsOnDuplicate() public {
        vm.prank(proposer);
        registry.propose(BYTECODE_HASH, SIG_MINT);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                TemplateRegistryV1.TemplateRegistryV1__AlreadyRegistered.selector,
                _key(BYTECODE_HASH, SEL_MINT)
            )
        );
        registry.propose(BYTECODE_HASH, SIG_MINT);
    }

    // ─── approve ─────────────────────────────────────────────────────────────

    function test_approve_flipsApprovalAndStampsBlock() public {
        vm.prank(proposer);
        bytes32 key = registry.propose(BYTECODE_HASH, SIG_MINT);

        vm.roll(500);
        vm.prank(operator);
        registry.approve(key);

        ITemplateRegistry.Template memory t = registry.getTemplate(key);
        assertTrue(t.approved);
        assertEq(t.approvedAtBlock, 500);
    }

    function test_approve_revertsIfNotProposed() public {
        bytes32 key = _key(BYTECODE_HASH, SEL_MINT);
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(TemplateRegistryV1.TemplateRegistryV1__NotProposed.selector, key)
        );
        registry.approve(key);
    }

    function test_approve_revertsIfAlreadyApproved() public {
        vm.prank(operator);
        registry.seedStandardTemplate(BYTECODE_HASH, SIG_MINT);

        bytes32 key = _key(BYTECODE_HASH, SEL_MINT);
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(TemplateRegistryV1.TemplateRegistryV1__AlreadyApproved.selector, key)
        );
        registry.approve(key);
    }

    function test_approve_revertsIfNotOperator() public {
        vm.prank(proposer);
        bytes32 key = registry.propose(BYTECODE_HASH, SIG_MINT);

        vm.prank(stranger);
        vm.expectRevert();
        registry.approve(key);
    }

    // ─── revoke ──────────────────────────────────────────────────────────────

    function test_revoke_clearsApprovalAndStampsBlock() public {
        vm.prank(operator);
        registry.seedStandardTemplate(BYTECODE_HASH, SIG_MINT);
        bytes32 key = _key(BYTECODE_HASH, SEL_MINT);

        vm.roll(999);
        vm.prank(operator);
        registry.revoke(key);

        ITemplateRegistry.Template memory t = registry.getTemplate(key);
        assertFalse(t.approved);
        assertEq(t.approvedAtBlock, 999, "ordering token bumped on revoke");
        // signature & selector retained for explorer history
        assertEq(t.signature, SIG_MINT);
        assertEq(t.selector,  SEL_MINT);
    }

    function test_revoke_revertsIfNotApproved() public {
        bytes32 key = _key(BYTECODE_HASH, SEL_MINT);
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(TemplateRegistryV1.TemplateRegistryV1__NotApproved.selector, key)
        );
        registry.revoke(key);
    }

    function test_revoke_revertsIfNotOperator() public {
        vm.prank(operator);
        registry.seedStandardTemplate(BYTECODE_HASH, SIG_MINT);
        bytes32 key = _key(BYTECODE_HASH, SEL_MINT);

        vm.prank(stranger);
        vm.expectRevert();
        registry.revoke(key);
    }

    // ─── re-approve after revoke (used by upgrade rollouts) ─────────────────

    function test_approveAgainAfterRevoke_bumpsApprovedAt() public {
        vm.prank(operator);
        registry.seedStandardTemplate(BYTECODE_HASH, SIG_MINT);
        bytes32 key = _key(BYTECODE_HASH, SEL_MINT);

        vm.roll(10);
        vm.prank(operator);
        registry.revoke(key);

        vm.roll(20);
        vm.prank(operator);
        registry.approve(key);

        ITemplateRegistry.Template memory t = registry.getTemplate(key);
        assertTrue(t.approved);
        assertEq(t.approvedAtBlock, 20);
    }

    // ─── reseedStandardTemplate (post-UUPS-upgrade re-register) ──────────────

    function test_reseedStandardTemplate_revertsIfNotOperator() public {
        vm.prank(stranger);
        vm.expectRevert();
        registry.reseedStandardTemplate(BYTECODE_HASH, SIG_MINT);
    }

    function test_reseedStandardTemplate_revertsOnEmptyBytecodeHash() public {
        vm.prank(operator);
        vm.expectRevert(TemplateRegistryV1.TemplateRegistryV1__EmptyBytecodeHash.selector);
        registry.reseedStandardTemplate(bytes32(0), SIG_MINT);
    }

    function test_reseedStandardTemplate_revertsOnEmptySignature() public {
        vm.prank(operator);
        vm.expectRevert(TemplateRegistryV1.TemplateRegistryV1__EmptySignature.selector);
        registry.reseedStandardTemplate(BYTECODE_HASH, "");
    }

    /// @dev First-time write path: reseed over an absent key behaves like a seed.
    function test_reseedStandardTemplate_writesApprovedTemplateOverAbsentKey() public {
        vm.roll(321);
        vm.prank(operator);
        registry.reseedStandardTemplate(BYTECODE_HASH, SIG_MINT);

        ITemplateRegistry.Template memory t = registry.getTemplate(_key(BYTECODE_HASH, SEL_MINT));
        assertEq(t.bytecodeHash, BYTECODE_HASH, "bytecodeHash");
        assertEq(t.signature,    SIG_MINT,      "signature");
        assertEq(t.selector,     SEL_MINT,      "selector");
        assertEq(t.approvedAtBlock,   321,           "approvedAt");
        assertTrue(t.approved,                  "approved");
    }

    /// @dev Idempotent no-op: unlike seedStandardTemplate (which reverts), reseed over an
    ///      already-approved key does NOT revert. It short-circuits — leaving state untouched
    ///      (approvedAt NOT re-stamped) and, crucially, NOT re-broadcasting to the PN replicas.
    function test_reseedStandardTemplate_noOpsOnAlreadyApprovedKey() public {
        vm.roll(100);
        vm.prank(operator);
        registry.seedStandardTemplate(BYTECODE_HASH, SIG_MINT);
        assertEq(_endpoint().callCount(), 1, "seed broadcast once");

        vm.roll(200);
        vm.prank(operator);
        registry.reseedStandardTemplate(BYTECODE_HASH, SIG_MINT); // must not revert

        ITemplateRegistry.Template memory t = registry.getTemplate(_key(BYTECODE_HASH, SEL_MINT));
        assertTrue(t.approved,        "still approved");
        assertEq(t.approvedAtBlock, 100,   "approvedAt unchanged (no-op did not re-stamp)");
        assertEq(_endpoint().callCount(), 1, "no redundant broadcast on no-op reseed");
    }

    /// @dev The no-op short-circuit must not emit either event when the key is already approved.
    function test_reseedStandardTemplate_noOpEmitsNothing() public {
        vm.prank(operator);
        registry.seedStandardTemplate(BYTECODE_HASH, SIG_MINT);

        vm.recordLogs();
        vm.prank(operator);
        registry.reseedStandardTemplate(BYTECODE_HASH, SIG_MINT);
        assertEq(vm.getRecordedLogs().length, 0, "no events emitted on no-op reseed");
    }

    /// @dev Security guard: reseed must NOT silently un-revoke bytecode an auditor pulled.
    function test_reseedStandardTemplate_revertsOnRevokedKey() public {
        vm.prank(operator);
        registry.seedStandardTemplate(BYTECODE_HASH, SIG_MINT);
        bytes32 key = _key(BYTECODE_HASH, SEL_MINT);

        vm.prank(operator);
        registry.revoke(key);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(TemplateRegistryV1.TemplateRegistryV1__RevokedTemplate.selector, key)
        );
        registry.reseedStandardTemplate(BYTECODE_HASH, SIG_MINT);

        // State unchanged: still revoked.
        assertFalse(registry.getTemplate(key).approved, "key remains revoked after blocked reseed");
    }

    /// @dev A key that was `propose`d but never approved (approvedAt == 0) is NOT a revoke — `propose`
    ///      is open to anyone, so an external actor pre-empting the runbook must not be able to make the
    ///      reseed revert with a misleading `RevokedTemplate`. The reseed overwrites it in place (approves).
    function test_reseedStandardTemplate_overwritesProposedButNeverApprovedKey() public {
        vm.prank(proposer);
        registry.propose(BYTECODE_HASH, SIG_MINT); // proposed, not approved (approvedAt == 0)

        bytes32 key = _key(BYTECODE_HASH, SEL_MINT);
        assertFalse(registry.getTemplate(key).approved, "precondition: proposed, not approved");
        assertEq(registry.getTemplate(key).approvedAtBlock, 0, "precondition: approvedAt == 0");

        vm.roll(555);
        vm.prank(operator);
        registry.reseedStandardTemplate(BYTECODE_HASH, SIG_MINT); // must not revert

        ITemplateRegistry.Template memory t = registry.getTemplate(key);
        assertTrue(t.approved,            "proposed-only key is approved by reseed");
        assertEq(t.approvedAtBlock, 555,       "approvedAt stamped to reseed block");
        assertEq(t.bytecodeHash, BYTECODE_HASH, "bytecodeHash");
        assertEq(t.selector,     SEL_MINT,      "selector");
    }

    /// @dev Both events fire on a successful reseed: TemplateApproved (replica-driving) and
    ///      StandardTemplateReseeded (off-chain audit discriminator).
    function test_reseedStandardTemplate_emitsBothEvents() public {
        bytes32 key = _key(BYTECODE_HASH, SEL_MINT);
        vm.roll(777);

        vm.expectEmit(true, false, false, true, address(registry));
        emit ITemplateRegistry.TemplateApproved(key, BYTECODE_HASH, SIG_MINT, SEL_MINT, 777);
        vm.expectEmit(true, true, true, true, address(registry));
        emit ITemplateRegistry.StandardTemplateReseeded(key, BYTECODE_HASH, SEL_MINT, 777);

        vm.prank(operator);
        registry.reseedStandardTemplate(BYTECODE_HASH, SIG_MINT);
    }

    /// @dev Reseed re-broadcasts the approval to replicas via the same onTemplateApproved fan-out.
    function test_reseedStandardTemplate_broadcastsOnTemplateApproved() public {
        vm.roll(777);
        vm.prank(operator);
        registry.reseedStandardTemplate(BYTECODE_HASH, SIG_MINT);

        assertEq(_endpoint().callCount(), 1, "one broadcast");
        _StubEndpoint.Call memory c = _endpoint().lastCall();
        assertEq(c.toChainId,  Constants.CHAIN_ID_ALL_PARTICIPANTS,    "fan-out chain id");
        assertEq(c.resourceId, Constants.RESOURCE_ID_TEMPLATE_REGISTRY, "registry resource id");
        assertEq(_selectorOf(c.payload), TemplateRegistryReplicaV1.onTemplateApproved.selector, "selector");

        bytes memory args = _stripSelector(c.payload);
        (bytes32 hash, string memory sig, uint64 approvedAt) =
            abi.decode(args, (bytes32, string, uint64));
        assertEq(hash,       BYTECODE_HASH, "bytecodeHash");
        assertEq(sig,        SIG_MINT,      "signature");
        assertEq(approvedAt, 777,           "approvedAt == block");
    }

    // ─── Phase 2: broadcast emission ─────────────────────────────────────────

    /// @dev Helper: typed accessor for the recording endpoint stub.
    function _endpoint() internal view returns (_StubEndpoint) {
        return _StubEndpoint(endpointAddr);
    }

    /// @dev Helper: extract the leading 4-byte selector from a `bytes` payload.
    function _selectorOf(bytes memory data) internal pure returns (bytes4 sel) {
        require(data.length >= 4, "payload too short");
        assembly { sel := mload(add(data, 32)) }
    }

    function test_seedStandardTemplate_broadcastsOnTemplateApproved() public {
        vm.roll(123);
        vm.prank(operator);
        registry.seedStandardTemplate(BYTECODE_HASH, SIG_MINT);

        assertEq(_endpoint().callCount(), 1, "one broadcast");
        _StubEndpoint.Call memory c = _endpoint().lastCall();
        assertEq(c.toChainId,  Constants.CHAIN_ID_ALL_PARTICIPANTS,    "fan-out chain id");
        assertEq(c.resourceId, Constants.RESOURCE_ID_TEMPLATE_REGISTRY, "registry resource id");
        assertEq(_selectorOf(c.payload), TemplateRegistryReplicaV1.onTemplateApproved.selector, "selector");

        // Decode the trailing args after the 4-byte selector.
        bytes memory args = _stripSelector(c.payload);
        (bytes32 hash, string memory sig, uint64 approvedAt) =
            abi.decode(args, (bytes32, string, uint64));
        assertEq(hash,       BYTECODE_HASH, "bytecodeHash");
        assertEq(sig,        SIG_MINT,      "signature");
        assertEq(approvedAt, 123,           "approvedAt == block");
    }

    function test_propose_doesNotBroadcast() public {
        vm.prank(proposer);
        registry.propose(BYTECODE_HASH, SIG_MINT);
        assertEq(_endpoint().callCount(), 0, "propose must not broadcast");
    }

    function test_approve_broadcastsOnTemplateApproved() public {
        vm.prank(proposer);
        bytes32 key = registry.propose(BYTECODE_HASH, SIG_MINT);
        assertEq(_endpoint().callCount(), 0, "propose did not broadcast");

        vm.roll(500);
        vm.prank(operator);
        registry.approve(key);

        assertEq(_endpoint().callCount(), 1, "approve broadcasts exactly once");
        _StubEndpoint.Call memory c = _endpoint().lastCall();
        assertEq(_selectorOf(c.payload), TemplateRegistryReplicaV1.onTemplateApproved.selector, "selector");

        bytes memory args = _stripSelector(c.payload);
        (bytes32 hash, string memory sig, uint64 approvedAt) =
            abi.decode(args, (bytes32, string, uint64));
        assertEq(hash,       BYTECODE_HASH, "bytecodeHash");
        assertEq(sig,        SIG_MINT,      "signature");
        assertEq(approvedAt, 500,           "approvedAt");
    }

    function test_revoke_broadcastsOnTemplateRevoked() public {
        vm.prank(operator);
        registry.seedStandardTemplate(BYTECODE_HASH, SIG_MINT);
        bytes32 key = _key(BYTECODE_HASH, SEL_MINT);
        assertEq(_endpoint().callCount(), 1, "seed broadcast");

        vm.roll(999);
        vm.prank(operator);
        registry.revoke(key);

        assertEq(_endpoint().callCount(), 2, "revoke broadcasts exactly once more");
        _StubEndpoint.Call memory c = _endpoint().lastCall();
        assertEq(c.toChainId,  Constants.CHAIN_ID_ALL_PARTICIPANTS,    "fan-out chain id");
        assertEq(c.resourceId, Constants.RESOURCE_ID_TEMPLATE_REGISTRY, "registry resource id");
        assertEq(_selectorOf(c.payload), TemplateRegistryReplicaV1.onTemplateRevoked.selector, "selector");

        bytes memory args = _stripSelector(c.payload);
        (bytes32 hash, bytes4 sel, uint64 revokedAt) =
            abi.decode(args, (bytes32, bytes4, uint64));
        assertEq(hash,      BYTECODE_HASH, "bytecodeHash");
        assertEq(sel,       SEL_MINT,      "selector arg");
        assertEq(revokedAt, 999,           "revokedAt");
    }

    function test_seedThenRevokeThenApprove_broadcastsThreeTimesInOrder() public {
        vm.roll(10);
        vm.prank(operator);
        registry.seedStandardTemplate(BYTECODE_HASH, SIG_MINT);
        bytes32 key = _key(BYTECODE_HASH, SEL_MINT);

        vm.roll(20);
        vm.prank(operator);
        registry.revoke(key);

        vm.roll(30);
        vm.prank(operator);
        registry.approve(key);

        assertEq(_endpoint().callCount(), 3, "three broadcasts");

        bytes4 approvedSel = TemplateRegistryReplicaV1.onTemplateApproved.selector;
        bytes4 revokedSel  = TemplateRegistryReplicaV1.onTemplateRevoked.selector;

        assertEq(_selectorOf(_endpoint().callAt(0).payload), approvedSel, "seed -> approved");
        assertEq(_selectorOf(_endpoint().callAt(1).payload), revokedSel,  "revoke -> revoked");
        assertEq(_selectorOf(_endpoint().callAt(2).payload), approvedSel, "re-approve -> approved");
    }

    /// @dev Helper: strip the 4-byte selector from an ABI-encoded call payload,
    ///      returning the args portion suitable for `abi.decode`. Uses a calldata slice
    ///      (`payload[4:]`) via an external self-call instead of a byte-by-byte copy.
    function _stripSelector(bytes memory payload) internal view returns (bytes memory args) {
        require(payload.length >= 4, "payload too short");
        return this.sliceFromFour(payload);
    }

    /// @dev External so `payload` lands in calldata, enabling a native `[4:]` slice.
    function sliceFromFour(bytes calldata payload) external pure returns (bytes memory) {
        return payload[4:];
    }
}
