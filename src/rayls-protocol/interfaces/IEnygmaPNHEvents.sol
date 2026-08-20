//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IEnygmaPNHEvents {       
    function transfer(bytes32 resourceId,  uint256 value, uint256 toChainId) external;
}