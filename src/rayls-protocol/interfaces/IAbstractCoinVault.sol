// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.0;

import {IDvp} from "./IDvp.sol";

interface IAbstractCoinVault {


    event CoinLocked(
        address indexed tokenAddress,
        uint256 indexed treeNumber,
        uint256 indexed nullifier
    );

    event CoinUnlocked(
        address indexed tokenAddress,
        uint256 indexed treeNumber,
        uint256 indexed nullifier
    );

    event OwnershipVerificationReceipt(
        uint256 indexed challenge,
        uint256 indexed vaultId,
        uint256 indexed tokenId,
        uint256 amount
    );

    event PendingProofAdded(
        IDvp.ProofReceipt pendingProof
    );

    error RottenChallenge();
    error InvalidOpening();
    error InvalidErc721Transfer();
    error InvalidErc20Transfer();
    error InvalidErc1155Transfer();
    error InvalidErc1155BatchTransfer();
    error JoinSplitWithSameCommitments();
    error InvalidMerkleRoot();
    error InvalidNullifier();
    error InvalidNumberOfInputs();
    error InvalidNumberOfOutputs();
    error WrongNumberOfIdentifiers();
    error NotImplemented();
    error FungibilityMismatch();

    error ProofReceiptAlreadyAdded();
    error CantSpendLockedCoin();
    error CoinAlreadyUnlocked();
    error InvalidStatmentSize();

    error InvalidAuditorPublicKey();

    function getVaultId() external view returns (uint256);
    function getAssetContractAddress() external view returns (address);
    function getHashContractAddress() external view returns (address);
    function getVerifierContractAddress() external view returns (address);
    function getNumberOfAssetIdentifiers() external view returns (uint256);
    function getRoot() external view returns (uint256 root);
    function verifyRoot(uint256 treeNumber, uint256 root) external view returns(bool);

    function initializeVault(
        // string memory assetSymbol,
        // string memory assetStandard,
        uint256 vaultId, 
    //    uint256 numberOfAssetIdentifiers, 
        address assetContractAddress, 
        uint256 treeDepth,
        address hashContractAddress,
        address verifierContractAddress,
        address zkAuctionContractAddress
    ) external returns (bool);

    function nullifyFromReceipt(
        IDvp.ProofReceipt memory receipt
    ) external returns (bool); 

    function registerCoins(
        uint256[] memory commitments
    ) external returns (bool);

    function lockCoin(
        uint256 treeNumber,
        uint256 nullifier
    ) external returns (bool);

    function unlockCoin(
        uint256 treeNumber,
        uint256 nullifier
    ) external returns (bool);

    function nullifyCoin(
        uint256 treeNumber,
        uint256 nullifier
    )external returns (bool); 

    function insertCommitmentsFromReceipt(
        IDvp.ProofReceipt memory receipt
    ) external returns (bool); 

    function unlockFromReceipt(
        IDvp.ProofReceipt memory receipt
    ) external returns (bool);
    /////////////////////////////////
    // Virtual functions
    /////////////////////////////////

    function deposit(
        uint256[] memory depositParams
    ) external returns (bool); 

    function transfer(
        IDvp.ProofReceipt memory receipt
    ) external returns (bool); 

    function withdraw(
        uint256[] memory withdrawParams,
        address recipient,
        IDvp.ProofReceipt memory receipt
    ) external returns (bool);

    function generateUniqueId(
        uint256[] memory assetIdentifiers
    ) external view returns(uint256);
   
    function checkReceiptConditions(
        IDvp.ProofReceipt memory receipt
    ) external view returns (bool); 

    function verifyOwnership(
        uint256[] memory params,
        IDvp.ProofReceipt memory receipt
    ) external returns (bool);

    function addPendingProofReceipt(
        IDvp.ProofReceipt memory receipt
    ) external returns (bool);


    function getPendingProofReceipt(
        uint256 receiptUniqueId
    ) external returns (IDvp.ProofReceipt memory receipt);


    function checkRegisterBrokerProofConditions(
        IDvp.ProofReceipt memory receipt
    ) external returns (bool);

}
