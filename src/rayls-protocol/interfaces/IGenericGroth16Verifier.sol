// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.0;

import {IDvp} from "../interfaces/IDvp.sol";

interface IGenericGroth16Verifier {

    function negate(IDvp.G1Point memory p) external pure returns (IDvp.G1Point memory) ;
    
    function add(IDvp.G1Point memory p1, IDvp.G1Point memory p2)
        external
        view
        returns (IDvp.G1Point memory);

    function scalarMul(IDvp.G1Point memory p, uint256 s)
        external
        view
        returns (IDvp.G1Point memory r);

    function pairing(
        IDvp.G1Point memory _a1,
        IDvp.G2Point memory _a2,
        IDvp.G1Point memory _b1,
        IDvp.G2Point memory _b2,
        IDvp.G1Point memory _c1,
        IDvp.G2Point memory _c2,
        IDvp.G1Point memory _d1,
        IDvp.G2Point memory _d2
    ) external view returns (bool);

    function verify(
        IDvp.VerifyingKey memory _vk,
        IDvp.SnarkProof memory _proof,
        uint256[] memory _input
    ) external view returns (bool);
}
