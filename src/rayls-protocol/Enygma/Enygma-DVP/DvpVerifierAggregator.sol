// SPDX-License-Identifier: Apache-2.0

pragma solidity 0.8.24;

import {IDvp} from '../../interfaces/IDvp.sol';
import {IEnygmaJoinSplitVerifier} from '../../interfaces/IEnygmaJoinSplitVerifier.sol';
import {IErc721OwnershipVerifier} from '../../interfaces/IErc721OwnershipVerifier.sol';
import {IErc1155JoinSplitVerifier} from '../../interfaces/IErc1155JoinSplitVerifier.sol';
import {RaylsAccessManaged} from '../../../privateHub/AccessControl/RaylsAccessManaged.sol';

contract DvpVerifierAggregator is RaylsAccessManaged {
    address private enygmaJoinSplitVerifierAddress;
    address private erc721OwnershipAddress;
    address private erc1155JoinSplitVerifierAddress;

    constructor(address _authority) {
        if (_authority != address(0)) _setAuthority(_authority);
    }

    function initializeVerifier(IDvp.VerifierAddresses calldata addresses) external restricted {
        enygmaJoinSplitVerifierAddress = addresses.enygmaJoinSplit;
        erc721OwnershipAddress = addresses.erc721Ownership;
        erc1155JoinSplitVerifierAddress = addresses.erc1155JoinSplit;
    }

    function verifyJoinSplitProof(
        IDvp.ProofReceipt memory _tx
    ) public view returns (bool) {
        // Ensure arrays have exactly 10 elements
        require(
            _tx.merkleRoots.length == 10,
            'JoinSplitProof: merkleRoots must have exactly 10 elements'
        );
        require(
            _tx.treeNumbers.length == 10,
            'JoinSplitProof: treeNumbers must have exactly 10 elements'
        );
        require(
            _tx.nullifiers.length == 10,
            'JoinSplitProof: nullifiers must have exactly 10 elements'
        );

        // Fixed size array: 1 message + 10 merkleRoots + 10 nullifiers + 10 treeNumbers + 2 commitments + 1 revertCommitment = 34
        uint256[34] memory inputs;

        // Index 0: Add message
        inputs[0] = _tx.message;

        // Indices 1-10: Add 10 merkle roots
        for (uint256 i = 0; i < 10; i++) {
            inputs[i + 1] = _tx.merkleRoots[i];
        }

        // Indices 11-20: Add 10 nullifiers
        for (uint256 i = 0; i < 10; i++) {
            inputs[i + 11] = _tx.nullifiers[i];
        }

        // Indices 21-30: Add 10 treeNumbers (FIXED: was i + 11, now i + 21)
        for (uint256 i = 0; i < 10; i++) {
            inputs[i + 21] = _tx.treeNumbers[i];
        }

        // Indices 31-32: Add output commitments
        inputs[31] = _tx.commitments[0];
        inputs[32] = _tx.commitments[1];

        // Index 33: Add revert commitment
        inputs[33] = _tx.revertCommitment;

        // Convert G1Point and G2Point to arrays for the verifier
        uint256[2] memory pi_a = [_tx.proof.a.x, _tx.proof.a.y];
        uint256[2][2] memory pi_b = [
            [_tx.proof.b.x[0], _tx.proof.b.x[1]],
            [_tx.proof.b.y[0], _tx.proof.b.y[1]]
        ];
        uint256[2] memory pi_c = [_tx.proof.c.x, _tx.proof.c.y];

        return IEnygmaJoinSplitVerifier(enygmaJoinSplitVerifierAddress).verifyProof(
            pi_a,
            pi_b,
            pi_c,
            inputs
        );
    }

    function verifyOwnershipProof(
        IDvp.ProofReceipt memory _tx
    ) public view returns (bool) {
        // Fixed size array: message + merkleRoot + nullifier + treeNumber + commitment + revertCommitment = 6
        uint256[6] memory inputs;
        inputs[0] = _tx.message;
        inputs[1] = _tx.merkleRoots[0];
        inputs[2] = _tx.nullifiers[0];
        inputs[3] = _tx.treeNumbers[0];
        inputs[4] = _tx.commitments[0];
        inputs[5] = _tx.revertCommitment;

        // Convert G1Point and G2Point to arrays for the verifier
        uint256[2] memory pi_a = [_tx.proof.a.x, _tx.proof.a.y];
        uint256[2][2] memory pi_b = [
            [_tx.proof.b.x[0], _tx.proof.b.x[1]],
            [_tx.proof.b.y[0], _tx.proof.b.y[1]]
        ];
        uint256[2] memory pi_c = [_tx.proof.c.x, _tx.proof.c.y];

        return IErc721OwnershipVerifier(erc721OwnershipAddress).verifyProof(
            pi_a,
            pi_b,
            pi_c,
            inputs
        );
    }

    function verifyErc1155JoinSplitProof(
        IDvp.ProofReceipt memory _tx
    ) public view returns (bool) {
        // Ensure arrays have exactly 10 elements
        require(
            _tx.merkleRoots.length == 10,
            'JoinSplitProof: merkleRoots must have exactly 10 elements'
        );
        require(
            _tx.treeNumbers.length == 10,
            'JoinSplitProof: treeNumbers must have exactly 10 elements'
        );
        require(
            _tx.nullifiers.length == 10,
            'JoinSplitProof: nullifiers must have exactly 10 elements'
        );

        // Fixed size array: 1 message + 10 merkleRoots + 10 nullifiers + 10 treeNumbers + 2 commitments + 1 revertCommitment = 34
        uint256[34] memory inputs;

        // Index 0: Add message
        inputs[0] = _tx.message;

        // Indices 1-10: Add 10 merkle roots
        for (uint256 i = 0; i < 10; i++) {
            inputs[i + 1] = _tx.merkleRoots[i];
        }

        // Indices 11-20: Add 10 nullifiers
        for (uint256 i = 0; i < 10; i++) {
            inputs[i + 11] = _tx.nullifiers[i];
        }

        // Indices 21-30: Add 10 treeNumbers (FIXED: was i + 11, now i + 21)
        for (uint256 i = 0; i < 10; i++) {
            inputs[i + 21] = _tx.treeNumbers[i];
        }

        // Indices 31-32: Add output commitments
        inputs[31] = _tx.commitments[0];
        inputs[32] = _tx.commitments[1];

        // Index 33: Add revert commitment
        inputs[33] = _tx.revertCommitment;

        // Convert G1Point and G2Point to arrays for the verifier
        uint256[2] memory pi_a = [_tx.proof.a.x, _tx.proof.a.y];
        uint256[2][2] memory pi_b = [
            [_tx.proof.b.x[0], _tx.proof.b.x[1]],
            [_tx.proof.b.y[0], _tx.proof.b.y[1]]
        ];
        uint256[2] memory pi_c = [_tx.proof.c.x, _tx.proof.c.y];

        return IErc1155JoinSplitVerifier(erc1155JoinSplitVerifierAddress).verifyProof(
            pi_a,
            pi_b,
            pi_c,
            inputs
        );
    }


        function verifyBrokerProof(
        uint256 verificationKeyIndex_, 
                IDvp.SnarkProof memory proof_, 
                uint256[] memory inputs_
        ) public view returns (bool) {
    }

        function verifyAuctionProof(
        uint256 verificationKeyIndex_, 
                IDvp.SnarkProof memory proof_, 
                uint256[] memory inputs_
        ) public view returns (bool) {
    }

}