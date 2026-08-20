// SPDX-License-Identifier: Apache-2.0

pragma solidity 0.8.24;

import {IERC1155} from '@openzeppelin/contracts/token/ERC1155/IERC1155.sol';
//import {IRaylsERC1155} from "../../../erc1155/interfaces/IRaylsERC1155.sol";
import '@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol';

import {IRaylsAccessManager} from '../../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol';

import {IDvp} from '../../interfaces/IDvp.sol';
import {IPoseidonWrapper} from '../../interfaces/IPoseidonWrapper.sol';
import {IDvpVerifierAggregator} from '../../interfaces/IDvpVerifierAggregator.sol';
import {AbstractCoinVault} from './AbstractCoinVault.sol';
import {DvpTeleport} from './DvpTeleport.sol';

// import {IFungibilityMerkle} from "../../interfaces/IFungibilityMerkle.sol";

contract Erc1155CoinVault is AbstractCoinVault, ERC1155Holder {
    ///////////////////////////////////////////////
    //              Errors
    //////////////////////////////////////////////

    /// @notice Thrown when the ZK ERC1155 join-split proof verification returns false.
    /// @dev IDvpVerifierAggregator.verifyErc1155JoinSplitProof returns bool (does NOT revert on
    ///      failure due to try/catch in the underlying Groth16 verifier). Without this explicit
    ///      check, checkReceiptConditions would silently return true for forged proofs, allowing
    ///      deposit(), withdraw(), and transfer() without a valid ZK proof.
    error Erc1155CoinVault__ZkProofVerificationFailed();

    /// @notice Thrown when withdrawParams array has fewer than 3 elements.
    /// @dev withdraw() reads withdrawParams[0] (amountOrOne), withdrawParams[1] (tokenId), and
    ///      withdrawParams[2] (salt). A shorter array would cause an array-out-of-bounds panic
    ///      mid-execution. Explicit check produces a clear domain error and prevents accidental
    ///      misuse from off-chain callers that build malformed parameter arrays.
    error Erc1155CoinVault__InvalidWithdrawParamsLength();

    ///////////////////////////////////////////////
    //              Constants
    //////////////////////////////////////////////

    uint256 public constant VK_ID_ERC1155_1 = 2; // nonfungible
    uint256 public constant VK_ID_ERC1155_FUNG_1 = 3;
    uint256 public constant VK_ID_ERC1155_2 = 4; // fungible joinSplit
    uint256 public constant VK_ID_ERC1155_10 = 5; // non-fungible batch
    uint256 public constant VK_ID_ERC1155_FUNG_BROKER = 14;
    uint256 public constant VK_ID_ERC1155_FUNG_AUDITOR = 15;
    uint256 public constant VK_ID_ERC1155_NON_FUNG_AUDITOR = 16;

    // TODO: When implementing non-fungible ERC1155 support:
    // 1. The vault itself does NOT need to track fungibility per token - that's handled by the token contract
    // 2. The vault DOES need to ensure that proofs are valid for the token's fungibility type
    // 3. During swap/exchange operations, Dvp.sol will check AssetGroup membership which already
    //    accounts for whether the token is in Fungibles (group 0) or NonFungibles (group 1)
    // 4. The vault's checkReceiptConditions() may need additional validation to ensure the proof
    //    type matches the expected fungibility (e.g., can't use fungible proof for non-fungible token)
    // 5. Consider adding a helper to query token contract: DvpErc1155PNH(assetContract).getTokenFungibility(tokenId)

    ///////////////////////////////////////////////
    //              Constructor
    //////////////////////////////////////////////

    constructor(
        address dvpContractAddress,
        address dvpTeleportAddress,
        address poseidonWrapperAddress,
        uint256 treeDepth,
        address authority_
    ) AbstractCoinVault(dvpContractAddress, dvpTeleportAddress, authority_) {
        _name = 'Dvp - ERC1155 Coin Vault';
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

    //////////////////////////////////////////////
    // Overwrite function :  Access Control and ERC155Holder
    //////////////////////////////////////////////
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC1155Holder) returns (bool) {
        return ERC1155Holder.supportsInterface(interfaceId);
    }

    //////////////////////////////////////////////
    // Vault functions
    //////////////////////////////////////////////
    /// @notice Deposit ERC1155 tokens into the vault and generate a Poseidon commitment.
    /// @dev DVP-restricted: `restricted` + `deposit.selector` is registered under the `DVP_CONTRACT`
    ///      role (see constructor), so only the Dvp facade (the role holder) can call this — via
    ///      Dvp.depositERC1155, which transfers the tokens into the vault first. A direct EOA call
    ///      reverts RaylsAccessManaged__Unauthorized.
    function deposit(uint256[] memory params) public override restricted nonReentrant returns (bool) {
        if (params.length == 4) {
            // ERC1155 tokens should already be transferred to this vault by Dvp contract
            // We just process the commitment creation and merkle tree insertion

            uint256 amountOrOne = params[0];
            uint256 tokenId = params[1];
            uint256 publicKey = params[2];
            uint256 salt = params[3];

            // generating commitment: H(H(H(H(spendPK, salt), tokenAddress), tokenID), tokenAmount)
            uint256 h1 = IPoseidonWrapper(_hashContractAddress).poseidon([publicKey, salt]);
            uint256 h2 = IPoseidonWrapper(_hashContractAddress).poseidon([h1, uint256(uint160(_assetContractAddress))]);
            uint256 h3 = IPoseidonWrapper(_hashContractAddress).poseidon([h2, tokenId]);
            uint256 commitment = IPoseidonWrapper(_hashContractAddress).poseidon([h3, amountOrOne]);

            // Store the original commitment for event emission
            uint256[] memory commitmentsForEvent = new uint256[](1);
            commitmentsForEvent[0] = commitment;

            // Get tree number BEFORE insertion (in case insertLeaves triggers newTree())
            uint256 currentTreeNumber = treeNumber;

            // Create separate array for insertLeaves (will be modified in-place by merkle tree operations)
            uint256[] memory commitmentsForInsertion = new uint256[](1);
            commitmentsForInsertion[0] = commitment;

            insertLeaves(commitmentsForInsertion);

            DvpTeleport(_dvpTeleportAddress).emitCommitments(
                _assetContractAddress,
                getTokenType(),
                currentTreeNumber,
                commitmentsForEvent
            );
        } else {
            // Batch mode — DIFFERENT transfer model from the single-token branch above: this branch
            // pulls the tokens FROM msg.sender (safeBatchTransferFrom below) instead of trusting a
            // prior Dvp transfer. It is not wired to any Dvp entry point (there is no
            // Dvp.depositERC1155Batch), so with `restricted` it is currently unreachable; retained
            // for a future batch deposit path.

            uint256 tokenCount = params.length / 4;
            uint256[] memory tokenIds = new uint256[](tokenCount);
            uint256[] memory amounts = new uint256[](tokenCount);
            uint256[] memory publicKeys = new uint256[](tokenCount);
            uint256[] memory salts = new uint256[](tokenCount);

            for (uint i = 0; i < tokenIds.length; i++) {
                tokenIds[i] = params[i];
                amounts[i] = params[i + tokenCount];
                publicKeys[i] = params[i + (tokenCount * 2)];
                salts[i] = params[i + (tokenCount * 3)];
            }

            IERC1155(_assetContractAddress).safeBatchTransferFrom(
                msg.sender,
                address(this),
                tokenIds,
                amounts,
                ''
            );

            for (uint i = 0; i < tokenIds.length; i++) {
                // generating commitment: H(H(H(H(spendPK, salt), tokenAddress), tokenID), tokenAmount)
                uint256 h1 = IPoseidonWrapper(_hashContractAddress).poseidon([publicKeys[i], salts[i]]);
                uint256 h2 = IPoseidonWrapper(_hashContractAddress).poseidon([h1, uint256(uint160(_assetContractAddress))]);
                uint256 h3 = IPoseidonWrapper(_hashContractAddress).poseidon([h2, tokenIds[i]]);
                uint256 commitment = IPoseidonWrapper(_hashContractAddress).poseidon([h3, amounts[i]]);

                // Store the original commitment for event emission
                uint256[] memory commitmentsForEvent = new uint256[](1);
                commitmentsForEvent[0] = commitment;

                // Get tree number BEFORE insertion (in case insertLeaves triggers newTree())
                uint256 currentTreeNumber = treeNumber;

                // Copy commitments array to commitmentsRaw for insertLeaves
                uint256[] memory commitmentsRaw = new uint256[](1);
                commitmentsRaw[0] = commitment;

                insertLeaves(commitmentsRaw);

                DvpTeleport(_dvpTeleportAddress).emitCommitments(
                    _assetContractAddress,
                    getTokenType(),
                    currentTreeNumber,
                    commitmentsForEvent
                );
            }
        }

        return true;
    }

    /// @notice Transfer commitment ownership via ZK proof (nullify old, insert new).
    /// @dev User-callable (no `restricted` modifier). Security relies on checkReceiptConditions ZK verification.
    function transfer(IDvp.ProofReceipt memory receipt) public override nonReentrant returns (bool) {
        checkReceiptConditions(receipt);

        _insertCommitmentsFromReceipt(receipt);

        // Nullifying the old coins
        _nullifyFromReceipt(receipt);

        return true;
    }

    /// @notice Withdraw ERC1155 tokens by proving commitment ownership via ZK proof.
    /// @dev User-callable (no `restricted` modifier). Security relies on checkReceiptConditions ZK verification.
    function withdraw(
        uint256[] memory withdrawParams,
        address recipient,
        IDvp.ProofReceipt memory receipt
    ) public override nonReentrant returns (bool) {
        if (withdrawParams.length < 3) {
            revert Erc1155CoinVault__InvalidWithdrawParamsLength();
        }

        // check and verify generic Erc1155 proof receipt
        checkReceiptConditions(receipt);
        /*    for(uint256 i = 0; i < receipt.commitments.length; i++){
            uint256 amountOrOne = withdrawParams[i * 2];
            uint256 tokenId = withdrawParams[i * 2 + 1]; */

        uint256 amountOrOne = withdrawParams[0];
        uint256 tokenId = withdrawParams[1];
        uint256 salt = withdrawParams[2];

        // generating commitment: H(H(H(H(recipient, salt), tokenAddress), tokenID), tokenAmount)
        uint256 h1 = IPoseidonWrapper(_hashContractAddress).poseidon([uint256(uint160(recipient)), salt]);
        uint256 h2 = IPoseidonWrapper(_hashContractAddress).poseidon([h1, uint256(uint160(_assetContractAddress))]);
        uint256 h3 = IPoseidonWrapper(_hashContractAddress).poseidon([h2, tokenId]);
        uint256 commitment = IPoseidonWrapper(_hashContractAddress).poseidon([h3, amountOrOne]);

        // checking if the computed commitment
        // matches the first commitment in the proof.

        // if(receipt.commitments[i] != commitment){

        if (receipt.commitments[0] != commitment) {
            revert InvalidOpening();
        }
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

        // Interaction last (CEI): transfer the tokens from the vault to the recipient only after the
        // nullifiers are written. safeTransferFrom hands control to the recipient
        // (onERC1155Received); with the effects already applied there is nothing left to re-enter,
        // and a failed transfer reverts the whole tx (including the nullifier writes) atomically.
        IERC1155(_assetContractAddress).safeTransferFrom(
            address(this),
            recipient,
            tokenId,
            amountOrOne,
            ''
        );

        return true;
    }

    /// @notice Prove ownership of a commitment without transferring it.
    /// @dev User-callable (no `restricted` modifier). Security relies on checkReceiptConditions ZK verification.
    function verifyOwnership(
        uint256[] memory params_,
        IDvp.ProofReceipt memory receipt_
    ) public override nonReentrant returns (bool) {
        // params:
        // 0: tokenId
        // 1: amountOrOne

        // receipt fields:
        // message (challenge)
        // treeNumbers[0]
        // merkleRoots[0]
        // nullifiers[0]
        // commitments[0]
        uint256 amountOrOne = params_[0];
        uint256 tokenId = params_[1];
        uint256 challenge = receipt_.message;

        // to avoid replay-attack
        IDvp(_dvpContractAddress).checkAndRegisterChallenge(challenge);

        uint256[] memory uparams = new uint256[](2);
        uparams[0] = amountOrOne;
        uparams[1] = tokenId;
        // regenerating uniqueId and commitment to verify
        uint256 uid = generateUniqueId(uparams);

        uint256 commitment = IPoseidonWrapper(_hashContractAddress).poseidon(
            [uid, uint256(uint160(0))]
        );

        if (receipt_.commitments[0] != commitment) {
            revert InvalidOpening();
        }

        // checking generic conditions of Ownership receipt.

        checkReceiptConditions(receipt_);
        // firing the receipt event
        emit OwnershipVerificationReceipt(challenge, _vaultId, tokenId, amountOrOne);

        return true;
    }

    function getTokenType() public pure override returns (uint256) {
        return TOKEN_TYPE_ERC1155;
    }

    function generateUniqueId(uint256[] memory params) public view override returns (uint256) {
        uint256 amountOrOne = params[0];
        uint256 tokenId = params[1];

        uint256 uid1 = IPoseidonWrapper(_hashContractAddress).poseidon(
            [uint256(uint160(_assetContractAddress)), tokenId]
        );
        uint256 uid2 = IPoseidonWrapper(_hashContractAddress).poseidon([uid1, amountOrOne]);

        return uid2;
    }

    function getEncryptionSizeForFungible(
        uint numberOfInputs,
        uint numberOfOutputs
    ) public pure returns (uint) {
        uint plainLength = numberOfInputs + numberOfInputs + 2;
        uint decLength = plainLength;
        while (decLength % 3 != 0) {
            decLength += 1;
        }
        return (decLength + 1);
    }

    function getEncryptionSizeForNonFungible(uint numberOfTokens) public pure returns (uint) {
        uint plainLength = numberOfTokens * 2 + 1;
        uint decLength = plainLength;
        while (decLength % 3 != 0) {
            decLength += 1;
        }
        return (decLength + 1);
    }

    function checkReceiptConditions(
        IDvp.ProofReceipt memory receipt
    ) public view override returns (bool) {
        //The commented code here will be needed
        //when 1155 nft funcionality is added

        // TODO:: In this function, type of receipt
        // is being determined by the size of the arrays
        // it is not secure. Fix it.

        //uint256 receiptType;

        uint256 numberOfInputs = receipt.nullifiers.length;
        uint256 numberOfOutputs = receipt.commitments.length;

        /*   // Determine receipt type based on inputs/outputs
        if(numberOfInputs == numberOfOutputs){
            receiptType = 1; // Normal receipt

            // TODO:: when adding new normal circuits,
            // you need to add the numberOfInputs and outputs here
            if(numberOfInputs != 1 && numberOfInputs != 2 && numberOfInputs != 10){
                revert InvalidNumberOfInputs();
            }

            if(numberOfOutputs != 1 && numberOfOutputs != 2 && numberOfOutputs != 10){
                revert InvalidNumberOfOutputs();
            }
        }
        else if(numberOfInputs == 10){
            receiptType = 2; // Batch receipt
        }
        else {
            // Check for auditor-enabled receipts
            // This is a simplified check - may need refinement
            if(numberOfInputs >= 1 && numberOfOutputs >= 1){
                receiptType = 4; // Auditor receipt (fungible or non-fungible)
            } else {
                revert InvalidStatmentSize();
            }
        } */

        // Check that no two non-zero commitments are the same
        for (uint i = 0; i < numberOfOutputs; i++) {
            for (uint j = i + 1; j < numberOfOutputs; j++) {
                if (receipt.commitments[i] != 0 && receipt.commitments[j] != 0) {
                    if (receipt.commitments[i] == receipt.commitments[j]) {
                        revert JoinSplitWithSameCommitments();
                    }
                }
            }
        }

        for (uint i = 0; i < numberOfInputs; i++) {
            if (receipt.nullifiers[i] == dummyNullifier) continue;
            if (receipt.merkleRoots[i] != 0) {
                if (!isValidRoot(receipt.treeNumbers[i], receipt.merkleRoots[i])) {
                    revert InvalidMerkleRoot();
                }

                if (isValidNullifier(receipt.treeNumbers[i], receipt.nullifiers[i])) {
                    revert InvalidNullifier();
                }
            }
        }
        /* 
        if(receiptType == 5){
            verifyAuditorPublicKey(receipt);
             IVerifier(_verifierContractAddress).verifyProof(
                VK_ID_ERC1155_NON_FUNG_AUDITOR, receipt.proof, receipt.statement
            );                 
        } else if(receiptType == 4){ // Auditor-enabled Proof

            verifyAuditorPublicKey(receipt);
             IVerifier(_verifierContractAddress).verifyProof(
                VK_ID_ERC1155_FUNG_AUDITOR, receipt.proof, receipt.statement
            ); 
        }
        else if(receiptType == 3){ // it is a broker-enabled receipt
            if(numberOfInputs == 2){ // JoinSplit broker-enabled
                 IVerifier(_verifierContractAddress).verifyProof(
                    VK_ID_ERC1155_FUNG_BROKER, receipt.proof, receipt.statement
                ); 
            }
            else{ 
                revert InvalidStatmentSize();
            }
        }
        else if (receiptType == 1){ // it is normal receipt
            if(numberOfInputs == 1){
                 IVerifier(_verifierContractAddress).verifyProof(
                    VK_ID_ERC1155_1, receipt.proof, receipt.statement
                ); 
            }
            else if(numberOfInputs == 2){
                 IVerifier(_verifierContractAddress).verifyProof(
                    VK_ID_ERC1155_2, receipt.proof, receipt.statement
                ); 
            }
            else{
                revert InvalidStatmentSize();
            }
        }
        else if(receiptType == 2){
            if(numberOfInputs == 10){
                IVerifier(_verifierContractAddress).verifyProof(
                    VK_ID_ERC1155_10, receipt.proof, receipt.statement
                ); 
            }
            else{
                revert InvalidStatmentSize();
            }
        } */

        if (!IDvpVerifierAggregator(_verifierContractAddress).verifyErc1155JoinSplitProof(receipt)) {
            revert Erc1155CoinVault__ZkProofVerificationFailed();
        }
        return true;
    }

    function verifyAuditorPublicKey(
        IDvp.ProofReceipt memory receipt
    ) internal view returns (bool) {
        uint256[2] memory auditorPublicKey;

        // For auditor-enabled receipts, auditor public key is stored in message field
        // This is a simplified implementation - may need to be adjusted based on actual circuit design
        // The auditor public key might need to be passed separately or encoded differently
        auditorPublicKey[0] = receipt.message;
        auditorPublicKey[1] = 0; // Second part might need to come from a different source

        if (!(IDvp(_dvpContractAddress).isAuditorRegistered(auditorPublicKey))) {
            revert InvalidAuditorPublicKey();
        }

        return true;
    }
}
