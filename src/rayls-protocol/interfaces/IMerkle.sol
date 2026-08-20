// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.0;

interface IMerkle {

    function hashLeftRight(uint256 _left, uint256 _right) external view returns (uint256);

    function isValidNullifier(uint256 _treeNumber, uint256 _nullifierId)  external view returns (bool);

    function isValidRoot(uint256 _treeNumber, uint256 _merkleRoot)  external view returns (bool);

    function currentRoot() external view returns (uint256);

}