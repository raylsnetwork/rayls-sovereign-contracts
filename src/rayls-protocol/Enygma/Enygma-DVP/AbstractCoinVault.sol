// SPDX-License-Identifier: Apache-2.0

pragma solidity 0.8.24;

import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

import {RaylsAccessManaged} from '../../../privateHub/AccessControl/RaylsAccessManaged.sol';
import {IRaylsAccessManager} from '../../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol';

import {IDvp} from '../../interfaces/IDvp.sol';
import {IAbstractCoinVault} from '../../interfaces/IAbstractCoinVault.sol';
import {Merkle} from './Merkle.sol';
import {DvpTeleport} from './DvpTeleport.sol';

abstract contract AbstractCoinVault is IAbstractCoinVault, Merkle, RaylsAccessManaged, ReentrancyGuard {
    uint256 constant TOKEN_TYPE_CUSTOM = 0;
    uint256 constant TOKEN_TYPE_ERC20 = 1;
    uint256 constant TOKEN_TYPE_ERC721 = 2;
    uint256 constant TOKEN_TYPE_ERC1155 = 3;
    uint256 constant TOKEN_TYPE_ENYGMA = 4;
    uint256 constant TOKEN_TYPE_DVP_ERC721 = 5;
    uint256 constant TOKEN_TYPE_DVP_ERC1155 = 6;

    /// @notice Sentinel value used to represent unused input slots in fixed-size join-split ZK circuits.
    /// Transactions with fewer inputs than the circuit's maximum capacity fill the remaining nullifier
    /// slots with this value. The protocol checks against it to skip validation, locking, unlocking,
    /// and nullification for these padding inputs.
    uint256 dummyNullifier = 14744269619966411208579211824598458697587494354926760081771325075741142829156;


    // Abstract function to be implemented by derived contracts
    function getTokenType() public view virtual returns (uint256);
    

    ///////////////////////////////////////////////
    //           Private attributes
    //////////////////////////////////////////////

    // name identifier for Dvp smart contract
    string internal _name;

    // the address of PoseidonWrapper smart contract
    address internal _hashContractAddress;

    // address of non-generic verifier that pack the proofs
    // and utilizes the generic Gorth16 verifier smart contract
    address internal _verifierContractAddress;

    address internal _dvpContractAddress;

    address internal _assetContractAddress;

    address internal _zkAuctionContractAddress;

    address internal _dvpTeleportAddress;

    uint256 internal _vaultId;

    uint256 internal _numberOfIdentifiers;

    // utxo's uniqueId to proofReceipt
    mapping(uint256 => IDvp.ProofReceipt) _pendingProofReceipts;

    function getVaultId() public view returns (uint256) {
        return _vaultId;
    }

    function getAssetContractAddress() public view returns (address) {
        return _assetContractAddress;
    }

    function getHashContractAddress() public view returns (address) {
        return _hashContractAddress;
    }

    function getVerifierContractAddress() public view returns (address) {
        return _verifierContractAddress;
    }

    function getNumberOfAssetIdentifiers() public view returns (uint256) {
        return _numberOfIdentifiers;
    }

    function getRoot() public view returns (uint256 root) {
        return currentRoot();
    }

    function verifyRoot(uint256 treeNumber, uint256 root) public view returns (bool) {
        return isValidRoot(treeNumber, root);
    }

    constructor(address dvpAddress, address dvpTeleportAddress, address authority_) Merkle() {
        _dvpTeleportAddress = dvpTeleportAddress;
        _setAuthority(authority_);
    }

    function initializeVault(
        uint256 vaultId,
        //  uint256 numberOfAssetIdentifiers,
        address assetContractAddress,
        uint256 treeDepth,
        address hashContractAddress,
        address verifierContractAddress,
        address zkAuctionContractAddress
    ) public restricted returns (bool) {
        _vaultId = vaultId;
        _dvpContractAddress = msg.sender;
        _hashContractAddress = hashContractAddress;
        _verifierContractAddress = verifierContractAddress;
        _assetContractAddress = assetContractAddress;
        _zkAuctionContractAddress = zkAuctionContractAddress;
        _numberOfIdentifiers = 1;

        initializeMerkle(treeDepth, _vaultId, _hashContractAddress);

        return true;
    }

    function _insertCommitmentsFromReceipt(
        IDvp.ProofReceipt memory receipt
    ) internal returns (bool) {
        uint numberOfCommitments = 0;
        for (uint256 i = 0; i < receipt.commitments.length; i++) {
            if (receipt.commitments[i] != 0) {
                numberOfCommitments++;
            }
        }

        // Store original commitments for event emission
        uint256[] memory commitmentsForEvent = new uint256[](numberOfCommitments);
        for (uint256 i = 0; i < numberOfCommitments; i++) {
            commitmentsForEvent[i] = receipt.commitments[i];
        }

        // Get tree number BEFORE insertion (in case insertLeaves triggers newTree())
        uint256 currentTreeNumber = treeNumber;

        // Create separate array for insertLeaves (will be modified in-place by merkle tree operations)
        uint256[] memory commitmentsForInsertion = new uint256[](numberOfCommitments);
        for (uint256 i = 0; i < numberOfCommitments; i++) {
            commitmentsForInsertion[i] = receipt.commitments[i];
        }

        insertLeaves(commitmentsForInsertion);

        DvpTeleport(_dvpTeleportAddress).emitCommitments(_assetContractAddress, getTokenType(), currentTreeNumber, commitmentsForEvent);

        return true;
    }

    // publicly only accessible by Dvp
    function insertCommitmentsFromReceipt(
        IDvp.ProofReceipt memory receipt
    ) public restricted returns (bool) {
        return _insertCommitmentsFromReceipt(receipt);
    }

    function _nullifyFromReceipt(IDvp.ProofReceipt memory receipt) internal returns (bool) {
        // Filter valid (non-dummy, non-zero root, unlocked) nullifiers
        uint256 count = 0;
        uint256[] memory validIndices = new uint256[](receipt.nullifiers.length);

        for (uint256 i = 0; i < receipt.nullifiers.length; i++) {
            if (receipt.nullifiers[i] == dummyNullifier) continue;
            if (receipt.merkleRoots[i] == 0) continue;
            if (isLocked(receipt.treeNumbers[i], receipt.nullifiers[i])) {
                revert CantSpendLockedCoin();
            }
            validIndices[count] = i;
            count++;
        }

        if (count == 0) return true;

        uint256[] memory nullifiers = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            uint256 idx = validIndices[i];
            setNullifier(receipt.treeNumbers[idx], receipt.nullifiers[idx]);
            nullifiers[i] = receipt.nullifiers[idx];
        }

        DvpTeleport(_dvpTeleportAddress).emitNullifiers(
            _assetContractAddress,
            getTokenType(),
            nullifiers
        );

        return true;
    }

    function _unlockFromReceipt(IDvp.ProofReceipt memory receipt) internal returns (bool) {
        for (uint i = 0; i < receipt.nullifiers.length; i++) {
            uint256 treeNumber = receipt.treeNumbers[i];
            uint256 nullifier = receipt.nullifiers[i];
            if (nullifier == dummyNullifier) continue;
            if (receipt.merkleRoots[i] != 0) {
                if (isLocked(treeNumber, nullifier)) {
                    unlockCoin(treeNumber, nullifier);
                    emit CoinUnlocked(_assetContractAddress, treeNumber, nullifier);
                } else {
                    revert CoinAlreadyUnlocked();
                }
            }
        }
        return true;
    }

    // public access is only allowed for Dvp
    function nullifyFromReceipt(
        IDvp.ProofReceipt memory receipt
    ) public restricted returns (bool) {
        return _nullifyFromReceipt(receipt);
    }

    function unlockFromReceipt(
        IDvp.ProofReceipt memory receipt
    ) public restricted returns (bool) {
        return _unlockFromReceipt(receipt);
    }

    function lockCoin(
        uint256 treeNumber,
        uint256 nullifier
    ) public restricted returns (bool) {
        if (nullifier != dummyNullifier) {
            lock(treeNumber, nullifier);
            emit CoinLocked(_assetContractAddress, treeNumber, nullifier);
        }

        return true;
    }

    function unlockCoin(
        uint256 treeNumber,
        uint256 nullifier
    ) public restricted returns (bool) {
        if (nullifier != dummyNullifier) {
            unlock(treeNumber, nullifier);
            emit CoinUnlocked(_assetContractAddress, treeNumber, nullifier);
        }
        return true;
    }

    function nullifyCoin(
        uint256 _treeNumber,
        uint256 nullifier
    ) public restricted returns (bool) {
        if (nullifier != dummyNullifier) {
            setNullifier(_treeNumber, nullifier);
            uint256[] memory nullifiers = new uint256[](1);
            nullifiers[0] = nullifier;
            DvpTeleport(_dvpTeleportAddress).emitNullifiers(_assetContractAddress, getTokenType(), nullifiers);
        }
        return true;
    }

    function registerCoins(
        uint256[] memory commitments
    ) public restricted returns (bool) {
        uint numberOfCommitments = 0;
        for (uint256 i = 0; i < commitments.length; i++) {
            if (commitments[i] != 0) {
                numberOfCommitments++;
            }
        }

        // Store original commitments for event emission
        uint256[] memory commitmentsForEvent = new uint256[](numberOfCommitments);
        uint256 eventIndex = 0;
        for (uint256 i = 0; i < commitments.length; i++) {
            if (commitments[i] != 0) {
                commitmentsForEvent[eventIndex] = commitments[i];
                eventIndex++;
            }
        }

        // Get tree number BEFORE insertion (in case insertLeaves triggers newTree())
        uint256 currentTreeNumber = treeNumber;

        // Create separate array for insertLeaves (will be modified in-place by merkle tree operations)
        uint256[] memory commitmentsToInsert = new uint256[](numberOfCommitments);
        uint256 insertIndex = 0;
        for (uint256 i = 0; i < commitments.length; i++) {
            if (commitments[i] != 0) {
                commitmentsToInsert[insertIndex] = commitments[i];
                insertIndex++;
            }
        }

        insertLeaves(commitmentsToInsert);

        DvpTeleport(_dvpTeleportAddress).emitCommitments(
            _assetContractAddress,
            getTokenType(),
            currentTreeNumber,
            commitmentsForEvent
        );

        return true;
    }

    function addPendingProofReceipt(
        IDvp.ProofReceipt memory receipt
    ) public restricted returns (bool) {
        uint256 utxoUniqueId = receipt.commitments[0];

        // TODO:: you can check being empty but proof parameters being zero
        if (_pendingProofReceipts[utxoUniqueId].commitments.length != 0) {
            // proofReceipt has been already added to the vault
            revert ProofReceiptAlreadyAdded();
        } else {
            _pendingProofReceipts[utxoUniqueId] = receipt;

            // lock the nullifiers to avoid potential front-running cases

            for (uint256 i = 0; i < receipt.nullifiers.length; i++) {
                if (receipt.nullifiers[i] == dummyNullifier) continue;
                lockCoin(
                    receipt.treeNumbers[i],
                    receipt.nullifiers[i]
                );
            }
        }

        return true;
    }

    function getPendingProofReceipt(
        uint256 proofUniqueId
    ) public view returns (IDvp.ProofReceipt memory proofReceipt) {
        return _pendingProofReceipts[proofUniqueId];
    }

    function checkRegisterBrokerProofConditions(
        IDvp.ProofReceipt memory receipt
    ) public returns (bool) {
        // signal input st_beacon;
        // signal input st_vaultId;
        // signal input st_groupId;
        // signal input st_delegator_treeNumbers[tm_numOfInputs];
        // signal input st_delegator_merkleRoots[tm_numOfInputs];
        // signal input st_delegator_nullifiers[tm_numOfInputs];
        // signal input st_broker_blindedPublicKey;

        // signal input st_assetGroup_treeNumber;
        // signal input st_assetGroup_merkleRoot;

        // Note: In the broker proof, treeNumbers start at index 3 in the old structure
        // Now they're in the treeNumbers array directly
        for (uint i = 0; i < receipt.treeNumbers.length; i++) {
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

                // locking the coins for later settlement
                lockCoin(
                    receipt.treeNumbers[i],
                    receipt.nullifiers[i]
                );
            }
        }

        return true;
    }
}
