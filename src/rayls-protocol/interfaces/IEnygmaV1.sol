// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;
import '../interfaces/IDvp.sol';

/**
 * @title IEnygmaV1
 * @dev Updated interface for EnygmaV1 without DVP functionality
 */
interface IEnygmaV1 {
    struct EnygmaPointWithChainId {
        uint256 c1;
        uint256 c2;
        uint256 chainId;
    }

    struct EnygmaPublicKeyWithChainId {
        uint256 publicKey; // Poseidon(sk, sk)
        uint256 chainId;
    }

    struct Point {
        uint256 c1;
        uint256 c2;
    }

    struct TransferProof {
        uint256[2] pi_a;
        uint256[2][2] pi_b;
        uint256[2] pi_c;
        uint256[] public_signal;
    }

    enum TxType {
        Creation,
        Mint,
        Burn,
        Transfer,
        Deposit,
        Withdraw
    }
    
    struct SupplyUpdateTx {
        uint256 amount;
        TxType txType;
    }

    struct PendingTransaction {
        EnygmaPointWithChainId[] pointsToAddToBalance;
        uint256 nullifier;
        TxType transactionType; // 3 = transfer, 4 = depositToDvp, 5= withdrawFromDvp
    }

    struct PendingMintOrBurn {
        EnygmaPointWithChainId pointToAddToBalance;
        uint256 amount;
        uint256 blockNumber;
        TxType transactionType; // 1 = mint, 2 = burn
    }

    // Centralized struct for all extracted proof data
    // Public signal layout: [ArrayHashSecrets (k), PublicKeys (k), PreviousCommit (2*k), TxCommit (2*k), Nullifier, BlockNumber, KIndex (k), MessageTags (k)]
    struct ExtractedProofData {
        uint8 k;
        uint256 proofLength;       // original proof.public_signal.length for validation
        uint256[] arrayHashSecrets; // k elements, starting at index 0
        uint256[] publicKeys;      // k elements, starting at index k
        Point[] balances;          // k points (2*k values), starting at index 2*k
        Point[] commitments;       // k points (2*k values), starting at index 4*k
        uint256 nullifier;         // at index 6*k
        uint256 blockNumber;       // at index 6*k + 1
        uint256[] chainIds;        // k elements, starting at index 6*k + 2
        uint256[] messageTags;     // k elements, starting at index 7*k + 2
    }


    event SupplyMinted(uint256 indexed lastblockNum, uint256 amount, uint256 toChainId);
    event VerifierRegistered(address indexed verifierAddress, uint8 k);
    event TransactionSuccessful(address indexed senderAddress);
    event BurnSuccessful(uint256 indexed chainId, uint256 burnValue);
    event BalancesFinalised(uint256 indexed blockNumber);
    /// @notice Emitted once per nullifier when it is recorded in `consumedNullifiers`. On-chain audit
    ///         trail of spent nullifiers for off-chain indexers/reconciliation.
    event NullifierConsumed(bytes32 indexed resourceId, uint256 indexed nullifier, uint256 indexed blockNumber, TxType txType);

    // function mintSupply(uint256 amount, uint256 toChainId, uint256 blockNumber) external returns (bool);

    // function burn(uint256 chainId, uint256 burnValue, uint256 blockNumber) external returns (bool);
    function updateSupply(uint256 _chainId, uint256 _blockNumber, SupplyUpdateTx calldata _update) external;

    function checkTotalSumOfBalances(uint256 blockNumber) external view returns (bool);

    function addTransferVerifier(address verifier, uint8 k) external returns (bool);

    function getBalanceFinalised(uint256 chainId) external view returns (uint256 x, uint256 y);

    function getBalancePending(uint256 chainId) external view returns (uint256 x, uint256 y);

    function getBalanceByBlockNumber(uint256 chainId, uint256 blockNumber) external view returns (uint256 x, uint256 y);

    function getPublicValuesByBlockNumber(uint256 blockNumber) external view returns (EnygmaPointWithChainId[] memory refBalances, EnygmaPublicKeyWithChainId[] memory publicKeys);

    function getPublicValuesFinalised() external view returns (EnygmaPointWithChainId[] memory refBalances, EnygmaPublicKeyWithChainId[] memory publicKeys);

    function getPublicValuesPending() external view returns (EnygmaPointWithChainId[] memory refBalances, EnygmaPublicKeyWithChainId[] memory publicKeys);

    // function transfer(uint8 k, Point[] memory commitments, TransferProof memory proof, uint256[] memory chainIds, bytes[] memory encryptedMessages) external returns (bool);

    function derivePk(uint256 v) external view returns (uint256 x2, uint256 y2);

    function derivePkH(uint256 r) external view returns (uint256 x2, uint256 y2);

    function pedCom(uint256 v, uint256 r) external view returns (uint256 pedComX, uint256 pedComY);

    function Name() external view returns (string memory);

    function Symbol() external view returns (string memory);

    function getTotalRegisteredBanks() external view returns (uint256);

    function getTotalSupply() external view returns (uint256);

    function getTransferVerifierAddress(uint8 k) external view returns (address);

    function getPendingTransactions() external view returns (PendingTransaction[] memory);

    function getPendingMintsAndBurns() external view returns (PendingMintOrBurn[] memory);

    function getLastblockNumAtCurrentBlockNumber(uint256 currentBlockNumber) external view returns (uint256);

    function getNextBlockNumberToFinaliseAfter(uint256 blockNumber) external view returns (uint256);


    function isNullifierUnspent(uint256 nullifier) external view returns (bool);

    // External wrappers for DVP integration
    function dvpFinalisePendingTransactions(uint256 currentBlockNumber) external;

    function dvpAddPendingTransaction(
        TransferProof memory proof,
        TxType transactionType
    ) external;

    function dvpSendEvents(ExtractedProofData memory proofData, bytes[] memory encryptedMessages, bytes calldata encryptedUpdate) external;

    function dvpSetLastblockNumPending(uint256 newValue) external;

    function dvpValidateTransferInputs(TransferProof memory proof) external view;
}