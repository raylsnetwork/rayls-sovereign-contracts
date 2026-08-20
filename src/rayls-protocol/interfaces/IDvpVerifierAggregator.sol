// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.0;

import {IDvp} from "../interfaces/IDvp.sol";

interface IDvpVerifierAggregator {

    function initializeVerifier(IDvp.VerifierAddresses calldata addresses) external;

    function verifyJoinSplitProof(
        IDvp.ProofReceipt memory _tx
    ) external view returns (bool);

    function verifyOwnershipProof(
        IDvp.ProofReceipt memory _tx
    ) external view returns (bool);

    function verifyErc1155JoinSplitProof(
        IDvp.ProofReceipt memory _tx
    ) external view returns (bool);

    function verifyBrokerProof(
            uint256 verificationKeyIndex_, 
            IDvp.SnarkProof memory proof_, 
            uint256[] memory inputs_
    ) external view returns(bool);

           function verifyAuctionProof(
            uint256 verificationKeyIndex_, 
            IDvp.SnarkProof memory proof_, 
            uint256[] memory inputs_
    ) external view returns(bool);
 
}
