// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import '../../interfaces/IEnygmaV1.sol';
import '../../interfaces/IDvp.sol';
import '../../interfaces/IEnygmaDepositToDvpVerifierk2.sol';
import '../../interfaces/IEnygmaDepositToDvpVerifierk3.sol';
import '../../interfaces/IEnygmaDepositToDvpVerifierk4.sol';
import '../../interfaces/IEnygmaDepositToDvpVerifierk5.sol';
import '../../interfaces/IEnygmaDepositToDvpVerifierk6.sol';
import '../../interfaces/IEnygmaDvpIntegration.sol';
import '../../../privateHub/TokenRegistry/TokenRegistryV1.sol';
import '../../../rayls-protocol-sdk/interfaces/IRaylsEndpoint.sol';
import './EnygmaV1.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

/**
 * @title EnygmaDvpIntegration
 * @dev Extension contract for EnygmaV1 that adds DVP functionality
 */
contract EnygmaDvpIntegration is IEnygmaDvpIntegration, ReentrancyGuard {
    EnygmaV1 private _enygmaV1;
    address private _dvpAddress;
    uint256 private _vaultId;
    address public immutable factory;

    mapping(uint8 => address) public depositToDvpVerifiers;
    mapping(uint8 => address) public withdrawFromDvpVerifiers;

    error EnygmaDvpIntegration__OnlyFactoryAllowed();
    /// @dev The withdraw proof's PaymentCommitment does not equal the receipt's commitments[0].
    error EnygmaDvpIntegration__PaymentCommitmentMismatch();
    /// @dev The receipt has no output commitments, so there is no payment output to bind to.
    error EnygmaDvpIntegration__EmptyReceiptCommitments();
    /// @dev The proof has no public signals, so there is no trailing commitment to strip.
    error EnygmaDvpIntegration__EmptyPublicSignals();
    /// @dev The receipt's payment commitment is 0: an uninitialised value or a bug, never a real payment.
    error EnygmaDvpIntegration__ZeroPaymentCommitment();
    /// @dev The deposit's hashCommitment is 0, which would insert a trivially known note into the vault.
    error EnygmaDvpIntegration__ZeroHashCommitment();
    /// @dev A verifier or DvP address was set to zero, which would only surface later as a failed call.
    error EnygmaDvpIntegration__ZeroAddress();
    /// @dev The Enygma token is frozen for this participant.
    error EnygmaDvpIntegration__TokenFrozen();
    error EnygmaDvpIntegration__VaultIdAlreadySet();
    error EnygmaDvpIntegration__InvalidVaultId();
    error EnygmaDvpIntegration__VaultIdNotInitialized();
    error EnygmaDvpIntegration__DvpNotSet();
    /// @dev No verifier is registered for this k.
    error EnygmaDvpIntegration__VerifierNotSet(uint8 k);
    /// @dev The Groth16 verifier rejected the proof.
    error EnygmaDvpIntegration__InvalidProof();
    /// @dev k is outside the supported range (2-6).
    error EnygmaDvpIntegration__UnsupportedK(uint8 k);
    /// @dev The public signal count matches no supported k.
    error EnygmaDvpIntegration__InvalidPublicSignalLength(uint256 length);
    /// @dev The DvP contract returned false.
    error EnygmaDvpIntegration__DvpCallFailed();

    modifier onlyFactory() {
        if (msg.sender != factory) revert EnygmaDvpIntegration__OnlyFactoryAllowed();
        _;
    }

   /**
     * @dev Constructor that sets the address of the EnygmaV1 contract and the factory
     * @param enygmaV1Address The address of the EnygmaV1 contract
     * @param _factory The address of the factory contract authorized to configure this integration
     */
    constructor(address enygmaV1Address, address _factory) {
        if (enygmaV1Address == address(0) || _factory == address(0)) revert EnygmaDvpIntegration__ZeroAddress();
        _enygmaV1 = EnygmaV1(enygmaV1Address);
        factory = _factory;
    }

    modifier checkFreeze() {
        address tokenRegistryContract = _enygmaV1.tokenRegistryContract();
        TokenRegistryV1 tokenRegistry = TokenRegistryV1(tokenRegistryContract);
        bytes32 resourceId = _enygmaV1.resourceId();
        uint256 currentChainId = _enygmaV1.ownerChainId();
        bool isFrozen = tokenRegistry.isTokenFrozenForParticipant(resourceId, currentChainId);
        if (isFrozen) revert EnygmaDvpIntegration__TokenFrozen();
        _;
    }

    /// @dev Overwrites any verifier already set for `k`, unlike the set-once `setVaultId`: the factory
    ///      re-registers verifiers when a trusted-setup ceremony rotates the keys.
    function addDepositToDvpVerifier(address depositToDvpVerifier, uint8 k) external onlyFactory returns (bool) {
        if (depositToDvpVerifier == address(0)) revert EnygmaDvpIntegration__ZeroAddress();
        depositToDvpVerifiers[k] = depositToDvpVerifier;
        emit IEnygmaDvpIntegration.VerifierDepositToDvpRegistered(depositToDvpVerifier, k);
        return true;
    }

    /// @dev Overwrites any verifier already set for `k`; see addDepositToDvpVerifier.
    function addWithdrawFromDvpVerifier(address withdrawFromDvpVerifier, uint8 k) external onlyFactory returns (bool) {
        if (withdrawFromDvpVerifier == address(0)) revert EnygmaDvpIntegration__ZeroAddress();
        withdrawFromDvpVerifiers[k] = withdrawFromDvpVerifier;
        emit IEnygmaDvpIntegration.VerifierWithdrawFromDvpRegistered(withdrawFromDvpVerifier, k);
        return true;
    }

    /// @dev Overwrites any DvP address already set; DvpRegistered logs only the new one, so the previous
    ///      address comes from the earlier event. `_vaultId` is set-once: a replacement DvP must use the
    ///      same vault id, otherwise this integration has to be redeployed.
    function addDvp(address dvpAddress) external onlyFactory returns (bool) {
        if (dvpAddress == address(0)) revert EnygmaDvpIntegration__ZeroAddress();
        _dvpAddress = dvpAddress;
        emit IEnygmaDvpIntegration.DvpRegistered(dvpAddress);
        return true;
    }

    function setVaultId(uint256 vaultId) external onlyFactory returns (bool) {
        if (_vaultId != 0) revert EnygmaDvpIntegration__VaultIdAlreadySet();
        if (vaultId == 0) revert EnygmaDvpIntegration__InvalidVaultId();
        _vaultId = vaultId;
        emit IEnygmaDvpIntegration.VaultIdSet(vaultId);
        return true;
    }

    function depositToDvp(
        IEnygmaDvpIntegration.WithdrawOrDepositProof memory proof,
        bytes[] memory encryptedMessages,
        bytes calldata encryptedBurnUpdate
    ) external nonReentrant checkFreeze returns (bool) {
        // Reject before stripping hashCommitment so an empty proof doesn't panic on underflow
        if (proof.public_signal.length == 0) revert EnygmaDvpIntegration__EmptyPublicSignals();
        // hashCommitment is the extra element at the end of the deposit proof
        uint256 hashCommitment = proof.public_signal[proof.public_signal.length - 1];
        if (hashCommitment == 0) revert EnygmaDvpIntegration__ZeroHashCommitment();
        _dvpConfig(); // fail before proof verification if the integration isn't configured

        // Convert to transfer proof and extract all data in one place
        IEnygmaV1.TransferProof memory transferProof = _stripTrailingSignal(proof);
        IEnygmaV1.ExtractedProofData memory proofData = _extractProofDataFromTransferProof(transferProof);

        // Validate inputs and verify deposit proof
        _enygmaV1.dvpValidateTransferInputs(transferProof);
        _verifyZkProof(depositToDvpVerifiers[proofData.k], proofData.k, proof);

        // Finalize pending transactions
        _enygmaV1.dvpFinalisePendingTransactions(proofData.blockNumber);

        // Process deposit
        if (!processDeposit(hashCommitment)) revert EnygmaDvpIntegration__DvpCallFailed();

        // Add the current transaction to pending balances
        _enygmaV1.dvpAddPendingTransaction(transferProof, IEnygmaV1.TxType.Deposit);

        // Send events
        _enygmaV1.dvpSendEvents(proofData, encryptedMessages, encryptedBurnUpdate);

        // Update lastblockNumPending
        _enygmaV1.dvpSetLastblockNumPending(proofData.blockNumber);

        emit IEnygmaDvpIntegration.DepositToDvpSuccesful(hashCommitment, address(_enygmaV1));
        return true;
    }

    /**
     * @notice Credits Enygma with the value paid out of a DvP join-split.
     * @dev Invariants this function depends on:
     *      - The proof's last public signal (PaymentCommitment) must equal `transaction.commitments[0]`;
     *        this is what ties the credited amount to the burned DvP notes.
     *      - A commitment of 0 is rejected: it signals an uninitialised value or a bug. A Poseidon
     *        output of 0 is possible only with negligible (~2^-254) probability.
     *      - `transaction` is NOT verified here. It is trusted only because `processWithdraw` ->
     *        `IDvp.withdrawEnygma` -> `EnygmaCoinVault.withdraw` verifies its join-split proof, roots
     *        and nullifiers, and the whole call reverts if that fails. This is only as strong as the
     *        contract at `_dvpAddress`, which only the factory can set (`addDvp`).
     * @custom:security-invariant _checkPaymentBinding, _verifyZkProof and processWithdraw must all run in
     *        this one call. The binding alone proves nothing; moving either authentication step to
     *        another entry point reopens the inflated-credit exploit.
     */
    function withdrawFromDvp(
        IEnygmaDvpIntegration.WithdrawOrDepositProof memory proof,
        bytes[] memory encryptedMessages,
        IDvp.ProofReceipt memory transaction,
        bytes calldata encryptedMintUpdate
    ) external nonReentrant checkFreeze returns (bool) {
        if (proof.public_signal.length == 0) revert EnygmaDvpIntegration__EmptyPublicSignals();

        // Fail-fast binding check; see _checkPaymentBinding for why the calls below must stay here.
        _checkPaymentBinding(proof, transaction);
        _dvpConfig(); // fail before proof verification if the integration isn't configured

        // Convert to transfer proof and extract all data in one place
        IEnygmaV1.TransferProof memory transferProof = _stripTrailingSignal(proof);
        IEnygmaV1.ExtractedProofData memory proofData = _extractProofDataFromTransferProof(transferProof);

        // Validate inputs and verify withdraw proof
        _enygmaV1.dvpValidateTransferInputs(transferProof);
        _verifyZkProof(withdrawFromDvpVerifiers[proofData.k], proofData.k, proof);

        // Finalize pending transactions
        _enygmaV1.dvpFinalisePendingTransactions(proofData.blockNumber);

        // Process withdrawal
        if (!processWithdraw(transaction)) revert EnygmaDvpIntegration__DvpCallFailed();

        // Add the current transaction to pending balances
        _enygmaV1.dvpAddPendingTransaction(transferProof, IEnygmaV1.TxType.Withdraw);

        // Send events
        _enygmaV1.dvpSendEvents(proofData, encryptedMessages, encryptedMintUpdate);

        // Update lastblockNumPending
        _enygmaV1.dvpSetLastblockNumPending(proofData.blockNumber);

        emit IEnygmaDvpIntegration.WithdrawFromDvpSuccesful(transaction, address(_enygmaV1));
        return true;
    }

    /**
     * @notice Merges DvP vault notes into new outputs via a join-split receipt.
     * @dev Permissionless by design: anyone may relay a valid receipt. Authorisation comes from the
     *      receipt itself, which `Dvp.mixFunds` -> `EnygmaCoinVault.transfer` verifies (join-split
     *      proof, roots, nullifiers) before spending any note. `Dvp.mixFunds` is `restricted`, so this
     *      contract is the only Enygma entry point to it; that gate is not a caller check.
     *      The freeze check applies: a join-split can pay notes to other keys, so consolidation could
     *      otherwise move value while the token is frozen for this participant.
     * @param transaction The join-split receipt to apply.
     */
    function consolidateFunds(IDvp.ProofReceipt memory transaction) external nonReentrant checkFreeze returns (bool) {
        (uint256 vaultId, address dvpAddress) = _dvpConfig();
        if (!IDvp(dvpAddress).mixFunds(vaultId, transaction)) revert EnygmaDvpIntegration__DvpCallFailed();
        return true;
    }

    // Extract proof data from transfer proof (mirrors EnygmaV1.extractProofData)
    // Public signal layout: [ArrayHashSecrets (k), PublicKeys (k), PreviousCommit (2*k), TxCommit (2*k), Nullifier, BlockNumber, KIndex (k), MessageTags (k)]
    function _extractProofDataFromTransferProof(IEnygmaV1.TransferProof memory proof) internal pure returns (IEnygmaV1.ExtractedProofData memory data) {
        data.k = _extractKFromTransferProof(proof);
        data.proofLength = proof.public_signal.length;
        uint256 k = data.k;

        // Extract arrayHashSecrets (k elements starting at 0)
        data.arrayHashSecrets = new uint256[](k);
        for (uint256 i = 0; i < k; i++) {
            data.arrayHashSecrets[i] = proof.public_signal[i];
        }

        // Extract public keys (k elements starting at k)
        data.publicKeys = new uint256[](k);
        uint256 pkBase = k;
        for (uint256 i = 0; i < k; i++) {
            data.publicKeys[i] = proof.public_signal[pkBase + i];
        }

        // Extract balances/PreviousCommit (k points starting at 2*k)
        data.balances = new IEnygmaV1.Point[](k);
        uint256 balanceBase = 2 * k;
        for (uint256 i = 0; i < k; i++) {
            data.balances[i] = IEnygmaV1.Point({
                c1: proof.public_signal[balanceBase + i * 2],
                c2: proof.public_signal[balanceBase + i * 2 + 1]
            });
        }

        // Extract TxCommit/commitments (k points starting at 4*k)
        data.commitments = new IEnygmaV1.Point[](k);
        uint256 commitBase = 4 * k;
        for (uint256 i = 0; i < k; i++) {
            data.commitments[i] = IEnygmaV1.Point({
                c1: proof.public_signal[commitBase + i * 2],
                c2: proof.public_signal[commitBase + i * 2 + 1]
            });
        }

        // Extract nullifier and blockNumber (after TxCommit at 6*k)
        uint256 nullifierIndex = 6 * k;
        data.nullifier = proof.public_signal[nullifierIndex];
        data.blockNumber = proof.public_signal[nullifierIndex + 1];

        // Extract chainIds/KIndex (k elements starting at 6*k + 2)
        data.chainIds = new uint256[](k);
        uint256 chainIdBase = 6 * k + 2;
        for (uint256 i = 0; i < k; i++) {
            data.chainIds[i] = proof.public_signal[chainIdBase + i];
        }

        // Extract messageTags (k elements starting at 7*k + 2)
        data.messageTags = new uint256[](k);
        uint256 tagBase = 7 * k + 2;
        for (uint256 i = 0; i < k; i++) {
            data.messageTags[i] = proof.public_signal[tagBase + i];
        }

        return data;
    }

    function _extractKFromTransferProof(IEnygmaV1.TransferProof memory proof) internal pure returns (uint8) {
        uint256 length = proof.public_signal.length;
        // Formula: 8*k + 2
        // For k=2: 16 + 2 = 18
        // For k=3: 24 + 2 = 26
        // For k=4: 32 + 2 = 34
        // For k=5: 40 + 2 = 42
        // For k=6: 48 + 2 = 50
        if (length == 18) return 2;
        if (length == 26) return 3;
        if (length == 34) return 4;
        if (length == 42) return 5;
        if (length == 50) return 6;
        revert EnygmaDvpIntegration__InvalidPublicSignalLength(length);
    }

    /**
     * @dev Binds the credit to the burned value: the proof's last signal (paymentCommitment) must equal
     *      the receipt's payment output. This is a fail-fast check, not a complete one: it is sound only
     *      because withdrawFromDvp then runs _verifyZkProof (authenticates the signal) and
     *      processWithdraw (authenticates the receipt). Both must stay in withdrawFromDvp; moving either
     *      to a separate call path would decouple the binding and reopen the inflated-credit exploit.
     */
    function _checkPaymentBinding(
        IEnygmaDvpIntegration.WithdrawOrDepositProof memory proof,
        IDvp.ProofReceipt memory transaction
    ) internal pure {
        if (transaction.commitments.length == 0) revert EnygmaDvpIntegration__EmptyReceiptCommitments();
        uint256 receiptPayment = transaction.commitments[0];
        // A zero proof signal could only pass by matching a zero receipt, which is rejected here first,
        // so a zero signal always reverts (with PaymentCommitmentMismatch against a non-zero receipt).
        if (receiptPayment == 0) revert EnygmaDvpIntegration__ZeroPaymentCommitment();
        if (receiptPayment != proof.public_signal[proof.public_signal.length - 1]) {
            revert EnygmaDvpIntegration__PaymentCommitmentMismatch();
        }
    }

    /**
     * @dev Verifies a deposit or withdraw proof against `verifier`. Deposit and withdraw circuits share
     *      the 8k + 3 public-signal layout and the same verifyProof ABI per k, so one dispatch table
     *      serves both; the caller picks the verifier mapping. The IEnygmaDepositToDvpVerifierkN types are
     *      used for both families; EnygmaDvpIntegration_VerifierAbi.t.sol fails if the deposit and
     *      withdraw selectors ever diverge, at which point this must split per family.
     */
    function _verifyZkProof(address verifier, uint8 k, IEnygmaDvpIntegration.WithdrawOrDepositProof memory proof) internal view {
        if (verifier == address(0)) revert EnygmaDvpIntegration__VerifierNotSet(k);
        bool valid;
        // 8*k + 3 = k2:19, k3:27, k4:35, k5:43, k6:51. Withdraw verifiers (and their proxies) expose the
        // same verifyProof ABI, which is why IEnygmaWithdrawFromDvpVerifierkN isn't imported here.
        if (k == 2) {
            valid = IEnygmaDepositToDvpVerifierk2(verifier).verifyProof(proof.pi_a, proof.pi_b, proof.pi_c, convertToUint256Array19(proof.public_signal));
        } else if (k == 3) {
            valid = IEnygmaDepositToDvpVerifierk3(verifier).verifyProof(proof.pi_a, proof.pi_b, proof.pi_c, convertToUint256Array27(proof.public_signal));
        } else if (k == 4) {
            valid = IEnygmaDepositToDvpVerifierk4(verifier).verifyProof(proof.pi_a, proof.pi_b, proof.pi_c, convertToUint256Array35(proof.public_signal));
        } else if (k == 5) {
            valid = IEnygmaDepositToDvpVerifierk5(verifier).verifyProof(proof.pi_a, proof.pi_b, proof.pi_c, convertToUint256Array43(proof.public_signal));
        } else if (k == 6) {
            valid = IEnygmaDepositToDvpVerifierk6(verifier).verifyProof(proof.pi_a, proof.pi_b, proof.pi_c, convertToUint256Array51(proof.public_signal));
        } else {
            revert EnygmaDvpIntegration__UnsupportedK(k);
        }
        if (!valid) revert EnygmaDvpIntegration__InvalidProof();
    }

    function processDeposit(uint256 hashCommitment) private returns (bool) {
        (uint256 vaultId, address dvpAddress) = _dvpConfig();
        return IDvp(dvpAddress).depositEnygma(vaultId, hashCommitment);
    }

    function processWithdraw(IDvp.ProofReceipt memory transaction) private returns (bool) {
        (uint256 vaultId, address dvpAddress) = _dvpConfig();
        return IDvp(dvpAddress).withdrawEnygma(vaultId, transaction);
    }

    /// @dev Reads the vault id and DvP address once, reverting if either is unset.
    function _dvpConfig() internal view returns (uint256 vaultId, address dvpAddress) {
        vaultId = _vaultId;
        dvpAddress = _dvpAddress;
        if (vaultId == 0) revert EnygmaDvpIntegration__VaultIdNotInitialized();
        if (dvpAddress == address(0)) revert EnygmaDvpIntegration__DvpNotSet();
    }

    /**
     * @dev Drops the circuit-specific trailing signal (paymentCommitment for withdraw, hashCommitment
     *      for deposit) to get the 8k + 2 transfer layout EnygmaV1 expects. Callers check emptiness too;
     *      repeated here so the helper is safe on its own.
     */
    function _stripTrailingSignal(IEnygmaDvpIntegration.WithdrawOrDepositProof memory proof) internal pure returns (IEnygmaV1.TransferProof memory transferProof) {
        if (proof.public_signal.length == 0) revert EnygmaDvpIntegration__EmptyPublicSignals();
        transferProof.pi_a = proof.pi_a;
        transferProof.pi_b = proof.pi_b;
        transferProof.pi_c = proof.pi_c;

        uint256[] memory adjustedPublicSignal = new uint256[](proof.public_signal.length - 1);
        for (uint256 i = 0; i < adjustedPublicSignal.length; i++) {
            adjustedPublicSignal[i] = proof.public_signal[i];
        }
        transferProof.public_signal = adjustedPublicSignal;
    }

    // Deposit and withdraw verifier array conversions: 8*k + 3
    // k=2: 19, k=3: 27, k=4: 35, k=5: 43, k=6: 51
    function convertToUint256Array19(uint256[] memory dynamicArray) internal pure returns (uint256[19] memory fixedArray) {
        if (dynamicArray.length != 19) revert EnygmaDvpIntegration__InvalidPublicSignalLength(dynamicArray.length);
        for (uint256 i = 0; i < 19; i++) {
            fixedArray[i] = dynamicArray[i];
        }
        return fixedArray;
    }

    function convertToUint256Array27(uint256[] memory dynamicArray) internal pure returns (uint256[27] memory fixedArray) {
        if (dynamicArray.length != 27) revert EnygmaDvpIntegration__InvalidPublicSignalLength(dynamicArray.length);
        for (uint256 i = 0; i < 27; i++) {
            fixedArray[i] = dynamicArray[i];
        }
        return fixedArray;
    }

    function convertToUint256Array35(uint256[] memory dynamicArray) internal pure returns (uint256[35] memory fixedArray) {
        if (dynamicArray.length != 35) revert EnygmaDvpIntegration__InvalidPublicSignalLength(dynamicArray.length);
        for (uint256 i = 0; i < 35; i++) {
            fixedArray[i] = dynamicArray[i];
        }
        return fixedArray;
    }

    function convertToUint256Array43(uint256[] memory dynamicArray) internal pure returns (uint256[43] memory fixedArray) {
        if (dynamicArray.length != 43) revert EnygmaDvpIntegration__InvalidPublicSignalLength(dynamicArray.length);
        for (uint256 i = 0; i < 43; i++) {
            fixedArray[i] = dynamicArray[i];
        }
        return fixedArray;
    }

    function convertToUint256Array51(uint256[] memory dynamicArray) internal pure returns (uint256[51] memory fixedArray) {
        if (dynamicArray.length != 51) revert EnygmaDvpIntegration__InvalidPublicSignalLength(dynamicArray.length);
        for (uint256 i = 0; i < 51; i++) {
            fixedArray[i] = dynamicArray[i];
        }
        return fixedArray;
    }

    function getDepositToDvpVerifierAddress(uint8 k) public view returns (address) {
        return depositToDvpVerifiers[k];
    }

    function getWithdrawFromDvpVerifierAddress(uint8 k) public view returns (address) {
        return withdrawFromDvpVerifiers[k];
    }

    function getDvpAddress() public view returns (address) {
        return _dvpAddress;
    }

    function getVaultId() public view returns (uint256) {
        return _vaultId;
    }
}