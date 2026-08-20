// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPoseidonWrapper} from "../../../rayls-protocol/interfaces/IPoseidonWrapper.sol";

/**
 * @title MockPoseidonWrapper
 * @notice Simple mock that returns keccak256 hash truncated to field element
 * @dev Used for testing CoinVault without real Poseidon circuit
 */
contract MockPoseidonWrapper is IPoseidonWrapper {
    uint256 constant SNARK_SCALAR_FIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    function poseidon(uint256[2] memory input) external pure override returns (uint256) {
        return uint256(keccak256(abi.encode(input[0], input[1]))) % SNARK_SCALAR_FIELD;
    }
}
