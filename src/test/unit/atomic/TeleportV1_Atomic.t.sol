// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import "../../../privateHub/Teleport/TeleportV1.sol";

/**
 * @title TeleportV1 Atomic Execute/Revert Tests
 * @notice Covers the atomic-message state machine on the Hub: execute and revert are mutually
 *         exclusive, idempotent on their own terminal state, surface the correct distinct error
 *         on a cross-state conflict, and emit a status event only for the messages that actually
 *         transitioned. There is NO on-chain lock-time / expiration window — revert is gated
 *         solely by `status` and the `restricted` modifier (expiry is enforced off-chain by the
 *         relayer's revert poller).
 * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
 */
contract TeleportV1AtomicTest is Test {
    TeleportV1 public teleport;
    RaylsAccessManagerV1 public manager;

    address public owner;
    address public relayer;
    address public attacker;

    uint64 public relayerRoleId;

    function _singleRole(uint64 roleId) internal pure returns (uint64[] memory roles) {
        roles = new uint64[](1);
        roles[0] = roleId;
    }

    function setUp() public {
        owner = address(this);
        relayer = makeAddr("relayer");
        attacker = makeAddr("attacker");

        // Deploy RaylsAccessManagerV1 via proxy
        RaylsAccessManagerV1 managerImpl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(
            address(new ERC1967Proxy(address(managerImpl), abi.encodeCall(RaylsAccessManagerV1.initialize, (owner))))
        );

        relayerRoleId = manager.registerRole("RELAYER");

        // Deploy TeleportV1 via proxy
        TeleportV1 teleportImpl = new TeleportV1();
        bytes memory teleportInit = abi.encodeCall(TeleportV1.initialize, (address(manager)));
        ERC1967Proxy teleportProxy = new ERC1967Proxy(address(teleportImpl), teleportInit);
        teleport = TeleportV1(address(teleportProxy));

        // Map relayer-gated selectors to RELAYER
        bytes4[] memory relayerSelectors = new bytes4[](5);
        relayerSelectors[0] = TeleportV1.storeEncryptedDataBatch.selector;
        relayerSelectors[1] = TeleportV1.addHeader.selector;
        relayerSelectors[2] = TeleportV1.addSingleHeader.selector;
        relayerSelectors[3] = TeleportV1.executeAtomicMessageBatch.selector;
        relayerSelectors[4] = TeleportV1.revertAtomicMessageBatch.selector;
        manager.addFunctionAllowedRoles(address(teleport), relayerSelectors, _singleRole(relayerRoleId));

        manager.grantRole(relayerRoleId, relayer, 0);
    }

    // ============================================================
    // HELPERS
    // ============================================================

    function _storeBatch(string[] memory msgIds) internal {
        TeleportV1.dataBatch memory batch = TeleportV1.dataBatch({
            batchId: "batch1",
            messageTag: "fp1",
            data: bytes("data"),
            sharedIds: msgIds
        });
        vm.prank(relayer);
        teleport.storeEncryptedDataBatch(batch, 1);
    }

    function _singleMsgArray(string memory msgId) internal pure returns (string[] memory) {
        string[] memory ids = new string[](1);
        ids[0] = msgId;
        return ids;
    }

    // ============================================================
    // INITIALIZATION / ACCESS CONTROL
    // ============================================================

    function test_initialize_setsAuthority() public view {
        assertEq(teleport.authority(), address(manager));
    }

    function test_contractVersion_returns1() public view {
        assertEq(teleport.contractVersion(), 1);
    }

    function test_executeAtomicMessageBatch_onlyRelayer() public {
        string[] memory ids = _singleMsgArray("acl-exec");
        _storeBatch(ids);

        vm.prank(attacker);
        vm.expectRevert();
        teleport.executeAtomicMessageBatch(ids, "enc");
    }

    function test_revertAtomicMessageBatch_onlyRelayer() public {
        string[] memory ids = _singleMsgArray("acl-rev");
        _storeBatch(ids);

        vm.prank(attacker);
        vm.expectRevert();
        teleport.revertAtomicMessageBatch(ids, "enc");
    }

    // ============================================================
    // EXECUTE / REVERT MECHANICS
    // ============================================================

    function test_execute_setsExecuted() public {
        string[] memory ids = _singleMsgArray("exec1");
        _storeBatch(ids);

        vm.prank(relayer);
        teleport.executeAtomicMessageBatch(ids, "enc");

        assertEq(uint(teleport.getAtomicMessage("exec1").status), uint(Utils.MessageStatus.Executed));
    }

    function test_revert_setsReverted() public {
        string[] memory ids = _singleMsgArray("rev1");
        _storeBatch(ids);

        vm.prank(relayer);
        teleport.revertAtomicMessageBatch(ids, "enc");

        assertEq(uint(teleport.getAtomicMessage("rev1").status), uint(Utils.MessageStatus.Reverted));
    }

    function test_revert_batch_setsAllReverted() public {
        string[] memory ids = new string[](3);
        ids[0] = "b1";
        ids[1] = "b2";
        ids[2] = "b3";
        _storeBatch(ids);

        vm.prank(relayer);
        teleport.revertAtomicMessageBatch(ids, "enc");

        for (uint i = 0; i < ids.length; i++) {
            assertEq(uint(teleport.getAtomicMessage(ids[i]).status), uint(Utils.MessageStatus.Reverted));
        }
    }

    // ============================================================
    // IDEMPOTENCY + CORRECT-ERROR (regression: atomic-teleport token loss)
    //
    // executeAtomicMessageBatch previously threw MessageAlreadyReverted for ANY non-Pending
    // status (incl. Executed). The dest relayer decoded that as ErrAlreadyReverted and burned
    // the already-executed mint → token loss. Execute/revert are now idempotent on their own
    // terminal state and only hard-fail on the OPPOSITE one with the correct distinct error.
    // ============================================================

    /// @notice Retrying execute on an already-Executed message must be a no-op, not a revert.
    ///         (At-least-once delivery: a relayer that crashes after the Hub call but before
    ///         persisting its local state will re-send execute on restart.)
    function test_execute_isIdempotent_onAlreadyExecuted() public {
        string[] memory ids = _singleMsgArray("idem-exec");
        _storeBatch(ids);

        vm.prank(relayer);
        teleport.executeAtomicMessageBatch(ids, "enc");

        // Retry must NOT revert, must leave status Executed, and must emit NO event — a duplicate
        // AtomicMessageStatusChangedBatch would create a duplicate status row downstream and wedge
        // the relayer's block processing.
        vm.recordLogs();
        vm.prank(relayer);
        teleport.executeAtomicMessageBatch(ids, "enc");
        assertEq(vm.getRecordedLogs().length, 0, "idempotent execute retry must emit no events");

        assertEq(uint(teleport.getAtomicMessage("idem-exec").status), uint(Utils.MessageStatus.Executed));
    }

    /// @notice Retrying revert on an already-Reverted message must be a no-op, not a revert.
    ///         (Otherwise the source row wedges and the sender is never refunded.)
    function test_revert_isIdempotent_onAlreadyReverted() public {
        string[] memory ids = _singleMsgArray("idem-rev");
        _storeBatch(ids);
        // No vm.warp needed: revert has no on-chain expiration/lock-time window — a Pending
        // message reverts immediately (expiry is enforced off-chain by the relayer).

        vm.prank(relayer);
        teleport.revertAtomicMessageBatch(ids, "enc");

        // Retry must NOT revert, must leave status Reverted, and must emit NO event.
        vm.recordLogs();
        vm.prank(relayer);
        teleport.revertAtomicMessageBatch(ids, "enc");
        assertEq(vm.getRecordedLogs().length, 0, "idempotent revert retry must emit no events");

        assertEq(uint(teleport.getAtomicMessage("idem-rev").status), uint(Utils.MessageStatus.Reverted));
    }

    /// @notice Executing a message that already lost the race to a revert must surface the
    ///         CORRECT distinct error so the relayer burns its orphan mint (genuine race-lost).
    function test_execute_afterRevert_failsWithRevertedError() public {
        string[] memory ids = _singleMsgArray("exec-after-rev");
        _storeBatch(ids);

        vm.prank(relayer);
        teleport.revertAtomicMessageBatch(ids, "enc");

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(TeleportV1.TeleportV1__MessageAlreadyReverted.selector, "exec-after-rev"));
        teleport.executeAtomicMessageBatch(ids, "enc");
    }

    /// @notice Reverting a message that already executed must surface the CORRECT distinct error
    ///         so the source relayer does NOT refund a sender whose transfer already executed
    ///         (the core double-spend guard).
    function test_revert_afterExecute_failsWithExecutedError() public {
        string[] memory ids = _singleMsgArray("rev-after-exec");
        _storeBatch(ids);

        vm.prank(relayer);
        teleport.executeAtomicMessageBatch(ids, "enc");

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(TeleportV1.TeleportV1__MessageAlreadyExecuted.selector, "rev-after-exec"));
        teleport.revertAtomicMessageBatch(ids, "enc");
    }

    /// @notice Defensive: a MIXED batch (one already-Executed, one still-Pending) must emit a
    ///         status event carrying ONLY the id that actually transitioned — never the
    ///         already-terminal id, which would create a duplicate status row downstream.
    ///         (Cannot arise in normal at-least-once flow, where a whole batch is retried.)
    function test_execute_mixedBatch_emitsOnlyTransitionedId() public {
        _storeBatch(_singleMsgArray("mix-1"));
        vm.prank(relayer);
        teleport.executeAtomicMessageBatch(_singleMsgArray("mix-1"), "enc"); // mix-1 -> Executed

        _storeBatch(_singleMsgArray("mix-2")); // mix-2 stays Pending

        string[] memory both = new string[](2);
        both[0] = "mix-1"; // already Executed — must NOT be re-emitted
        both[1] = "mix-2"; // Pending — transitions

        vm.recordLogs();
        vm.prank(relayer);
        teleport.executeAtomicMessageBatch(both, "enc");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 statusTopic = keccak256("AtomicMessageStatusChangedBatch(string[],uint8)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == statusTopic) {
                (string[] memory idsDecoded, ) = abi.decode(logs[i].data, (string[], uint8));
                assertEq(idsDecoded.length, 1, "mixed batch must emit only the transitioned id");
                assertEq(keccak256(bytes(idsDecoded[0])), keccak256(bytes("mix-2")), "emitted id must be the transitioned one");
                found = true;
            }
        }
        assertTrue(found, "expected an AtomicMessageStatusChangedBatch event");

        // Both end Executed (mix-1 idempotent no-op, mix-2 newly executed).
        assertEq(uint(teleport.getAtomicMessage("mix-1").status), uint(Utils.MessageStatus.Executed));
        assertEq(uint(teleport.getAtomicMessage("mix-2").status), uint(Utils.MessageStatus.Executed));
    }
}
