// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.0;

interface IDvp {
    ///////////////////////////////////////////////
    //                  Structs
    //////////////////////////////////////////////
    struct G1Point {
        uint256 x;
        uint256 y;
    }
    struct G2Point {
        uint256[2] x;
        uint256[2] y;
    }

    struct VerifyingKey {
        G1Point alpha1;
        G2Point beta2;
        G2Point gamma2;
        G2Point delta2;
        G1Point[] ic;
    }

    struct SnarkProof {
        G1Point a;
        G2Point b;
        G1Point c;
    }

    struct VerifierAddresses {
        address enygmaJoinSplit;
        address erc721Ownership;
        address erc1155JoinSplit;
    }

    // Universal proof receipt structure for all proof types
    struct ProofReceipt {
        SnarkProof proof;
        uint256[] treeNumbers;
        uint256 message;
        uint256[] merkleRoots;
        uint256[] commitments;
        uint256[] nullifiers;
        uint256 revertCommitment;
    }



    struct ProofReceiptAuction{
        SnarkProof proof;
        uint256[] statement;
        uint256 numberOfInputs;
        uint256 numberOfOutputs;
    }

    struct TransactionMetadata{
        uint256 vaultId;
        uint256 groupId;
        uint256 targetReceiptId; // the uniqueId of the proofReceipt of the other leg's transaction
        uint256 proofHash; // reserved to mitigate potential replay attacks
    }


  


    error AuctionIdMismatch();
    error BlindedBidMismatch();
    error WinningBidOpeningMismatch();
    error NotWinningBidsCountMismatch();
    error BidStateMismatch();
    error RottenChallenge();
    error InvalidOpening();
    error InvalidChallenge();
    error Dvp__InvalidPaymentMessage();
    error Dvp__InvalidDeliveryMessage();
    error JoinSplitWithSameCommitments();
    error InvalidMerkleRoot();
    error InvalidNullifier();
    error InvalidNumberOfInputs();
    error InvalidNumberOfOutputs();
    error NotImplemented();
    error NonFungiblePaymentVault();
    error FungibleDeliveryVault();
    error AuctionAlreadyExists();
    error AuctionStateMismatch();

    error GroupMembershipMismatch();
    error Dvp__GroupFungibilityMismatch();
    error Dvp__GroupIdOutOfRange();
    error Dvp__GroupPairAlreadyRegistered();
    error Dvp__InvalidSwapGroupPair();
    error InvalidExchangeGroupPair();

    error InvalidPartialProofReceipt();

    error Dvp__BrokerAlreadyRegistered();
    error Dvp__InvalidStatementSize();

    error Dvp__AuditorAlreadyRegistered(uint256, uint256);
    error AuditorNotRegistered(uint256);




    ///////////////////////////////////////////////
    //                  Events
    //////////////////////////////////////////////

    // Getting fired on a successful 
    // VerifyOwnership functioncall
    event VerifyOwnershipReceipt(
        uint256 indexed challenge,
        uint256 indexed assetId,
        uint256 indexed tokenId,
        uint256 amountOrOne,
        address assetAddress, 
        address senderAddress
    );


    event CoinLocked(
        uint256 indexed assetId,
        uint256 indexed treeNumber,
        uint256 indexed nullifier
    );

    event CoinUnlocked(
        uint256 indexed assetId,
        uint256 indexed treeNumber,
        uint256 indexed nullifier
    );

    event TokenAddedToGroup(
        uint256 indexed vaultId,
        uint256 indexed tokenUniqueId,
        uint256 indexed groupId
    );

    event VaultAddedToGroup(
        uint256 indexed vaultId,
        uint256 indexed groupId
    );

    event BrokerRegistered(
        uint256 indexed vaultId,
        uint256 indexed blindedBrokerPublicKey
    );

    event LegitBrokerReceipt(
        uint256 indexed beacon,
        uint256 indexed blindedBrokerPublicKey
    );

    event PendingProofAddedToVault(
        uint256 indexed vaultId,
        uint256 indexed groupId,
        uint256 indexed targetReceiptId,
        IDvp.ProofReceipt pendingProof
    );

