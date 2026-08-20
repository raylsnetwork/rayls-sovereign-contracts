// SPDX-License-Identifier: Apache-2.0

pragma solidity 0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {IRaylsAccessManager} from "../../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol";

import {IDvp} from "../../interfaces/IDvp.sol";
import {IPoseidonWrapper} from "../../interfaces/IPoseidonWrapper.sol";
import {IDvpVerifierAggregator} from '../../interfaces/IDvpVerifierAggregator.sol';
import {AbstractCoinVault} from "./AbstractCoinVault.sol";
import {DvpTeleport} from "./DvpTeleport.sol";


contract Erc721CoinVault is AbstractCoinVault {

    ///////////////////////////////////////////////
    //              Errors
    //////////////////////////////////////////////

    /// @notice Thrown when withdrawParams array has fewer than 3 elements.
    /// @dev withdraw() expects [unusedAmountPlaceholder, nftId, salt]. Index [0] is reserved to
    ///      keep the parameter array shape consistent with Erc1155CoinVault.withdraw (which uses
    ///      [0] for amountOrOne) so Dvp.sol can build call params uniformly across vault types.
    ///      Index [1] (nftId) and [2] (salt) are the values actually consumed. A shorter array
    ///      would cause an array-out-of-bounds panic mid-execution. Explicit check produces a
    ///      clear domain error and prevents accidental misuse from off-chain callers that build
    ///      malformed parameter arrays.
    error Erc721CoinVault__InvalidWithdrawParamsLength();

    /// @notice Thrown when the ZK ownership proof verification returns false.
    /// @dev IDvpVerifierAggregator.verifyOwnershipProof returns bool (does NOT revert on failure
    ///      due to try/catch in the underlying Groth16 verifier). Without this explicit check,
    ///      checkReceiptConditions would silently return true for forged proofs, allowing
    ///      transfer(), withdraw(), and verifyOwnership() without a valid ZK proof.
    error Erc721CoinVault__ZkProofVerificationFailed();

    ///////////////////////////////////////////////
    //              Constants
    //////////////////////////////////////////////

    uint256 constant public VK_ID_ERC721_1 = 1;
    ///////////////////////////////////////////////
    //              Constructor
    //////////////////////////////////////////////

    // hashContractAddress: poseidon Wrapper contract address
    // genericVerifierContractAddress: Groth16 generic verifier address.
    // TODO:: some form of verification is needed
    constructor(
        address dvpContractAddress,
        address dvpTeleportAddress,
        address poseidonWrapperAddress,
        uint256 treeDepth,
        address authority_
    ) AbstractCoinVault(dvpContractAddress, dvpTeleportAddress, authority_) {
        _name = "Dvp - ERC721 Coin Vault";
        _hashContractAddress = poseidonWrapperAddress;

        bytes4[] memory ownerSels = new bytes4[](0);
        bytes4[] memory dvpSels = new bytes4[](10);
        dvpSels[0] = this.initializeVault.selector;
        dvpSels[1] = this.insertCommitmentsFromReceipt.selector;
        dvpSels[2] = this.nullifyFromReceipt.selector;
        dvpSels[3] = this.unlockFromReceipt.selector;
        dvpSels[4] = this.lockCoin.selector;
        dvpSels[5] = this.unlockCoin.selector;
        dvpSels[6] = this.nullifyCoin.selector;
        dvpSels[7] = this.registerCoins.selector;
        dvpSels[8] = this.addPendingProofReceipt.selector;
        dvpSels[9] = this.deposit.selector;
        IRaylsAccessManager.SelectorRoleMapping[] memory mappings = new IRaylsAccessManager.SelectorRoleMapping[](1);
        mappings[0] = IRaylsAccessManager.SelectorRoleMapping("DVP_CONTRACT", dvpSels);
        IRaylsAccessManager(authority_).selfRegisterManagedContract(msg.sender, ownerSels, mappings);
    }

    /// @notice Deposit an ERC721 token into the vault and generate a Poseidon commitment.
    /// @dev DVP-restricted: `restricted` + `deposit.selector` is registered under the `DVP_CONTRACT`
    ///      role (see constructor), so only the Dvp facade (the role holder) can call this — via
    ///      Dvp.depositERC721, which transfers the NFT into the vault first. A direct EOA call reverts
    ///      RaylsAccessManaged__Unauthorized.
    function deposit(
        uint256[] memory params
    ) public override restricted nonReentrant returns(bool) {
        // NFT should already be transferred to this vault by Dvp contract
        // We just process the commitment creation and merkle tree insertion

        uint256 tokenId = params[0];
        uint256 publicKey = params[1]; // spendPK
        uint256 salt = params[2];

        uint256[] memory assetParams = new uint256[](2);
        assetParams[0] = tokenId;
        assetParams[1] = uint256(uint160(_assetContractAddress));
        // Generating uniqueId for the ERC721 token
        uint256 uid = generateUniqueId(assetParams);

        // Generating the commitment: H( H(spendPK, salt), uid )
        uint256 spendPkSaltHash = IPoseidonWrapper(_hashContractAddress).poseidon(
            [publicKey, salt]
        );
        uint256 commitment = IPoseidonWrapper(_hashContractAddress).poseidon(
            [spendPkSaltHash, uid]
        );

        // Store the original commitment for event emission
        uint256[] memory commitmentsForEvent = new uint256[](1);
        commitmentsForEvent[0] = commitment;

        // Get tree number BEFORE insertion (in case insertLeaves triggers newTree())
        uint256 currentTreeNumber = treeNumber;

        // Create separate array for insertLeaves (will be modified in-place by merkle tree operations)
        uint256[] memory commitmentsForInsertion = new uint256[](1);
        commitmentsForInsertion[0] = commitment;

        insertLeaves(commitmentsForInsertion);

        DvpTeleport(_dvpTeleportAddress).emitCommitments(_assetContractAddress, getTokenType(), currentTreeNumber, commitmentsForEvent);

        return true;
    }

    /// @notice Transfer commitment ownership via ZK proof (nullify old, insert new).
    /// @dev User-callable (no `restricted` modifier). Security relies on checkReceiptConditions ZK verification.
    function transfer(
        IDvp.ProofReceipt memory receipt
    ) public override nonReentrant returns (bool){


        // receipt.proof;
        // receipt.treeNumbers;
        // receipt.message;
        // receipt.merkleRoots;
        // receipt.nullifiers;
        // receipt.commitments;

        // checking the proof

        checkReceiptConditions(receipt);

        _insertCommitmentsFromReceipt(receipt);

        // Nullifying the old coins
        _nullifyFromReceipt(receipt);

        return true;

    }



    /// @notice Withdraw an ERC721 token by proving commitment ownership via ZK proof.
    /// @dev User-callable (no `restricted` modifier). Security relies on checkReceiptConditions ZK verification.
    function withdraw(
        uint256[] memory withdrawParams,
        address recipient,
        IDvp.ProofReceipt memory receipt
    ) public override nonReentrant returns(bool) {
        if (withdrawParams.length < 3) {
            revert Erc721CoinVault__InvalidWithdrawParamsLength();
        }

        uint256 nftId = withdrawParams[1];
        uint256 salt = withdrawParams[2];

        uint256[] memory assetParams = new uint256[](2);
        assetParams[0] = nftId;
        assetParams[1] = uint256(uint160(_assetContractAddress));
        // generating uniqueId for ERC721 token
        uint256 uid = generateUniqueId(assetParams);

        // generating commitment: H( H(recipient, salt), uid )
        uint256 recipientSaltHash = IPoseidonWrapper(_hashContractAddress).poseidon(
            [uint256(uint160(recipient)), salt]
        );
        uint256 commitment = IPoseidonWrapper(_hashContractAddress).poseidon(
            [recipientSaltHash, uid]
        );

        // checking if the computed commitment
        // matches the first commitment in the proof.

        if(receipt.commitments[0] != commitment){
            revert InvalidOpening();
        }

        // checking proof conditions

        checkReceiptConditions(receipt);

        // Effects before interactions (CEI): mark the coins spent, then move the asset.

        // Step 1: Filter valid (non-dummy) nullifiers
        uint256 count = 0;
        uint256[] memory validIndices = new uint256[](receipt.nullifiers.length);

        for (uint256 i = 0; i < receipt.nullifiers.length; i++) {
            if (receipt.nullifiers[i] != dummyNullifier) {
                validIndices[count] = i;
                count++;
            }
        }

        if (count > 0) {
            // Step 2: Nullify each valid coin
            uint256[] memory nullifiers = new uint256[](count);
            for (uint256 i = 0; i < count; i++) {
                uint256 idx = validIndices[i];
                setNullifier(receipt.treeNumbers[idx], receipt.nullifiers[idx]);
                nullifiers[i] = receipt.nullifiers[idx];
            }

            // Step 3: Emit batch
            DvpTeleport(_dvpTeleportAddress).emitNullifiers(
                _assetContractAddress,
                getTokenType(),
                nullifiers
            );
        }

        // Interaction last (CEI): transfer the NFT from the vault to the recipient only after the
        // nullifiers are written. A failed transfer reverts the whole tx (including the nullifier
        // writes) atomically, so effects are never observed without a successful transfer.
        IERC721(_assetContractAddress).transferFrom(address(this), recipient, nftId);

        return true;
    }

    /// @notice Prove ownership of a commitment without transferring it.
    /// @dev User-callable (no `restricted` modifier). Security relies on checkReceiptConditions ZK verification.
    function verifyOwnership(
        uint256[] memory params_,
        IDvp.ProofReceipt memory receipt_
    ) public nonReentrant returns (bool) {

        // params:
        // 0: nftId
        // 1: challenge
        uint256 nftId = params_[0];

        // receipt fields:
        // proof
        // treeNumbers
        // message (challenge)
        // merkleRoots
        // nullifiers
        // commitments
        uint256 challenge = receipt_.message;

        IDvp(_dvpContractAddress).checkAndRegisterChallenge(challenge);


        uint256[] memory uparams = new uint256[](1);
        uparams[0] = nftId;
        // regenerating uniqueId and commitment to verify
        uint256 uid = generateUniqueId(uparams);

        // re-computing commitment to verify
        uint256 commitment = IPoseidonWrapper(_hashContractAddress).poseidon(
            [uid, uint256(uint160(0))]
        );

        // verifying the corectness of the commitment
        if(receipt_.commitments[0] != commitment){
            revert InvalidOpening();
        }

        // checking generic conditions of Ownership receipt.

        checkReceiptConditions(receipt_);
        emit OwnershipVerificationReceipt(
            challenge,
            _vaultId,
            nftId,
            1 // the amount of Nft is always 1
        );
        return true;
    }
    ///////////////////////////////////////////////
    //       Generic functions
    //////////////////////////////////////////////
    function getTokenType() public pure override returns (uint256) {
        return TOKEN_TYPE_ERC721;
    }

    function generateUniqueId(
        uint256[] memory params
    ) public override view returns(uint256) {
        uint256 nftId = params[0];
        return
            IPoseidonWrapper(_hashContractAddress).poseidon(
                [uint256(uint160(_assetContractAddress)), nftId]
            );
    }

    function checkReceiptConditions(
        IDvp.ProofReceipt memory receipt
    ) public override view returns(bool) {

        // receipt fields:
        // proof
        // treeNumbers
        // message
        // merkleRoots
        // nullifiers
        // commitments

        if(receipt.nullifiers[0] != dummyNullifier) {
            if(!isValidRoot(
                            receipt.treeNumbers[0],
                            receipt.merkleRoots[0]
                        )){
                revert InvalidMerkleRoot();
            }

            if(isValidNullifier(
                    receipt.treeNumbers[0],
                    receipt.nullifiers[0]
                )){
                revert InvalidNullifier();
            }
        }

        if (!IDvpVerifierAggregator(_verifierContractAddress).verifyOwnershipProof(receipt)) {
            revert Erc721CoinVault__ZkProofVerificationFailed();
        }
        return true;
    }


}
