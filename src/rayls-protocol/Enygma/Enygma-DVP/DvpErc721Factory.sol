// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import './DvpErc721PNH.sol';
import './Erc721CoinVaultCreator.sol';
import './DvpSettings.sol';
import '../../interfaces/IEnygmaFactorySettings.sol';
import '../../interfaces/IDvp.sol';
import {RaylsAccessManaged} from '../../../privateHub/AccessControl/RaylsAccessManaged.sol';
import {IRaylsAccessManaged} from '../../../privateHub/AccessControl/interfaces/IRaylsAccessManaged.sol';
import {IRaylsAccessManager} from '../../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol';

/**
 * @title DvpErc721Factory
 * @dev Factory contract to create Dvp ERC721 tokens with their associated vaults
 * Similar to EnygmaFactory but simplified for Dvp tokens
 */
contract DvpErc721Factory is RaylsAccessManaged {
    address public immutable settingsContractAdd;
    address public immutable dvpSettingsAdd;

    // Track created components by token address
    mapping(address => address) private vaultAddresses;
    mapping(address => address) private merkleAddresses;
    mapping(address => uint256) private vaultIds;

    event DvpErc721Created(
        address indexed tokenAddress,
        address vault,
        address merkle,
        uint256 vaultId
    );

    constructor(
        address _settingsContractAdd,
        address _dvpSettingsAdd,
        address _authority
    ) {
        settingsContractAdd = _settingsContractAdd;
        dvpSettingsAdd = _dvpSettingsAdd;
        _initializeAuthority(_authority);
    }

    /**
     * @dev Creates a Dvp ERC721 token and its vault
     * @param uri_ The URI of the token
     * @param name_ The name of the token
     * @param symbol_ The symbol of the token
     * @param treeDepth The depth of the merkle tree for the vault
     * @return tokenAddress The address of the created token
     */
    function createDvpErc721(
        string memory uri_,
        string memory name_,
        string memory symbol_,
        address /* owner_ */,
        uint256 treeDepth
    ) external restricted returns (address tokenAddress) {
        // Create the Dvp ERC721 token with the shared access manager as authority
        // The manager must grant this factory permission to call setVaultInfo
        DvpErc721PNH token = new DvpErc721PNH(
            uri_,
            name_,
            symbol_,
            authority(),
            treeDepth
        );

        tokenAddress = address(token);

        // Create vault and merkle tree (calls setVaultInfo which requires restricted)
        createVaultAndMerkle(tokenAddress, treeDepth);

        return tokenAddress;
    }

    /**
     * @dev Creates a vault and merkle tree for a Dvp ERC721 token
     * @param tokenAddress The address of the token
     * @param treeDepth The depth of the merkle tree
     */
    function createVaultAndMerkle(
        address tokenAddress,
        uint256 treeDepth
    ) internal {
        require(tokenAddress != address(0), 'Invalid token address');

        IEnygmaFactorySettings settings = IEnygmaFactorySettings(settingsContractAdd);
        address dvpAddress = settings.dvpAddress();
        address poseidonWrapperAddress = settings.poseidonWrapperAddress();
        address dvpTeleportAddress = settings.dvpTeleportAddress();

        require(dvpAddress != address(0), 'Dvp address not set in settings');
        require(poseidonWrapperAddress != address(0), 'Poseidon wrapper not set in settings');
        require(dvpTeleportAddress != address(0), 'Dvp teleport not set in settings');

        // Get vault creator address from DVP settings
        DvpSettings dvpSettings = DvpSettings(dvpSettingsAdd);
        address vaultCreatorAddress = dvpSettings.erc721CoinVaultCreatorAddress();
        require(vaultCreatorAddress != address(0), 'Vault creator not set in DVP settings');

        // Create vault and merkle tree
        Erc721CoinVaultCreator vaultCreator = Erc721CoinVaultCreator(vaultCreatorAddress);
        (address vaultAddr, address merkleAddr) = vaultCreator.createErc721CoinVault(
            dvpAddress,
            dvpTeleportAddress,
            poseidonWrapperAddress,
            treeDepth,
            authority()
        );

        // Dvp.registerVault already issues the COIN_VAULT grant to the new
        // vault. The grant is intentionally global because COIN_VAULT is a
        // cross-contract role (Dvp + DvpTeleport per the deploy wiring at
        // hardhat/tasks/deploy/private-hub.ts:304).

        // Store addresses
        vaultAddresses[tokenAddress] = vaultAddr;
        merkleAddresses[tokenAddress] = merkleAddr;

        // Register vault with Dvp and get the vaultId
        IDvp dvp = IDvp(dvpAddress);
        uint256 vaultId = dvp.registerVault(
            vaultAddr,
            tokenAddress,
            treeDepth
        );

        // Store the vaultId
        vaultIds[tokenAddress] = vaultId;

        // Add vault to NonFungibles asset group (ERC721 tokens are always non-fungible)
        uint256 GROUP_ID_NON_FUNGIBLES = 1;
        dvp.addVaultToGroup(vaultId, GROUP_ID_NON_FUNGIBLES);

        // Set vault info in the token contract
        DvpErc721PNH(tokenAddress).setVaultInfo(vaultAddr, merkleAddr, vaultId);

        emit DvpErc721Created(tokenAddress, vaultAddr, merkleAddr, vaultId);
    }

    function getVaultAddress(address tokenAddress) external view returns (address) {
        return vaultAddresses[tokenAddress];
    }

    function getMerkleAddress(address tokenAddress) external view returns (address) {
        return merkleAddresses[tokenAddress];
    }

    function getVaultId(address tokenAddress) external view returns (uint256) {
        return vaultIds[tokenAddress];
    }
}
