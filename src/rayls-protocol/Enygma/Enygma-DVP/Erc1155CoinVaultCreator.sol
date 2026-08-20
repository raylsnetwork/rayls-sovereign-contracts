// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import './Erc1155CoinVault.sol';

/**
 * @title Erc1155CoinVaultCreator
 * @dev Factory contract to create ERC1155 coin vaults for Dvp
 */
contract Erc1155CoinVaultCreator {
    /**
     * @dev Creates a new Erc1155CoinVault instance
     * @param dvpAddress Address of the Dvp contract
     * @param dvpTeleportAddress Address of the DvpTeleport contract
     * @param poseidonWrapperAddress Address of the Poseidon wrapper contract
     * @param treeDepth Depth of the merkle tree
     * @return vaultAddress Address of the created vault
     * @return merkleAddress Address of the merkle tree (same as vault since they're combined)
     */
    function createErc1155CoinVault(
        address dvpAddress,
        address dvpTeleportAddress,
        address poseidonWrapperAddress,
        uint256 treeDepth,
        address authority_
    ) external returns (address vaultAddress, address merkleAddress) {
        // Create the Erc1155CoinVault (which inherits Merkle functionality via AbstractCoinVault)
        // The constructor grants DEFAULT_DVP_ROLE to dvpAddress automatically
        Erc1155CoinVault vault = new Erc1155CoinVault(dvpAddress, dvpTeleportAddress, poseidonWrapperAddress, treeDepth, authority_);

        // The vault IS the merkle tree (through inheritance from AbstractCoinVault -> Merkle)
        // Return the same address for both since one contract provides both functionalities
        // The Merkle initialization (with poseidonWrapperAddress and treeDepth)
        // happens when Dvp calls initializeVault() with the proper vaultId
        return (address(vault), address(vault));
    }
}
