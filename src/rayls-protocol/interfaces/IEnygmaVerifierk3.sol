// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;
interface IEnygmaVerifierk3 {
    function verifyProof(
        uint256[2] calldata pi_a,
        uint256[2][2] calldata pi_b,
        uint256[2] calldata pi_c,
        uint256[26] calldata public_signal
    ) external view returns (bool);
}
