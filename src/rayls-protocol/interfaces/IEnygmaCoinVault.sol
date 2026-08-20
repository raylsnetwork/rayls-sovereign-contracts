// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;
import {IDvp} from "../interfaces/IDvp.sol";
interface IEnygmaCoinVault {
    // Events
    event Commitment(uint256 indexed vaultId, uint256 commitment);
    event Nullifiers(uint256 indexed vaultId, uint256[] nullifiers);
    
    // Functions
    function deposit(
        uint256[] memory depositParams
    ) external returns (bool);
    
    function withdraw(
        IDvp.ProofReceipt memory receipt
    ) external returns (bool);

    function generateUniqueId(
        uint256[] memory params
    ) external view returns (uint256);
    
    function checkReceiptConditions(
        IDvp.ProofReceipt memory receipt
    ) external view returns (bool);
}