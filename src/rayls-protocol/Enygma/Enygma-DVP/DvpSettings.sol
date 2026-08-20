// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RaylsAccessManaged} from '../../../privateHub/AccessControl/RaylsAccessManaged.sol';

/**
 * @title DvpSettings
 * @dev Centralized settings contract for DVP vault creators
 */
contract DvpSettings is RaylsAccessManaged {
    // Vault creator addresses
    address public erc721CoinVaultCreatorAddress;
    address public erc1155CoinVaultCreatorAddress;

    /**
     * @dev Constructor to initialize the DvpSettings with the provided authority
     * @param _authority The address of the access manager
     */
    constructor(address _authority) {
        if (_authority != address(0)) _setAuthority(_authority);
    }

    /**
     * @dev Sets the ERC721 coin vault creator address
     * @param _erc721CoinVaultCreatorAddress The address of the ERC721 vault creator
     */
    function setErc721CoinVaultCreatorAddress(address _erc721CoinVaultCreatorAddress) external restricted {
        require(_erc721CoinVaultCreatorAddress != address(0), 'Invalid address');
        erc721CoinVaultCreatorAddress = _erc721CoinVaultCreatorAddress;
    }

    /**
     * @dev Sets the ERC1155 coin vault creator address
     * @param _erc1155CoinVaultCreatorAddress The address of the ERC1155 vault creator
     */
    function setErc1155CoinVaultCreatorAddress(address _erc1155CoinVaultCreatorAddress) external restricted {
        require(_erc1155CoinVaultCreatorAddress != address(0), 'Invalid address');
        erc1155CoinVaultCreatorAddress = _erc1155CoinVaultCreatorAddress;
    }

    /**
     * @dev Sets all vault creator addresses at once
     * @param _erc721CoinVaultCreatorAddress The address of the ERC721 vault creator
     * @param _erc1155CoinVaultCreatorAddress The address of the ERC1155 vault creator
     */
    function setAllVaultCreators(
        address _erc721CoinVaultCreatorAddress,
        address _erc1155CoinVaultCreatorAddress
    ) external restricted {
        require(_erc721CoinVaultCreatorAddress != address(0), 'Invalid ERC721 address');
        require(_erc1155CoinVaultCreatorAddress != address(0), 'Invalid ERC1155 address');

        erc721CoinVaultCreatorAddress = _erc721CoinVaultCreatorAddress;
        erc1155CoinVaultCreatorAddress = _erc1155CoinVaultCreatorAddress;
    }
}
