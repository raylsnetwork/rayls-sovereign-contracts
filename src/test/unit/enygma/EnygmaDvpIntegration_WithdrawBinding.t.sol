// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import "../../../rayls-protocol/Enygma/Enygma-Payments/EnygmaDvpIntegration.sol";

/**
 * @title Security Test: withdrawFromDvp binds the credit to the burned DvP payment
 * @notice The withdraw proof's last public input is a commitment to the credited amount.
 *         withdrawFromDvp must only accept it when it equals the join-split receipt's
 *         payment output (commitments[0]); otherwise a small DvP burn could back an
 *         arbitrary Enygma credit.
 * @dev EnygmaV1, the token registry, the DvP contract and the verifier are mocked; the
 *      proof itself is not checked here, only the binding and the verifier input size.
 */
contract EnygmaDvpIntegrationWithdrawBindingTest is Test {
    EnygmaDvpIntegration public integration;

    address public factory;
    address public enygmaV1;
    address public tokenRegistry;
    address public dvp;
    address public verifier;

    uint256 constant K = 2;
    uint256 constant PAYMENT_COMMITMENT = 0xC0FFEE;

    function setUp() public {
        factory = makeAddr("factory");
        enygmaV1 = makeAddr("enygmaV1");
        tokenRegistry = makeAddr("tokenRegistry");
        dvp = makeAddr("dvp");
        verifier = makeAddr("verifier");

        // High-level calls require code at the target; mocks answer the calls. INVALID (0xfe)
        // makes any call that lacks a mock revert instead of silently returning nothing.
        vm.etch(enygmaV1, hex"fe");
        vm.etch(tokenRegistry, hex"fe");
        vm.etch(dvp, hex"fe");
        vm.etch(verifier, hex"fe");

        integration = new EnygmaDvpIntegration(enygmaV1, factory);
        vm.startPrank(factory);
        integration.addWithdrawFromDvpVerifier(verifier, uint8(K));
        integration.addDvp(dvp);
        integration.setVaultId(1);
        vm.stopPrank();

        vm.mockCall(enygmaV1, abi.encodeWithSignature("tokenRegistryContract()"), abi.encode(tokenRegistry));
        vm.mockCall(enygmaV1, abi.encodeWithSignature("resourceId()"), abi.encode(bytes32("resource")));
        vm.mockCall(enygmaV1, abi.encodeWithSignature("ownerChainId()"), abi.encode(uint256(1)));
        vm.mockCall(tokenRegistry, abi.encodeWithSelector(TokenRegistryV1.isTokenFrozenForParticipant.selector), abi.encode(false));
        vm.mockCall(enygmaV1, abi.encodeWithSelector(EnygmaV1.dvpValidateTransferInputs.selector), "");
        vm.mockCall(enygmaV1, abi.encodeWithSelector(EnygmaV1.dvpFinalisePendingTransactions.selector), "");
        vm.mockCall(enygmaV1, abi.encodeWithSelector(EnygmaV1.dvpAddPendingTransaction.selector), "");
        vm.mockCall(enygmaV1, abi.encodeWithSelector(EnygmaV1.dvpSendEvents.selector), "");
        vm.mockCall(enygmaV1, abi.encodeWithSelector(EnygmaV1.dvpSetLastblockNumPending.selector), "");
        vm.mockCall(verifier, abi.encodeWithSelector(IEnygmaWithdrawFromDvpVerifierk2.verifyProof.selector), abi.encode(true));
        vm.mockCall(dvp, abi.encodeWithSelector(IDvp.withdrawEnygma.selector), abi.encode(true));
    }

    /// @dev A k=2 withdraw proof: 8k + 2 transfer signals followed by the payment commitment.
    function _withdrawProof(uint256 paymentCommitment)
        internal
        pure
        returns (IEnygmaDvpIntegration.WithdrawOrDepositProof memory proof)
    {
        proof.public_signal = new uint256[](8 * K + 3);
        proof.public_signal[8 * K + 2] = paymentCommitment;
    }

    function _receipt(uint256[] memory commitments) internal pure returns (IDvp.ProofReceipt memory receipt) {
        receipt.commitments = commitments;
    }

    function _commitments(uint256 payment, uint256 change) internal pure returns (uint256[] memory c) {
        c = new uint256[](2);
        c[0] = payment;
        c[1] = change;
    }

    function test_withdrawFromDvp_matchingPaymentCommitment_succeeds() public {
        vm.expectCall(verifier, abi.encodeWithSelector(IEnygmaWithdrawFromDvpVerifierk2.verifyProof.selector));
        vm.expectCall(dvp, abi.encodeWithSelector(IDvp.withdrawEnygma.selector));

        bool ok = integration.withdrawFromDvp(
            _withdrawProof(PAYMENT_COMMITMENT), new bytes[](0), _receipt(_commitments(PAYMENT_COMMITMENT, 7)), ""
        );
        assertTrue(ok);
    }

    /// @notice The freeze check runs before anything else on the withdraw path.
    function test_withdrawFromDvp_tokenFrozen_reverts() public {
        vm.mockCall(tokenRegistry, abi.encodeWithSelector(TokenRegistryV1.isTokenFrozenForParticipant.selector), abi.encode(true));

        vm.expectRevert(EnygmaDvpIntegration.EnygmaDvpIntegration__TokenFrozen.selector);
        integration.withdrawFromDvp(
            _withdrawProof(PAYMENT_COMMITMENT), new bytes[](0), _receipt(_commitments(PAYMENT_COMMITMENT, 7)), ""
        );
    }

    function test_SECURITY_withdrawFromDvp_otherPaymentCommitment_reverts() public {
        vm.expectRevert(EnygmaDvpIntegration.EnygmaDvpIntegration__PaymentCommitmentMismatch.selector);
        integration.withdrawFromDvp(
            _withdrawProof(PAYMENT_COMMITMENT), new bytes[](0), _receipt(_commitments(PAYMENT_COMMITMENT + 1, 7)), ""
        );
    }

    /// @notice The change output must not be accepted in place of the payment output.
    function test_SECURITY_withdrawFromDvp_changeOutputAsPayment_reverts() public {
        vm.expectRevert(EnygmaDvpIntegration.EnygmaDvpIntegration__PaymentCommitmentMismatch.selector);
        integration.withdrawFromDvp(
            _withdrawProof(PAYMENT_COMMITMENT), new bytes[](0), _receipt(_commitments(7, PAYMENT_COMMITMENT)), ""
        );
    }

    function test_SECURITY_withdrawFromDvp_receiptWithoutOutputs_reverts() public {
        vm.expectRevert(EnygmaDvpIntegration.EnygmaDvpIntegration__PaymentCommitmentMismatch.selector);
        integration.withdrawFromDvp(
            _withdrawProof(PAYMENT_COMMITMENT), new bytes[](0), _receipt(new uint256[](0)), ""
        );
    }

    /// @notice An empty proof must revert with a dedicated error, not an index-underflow panic.
    function test_SECURITY_withdrawFromDvp_emptyProofSignals_reverts() public {
        IEnygmaDvpIntegration.WithdrawOrDepositProof memory proof;
        proof.public_signal = new uint256[](0);

        vm.expectRevert(EnygmaDvpIntegration.EnygmaDvpIntegration__EmptyPublicSignals.selector);
        integration.withdrawFromDvp(proof, new bytes[](0), _receipt(_commitments(PAYMENT_COMMITMENT, 7)), "");
    }

    /// @notice A proof carrying only the payment commitment passes the binding but has no
    ///         transfer signals, so it is rejected by the layout check.
    function test_withdrawFromDvp_onlyPaymentCommitmentSignal_reverts() public {
        IEnygmaDvpIntegration.WithdrawOrDepositProof memory proof;
        proof.public_signal = new uint256[](1);
        proof.public_signal[0] = PAYMENT_COMMITMENT;

        vm.expectRevert(abi.encodeWithSelector(EnygmaDvpIntegration.EnygmaDvpIntegration__InvalidPublicSignalLength.selector, 0));
        integration.withdrawFromDvp(proof, new bytes[](0), _receipt(_commitments(PAYMENT_COMMITMENT, 7)), "");
    }

    /// @notice A zero payment commitment on both sides must not pass the binding.
    function test_SECURITY_withdrawFromDvp_zeroPaymentCommitment_reverts() public {
        vm.expectRevert(EnygmaDvpIntegration.EnygmaDvpIntegration__ZeroPaymentCommitment.selector);
        integration.withdrawFromDvp(_withdrawProof(0), new bytes[](0), _receipt(_commitments(0, 7)), "");
    }

    /// @notice Any non-zero commitment, up to the top of the uint256 range, binds when both sides match.
    function testFuzz_withdrawFromDvp_matchingPaymentCommitment_succeeds(uint256 commitment) public {
        vm.assume(commitment != 0);

        bool ok = integration.withdrawFromDvp(
            _withdrawProof(commitment), new bytes[](0), _receipt(_commitments(commitment, 7)), ""
        );
        assertTrue(ok);
    }

    /// @notice Any difference between the proof's commitment and the receipt's payment output reverts.
    function testFuzz_SECURITY_withdrawFromDvp_mismatchedPaymentCommitment_reverts(
        uint256 proofCommitment,
        uint256 receiptCommitment
    ) public {
        vm.assume(proofCommitment != receiptCommitment);
        vm.assume(receiptCommitment != 0); // a zero receipt has its own error, tested above

        vm.expectRevert(EnygmaDvpIntegration.EnygmaDvpIntegration__PaymentCommitmentMismatch.selector);
        integration.withdrawFromDvp(
            _withdrawProof(proofCommitment), new bytes[](0), _receipt(_commitments(receiptCommitment, 7)), ""
        );
    }

    /// @notice A proof the verifier rejects reverts with InvalidProof, after the binding passes.
    function test_withdrawFromDvp_verifierRejects_reverts() public {
        vm.mockCall(verifier, abi.encodeWithSelector(IEnygmaWithdrawFromDvpVerifierk2.verifyProof.selector), abi.encode(false));

        vm.expectRevert(EnygmaDvpIntegration.EnygmaDvpIntegration__InvalidProof.selector);
        integration.withdrawFromDvp(
            _withdrawProof(PAYMENT_COMMITMENT), new bytes[](0), _receipt(_commitments(PAYMENT_COMMITMENT, 7)), ""
        );
    }

    /// @notice A well-formed proof for a k with no registered verifier reverts with VerifierNotSet(k).
    function test_withdrawFromDvp_verifierNotSet_reverts() public {
        IEnygmaDvpIntegration.WithdrawOrDepositProof memory proof;
        proof.public_signal = new uint256[](8 * 3 + 3);
        proof.public_signal[8 * 3 + 2] = PAYMENT_COMMITMENT;

        vm.expectRevert(abi.encodeWithSelector(EnygmaDvpIntegration.EnygmaDvpIntegration__VerifierNotSet.selector, uint8(3)));
        integration.withdrawFromDvp(proof, new bytes[](0), _receipt(_commitments(PAYMENT_COMMITMENT, 7)), "");
    }

    /// @notice The old 8k + 12 layout (10 trailing note hashes) is no longer a valid withdraw proof.
    /// @dev The last signal matches the receipt, so the binding passes; the rejection must come
    ///      from the layout itself (8k + 11 transfer signals match no supported k).
    function test_withdrawFromDvp_oldPublicSignalLayout_reverts() public {
        IEnygmaDvpIntegration.WithdrawOrDepositProof memory proof;
        proof.public_signal = new uint256[](8 * K + 12);
        proof.public_signal[8 * K + 11] = PAYMENT_COMMITMENT;

        vm.expectRevert(abi.encodeWithSelector(EnygmaDvpIntegration.EnygmaDvpIntegration__InvalidPublicSignalLength.selector, 8 * K + 11));
        integration.withdrawFromDvp(proof, new bytes[](0), _receipt(_commitments(PAYMENT_COMMITMENT, 7)), "");
    }
}