    event Settled(
        uint256 indexed receiptId1,
        uint256 indexed receiptId2
    );

    event AuditorRegistered(
        uint256 indexed onchainId,
        uint256 indexed offchainId,
        uint256 indexed groupId,
        uint256[2] publicKey
    );

    event AuditorUnregistered(
        uint256 indexed onchainId
    );
    ///////////////////////////////////////////////
    //              Getters
    //////////////////////////////////////////////


    function vaultById(uint256) external view returns (address);

    function getVaultIdByAddress(address contractAddress) external view returns (uint256);

    function name() external view returns (string memory);

    function hashContractAddress() external view returns (address);

    function verifierContractAddress() external view returns (address);

    ///////////////////////////////////////////////
    //         Initialization  Functions
    //////////////////////////////////////////////

    function initializeDvp(address verifierAddress)  external returns (bool);
    function addEnygmaDvpIntegrationAddress(address enygmaDvpIntegrationAddress) external returns (bool);

    function registerVault(
        address vaultContractAddress,
        address assetContractAddress,
        uint256 treeDepth
    ) external returns (uint256);

   ///////////////////////////////////////////////
    //      Asset Group Functions
    //////////////////////////////////////////////

    function registerAssetGroup(
        address assetGroupContractAddress,
        string memory assetGroupName,
        bool isAssetGroupFungible,
        uint256 treeDepth
    ) external returns(bool);

    function registerSwapGroupPair(
        uint256 groupId1, 
        uint256 groupId2
    ) external returns (bool);

    function registerExchangeGroupPair(
        uint256 groupId1, 
        uint256 groupId2
    ) external returns (bool);

    function isValidSwapGroupPair(
        uint256 groupId1, 
        uint256 groupId2
    ) external view returns (bool);

    function isValidExchangeGroupPair(
        uint256 groupId1, 
        uint256 groupId2
    ) external view returns (bool);

    function getGroupPairId(
        uint256 groupId1, 
        uint256 groupId2
    ) external pure returns (uint256);

    function addTokenToGroup(
        uint256 vaultId,
        uint256[] memory uniqueIdParams,
        uint256 groupId
    ) external returns(bool);

    function addVaultToGroup(
        uint256 vaultId,
        uint256 groupId
    ) external returns(bool);

    function isTokenMemberOf(
        uint256 vaultId,
        uint256[] memory uniqueIdParams,
        uint256 groupId
    ) external view returns(bool);

    function isVaultMemberOf(
        uint256 vaultId,
        uint256 groupId
    ) external view returns(bool);

    function isMemberOfFromProofReceipt(
        uint256 vaultId,
        ProofReceipt memory receipt,
        uint256 groupId
    ) external view returns(bool);

    ///////////////////////////////////////////////
    //      Deposit/Withdraw Functions
    //////////////////////////////////////////////

    function depositEnygma(uint256 vaultId, uint256 hashCommitment) external returns (bool);

    function depositERC721(
        address contractAddress,
        uint256 nftId,
        uint256 publicKey,
        uint256 salt,
        bytes calldata encryptedBalanceUpdate
    ) external returns (bool);

    function depositERC1155(
        address contractAddress,
        uint256 tokenId,
        uint256 amountOrOne,
        bytes memory data,
        uint256 publicKey,
        uint256 salt,
        bytes calldata encryptedBalanceUpdate
    ) external returns (bool);

    function withdrawEnygma(
        uint256 vaultId,
        IDvp.ProofReceipt memory _tx
    ) external returns (bool);

    function withdrawERC721(
        address contractAddress,
        uint256 nftId,
        address recipient,
        uint256 salt,
        IDvp.ProofReceipt memory proofTx,
        bytes calldata encryptedBalanceUpdate
    ) external returns (bool);

    function withdrawERC1155(
        address contractAddress,
        uint256 tokenId,
        uint256 amount,
        address recipient,
        uint256 salt,
        IDvp.ProofReceipt memory proofTx,
        bytes calldata encryptedBalanceUpdate
    ) external returns (bool);

