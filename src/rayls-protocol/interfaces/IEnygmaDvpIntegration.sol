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

    //ZK DVP functions
    function addDepositToDvpVerifier(address depositToDvpVerifier, uint8 k) external returns (bool);
    function addWithdrawFromDvpVerifier(address withdrawFromDvpVerifier, uint8 k) external returns (bool);
    function addDvp(address dvpAddress) external returns (bool);

    function depositToDvp(
        uint8 k,
        IEnygmaV1.Point[] memory commitments,
        WithdrawOrDepositProof memory proof,
        uint256[] memory chainIds,
        bytes[] memory encryptedMessages
    ) external returns (bool);

    function withdrawFromDvp(
        uint8 k,
        IEnygmaV1.Point[] memory commitments,
        IEnygmaDvpIntegration.WithdrawOrDepositProof memory proof,
        uint256[] memory chainIds,
        bytes[] memory encryptedMessages,
        IDvp.ProofReceipt memory transaction,
        bytes calldata encryptedMintUpdate
    ) external returns (bool);
    
    function getDepositToDvpVerifierAddress(uint8 k) external view returns (address);
    function getWithdrawFromDvpVerifierAddress(uint8 k) external view returns (address);
    function getDvpAddress() external view returns (address);
}