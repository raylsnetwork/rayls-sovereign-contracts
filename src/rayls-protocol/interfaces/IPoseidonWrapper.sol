// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.0;


interface IPoseidonWrapper {

    function poseidon(uint256[2] memory input) external pure returns (uint256);

}