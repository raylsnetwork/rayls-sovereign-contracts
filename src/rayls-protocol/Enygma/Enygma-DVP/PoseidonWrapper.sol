// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.0;
// pragma abicoder v2;

import {IDvp} from "../../interfaces/IDvp.sol";
import {PoseidonT3} from "./Poseidon.sol";

contract PoseidonWrapper {
    function poseidon(uint256[2] memory input) public pure returns (uint256) {
        return PoseidonT3.hash(input);
    }
}
