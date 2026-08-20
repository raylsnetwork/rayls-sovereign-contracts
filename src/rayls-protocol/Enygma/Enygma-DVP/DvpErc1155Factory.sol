// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import './DvpErc1155PNH.sol';
import './Erc1155CoinVaultCreator.sol';
import './DvpSettings.sol';
import '../../interfaces/IEnygmaFactorySettings.sol';
import '../../interfaces/IDvp.sol';
import {RaylsAccessManaged} from '../../../privateHub/AccessControl/RaylsAccessManaged.sol';
import {IRaylsAccessManaged} from '../../../privateHub/AccessControl/interfaces/IRaylsAccessManaged.sol';
import {IRaylsAccessManager} from '../../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol';

/**
 * @title DvpErc1155Factory
 * @dev Factory contract to create Dvp ERC1155 tokens with their associated vaults
 * Similar to EnygmaFactory but simplified for Dvp tokens
 */
contract DvpErc1155Factory is RaylsAccessManaged {
    address public immutable settingsContractAdd;
    address public immutable dvpSettingsAdd;

    // Track created components by token address
    mapping(address => address) private vaultAddresses;
    mapping(address => address) private merkleAddresses;
    mapping(address => uint256) private vaultIds;

    event DvpErc1155Created(
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
     * @dev Creates a Dvp ERC1155 token and its vault
     * @param uri_ The URI of the token
     * @param name_ The name of the token
     * @param treeDepth The depth of the merkle tree for the vault
     * @return tokenAddress The address of the created token
     */
    function createDvpErc1155(
        string memory uri_,
        string memory name_,
        address /* owner_ */,
        uint256 treeDepth
    ) external restricted returns (address tokenAddress) {
        // Create the Dvp ERC1155 token with the shared access manager as authority
        // The manager must grant this factory permission to call setVaultInfo
        DvpErc1155PNH token = new DvpErc1155PNH(
            uri_,
            name_,
            authority(),
            treeDepth
        );

        tokenAddress = address(token);

        // Create vault and merkle tree (calls setVaultInfo which requires restricted)
        createVaultAndMerkle(tokenAddress, treeDepth);

        return tokenAddress;
    }

    /**
     * @dev Creates a vault and merkle tree for a Dvp ERC1155 token
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
        address vaultCreatorAddress = dvpSettings.erc1155CoinVaultCreatorAddress();
        require(vaultCreatorAddress != address(0), 'Vault creator not set in DVP settings');

        // Create vault and merkle tree
        Erc1155CoinVaultCreator vaultCreator = Erc1155CoinVaultCreator(vaultCreatorAddress);
        (address vaultAddr, address merkleAddr) = vaultCreator.createErc1155CoinVault(
            dvpAddress,
            dvpTeleportAddress,
            poseidonWrapperAddress,
            treeDepth,
            authority()
        );

        // Dvp.registerVault already issues the COIN_VAULT grant to the new
        // vault. Emitting the same grant twice (here + inside registerVault)
        // was dead weight. The grant is intentionally global because
        // COIN_VAULT is a cross-contract role (Dvp + DvpTeleport per the
        // deploy wiring at hardhat/tasks/deploy/private-hub.ts:304).

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

        // Set vault info in the token contract
        DvpErc1155PNH(tokenAddress).setVaultInfo(vaultAddr, merkleAddr, vaultId, dvpAddress);

        // TODO: TEMPORARY FIX - Using vault-level membership like Enygma until ERC1155 circuit
        // is updated to include asset group merkle root as a public input.
        // This will be removed after full ERC1155 integration with token-level membership.
        //
        // Add the entire vault to the Fungibles asset group (same as Enygma)
        uint256 GROUP_ID_FUNGIBLES = 0;
        dvp.addVaultToGroup(vaultId, GROUP_ID_FUNGIBLES);

        // NOTE: Per-token registration functionality is commented out in DvpErc1155PNH.mint()
        // and registerTokenToGroup() below. This will be re-enabled when:
        // 1. ERC1155 circuit is updated to output asset group merkle root (34th public input)
        // 2. ProofReceipt struct is updated to include assetGroupMerkleRoot field
        // 3. DvpVerifierAggregator is updated to handle 34 inputs instead of 33
        // 4. AssetGroup.isMemberFromProofReceipt() is updated to use the new field

        emit DvpErc1155Created(tokenAddress, vaultAddr, merkleAddr, vaultId);
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

    // TODO: COMMENTED OUT - Token-level registration temporarily disabled
    // This will be re-enabled after ERC1155 circuit update to support asset group merkle root
    /*
    /**
     * @dev Register a token ID to an asset group
     * @param tokenAddress The address of the ERC1155 token contract
     * @param tokenId The token ID to register
     * @param groupId The asset group ID (0 for fungibles, 1 for non-fungibles)
     * @notice This function is called by the ERC1155 token contract during mint
     * @notice The factory has OWNER_ROLE in Dvp, so it can register tokens to groups
     */
    /*
    function registerTokenToGroup(
        address tokenAddress,
        uint256 tokenId,
        uint256 groupId
    ) external returns (bool) {
        require(msg.sender == tokenAddress, 'Only token contract can call');
        require(vaultIds[tokenAddress] != 0, 'Token not registered');

        IEnygmaFactorySettings settings = IEnygmaFactorySettings(settingsContractAdd);
        address dvpAddress = settings.dvpAddress();
        uint256 vaultId = vaultIds[tokenAddress];

        // Prepare uniqueIdParams: [0, tokenId] for ERC1155
        uint256[] memory uniqueIdParams = new uint256[](2);
        uniqueIdParams[0] = 0; // Reserved for value (not used for membership)
        uniqueIdParams[1] = tokenId;

        // Register token to the specified group
        IDvp(dvpAddress).addTokenToGroup(vaultId, uniqueIdParams, groupId);

        return true;
    }
    */
}
