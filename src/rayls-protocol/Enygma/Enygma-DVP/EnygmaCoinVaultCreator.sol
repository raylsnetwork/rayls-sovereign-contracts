// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import './EnygmaCoinVault.sol';

contract EnygmaCoinVaultCreator {
    function createEnygmaCoinVault(
        address dvpAddress,
        address enygmaAddress,
        address poseidonWrapperAddress,
        uint256 treeDepth,
        address dvpTeleportAddress,
        address authority_
    ) external returns (address vaultAddress, address merkleAddress) {
        // Create the EnygmaCoinVault (which inherits Merkle functionality via AbstractCoinVault)
        // The constructor grants ENYGMA_ROLE to dvpAddress automatically
        EnygmaCoinVault vault = new EnygmaCoinVault(dvpAddress, enygmaAddress, poseidonWrapperAddress, treeDepth, dvpTeleportAddress, authority_);

        // The vault IS the merkle tree (through inheritance from AbstractCoinVault -> Merkle)
        // Return the same address for both since one contract provides both functionalities
        // The Merkle initialization (with poseidonWrapperAddress and treeDepth)
        // happens when Dvp calls initializeVault() with the proper vaultId
        return (address(vault), address(vault));
    }
}