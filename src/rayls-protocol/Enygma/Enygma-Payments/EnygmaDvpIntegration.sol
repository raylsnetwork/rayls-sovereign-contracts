// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '../../interfaces/IEnygmaV1.sol';
import '../../interfaces/IDvp.sol';
import '../../interfaces/IEnygmaWithdrawFromDvpVerifierk2.sol';
import '../../interfaces/IEnygmaWithdrawFromDvpVerifierk3.sol';
import '../../interfaces/IEnygmaWithdrawFromDvpVerifierk4.sol';
import '../../interfaces/IEnygmaWithdrawFromDvpVerifierk5.sol';
import '../../interfaces/IEnygmaWithdrawFromDvpVerifierk6.sol';
import '../../interfaces/IEnygmaDepositToDvpVerifierk2.sol';
import '../../interfaces/IEnygmaDepositToDvpVerifierk3.sol';
import '../../interfaces/IEnygmaDepositToDvpVerifierk4.sol';
import '../../interfaces/IEnygmaDepositToDvpVerifierk5.sol';
import '../../interfaces/IEnygmaDepositToDvpVerifierk6.sol';
import '../../interfaces/IEnygmaDvpIntegration.sol';
import '../../../privateHub/TokenRegistry/TokenRegistryV1.sol';
import '../../../rayls-protocol-sdk/interfaces/IRaylsEndpoint.sol';
import './EnygmaV1.sol';

/**
 * @title EnygmaDvpIntegration
 * @dev Extension contract for EnygmaV1 that adds DVP functionality
 */
