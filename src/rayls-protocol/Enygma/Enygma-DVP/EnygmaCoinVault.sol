// SPDX-License-Identifier: Apache-2.0

pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IRaylsAccessManager} from '../../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol';

import {IDvp} from '../../interfaces/IDvp.sol';
import {IPoseidonWrapper} from '../../interfaces/IPoseidonWrapper.sol';
import {IDvpVerifierAggregator} from '../../interfaces/IDvpVerifierAggregator.sol';
import {AbstractCoinVault} from './AbstractCoinVault.sol';
import {DvpTeleport} from './DvpTeleport.sol';

contract EnygmaCoinVault is AbstractCoinVault {
    ///////////////////////////////////////////////
    //              Errors
    //////////////////////////////////////////////

    /// @notice Thrown when the ZK join-split proof verification returns false.
    /// @dev IDvpVerifierAggregator.verifyJoinSplitProof returns bool (does NOT revert on failure
    ///      due to try/catch in the underlying Groth16 verifier). Without this explicit check,
    ///      checkReceiptConditions would silently return true for forged proofs, allowing
    ///      deposit(), withdraw(), and transfer() without a valid ZK proof.
    error EnygmaCoinVault__ZkProofVerificationFailed();

    ///////////////////////////////////////////////
    //              Constants
    //////////////////////////////////////////////

    uint256 public constant VK_ID_ERC20_JOINSPLIT = 0;
    uint256 public constant VK_ID_ERC20_10INPUT = 5;

    address private _enygmaAddress;

    ///////////////////////////////////////////////
    //              Constructor
    //////////////////////////////////////////////

    constructor(
        address dvpContractAddress,
        address enygmaAddress,
        address poseidonWrapperAddress,
        uint256 treeDepth,
        address dvpTeleportAddress,
        address authority_
    ) AbstractCoinVault(dvpContractAddress, dvpTeleportAddress, authority_) {
        _name = 'Dvp - Enygma Coin Vault';
        _hashContractAddress = poseidonWrapperAddress;
        _enygmaAddress = enygmaAddress;

        bytes4[] memory ownerSels = new bytes4[](0);
        bytes4[] memory dvpSels = new bytes4[](12);
        // Parent (AbstractCoinVault) selectors
        dvpSels[0] = this.initializeVault.selector;
        dvpSels[1] = this.insertCommitmentsFromReceipt.selector;
        dvpSels[2] = this.nullifyFromReceipt.selector;
        dvpSels[3] = this.unlockFromReceipt.selector;
        dvpSels[4] = this.lockCoin.selector;
        dvpSels[5] = this.unlockCoin.selector;
        dvpSels[6] = this.nullifyCoin.selector;
        dvpSels[7] = this.registerCoins.selector;
        dvpSels[8] = this.addPendingProofReceipt.selector;
        // Own selectors
        dvpSels[9] = this.deposit.selector;
        dvpSels[10] = this.withdraw.selector;
        dvpSels[11] = this.transfer.selector;
        IRaylsAccessManager.SelectorRoleMapping[] memory mappings = new IRaylsAccessManager.SelectorRoleMapping[](1);
        mappings[0] = IRaylsAccessManager.SelectorRoleMapping("DVP_CONTRACT", dvpSels);
        IRaylsAccessManager(authority_).selfRegisterManagedContract(msg.sender, ownerSels, mappings);
    }

    /// @notice Deposit Enygma tokens into the vault and generate a Poseidon commitment.
    /// @dev DVP-restricted (unlike ERC20/721/1155 vaults). Only callable via Dvp.depositEnygma().
    function deposit(
        uint256[] memory depositParams
    ) public override restricted nonReentrant returns (bool) {
        /*    uint256 amount = depositParams[0];
        uint256 publicKey = depositParams[1];

        uint256[] memory assetParams = new uint256[](1);
        assetParams[0] = amount;

        uint256 uid = generateUniqueId(assetParams);

        // Generating the commitment based on the ERC20 uniqueId and the publickey
        uint256 commitment = IPoseidonWrapper(_hashContractAddress).poseidon(
            [uid, publicKey]
        );
*/
        uint256 commitment = depositParams[0];

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

    /// @notice Withdraw Enygma tokens by proving commitment ownership via ZK proof.
    /// @dev DVP-restricted (unlike ERC20/721/1155 vaults). Only callable via authorized DVP path.
    function withdraw(
        uint256[] memory params,
        address recipient,
        IDvp.ProofReceipt memory receipt
    ) public override restricted nonReentrant returns (bool) {
        checkReceiptConditions(receipt);

        // Step 1: Filter valid (non-dummy) nullifiers
        uint256 numberOfInputs = receipt.nullifiers.length;
        uint256 count = 0;
        uint256[] memory validIndices = new uint256[](numberOfInputs);

        for (uint256 i = 0; i < numberOfInputs; i++) {
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

        return true;
    }

    function transfer(IDvp.ProofReceipt memory receipt) public override restricted nonReentrant returns (bool) {
        checkReceiptConditions(receipt);

        _insertCommitmentsFromReceipt(receipt);

        // Nullifying the old coins
        _nullifyFromReceipt(receipt);

        return true;
    }

    /// @notice Not implemented for Enygma vaults.
    function verifyOwnership(
        uint256[] memory params,
        IDvp.ProofReceipt memory receipt
    ) public override returns (bool) {
        revert NotImplemented();
    }

    ///////////////////////////////////////////////
    //       Generic functions
    //////////////////////////////////////////////
    function getTokenType() public pure override returns (uint256) {
        return TOKEN_TYPE_ENYGMA;
    }

    function generateUniqueId(uint256[] memory params) public view override returns (uint256) {
        uint256 amount = params[0];
        return
            IPoseidonWrapper(_hashContractAddress).poseidon(
                [uint256(uint160(_enygmaAddress)), amount]
            );
    }

    function checkReceiptConditions(
        IDvp.ProofReceipt memory receipt
    ) public view override returns (bool) {
        uint jInputSize = receipt.nullifiers.length;

        if (receipt.commitments.length >= 2 && receipt.commitments[0] == receipt.commitments[1]) {
            revert JoinSplitWithSameCommitments();
        }

        for (uint i = 0; i < jInputSize; i++) {
            if (receipt.nullifiers[i] == dummyNullifier) continue;
            if (receipt.merkleRoots[i] != 0) {
                if (
                    !isValidRoot(
                        receipt.treeNumbers[i],
                        receipt.merkleRoots[i]
                    )
                ) {
                    revert InvalidMerkleRoot();
                }

                if (
                    isValidNullifier(
                        receipt.treeNumbers[i],
                        receipt.nullifiers[i]
                    )
                ) {
                    revert InvalidNullifier();
                }
            }
        }

        if (jInputSize != 2 && jInputSize != 10) {
            revert InvalidNumberOfInputs();
        }


        if (!IDvpVerifierAggregator(_verifierContractAddress).verifyJoinSplitProof(receipt)) {
            revert EnygmaCoinVault__ZkProofVerificationFailed();
        }
        return true;
    }
}