    ///////////////////////////////////////////////
    //      Swap/Exchange/Mix Functions
    //////////////////////////////////////////////

    function mixFunds(
        uint256 vaultId,
        IDvp.ProofReceipt memory _tx
    ) external returns (bool);

    function mixFundsERC1155(
        address contractAddress,
        IDvp.ProofReceipt memory _tx
    ) external returns (bool);

    ///////////////////////////////////////////////
    //      DvP v2 Swap Functions
    //////////////////////////////////////////////

    enum SwapProofType { Payment, Delivery }
    enum SwapStatus { None, Pending, Completed, Cancelled, TimedOut }

    function initiateSwap(
        bytes32 sharedId,
        bytes calldata encryptedData,
        bytes calldata ciphertext,
        address tokenAddress,
        SwapProofType proofType,
        IDvp.ProofReceipt memory proof,
        uint64 validityTime,
        uint256 passphrase
    ) external returns (bytes32 dvpId);

    function completeSwap(
        bytes32 sharedId,
        address tokenAddress,
        SwapProofType proofType,
        IDvp.ProofReceipt memory proof,
        bytes calldata encryptedData
    ) external;

    function cancelSwap(bytes32 sharedId, uint256 preimage) external;

    function expireSwap(bytes32 sharedId) external;

    ///////////////////////////////////////////////
    //         Auction functions
    //////////////////////////////////////////////

  enum AuctionStateEnum{
        AUCTION_INACTIVE,
        AUCTION_BIDDING,
        AUCTION_OPENNING,
        AUCTION_DECLARE_WINNER,
        AUCTION_CONCLUDED,
        AUCTION_REVERTED // TODO:: add the logic
    }

    enum BidStateEnum{
        BID_INACTIVE,
        BID_SEALED,
        BID_OPENED_PUBLICLY,
        BID_OPENED_PRIVATELY
    }

    struct AuctionData{
        uint256 auctionId;
        AuctionStateEnum auctionState;
        uint256[] uniqueIdParams;
        uint256 vaultId;
        uint256 bidVaultId;
        uint256 groupId;
        uint256 bidGroupId;
        address assetAddress;
        uint256 auctioneerItemPublicKey;
        uint256 sellerFundPublicKey;
        uint256 auctionEndsAtblock;
        IDvp.ProofReceipt itemProof;
        uint256 numberOfSubmittedBids;
        uint256 numberOfOpenedBids;
        mapping(uint256 => AuctionBidData) bids;
    }

    struct AuctionBidData{
        BidStateEnum bidState;
        uint256 blindedBid;
        uint256 bidAmount;
        uint256 bidRandom;
        uint256 bidBlockNumber;
        uint256[2] bidCommitments;
        uint256[2] bidTreeNumbers;
        uint256[2] bidNullifiers;
        uint256 receivingPublicKey;

    }

    
    function registerZkAuction(
        address zkAuctionContractAddress
    ) external returns (bool);

   ///////////////////////////////////////////////
    //         Auditor functions
    //////////////////////////////////////////////
    struct AuditorData{
        uint256 auditorOffchainId;
        uint256 auditorGroupId; // in case of having independent rings of auditors
        uint256[2] auditorPublicKey;
        // TODO:: add other desired attributes
    }

    function registerAuditor(
        uint256 auditorOffchainId,
        uint256 auditorGroupId,
        uint256[2] memory auditorPublicKey
    ) external returns(bool);

    function unregisterAuditor(
        uint256 auditorOnchainId
    ) external returns(bool); 

    function isAuditorRegistered(
        uint256[2] memory publicKey
    ) external view returns(bool);


    // TODO:: implement it
    ///////////////////////////////////////////////
    //          Random Oracle functions
    //////////////////////////////////////////////
    function checkAndRegisterChallenge(
        uint256 challenge
    ) external returns(bool);

    ///////////////////////////////////////////////
    //          Broker functions
    //////////////////////////////////////////////
    function registerBroker(
        ProofReceipt memory brokerRegistrationProof
    ) external returns(bool);
     
    function verifyLegitBrokerReceipt(
        ProofReceipt memory receipt
    ) external returns (bool);
   

}
