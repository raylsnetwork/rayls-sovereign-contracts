// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EnygmaV1} from "../../../rayls-protocol/Enygma/Enygma-Payments/EnygmaV1.sol";
import {EnygmaCreationParams} from "../../../rayls-protocol/Enygma/Enygma-Payments/EnygmaCreator.sol";
import {IEnygmaV1} from "../../../rayls-protocol/interfaces/IEnygmaV1.sol";
import {CurveBabyJubJub} from "../../../rayls-protocol/Enygma/Enygma-Payments/CurveBabyJubJub.sol";
import {ParticipantStructs} from "../../../privateHub/ParticipantStorage/libraries/ParticipantStructs.sol";

/**
 * @title EnygmaV1 nullifier-uniqueness ledger (#208) + #119 review items
 * @notice Clean branch off version/3.0.1 (issue/208), driving the REAL stock `transferBatch` /
 *         `updateSupply` signatures. All dependencies are stubbed, so the property under test is the
 *         nullifier-consumption invariant, not the cryptography.
 *
 *   #208 — nullifier-uniqueness ledger. Three distinct cases:
 *     - Cross-window replay: prevented by `blockNumber > lastblockNum` + the circuit binding nullifier
 *       to its block (a re-presented nullifier carries its now-finalised block)
 *       (test_realReplay_rejectedByBlockNumberMonotonicity).
 *     - Same-window duplicate: the block check can't catch it (same block), so the O(1)
 *       `consumedNullifiers` check is what prevents a second balance application
 *       (test_dvpPath_duplicateNullifier_rejectedByChokepointGuard).
 *     - Mismatched block (old nullifier, new block): reachable only via a verifier bypass — the ledger
 *       is the redundant backstop here (test_consumedNullifiersLedger_catchesReuseWithMismatchedBlock).
 *     Each consumption emits `NullifierConsumed` for off-chain indexers (test_nullifierConsumed_eventEmitted).
 *
 *   #119 #7 (LOW) — `updateSupply` burn bound message said "> Q" but compares against `CurveBabyJubJub.P`
 *     (the correct bound — `pedCom` multiplies the value by G). Fix: message => "Error: burnValue > P".
 *
 *   #119 #8 (LOW) — `sendEventsBatch` indexes `encryptedMessages` across `chainIds` with no length check
 *     (opaque out-of-bounds panic). Fix: explicit `require(encryptedMessages.length == chainIds.length)`.
 */

// ---------------------------------------------------------------------------
// Stubs (selector-compatible with the concrete dependencies EnygmaV1 calls)
// ---------------------------------------------------------------------------

/// @dev Two Enygma participant chains (1, 2) with fixed payment-spend public keys.
contract MockParticipantStorage {
    uint256 internal constant PK_CHAIN_1 = 1001;
    uint256 internal constant PK_CHAIN_2 = 1002;

    function getEnygmaAllParticipantsChainIds() external pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
    }

    function getAllPaymentSpendPublicKeys()
        external
        pure
        returns (ParticipantStructs.PrivacyNodeSpendDataSafeReturn[] memory keys)
    {
        keys = new ParticipantStructs.PrivacyNodeSpendDataSafeReturn[](2);
        keys[0] = ParticipantStructs.PrivacyNodeSpendDataSafeReturn({
            paymentSpendPublicKey: PK_CHAIN_1,
            pnAddresses: new address[](0),
            chainId: 1
        });
        keys[1] = ParticipantStructs.PrivacyNodeSpendDataSafeReturn({
            paymentSpendPublicKey: PK_CHAIN_2,
            pnAddresses: new address[](0),
            chainId: 2
        });
    }

    function checkEnygmaAccountAllowed(address) external pure returns (bool) {
        return true;
    }

    function checkEnygmaIssuerAccountAllowed(address, uint256) external pure returns (bool) {
        return true;
    }
}

/// @dev Endpoint stub: only `getChainId()` is exercised by `transferBatch` (via `checkFreeze`).
contract MockEndpoint {
    function getChainId() external pure returns (uint256) {
        return 1;
    }

    function getAddressByResourceId(bytes32) external pure returns (address) {
        return address(0);
    }
}

/// @dev Token registry stub: token is never frozen.
contract MockTokenRegistry {
    function isTokenFrozenForParticipant(bytes32, uint256) external pure returns (bool) {
        return false;
    }
}