contract EnygmaDvpIntegration {
    EnygmaV1 private _enygmaV1;
    address private _dvpAddress;
    address private _enygmaV1Address;
    uint256 private _vaultId;
    address public immutable factory;

    mapping(uint256 => address) public depositToDvpVerifiers;
    mapping(uint256 => address) public withdrawFromDvpVerifiers;

    error EnygmaDvpIntegration__OnlyFactoryAllowed();

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
        _enygmaV1Address = enygmaV1Address;
        _enygmaV1 = EnygmaV1(enygmaV1Address);
        factory = _factory;
    }

    bool private _processing;

    modifier checkFreeze() {
        address tokenRegistryContract = _enygmaV1.tokenRegistryContract();
        TokenRegistryV1 tokenRegistry = TokenRegistryV1(tokenRegistryContract);
        bytes32 resourceId = _enygmaV1.resourceId();
        uint256 currentChainId = _enygmaV1.ownerChainId();
        bool isFrozen = tokenRegistry.isTokenFrozenForParticipant(resourceId, currentChainId);
        require(!isFrozen, 'Token is in freeze status for this participant');
        _;
    }

    modifier nonReentrant() {
        require(!_processing, "ReentrancyGuard: reentrant call");
        _processing = true;
        _;
        _processing = false;
    }

    function addDepositToDvpVerifier(address depositToDvpVerifier, uint8 k) public onlyFactory returns (bool) {
        depositToDvpVerifiers[k] = depositToDvpVerifier;
        emit IEnygmaDvpIntegration.VerifierDepositToDvpRegistered(depositToDvpVerifier, k);
        return true;
    }

    function addWithdrawFromDvpVerifier(address withdrawFromDvpVerifier, uint8 k) public onlyFactory returns (bool) {
        withdrawFromDvpVerifiers[k] = withdrawFromDvpVerifier;
        emit IEnygmaDvpIntegration.VerifierWithdrawFromDvpRegistered(withdrawFromDvpVerifier, k);
        return true;
    }

    function addDvp(address dvpAddress) public onlyFactory returns (bool) {
        _dvpAddress = dvpAddress;
        return true;
    }

    function setVaultId(uint256 vaultId) public onlyFactory returns (bool) {
        require(_vaultId == 0, 'VaultId already set');
        require(vaultId != 0, 'Invalid vaultId');
        _vaultId = vaultId;
        return true;
    }

    function depositToDvp(
        IEnygmaDvpIntegration.WithdrawOrDepositProof memory proof,
        bytes[] memory encryptedMessages,
        bytes calldata encryptedBurnUpdate
    ) public checkFreeze nonReentrant returns (bool) {
        // Convert to transfer proof and extract all data in one place
        IEnygmaV1.TransferProof memory transferProof = convertDepositProofToTransferProof(proof);
        IEnygmaV1.ExtractedProofData memory proofData = _extractProofDataFromTransferProof(transferProof);

        // Validate inputs and verify deposit proof
        _enygmaV1.dvpValidateTransferInputs(transferProof);
        require(depositToDvpVerifiers[proofData.k] != address(0), 'Deposit verifier not set for given k');
        verifyDepositProof(proofData.k, proof);

        // Finalize pending transactions
        _enygmaV1.dvpFinalisePendingTransactions(proofData.blockNumber);

        // Process deposit - hashCommitment is the extra element at the end of deposit proof
        uint256 hashCommitment = uint256(proof.public_signal[proof.public_signal.length - 1]);
        require(processDeposit(hashCommitment), 'DVP deposit processing failed');

        // Add the current transaction to pending balances
        _enygmaV1.dvpAddPendingTransaction(transferProof, IEnygmaV1.TxType.Deposit);

        // Send events
        _enygmaV1.dvpSendEvents(proofData, encryptedMessages, encryptedBurnUpdate);

        // Update lastblockNumPending
        _enygmaV1.dvpSetLastblockNumPending(proofData.blockNumber);

        emit IEnygmaDvpIntegration.DepositToDvpSuccesful(hashCommitment, msg.sender);
        return true;
    }

    function withdrawFromDvp(
        IEnygmaDvpIntegration.WithdrawOrDepositProof memory proof,
        bytes[] memory encryptedMessages,
        IDvp.ProofReceipt memory transaction,
        bytes calldata encryptedMintUpdate
    ) public checkFreeze nonReentrant returns (bool) {
        // Convert to transfer proof and extract all data in one place
        IEnygmaV1.TransferProof memory transferProof = convertWithdrawProofToTransferProof(proof);
        IEnygmaV1.ExtractedProofData memory proofData = _extractProofDataFromTransferProof(transferProof);

        // Validate inputs and verify withdraw proof
        _enygmaV1.dvpValidateTransferInputs(transferProof);
        require(withdrawFromDvpVerifiers[proofData.k] != address(0), 'Withdraw verifier not set for given k');
        verifyWithdrawProof(proofData.k, proof);

        // Finalize pending transactions
        _enygmaV1.dvpFinalisePendingTransactions(proofData.blockNumber);

        // Process withdrawal
        require(processWithdraw(transaction), 'DVP withdrawal processing failed');

        // Add the current transaction to pending balances
        _enygmaV1.dvpAddPendingTransaction(transferProof, IEnygmaV1.TxType.Withdraw);

        // Send events
        _enygmaV1.dvpSendEvents(proofData, encryptedMessages, encryptedMintUpdate);

        // Update lastblockNumPending
        _enygmaV1.dvpSetLastblockNumPending(proofData.blockNumber);

        emit IEnygmaDvpIntegration.WithdrawFromDvpSuccesful(transaction, msg.sender);
        return true;
    }

    function consolidateFunds(IDvp.ProofReceipt memory transaction) public returns (bool) {
        require(_vaultId != 0, 'VaultId not initialized');
        require(_dvpAddress != address(0), 'Dvp address not set');

        IDvp dvp = IDvp(_dvpAddress);
        bool successDvpCall = dvp.mixFunds(_vaultId, transaction);
        return successDvpCall;
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
        revert('Invalid transfer proof public_signal length');
    }

    function verifyDepositProof(uint8 k, IEnygmaDvpIntegration.WithdrawOrDepositProof memory proof) internal view returns (bool) {
        // DepositToDvp sizes: 8*k + 3 = k2:19, k3:27, k4:35, k5:43, k6:51
        if (k == 2) {
            require(
                IEnygmaDepositToDvpVerifierk2(depositToDvpVerifiers[k]).verifyProof(proof.pi_a, proof.pi_b, proof.pi_c, convertToUint256Array19(proof.public_signal)),
                'verifyProof returned false: Invalid deposit proof'
            );
        } else if (k == 3) {
            require(
                IEnygmaDepositToDvpVerifierk3(depositToDvpVerifiers[k]).verifyProof(proof.pi_a, proof.pi_b, proof.pi_c, convertToUint256Array27(proof.public_signal)),
                'verifyProof returned false: Invalid deposit proof'
            );
        } else if (k == 4) {
            require(
                IEnygmaDepositToDvpVerifierk4(depositToDvpVerifiers[k]).verifyProof(proof.pi_a, proof.pi_b, proof.pi_c, convertToUint256Array35(proof.public_signal)),
                'verifyProof returned false: Invalid deposit proof'
            );
        } else if (k == 5) {
            require(
                IEnygmaDepositToDvpVerifierk5(depositToDvpVerifiers[k]).verifyProof(proof.pi_a, proof.pi_b, proof.pi_c, convertToUint256Array43(proof.public_signal)),
                'verifyProof returned false: Invalid deposit proof'
            );
        } else if (k == 6) {
            require(
                IEnygmaDepositToDvpVerifierk6(depositToDvpVerifiers[k]).verifyProof(proof.pi_a, proof.pi_b, proof.pi_c, convertToUint256Array51(proof.public_signal)),
                'verifyProof returned false: Invalid deposit proof'
            );
        } else {
            revert('That value of k is not supported');
        }
        return true;
    }

    function verifyWithdrawProof(uint8 k, IEnygmaDvpIntegration.WithdrawOrDepositProof memory proof) internal view returns (bool) {
        // WithdrawFromDvp sizes: 8*k + 12 = k2:28, k3:36, k4:44, k5:52, k6:60
        if (k == 2) {
            require(
                IEnygmaWithdrawFromDvpVerifierk2(withdrawFromDvpVerifiers[k]).verifyProof(proof.pi_a, proof.pi_b, proof.pi_c, convertToUint256Array28(proof.public_signal)),
                'verifyProof returned false: Invalid withdraw proof'
            );
        } else if (k == 3) {
            require(
                IEnygmaWithdrawFromDvpVerifierk3(withdrawFromDvpVerifiers[k]).verifyProof(proof.pi_a, proof.pi_b, proof.pi_c, convertToUint256Array36(proof.public_signal)),
                'verifyProof returned false: Invalid withdraw proof'
            );
        } else if (k == 4) {
            require(
                IEnygmaWithdrawFromDvpVerifierk4(withdrawFromDvpVerifiers[k]).verifyProof(proof.pi_a, proof.pi_b, proof.pi_c, convertToUint256Array44(proof.public_signal)),
                'verifyProof returned false: Invalid withdraw proof'
            );
        } else if (k == 5) {
            require(
                IEnygmaWithdrawFromDvpVerifierk5(withdrawFromDvpVerifiers[k]).verifyProof(proof.pi_a, proof.pi_b, proof.pi_c, convertToUint256Array52(proof.public_signal)),
                'verifyProof returned false: Invalid withdraw proof'
            );
        } else if (k == 6) {
            require(
                IEnygmaWithdrawFromDvpVerifierk6(withdrawFromDvpVerifiers[k]).verifyProof(proof.pi_a, proof.pi_b, proof.pi_c, convertToUint256Array60(proof.public_signal)),
                'verifyProof returned false: Invalid withdraw proof'
            );
        } else {
            revert('That value of k is not supported');
        }
        return true;
    }

    function processDeposit(uint256 hashCommitment) internal returns (bool) {
        require(_vaultId != 0, 'VaultId not initialized');
        require(_dvpAddress != address(0), 'Dvp address not set');

        IDvp dvp = IDvp(_dvpAddress);
        bool success = dvp.depositEnygma(_vaultId, hashCommitment);
        return success;
    }

    function processWithdraw(IDvp.ProofReceipt memory transaction) internal returns (bool) {
        require(_vaultId != 0, 'VaultId not initialized');
        require(_dvpAddress != address(0), 'Dvp address not set');

        IDvp dvp = IDvp(_dvpAddress);
        bool successDvpCall = dvp.withdrawEnygma(_vaultId, transaction);
        return successDvpCall;
    }

    function convertWithdrawProofToTransferProof(IEnygmaDvpIntegration.WithdrawOrDepositProof memory proof) internal pure returns (IEnygmaV1.TransferProof memory) {
        IEnygmaV1.TransferProof memory transferProof;
        transferProof.pi_a = proof.pi_a;
        transferProof.pi_b = proof.pi_b;
        transferProof.pi_c = proof.pi_c;

        // Create a new array without last 10 items (dvp commitment hashes)
        uint256[] memory adjustedPublicSignal = new uint256[](proof.public_signal.length - 10);
        for (uint256 i = 0; i < proof.public_signal.length - 10; i++) {
            adjustedPublicSignal[i] = proof.public_signal[i];
        }
        transferProof.public_signal = adjustedPublicSignal;

        return transferProof;
    }

    function convertDepositProofToTransferProof(IEnygmaDvpIntegration.WithdrawOrDepositProof memory proof) internal pure returns (IEnygmaV1.TransferProof memory) {
        IEnygmaV1.TransferProof memory transferProof;
        transferProof.pi_a = proof.pi_a;
        transferProof.pi_b = proof.pi_b;
        transferProof.pi_c = proof.pi_c;

        // Create a new array without last item (hashCommitment)
        uint256[] memory adjustedPublicSignal = new uint256[](proof.public_signal.length - 1);
        for (uint256 i = 0; i < proof.public_signal.length - 1; i++) {
            adjustedPublicSignal[i] = proof.public_signal[i];
        }

        transferProof.public_signal = adjustedPublicSignal;
        return transferProof;
    }

    // Deposit verifier array conversions: 8*k + 3
    // k=2: 19, k=3: 27, k=4: 35, k=5: 43, k=6: 51
    function convertToUint256Array19(uint256[] memory dynamicArray) internal pure returns (uint256[19] memory fixedArray) {
        require(dynamicArray.length == 19, 'Input array must have exactly 19 elements');
        for (uint256 i = 0; i < 19; i++) {
            fixedArray[i] = dynamicArray[i];
        }
        return fixedArray;
    }

    function convertToUint256Array27(uint256[] memory dynamicArray) internal pure returns (uint256[27] memory fixedArray) {
        require(dynamicArray.length == 27, 'Input array must have exactly 27 elements');
        for (uint256 i = 0; i < 27; i++) {
            fixedArray[i] = dynamicArray[i];
        }
        return fixedArray;
    }

    function convertToUint256Array35(uint256[] memory dynamicArray) internal pure returns (uint256[35] memory fixedArray) {
        require(dynamicArray.length == 35, 'Input array must have exactly 35 elements');
        for (uint256 i = 0; i < 35; i++) {
            fixedArray[i] = dynamicArray[i];
        }
        return fixedArray;
    }

    function convertToUint256Array43(uint256[] memory dynamicArray) internal pure returns (uint256[43] memory fixedArray) {
        require(dynamicArray.length == 43, 'Input array must have exactly 43 elements');
        for (uint256 i = 0; i < 43; i++) {
            fixedArray[i] = dynamicArray[i];
        }
        return fixedArray;
    }

    function convertToUint256Array51(uint256[] memory dynamicArray) internal pure returns (uint256[51] memory fixedArray) {
        require(dynamicArray.length == 51, 'Input array must have exactly 51 elements');
        for (uint256 i = 0; i < 51; i++) {
            fixedArray[i] = dynamicArray[i];
        }
        return fixedArray;
    }

    // Withdraw verifier array conversions: 8*k + 12
    // k=2: 28, k=3: 36, k=4: 44, k=5: 52, k=6: 60
    function convertToUint256Array28(uint256[] memory dynamicArray) internal pure returns (uint256[28] memory fixedArray) {
        require(dynamicArray.length == 28, 'Input array must have exactly 28 elements');
        for (uint256 i = 0; i < 28; i++) {
            fixedArray[i] = dynamicArray[i];
        }
        return fixedArray;
    }

    function convertToUint256Array36(uint256[] memory dynamicArray) internal pure returns (uint256[36] memory fixedArray) {
        require(dynamicArray.length == 36, 'Input array must have exactly 36 elements');
        for (uint256 i = 0; i < 36; i++) {
            fixedArray[i] = dynamicArray[i];
        }
        return fixedArray;
    }

    function convertToUint256Array44(uint256[] memory dynamicArray) internal pure returns (uint256[44] memory fixedArray) {
        require(dynamicArray.length == 44, 'Input array must have exactly 44 elements');
        for (uint256 i = 0; i < 44; i++) {
            fixedArray[i] = dynamicArray[i];
        }
        return fixedArray;
    }

    function convertToUint256Array52(uint256[] memory dynamicArray) internal pure returns (uint256[52] memory fixedArray) {
        require(dynamicArray.length == 52, 'Input array must have exactly 52 elements');
        for (uint256 i = 0; i < 52; i++) {
            fixedArray[i] = dynamicArray[i];
        }
        return fixedArray;
    }

    function convertToUint256Array60(uint256[] memory dynamicArray) internal pure returns (uint256[60] memory fixedArray) {
        require(dynamicArray.length == 60, 'Input array must have exactly 60 elements');
        for (uint256 i = 0; i < 60; i++) {
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