// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '../../interfaces/IEnygmaFactorySettings.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import './EnygmaDvpIntegration.sol';
import './EnygmaRegistry.sol';
import './DvpIntegrationCreator.sol';
import './EnygmaCreator.sol';
import '../Enygma-DVP/EnygmaCoinVaultCreator.sol';
import '../Enygma-DVP/Dvp.sol';
import '../../interfaces/IDvp.sol';
import './EnygmaV1.sol';
import {IRaylsAccessManaged} from '../../../privateHub/AccessControl/interfaces/IRaylsAccessManaged.sol';
import {IRaylsAccessManager} from '../../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol';
import {RaylsAccessManaged} from '../../../privateHub/AccessControl/RaylsAccessManaged.sol';

// Struct to avoid stack too deep error in initiateEnygmaCreation
struct EnygmaInitParams {
    string name;
    string symbol;
    uint8 decimals;
    bytes32 resourceId;
    address owner;
    uint256 ownerChainId;
    address participantStorageAddress;
    address endpoint;
    address tokenRegistry;
    uint256 treeDepth;
}

contract EnygmaFactory is ReentrancyGuard, RaylsAccessManaged {
    address public immutable registryAdd;
    address public immutable integrationCreatorAdd;
    address public immutable settingsContractAdd;
    address public immutable enygmaTeleport;
    address public immutable enygmaCreator;
    address public immutable vaultCreatorAdd;

    // Track created components by resourceId
    mapping(bytes32 => address) private enygmaAddresses;
    mapping(bytes32 => address) private vaultAddresses;
    mapping(bytes32 => address) private merkleAddresses;
    mapping(bytes32 => uint256) private vaultIds;

    // Single event for the entire creation process
    event Created(
        bytes32 indexed resourceId, 
        address enygma, 
        address integration, 
        address vault, 
        address merkle
    );

    constructor(
        address registry,
        address integrationCreator,
        address settings,
        address _enygmaTeleport,
        address _enygmaCreator,
        address _vaultCreator,
        address authority_
    ) {
        registryAdd = registry;
        integrationCreatorAdd = integrationCreator;
        settingsContractAdd = settings;
        enygmaTeleport = _enygmaTeleport;
        enygmaCreator = _enygmaCreator;
        vaultCreatorAdd = _vaultCreator;
        _setAuthority(authority_);
    }

    function initiateEnygmaCreation(
        EnygmaInitParams calldata params
    ) external restricted nonReentrant {
        require(enygmaAddresses[params.resourceId] == address(0), 'Already exists');

        // Create Enygma token using EnygmaCreator
        address enygmaAddr = EnygmaCreator(enygmaCreator).createEnygma(
            EnygmaCreationParams({
                name: params.name,
                symbol: params.symbol,
                decimals: params.decimals,
                resourceId: params.resourceId,
                owner: params.owner,
                ownerChainId: params.ownerChainId,
                participantStorageContract: params.participantStorageAddress,
                endpoint: params.endpoint,
                tokenRegistryContract: params.tokenRegistry,
                enygmaTeleport: enygmaTeleport,
                factory: address(this)
            })
        );

        // Grant ENYGMA_V1 role to the newly created EnygmaV1 contract via the shared manager
        {
            address _mgr = IRaylsAccessManaged(enygmaTeleport).authority();
            IRaylsAccessManager(_mgr).grantRole(
                IRaylsAccessManager(_mgr).getRoleIdByName("ENYGMA_V1"),
                enygmaAddr,
                0
            );
        }

        // Register the Enygma token
        EnygmaRegistry(registryAdd).registerEnygma(params.resourceId, enygmaAddr);
        enygmaAddresses[params.resourceId] = enygmaAddr;

        // Create vault and merkle tree
        createVaultAndMerkle(params.resourceId, enygmaAddr, params.treeDepth);

        // Create Dvp integration
        createDvpIntegration(params.resourceId, enygmaAddr);

        // Add verifiers and finalize
        addVerifiers(params.resourceId, enygmaAddr);
    }

    function createVaultAndMerkle(
        bytes32 _resourceId,
        address _enygmaAddr,
        uint256 _treeDepth
    ) internal {
        require(_enygmaAddr != address(0), 'Enygma not created');

        IEnygmaFactorySettings settings = IEnygmaFactorySettings(settingsContractAdd);
        address dvpAddress = settings.dvpAddress();
        address poseidonWrapperAddress = settings.poseidonWrapperAddress();
        address dvpTeleportAddress = settings.dvpTeleportAddress();

        // Create vault and merkle tree
        EnygmaCoinVaultCreator vaultCreator = EnygmaCoinVaultCreator(vaultCreatorAdd);
        (address vaultAddr, address merkleAddr) = vaultCreator.createEnygmaCoinVault(
            dvpAddress,
            _enygmaAddr,
            poseidonWrapperAddress,
            _treeDepth,
            dvpTeleportAddress,
            authority()
        );

        // Grant COIN_VAULT role to the new vault via the shared manager
        {
            address _mgr = IRaylsAccessManaged(dvpTeleportAddress).authority();
            IRaylsAccessManager(_mgr).grantRole(
                IRaylsAccessManager(_mgr).getRoleIdByName("COIN_VAULT"),
                vaultAddr,
                0
            );
        }

        // Store addresses
        vaultAddresses[_resourceId] = vaultAddr;
        merkleAddresses[_resourceId] = merkleAddr;

        // Register vault with Dvp and get the vaultId
        IDvp dvp = IDvp(dvpAddress);
        uint256 vaultId = dvp.registerVault(
            vaultAddr,
            _enygmaAddr,
            _treeDepth
        );

        // Store the vaultId
        vaultIds[_resourceId] = vaultId;

        // Add vault to Fungibles asset group (Enygma vaults are always fungible)
        uint256 GROUP_ID_FUNGIBLES = 0;
        dvp.addVaultToGroup(vaultId, GROUP_ID_FUNGIBLES);

        // Register in registry
        EnygmaRegistry(registryAdd).registerVault(_resourceId, vaultAddr);
        EnygmaRegistry(registryAdd).registerMerkle(_resourceId, merkleAddr);
    }

    function createDvpIntegration(bytes32 _resourceId, address _enygmaAddr) internal {
        require(_enygmaAddr != address(0), 'Enygma not created');

        // Create the integration
        DvpIntegrationCreator intCreator = DvpIntegrationCreator(integrationCreatorAdd);
        address integrationAddr = intCreator.createIntegration(_enygmaAddr, _resourceId, settingsContractAdd);

        // Register the integration
        EnygmaRegistry(registryAdd).registerDvpIntegration(_resourceId, integrationAddr);

        // Configure the Enygma token with the integration
        EnygmaV1(_enygmaAddr).setDvpIntegrationContract(integrationAddr);

        // Connect integration with Dvp and set the vaultId
        IEnygmaFactorySettings settings = IEnygmaFactorySettings(settingsContractAdd);
        address dvpAddress = settings.dvpAddress();
        uint256 vaultId = vaultIds[_resourceId];
        EnygmaDvpIntegration integration = EnygmaDvpIntegration(integrationAddr);
        integration.addDvp(dvpAddress);
        integration.setVaultId(vaultId);
    }

    function addVerifiers(bytes32 _resourceId, address _enygmaAddr) internal {
        require(_enygmaAddr != address(0), 'Enygma not created');

        // Get verifiers from settings
        IEnygmaFactorySettings settings = IEnygmaFactorySettings(settingsContractAdd);
        
        // Add transfer verifiers to Enygma
        EnygmaV1(_enygmaAddr).addTransferVerifier(settings.enygmaVerifierk2(), 2);
        EnygmaV1(_enygmaAddr).addTransferVerifier(settings.enygmaVerifierk3(), 3);
        EnygmaV1(_enygmaAddr).addTransferVerifier(settings.enygmaVerifierk4(), 4);
        EnygmaV1(_enygmaAddr).addTransferVerifier(settings.enygmaVerifierk5(), 5);
        EnygmaV1(_enygmaAddr).addTransferVerifier(settings.enygmaVerifierk6(), 6);

        // Get integration address
        address integrationAddr = EnygmaRegistry(registryAdd).getDvpIntegrationAddress(_resourceId);

        // Add deposit/withdraw verifiers to integration
        EnygmaDvpIntegration integration = EnygmaDvpIntegration(integrationAddr);
        integration.addDepositToDvpVerifier(settings.depositToDvpVerifierk2(), 2);
        integration.addDepositToDvpVerifier(settings.depositToDvpVerifierk3(), 3);
        integration.addDepositToDvpVerifier(settings.depositToDvpVerifierk4(), 4);
        integration.addDepositToDvpVerifier(settings.depositToDvpVerifierk5(), 5);
        integration.addDepositToDvpVerifier(settings.depositToDvpVerifierk6(), 6);
        
        integration.addWithdrawFromDvpVerifier(settings.withdrawFromDvpVerifierk2(), 2);
        integration.addWithdrawFromDvpVerifier(settings.withdrawFromDvpVerifierk3(), 3);
        integration.addWithdrawFromDvpVerifier(settings.withdrawFromDvpVerifierk4(), 4);
        integration.addWithdrawFromDvpVerifier(settings.withdrawFromDvpVerifierk5(), 5);
        integration.addWithdrawFromDvpVerifier(settings.withdrawFromDvpVerifierk6(), 6);

        // Add EnygmaDvpIntegration in Dvp
        address dvpAddress = settings.dvpAddress();
        IDvp dvp = IDvp(dvpAddress);
        dvp.addEnygmaDvpIntegrationAddress(integrationAddr);

        emit Created(
            _resourceId, 
            _enygmaAddr, 
            integrationAddr, 
            vaultAddresses[_resourceId],
            merkleAddresses[_resourceId]
        );
    }

    function getEnygmaAddress(bytes32 resourceId) external view returns (address) {
        return EnygmaRegistry(registryAdd).getEnygmaAddress(resourceId);
    }

    function getDvpIntegrationAddress(bytes32 resourceId) external view returns (address) {
        return EnygmaRegistry(registryAdd).getDvpIntegrationAddress(resourceId);
    }
    
    function getVaultAddress(bytes32 resourceId) external view returns (address) {
        return EnygmaRegistry(registryAdd).getVaultAddress(resourceId);
    }
    
    function getMerkleAddress(bytes32 resourceId) external view returns (address) {
        return EnygmaRegistry(registryAdd).getMerkleAddress(resourceId);
    }

    function getVaultId(bytes32 resourceId) external view returns (uint256) {
        return vaultIds[resourceId];
    }
}