/// @dev EnygmaTeleport stub: all outbound teleport calls are no-ops.
contract MockEnygmaTeleport {
    function transfer(bytes32, bytes calldata, uint256, uint256, uint256[] calldata, uint256[] calldata, uint256) external {}

    function enygmaSupplyUpdated(bytes32, uint256, IEnygmaV1.SupplyUpdateTx calldata, uint256) external {}

    function finalizeBalances(bytes32, uint256, uint256, IEnygmaV1.EnygmaPointWithChainId[] calldata) external {}

    function enygmaDvpBalanceUpdated(bytes calldata) external {}
}

/// @dev Groth16 verifier stub (k=2): accepts every proof so the test isolates the
///      nullifier-consumption invariant rather than the cryptography.
contract MockTransferVerifier {
    bool public shouldVerify = true;

    function setShouldVerify(bool v) external {
        shouldVerify = v;
    }

    function verifyProof(
        uint256[2] calldata,
        uint256[2][2] calldata,
        uint256[2] calldata,
        uint256[18] calldata
    ) external view returns (bool) {
        return shouldVerify;
    }
}

// ---------------------------------------------------------------------------
// Test
// ---------------------------------------------------------------------------

contract EnygmaV1NullifierReplayTest is Test {
    EnygmaV1 internal enygma;
    MockTransferVerifier internal verifier;

    // Must match MockParticipantStorage payment-spend public keys.
    uint256 internal constant PK_CHAIN_1 = 1001;
    uint256 internal constant PK_CHAIN_2 = 1002;

    uint256 internal constant CHAIN_1 = 1;
    uint256 internal constant CHAIN_2 = 2;
    bytes32 internal constant RESOURCE_ID = bytes32(uint256(0xE208));

    // Local copy of the contract event, for vm.expectEmit.
    event NullifierConsumed(bytes32 indexed resourceId, uint256 indexed nullifier, uint256 indexed blockNumber, IEnygmaV1.TxType txType);

    uint256 internal startBlock;

    function setUp() public {
        // Deterministic, non-zero starting block: lastblockNum = startBlock.
        startBlock = 100;
        vm.roll(startBlock);

        MockParticipantStorage ps = new MockParticipantStorage();
        MockEndpoint endpointMock = new MockEndpoint();
        MockTokenRegistry tr = new MockTokenRegistry();
        MockEnygmaTeleport teleport = new MockEnygmaTeleport();
        verifier = new MockTransferVerifier();

        // This test contract is the factory, so it may register the verifier.
        EnygmaCreationParams memory params = EnygmaCreationParams({
            name: "ReplayEnygma",
            symbol: "RE",
            decimals: 18,
            resourceId: RESOURCE_ID,
            owner: address(this),
            ownerChainId: CHAIN_1,
            participantStorageContract: address(ps),
            endpoint: address(endpointMock),
            tokenRegistryContract: address(tr),
            enygmaTeleport: address(teleport),
            factory: address(this)
        });

        enygma = new EnygmaV1(params);
        enygma.addTransferVerifier(address(verifier), 2);
    }

    // ---------------------------------------------------------------------
    // #208 — nullifier-uniqueness ledger. Three distinct cases:
    //  - Cross-window replay: prevented by `blockNumber > lastblockNum` + the circuit binding
    //    nullifier to its block (a replayed nullifier carries its now-finalised block).
    //  - Same-window duplicate: the block check is blind to it (same block), so the O(1)
    //    consumedNullifiers check is what prevents a second balance application.
    //  - Mismatched block (old nullifier, new block): reachable only via a verifier bypass — the
    //    ledger is the redundant backstop there, which is why that case is built with the mock.
    // ---------------------------------------------------------------------

    /// @notice REAL replay: reusing a consumed nullifier means resubmitting its original (now
    ///         finalised) blockNumber, so the blockNumber check rejects it first. This is the actual
    ///         protection and holds independently of the ledger.
    function test_realReplay_rejectedByBlockNumberMonotonicity() public {
        uint256 nullifierA = uint256(keccak256("nullifier-A"));
        uint256 nullifierB = uint256(keccak256("nullifier-B"));

        vm.roll(startBlock + 1);
        assertTrue(enygma.transferBatch(_buildProof(nullifierA, startBlock + 1), _emptyMessages()));

        // Higher-block transfer finalises window 1 (lastblockNum advances to startBlock + 1).
        vm.roll(startBlock + 2);
        assertTrue(enygma.transferBatch(_buildProof(nullifierB, startBlock + 2), _emptyMessages()));

        // A real replay of nullifierA carries its bound block (startBlock + 1), now finalised.
        vm.roll(startBlock + 3);
        vm.expectRevert(bytes("BlockNumber in Proof was already finalised."));
        enygma.transferBatch(_buildProof(nullifierA, startBlock + 1), _emptyMessages());
    }

    /// @notice Redundant-backstop case: the ledger catches a consumed nullifier arriving with a
    ///         non-original blockNumber that passes the block check. That (nullifier, blockNumber)
    ///         mismatch is UNREACHABLE with a sound verifier (the circuit binds them), so it is built
    ///         here only via the mock. This case is redundant with the block check — unlike the
    ///         same-window duplicate, which the block check cannot catch.
    function test_consumedNullifiersLedger_catchesReuseWithMismatchedBlock() public {
        uint256 nullifierA = uint256(keccak256("nullifier-A"));
        uint256 nullifierB = uint256(keccak256("nullifier-B"));

        vm.roll(startBlock + 1);
        assertTrue(enygma.transferBatch(_buildProof(nullifierA, startBlock + 1), _emptyMessages()));
        assertFalse(enygma.isNullifierUnspent(nullifierA), "nullifierA recorded in the permanent ledger");

        vm.roll(startBlock + 2);
        assertTrue(enygma.transferBatch(_buildProof(nullifierB, startBlock + 2), _emptyMessages()));

        // Mismatched pair (consumed nullifierA + fresh block) — passes the blockNumber check; only the
        // ledger rejects it. Without the ledger (stock) this would replay. Constructible solely because
        // the mock verifier skips the circuit's nullifier<->blockNumber binding.
        vm.roll(startBlock + 3);
        vm.expectRevert(bytes("Nullifier already used in pending transaction."));
        enygma.transferBatch(_buildProof(nullifierA, startBlock + 3), _emptyMessages());
    }

    // ---------------------------------------------------------------------
    // #119 finding #7 — burn bound message (P vs Q)
    // ---------------------------------------------------------------------

    /**
     * @notice A burn whose amount exceeds the curve scalar order (`CurveBabyJubJub.P`) must revert,
     *         and the message must name the ACTUAL bound (P), not Q. On stock the revert string is
     *         "Error: burnValue > Q" (wrong), so this expectRevert mismatches and the test FAILS;
     *         after the message fix it PASSES.
     */
    function test_burnAmountAboveScalarOrder_revertsWithCorrectMessage() public {
        IEnygmaV1.SupplyUpdateTx memory burnTx =
            IEnygmaV1.SupplyUpdateTx({amount: CurveBabyJubJub.P + 1, txType: IEnygmaV1.TxType.Burn});

        vm.roll(startBlock + 1);
        vm.expectRevert(bytes("Error: burnValue > P"));
        enygma.updateSupply(CHAIN_1, startBlock + 1, burnTx);
    }

    // ---------------------------------------------------------------------
    // #119 finding #8 — encryptedMessages length validation
    // ---------------------------------------------------------------------

    /**
     * @notice `sendEventsBatch` indexes `encryptedMessages` across `chainIds` (k=2). With fewer
     *         messages than chains, stock code reverts with an opaque array-out-of-bounds Panic;
     *         the fix reverts with an explicit length-mismatch message BEFORE the loop. On stock the
     *         Panic does not match this expectRevert, so the test FAILS; after the fix it PASSES.
     */
    function test_encryptedMessagesLengthMismatch_revertsExplicitly() public {
        uint256 nullifier = uint256(keccak256("len-mismatch"));
        bytes[] memory tooFew = new bytes[](1); // k=2 chains, only 1 message
        tooFew[0] = "";

        vm.roll(startBlock + 1);
        vm.expectRevert(bytes("EnygmaV1: encryptedMessages length mismatch"));
        enygma.transferBatch(_buildProof(nullifier, startBlock + 1), tooFew);
    }

    // ---------------------------------------------------------------------
    // DVP entrypoint — chokepoint uniqueness guard (claude[bot] review on PR #290)
    // ---------------------------------------------------------------------

    /**
     * @notice `dvpAddPendingTransaction` reaches `addPendingTransaction` without
     *         `validateTransferInputs`. The uniqueness guard at the recording chokepoint rejects a
     *         duplicate nullifier on that path, so a buggy/compromised DVP integration cannot push a
     *         second pending entry and apply its balance deltas twice. First add records the
     *         nullifier; the second reverts before any balance mutation.
     */
    function test_dvpPath_duplicateNullifier_rejectedByChokepointGuard() public {
        enygma.setDvpIntegrationContract(address(this)); // this test acts as the DVP integration
        uint256 n = uint256(keccak256("dvp-dup"));

        vm.roll(startBlock + 1);
        enygma.dvpFinalisePendingTransactions(startBlock + 1); // init window balances, as the real flow does
        enygma.dvpAddPendingTransaction(_buildProof(n, startBlock + 1), IEnygmaV1.TxType.Transfer);
        assertFalse(enygma.isNullifierUnspent(n), "nullifier recorded by the first DVP add");

        vm.expectRevert(bytes("EnygmaV1: nullifier already consumed"));
        enygma.dvpAddPendingTransaction(_buildProof(n, startBlock + 1), IEnygmaV1.TxType.Transfer);
    }

    // ---------------------------------------------------------------------
    // Audit trail — NullifierConsumed event
    // ---------------------------------------------------------------------

    /**
     * @notice Every nullifier consumption emits `NullifierConsumed(resourceId, nullifier, blockNumber,
     *         txType)` — the on-chain audit trail an off-chain indexer reads. Checks all topics + data.
     */
    function test_nullifierConsumed_eventEmitted() public {
        uint256 n = uint256(keccak256("audit-evt"));

        vm.roll(startBlock + 1);
        vm.expectEmit(true, true, true, true, address(enygma));
        emit NullifierConsumed(RESOURCE_ID, n, startBlock + 1, IEnygmaV1.TxType.Transfer);
        enygma.transferBatch(_buildProof(n, startBlock + 1), _emptyMessages());
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /**
     * @dev Builds a k=2 TransferProof whose 18 public signals satisfy every non-crypto check in
     *      `validateTransferInputs`. Layout (k=2):
     *      [0,1]=arrayHashSecrets, [2,3]=publicKeys, [4..7]=balances(2 points),
     *      [8..11]=commitments(2 points), [12]=nullifier, [13]=blockNumber,
     *      [14,15]=chainIds, [16,17]=messageTags.
     *      Balances and commitments are the curve identity (0,1): identity commitments keep the
     *      reference balances unchanged across windows so the balance-match check keeps passing.
     */
    function _buildProof(uint256 nullifier, uint256 blockNumber)
        internal
        pure
        returns (IEnygmaV1.TransferProof memory proof)
    {
        uint256[] memory ps = new uint256[](18);

        // arrayHashSecrets (arbitrary)
        ps[0] = 7;
        ps[1] = 9;
        // publicKeys — must match stored payment-spend keys per chainId order [1, 2]
        ps[2] = PK_CHAIN_1;
        ps[3] = PK_CHAIN_2;
        // balances (PreviousCommit) — identity (0,1) for both chains
        ps[4] = 0;
        ps[5] = 1;
        ps[6] = 0;
        ps[7] = 1;
        // commitments (TxCommit) — identity (0,1) for both chains
        ps[8] = 0;
        ps[9] = 1;
        ps[10] = 0;
        ps[11] = 1;
        // nullifier + blockNumber
        ps[12] = nullifier;
        ps[13] = blockNumber;
        // chainIds (KIndex)
        ps[14] = CHAIN_1;
        ps[15] = CHAIN_2;
        // messageTags
        ps[16] = 0;
        ps[17] = 0;

        uint256[2] memory pi_a;
        uint256[2][2] memory pi_b;
        uint256[2] memory pi_c;

        proof = IEnygmaV1.TransferProof({pi_a: pi_a, pi_b: pi_b, pi_c: pi_c, public_signal: ps});
    }

    function _emptyMessages() internal pure returns (bytes[] memory msgs) {
        msgs = new bytes[](2);
        msgs[0] = "";
        msgs[1] = "";
    }
}
