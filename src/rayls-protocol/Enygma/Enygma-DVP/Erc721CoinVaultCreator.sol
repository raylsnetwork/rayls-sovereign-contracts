// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import './Erc721CoinVault.sol';

/**
 * @title Erc721CoinVaultCreator
 * @dev Factory contract to create ERC721 coin vaults for Dvp
 */
contract Erc721CoinVaultCreator {
    /**
     * @dev Creates a new Erc721CoinVault instance
     * @param dvpAddress Address of the Dvp contract
     * @param dvpTeleportAddress Address of the DvpTeleport contract
     * @param poseidonWrapperAddress Address of the Poseidon wrapper contract
     * @param treeDepth Depth of the merkle tree
     * @return vaultAddress Address of the created vault
     * @return merkleAddress Address of the merkle tree (same as vault since they're combined)
     */
    function createErc721CoinVault(
        address dvpAddress,
        address dvpTeleportAddress,
        address poseidonWrapperAddress,
        uint256 treeDepth,
        address authority_
    ) external returns (address vaultAddress, address merkleAddress) {
        // Create the Erc721CoinVault (which inherits Merkle functionality via AbstractCoinVault)
        // The constructor grants DEFAULT_DVP_ROLE to dvpAddress automatically
        Erc721CoinVault vault = new Erc721CoinVault(dvpAddress, dvpTeleportAddress, poseidonWrapperAddress, treeDepth, authority_);

        // The vault IS the merkle tree (through inheritance from AbstractCoinVault -> Merkle)
        // Return the same address for both since one contract provides both functionalities
        // The Merkle initialization (with poseidonWrapperAddress and treeDepth)
        // happens when Dvp calls initializeVault() with the proper vaultId
        return (address(vault), address(vault));
    }
}
