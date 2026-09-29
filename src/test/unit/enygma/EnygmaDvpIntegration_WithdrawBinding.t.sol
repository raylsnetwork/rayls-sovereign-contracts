// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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

        // High-level calls require code at the target; mocks answer the calls.
        vm.etch(enygmaV1, hex"00");
        vm.etch(tokenRegistry, hex"00");
        vm.etch(dvp, hex"00");
        vm.etch(verifier, hex"00");

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

    /// @notice The old 8k + 12 layout (10 trailing note hashes) is no longer a valid withdraw proof.
    function test_withdrawFromDvp_oldPublicSignalLayout_reverts() public {
        IEnygmaDvpIntegration.WithdrawOrDepositProof memory proof;
        proof.public_signal = new uint256[](8 * K + 12);
        proof.public_signal[8 * K + 11] = PAYMENT_COMMITMENT;

        vm.expectRevert();
        integration.withdrawFromDvp(proof, new bytes[](0), _receipt(_commitments(PAYMENT_COMMITMENT, 7)), "");
    }
}
