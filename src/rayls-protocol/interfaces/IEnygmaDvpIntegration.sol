// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;
import '../interfaces/IDvp.sol';
import '../interfaces/IEnygmaV1.sol';
/**
 * @title IEnygmaDvpIntegration
 * @dev Interface for EnygmaDvpIntegration contract
 */
interface IEnygmaDvpIntegration {
    //ZK DVP extra structs
 /*    struct DepositParams {
        uint256 currentBlockNumber;
        uint256 nullifier;
        uint256 hashCommitment;
        uint256 lastBlockNum;
    }
    
    struct WithdrawParams {
        uint256 currentBlockNumber;
        uint256 nullifier;
        uint256 lastBlockNum;
        IDvp.JoinSplitTransaction transaction;
    } */
    
    struct WithdrawOrDepositProof {
        uint256[2] pi_a;
        uint256[2][2] pi_b;
        uint256[2] pi_c;
        uint256[] public_signal;
    }
    
    //ZK DVP extra events
    event VerifierDepositToDvpRegistered(address indexed verifierAddress, uint8 k);
    event DepositToDvpSuccesful(uint256 indexed commitment, address enygmaContractAddress);
    event VerifierWithdrawFromDvpRegistered(address indexed verifierAddress, uint8 k);
    event WithdrawFromDvpSuccesful(IDvp.ProofReceipt transaction, address enygmaContractAddress);
    event DvpRegistered(address indexed dvpAddress);
    event VaultIdSet(uint256 vaultId);

    //ZK DVP functions
    function addDepositToDvpVerifier(address depositToDvpVerifier, uint8 k) external returns (bool);
    function addWithdrawFromDvpVerifier(address withdrawFromDvpVerifier, uint8 k) external returns (bool);
    function addDvp(address dvpAddress) external returns (bool);

    /**
     * @notice Moves value from Enygma into the DvP vault.
     * @dev The proof's last public signal is the hashCommitment inserted into the vault; the rest is
     *      the 8k + 2 transfer layout.
     */
    function depositToDvp(
        WithdrawOrDepositProof memory proof,
        bytes[] memory encryptedMessages,
        bytes calldata encryptedBurnUpdate
    ) external returns (bool);

    /**
     * @notice Credits Enygma with the value paid out of a DvP join-split.
     * @dev Protocol invariants (changing the circuit or the DvP contract must preserve them):
     *      - The proof's last public signal (PaymentCommitment) must equal `transaction.commitments[0]`.
     *        This is the only link between the Enygma credit and the burned DvP notes.
     *      - A zero commitment is rejected as an uninitialised value or a bug; the circuit must never
     *        produce one for a valid payment.
     *      - `transaction` is authenticated by `IDvp.withdrawEnygma`, which must verify its join-split
     *        proof, roots and nullifiers and revert otherwise.
     */
    function withdrawFromDvp(
        WithdrawOrDepositProof memory proof,
        bytes[] memory encryptedMessages,
        IDvp.ProofReceipt memory transaction,
        bytes calldata encryptedMintUpdate
    ) external returns (bool);

    /// @notice Merges DvP vault notes via a join-split receipt. Permissionless; the receipt is the authorisation.
    function consolidateFunds(IDvp.ProofReceipt memory transaction) external returns (bool);

    function setVaultId(uint256 vaultId) external returns (bool);
    function getVaultId() external view returns (uint256);

    function getDepositToDvpVerifierAddress(uint8 k) external view returns (address);
    function getWithdrawFromDvpVerifierAddress(uint8 k) external view returns (address);
    function getDvpAddress() external view returns (address);
}