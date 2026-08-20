import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { NonceManager, DeploymentTask, ConfigTask, deployBatch, deployWithNonce, deployProxyWithoutNonce, executeBatchConfig, executeConfigWithNonce } from './batch-helpers';

// PN and PNH both define TokenRegistryV1/TokenCoreV1/TokenFreezeManagerV1.
// The PNH deployment uses Hardhat fully-qualified names so it stays explicit
// even when another contract with the same simple name is present.
export const PNH_TOKEN_REGISTRY_ARTIFACT_NAME = 'src/privateHub/TokenRegistry/TokenRegistryV1.sol:TokenRegistryV1';
export const PNH_TOKEN_CORE_ARTIFACT_NAME = 'src/privateHub/TokenRegistry/modules/TokenCore/TokenCoreV1.sol:TokenCoreV1';
export const PNH_TOKEN_FREEZE_MANAGER_ARTIFACT_NAME = 'src/privateHub/TokenRegistry/modules/TokenFreezeManager/TokenFreezeManagerV1.sol:TokenFreezeManagerV1';

export async function deployCoreBatch(nonceManager: NonceManager, hre: HardhatRuntimeEnvironment, initialOwner: string, pnhChainId: string, endpointMaxBatchMessages: string, managerAddr: string) {
  console.log('\n📦 BATCH 1: Deploy Endpoint and ResourceManager');

  // Deploy Endpoint FIRST (it must exist before any contracts that call registerResourceId)
  nonceManager.allocateNonce(); // Allocate nonce for Endpoint impl
  nonceManager.allocateNonce(); // Allocate nonce for Endpoint proxy
  const endpoint = await deployProxyWithoutNonce({
    name: 'Endpoint',
    contractName: 'EndpointV1',
    isProxy: true,
    initArgs: [pnhChainId, pnhChainId, parseInt(endpointMaxBatchMessages), managerAddr],
    initializer: 'initialize(uint256,uint256,uint256,address)',
    validationOpts: {}
  }, hre, 33000000);  

  // Deploy ResourceManager with placeholder contract factory and owner
  const resourceManager = await deployWithNonce({
    name: 'ResourceManager',
    contractName: 'ResourceManager',
    isProxy: false,
    constructorArgs: ['0x0000000000000000000000000000000000099999', initialOwner, managerAddr]
  }, nonceManager.allocateNonce(), hre);

  // Configure Endpoint with ResourceManager AND ResourceManager with Endpoint (parallel)
  await Promise.all([
    executeConfigWithNonce({
      name: 'ConfigEndpoint',
      contractName: 'EndpointV1',
      address: endpoint.address,
      method: 'configureModules',
      args: [resourceManager.address, hre.ethers.ZeroAddress, hre.ethers.ZeroAddress, hre.ethers.ZeroAddress]
    }, nonceManager.allocateNonce(), hre),
    executeConfigWithNonce({
      name: 'SetResourceManagerEndpoint',
      contractName: 'ResourceManager',
      address: resourceManager.address,
      method: 'setEndpoint',
      args: [endpoint.address]
    }, nonceManager.allocateNonce(), hre)
  ]);

  // NOTE: ResourceManager.setAuthorizedMessageReceiver() will be called later after MessageReceiver is deployed

  console.log('\n📦 BATCH 2: Deploy DeploymentProxyRegistry');

  // Deploy DeploymentProxyRegistry
  const deploymentProxyBatch = await deployBatch([
    { name: 'DeploymentProxyRegistry', contractName: 'DeploymentProxyRegistryV1', isProxy: true, initArgs: [managerAddr], initializer: 'initialize(address)', validationOpts: {} }
  ], nonceManager, hre);

  console.log('\n📦 BATCH 3: Core contracts (PARALLEL)');

  const batch = await deployBatch([
    { name: 'RaylsMessageExecutor', contractName: 'RaylsMessageExecutorV1', isProxy: true, initArgs: [managerAddr], initializer: 'initialize(address)', validationOpts: {} },
    // TeleportV1 retained (block-header relay); its atomic functions are decommissioned.
    { name: 'Teleport', contractName: 'TeleportV1', isProxy: true, initArgs: [managerAddr], initializer: 'initialize(address)', validationOpts: {} },
    { name: 'ResourceRegistry', contractName: 'ResourceRegistryV1', isProxy: true, initArgs: [managerAddr], initializer: 'initialize(address)', validationOpts: {} },
    { name: 'Proofs', contractName: 'Proofs', isProxy: false, constructorArgs: [managerAddr] }
  ], nonceManager, hre);

  return {
    deploymentProxyRegistryAddress: deploymentProxyBatch[0].address,
    messageExecutorAddress: batch[0].address,
    teleportAddress: batch[1].address,
    resourceRegistryAddress: batch[2].address,
    proofsAddress: batch[3].address,
    endpointAddress: endpoint.address,
    resourceManager: resourceManager.address
  };
}

export async function deployEnygmaSystemBatch(nonceManager: NonceManager, hre: HardhatRuntimeEnvironment, endpointAddress: string, initialOwner: string, managerAddr: string) {
  console.log('\n📦 BATCH 4-5: EnygmaFactory (all parallel)');

  // Deploy all base contracts in one batch (will need DvpSettings address later for factories)
  const batch = await deployBatch([
    {
      name: 'EnygmaFactorySettings', contractName: 'EnygmaFactorySettings', isProxy: false, constructorArgs: [
        hre.ethers.ZeroAddress, // enygmaVerifierk2 - to be set later via setters
        hre.ethers.ZeroAddress, // enygmaVerifierk3
        hre.ethers.ZeroAddress, // enygmaVerifierk4
        hre.ethers.ZeroAddress, // enygmaVerifierk5
        hre.ethers.ZeroAddress, // enygmaVerifierk6
        hre.ethers.ZeroAddress, // dvpAddress
        hre.ethers.ZeroAddress, // dvpTeleportAddress - to be set later via finalConfiguration
        hre.ethers.ZeroAddress, // poseidonWrapperAddress
        managerAddr             // _authority (RaylsAccessManagerV1)
      ]
    },
    { name: 'EnygmaRegistry', contractName: 'EnygmaRegistry', isProxy: false, constructorArgs: [managerAddr] },
    { name: 'EnygmaCreator', contractName: 'EnygmaCreator', isProxy: false, constructorArgs: [] },
    { name: 'DvpIntegrationCreator', contractName: 'DvpIntegrationCreator', isProxy: false, constructorArgs: [] },
    { name: 'EnygmaTeleport', contractName: 'EnygmaTeleport', isProxy: false, constructorArgs: [managerAddr] },
    { name: 'EnygmaPNHEvents', contractName: 'EnygmaPNHEvents', isProxy: false, constructorArgs: [endpointAddress] },
    { name: 'EnygmaCoinVaultCreator', contractName: 'EnygmaCoinVaultCreator', isProxy: false, constructorArgs: [] },
    { name: 'Erc721CoinVaultCreator', contractName: 'Erc721CoinVaultCreator', isProxy: false, constructorArgs: [] },
    { name: 'Erc1155CoinVaultCreator', contractName: 'Erc1155CoinVaultCreator', isProxy: false, constructorArgs: [] }
    // 30M gas: these *Creator contracts SSTORE the full creationCode of the contracts they deploy
    // (e.g. EnygmaCreator stores EnygmaV1's ~25KB creationCode → ~17.5M gas, over the 16.7M default).
    // Safe here because this batch is PNH-only and the local PNH block gas limit is 2^53 (no per-tx
    // cap); the 16.7M default still protects the remote public chain (2^24 cap). Durable fix: SSTORE2.
  ], nonceManager, hre, 30_000_000);

  // EnygmaFactory deployment
  const factoryNonce = nonceManager.allocateNonce();

  const factory = await deployWithNonce({
    name: 'EnygmaFactory', contractName: 'EnygmaFactory', isProxy: false, constructorArgs: [
      batch[1].address,  // registry (EnygmaRegistry)
      batch[3].address,  // integrationCreator (DvpIntegrationCreator)
      batch[0].address,  // settings (EnygmaFactorySettings)
      batch[4].address,  // _enygmaTeleport (EnygmaTeleport)
      batch[2].address,  // _enygmaCreator (EnygmaCreator)
      batch[6].address,  // _vaultCreator (EnygmaCoinVaultCreator)
      managerAddr        // authority_ (RaylsAccessManagerV1)
    ]
  }, factoryNonce, hre);

  // NOTE: EnygmaRegistry is now RaylsAccessManaged (no transferOwnership).
  // EnygmaFactory's access to registerEnygma/registerVault/registerMerkle/registerDvpIntegration
  // is granted via addFunctionAllowedRoles + grantRole in private-hub.ts role-mapping section.

  return {
    enygmaFactoryAddress: factory.address,
    enygmaFactorySettingsAddress: batch[0].address,
    enygmaRegistryAddress: batch[1].address,
    enygmaIntegrationCreatorAddress: batch[3].address,
    enygmaTeleportAddress: batch[4].address,
    enygmaPnhEventsAddress: batch[5].address,
    enygmaCoinVaultCreatorAddress: batch[6].address,
    erc721CoinVaultCreatorAddress: batch[7].address,
    erc1155CoinVaultCreatorAddress: batch[8].address
  };
}

export async function deployParticipantSystemBatch(nonceManager: NonceManager, hre: HardhatRuntimeEnvironment, initialOwner: string, endpointAddress: string, managerAddr: string) {
  console.log('\n📦 BATCH 6-7: ParticipantStorage (4 contracts in parallel)');

  // Deploy ParticipantStorage and ParticipantCore in parallel
  const batch12 = await deployBatch([
    { name: 'ParticipantStorage', contractName: 'ParticipantStorageV1', isProxy: true, initArgs: [endpointAddress, managerAddr], initializer: 'initialize(address,address)', validationOpts: {} },
    { name: 'ParticipantCore', contractName: 'ParticipantCoreV1', isProxy: true, initArgs: [endpointAddress, managerAddr], initializer: 'initialize(address,address)', validationOpts: {} }
  ], nonceManager, hre);

  // Now deploy managers + run configs in parallel
  const [managersBatch] = await Promise.all([
    deployBatch([
      { name: 'AuditManager', contractName: 'AuditManagerV1', isProxy: true, initArgs: [batch12[1].address, batch12[0].address, managerAddr], initializer: 'initialize(address,address,address)', validationOpts: {} },
      { name: 'EnygmaManager', contractName: 'EnygmaManagerV1', isProxy: true, initArgs: [batch12[1].address, batch12[0].address, managerAddr], initializer: 'initialize(address,address,address)', validationOpts: {} }
    ], nonceManager, hre)
  ]);

  const batch = [...batch12, ...managersBatch];

  await executeBatchConfig([
    { name: 'ConfigPSModules', contractName: 'ParticipantStorageV1', address: batch[0].address, method: 'configureModules', args: [batch[1].address, batch[2].address, batch[3].address] },
    { name: 'SetPSAddress', contractName: 'ParticipantCoreV1', address: batch[1].address, method: 'setParticipantStorageAddress', args: [batch[0].address] }
  ], nonceManager, hre);

  return { participantStorageAddress: batch[0].address, participantCoreAddress: batch[1].address, auditManagerAddress: batch[2].address, enygmaManagerAddress: batch[3].address };
}

export async function deployTokenSystemBatch(nonceManager: NonceManager, hre: HardhatRuntimeEnvironment, initialOwner: string, endpointAddress: string, resourceRegistryAddress: string, participantStorageAddress: string, enygmaFactoryAddress: string, enygmaFactorySettingsAddress: string, dvpSettingsAddress: string, dvpErc721FactoryAddress: string, dvpErc1155FactoryAddress: string, managerAddr: string) {
  console.log('\n📦 BATCH 8-9: TokenRegistry');

  const batch = await deployBatch([
    // Duplicate simple names are resolved through explicit PNH Hardhat FQNs.
    { name: 'TokenRegistry', contractName: 'TokenRegistryV1', artifactName: PNH_TOKEN_REGISTRY_ARTIFACT_NAME, isProxy: true, initArgs: [endpointAddress, managerAddr], initializer: 'initialize(address,address)', validationOpts: {} },
    { name: 'EnygmaTokenManager', contractName: 'EnygmaTokenManagerV1', isProxy: true, initArgs: [endpointAddress, hre.ethers.ZeroAddress, enygmaFactoryAddress, managerAddr], initializer: 'initialize(address,address,address,address)', validationOpts: {} },
    { name: 'TokenCore', contractName: 'TokenCoreV1', artifactName: PNH_TOKEN_CORE_ARTIFACT_NAME, isProxy: true, initArgs: [hre.ethers.ZeroAddress, participantStorageAddress, resourceRegistryAddress, hre.ethers.ZeroAddress, endpointAddress, enygmaFactorySettingsAddress, dvpSettingsAddress, managerAddr], initializer: 'initialize(address,address,address,address,address,address,address,address)', validationOpts: {} },
    { name: 'TokenFreezeManager', contractName: 'TokenFreezeManagerV1', artifactName: PNH_TOKEN_FREEZE_MANAGER_ARTIFACT_NAME, isProxy: true, initArgs: [endpointAddress, hre.ethers.ZeroAddress, managerAddr], initializer: 'initialize(address,address,address)', validationOpts: {} }
  ], nonceManager, hre);

  await executeBatchConfig([
    { name: 'SetETMTokenRegistry', contractName: 'EnygmaTokenManagerV1', address: batch[1].address, method: 'setTokenRegistryAddress', args: [batch[0].address] },
    { name: 'SetTokenCoreAddr', contractName: 'EnygmaTokenManagerV1', address: batch[1].address, method: 'setTokenCoreAddress', args: [batch[2].address] },
    { name: 'SetTCTokenRegistry', contractName: 'TokenCoreV1', artifactName: PNH_TOKEN_CORE_ARTIFACT_NAME, address: batch[2].address, method: 'setTokenRegistryAddress', args: [batch[0].address] },
    { name: 'SetTCEnygmaManager', contractName: 'TokenCoreV1', artifactName: PNH_TOKEN_CORE_ARTIFACT_NAME, address: batch[2].address, method: 'setEnygmaTokenManager', args: [batch[1].address] },
    { name: 'SetTCDvpErc721Factory', contractName: 'TokenCoreV1', artifactName: PNH_TOKEN_CORE_ARTIFACT_NAME, address: batch[2].address, method: 'setDvpErc721FactoryAddress', args: [dvpErc721FactoryAddress] },
    { name: 'SetTCDvpErc1155Factory', contractName: 'TokenCoreV1', artifactName: PNH_TOKEN_CORE_ARTIFACT_NAME, address: batch[2].address, method: 'setDvpErc1155FactoryAddress', args: [dvpErc1155FactoryAddress] },
    { name: 'SetTFMTokenRegistry', contractName: 'TokenFreezeManagerV1', artifactName: PNH_TOKEN_FREEZE_MANAGER_ARTIFACT_NAME, address: batch[3].address, method: 'setTokenRegistryAddress', args: [batch[0].address] },
    { name: 'ConfigTRModules', contractName: 'TokenRegistryV1', artifactName: PNH_TOKEN_REGISTRY_ARTIFACT_NAME, address: batch[0].address, method: 'configureModules', args: [batch[2].address, batch[3].address, batch[1].address] },
    { name: 'SetRRTokenReg', contractName: 'ResourceRegistryV1', address: resourceRegistryAddress, method: 'setTokenRegistry', args: [batch[2].address] }
  ], nonceManager, hre);

  return { tokenRegistryAddress: batch[0].address, enygmaTokenManagerAddress: batch[1].address, tokenCoreAddress: batch[2].address, tokenFreezeManagerAddress: batch[3].address };
}

export async function deployAllVerifiersBatched(nonceManager: NonceManager, hre: HardhatRuntimeEnvironment, managerAddr: string) {
  console.log('\n📦 BATCH 10-12: ALL 30 verifiers (impls + proxies in ONE BATCH)');

  const verifierNames = ['k2', 'k3', 'k4', 'k5', 'k6'];

  // Deploy ALL 15 impls + 15 proxies in ONE single batch (30 contracts total)
  const allTasks = verifierNames.flatMap(k => [
    // Implementations
    { name: `Enygma${k}Impl`, contractName: `EnygmaVerifier${k}`, isProxy: false, constructorArgs: [] },
    { name: `Deposit${k}Impl`, contractName: `EnygmaDepositToDvpVerifier${k}`, isProxy: false, constructorArgs: [] },
    { name: `Withdraw${k}Impl`, contractName: `EnygmaWithdrawFromDvpVerifier${k}`, isProxy: false, constructorArgs: [] }
  ]);

  const impls = await deployBatch(allTasks, nonceManager, hre);
  const implMap: any = {};
  impls.forEach(r => { implMap[r.name] = r.address; });

  // Deploy all proxies + configure them in parallel (config doesn't need to wait)
  const proxyTasks = verifierNames.flatMap(k => [
    { name: `Enygma${k}Proxy`, contractName: `EnygmaVerifier${k}Proxy`, isProxy: false, constructorArgs: [implMap[`Enygma${k}Impl`], managerAddr] },
    { name: `Deposit${k}Proxy`, contractName: `EnygmaDepositToDvpVerifier${k}Proxy`, isProxy: false, constructorArgs: [implMap[`Deposit${k}Impl`], managerAddr] },
    { name: `Withdraw${k}Proxy`, contractName: `EnygmaWithdrawFromDvpVerifier${k}Proxy`, isProxy: false, constructorArgs: [implMap[`Withdraw${k}Impl`], managerAddr] }
  ]);

  const proxies = await deployBatch(proxyTasks, nonceManager, hre);
  const proxyMap: any = {};
  proxies.forEach(r => { proxyMap[r.name] = r.address; });

  // Configure all proxies (these can happen async, but we await to get addresses)
  const configTasks = verifierNames.flatMap(k => [
    { name: `ConfigEnygma${k}`, contractName: `EnygmaVerifier${k}Proxy`, address: proxyMap[`Enygma${k}Proxy`], method: 'setVerifierAddress', args: [implMap[`Enygma${k}Impl`]] },
    { name: `ConfigDeposit${k}`, contractName: `EnygmaDepositToDvpVerifier${k}Proxy`, address: proxyMap[`Deposit${k}Proxy`], method: 'setVerifierAddress', args: [implMap[`Deposit${k}Impl`]] },
    { name: `ConfigWithdraw${k}`, contractName: `EnygmaWithdrawFromDvpVerifier${k}Proxy`, address: proxyMap[`Withdraw${k}Proxy`], method: 'setVerifierAddress', args: [implMap[`Withdraw${k}Impl`]] }
  ]);

  await executeBatchConfig(configTasks, nonceManager, hre);

  return {
    enygmaVerifierk2Address: proxyMap['Enygmak2Proxy'],
    enygmaVerifierk3Address: proxyMap['Enygmak3Proxy'],
    enygmaVerifierk4Address: proxyMap['Enygmak4Proxy'],
    enygmaVerifierk5Address: proxyMap['Enygmak5Proxy'],
    enygmaVerifierk6Address: proxyMap['Enygmak6Proxy'],
    depositToDvpVerifierk2Address: proxyMap['Depositk2Proxy'],
    depositToDvpVerifierk3Address: proxyMap['Depositk3Proxy'],
    depositToDvpVerifierk4Address: proxyMap['Depositk4Proxy'],
    depositToDvpVerifierk5Address: proxyMap['Depositk5Proxy'],
    depositToDvpVerifierk6Address: proxyMap['Depositk6Proxy'],
    withdrawFromDvpVerifierk2Address: proxyMap['Withdrawk2Proxy'],
    withdrawFromDvpVerifierk3Address: proxyMap['Withdrawk3Proxy'],
    withdrawFromDvpVerifierk4Address: proxyMap['Withdrawk4Proxy'],
    withdrawFromDvpVerifierk5Address: proxyMap['Withdrawk5Proxy'],
    withdrawFromDvpVerifierk6Address: proxyMap['Withdrawk6Proxy']
  };
}

export async function deployDvpSystemBatch(nonceManager: NonceManager, hre: HardhatRuntimeEnvironment, enygmaFactoryAddress: string, verifierAddresses: any, dvpErc721FactoryAddress: string, dvpErc1155FactoryAddress: string, endpointAddress: string, initialOwner: string, managerAddr: string) {
  console.log('\n📦 BATCH 13-16: Dvp system');

  const poseidon = await deployWithNonce({ name: 'PoseidonT3', contractName: 'poseidon-solidity/PoseidonT3.sol:PoseidonT3', isProxy: false, constructorArgs: [] }, nonceManager.allocateNonce(), hre);
  const wrapper = await deployWithNonce({ name: 'PoseidonWrapper', contractName: 'PoseidonWrapper', isProxy: false, constructorArgs: [], libraries: { PoseidonT3: poseidon.address } }, nonceManager.allocateNonce(), hre);

  const dvpBatch = await deployBatch([
    { name: 'DvpVerifierAggregator', contractName: 'DvpVerifierAggregator', isProxy: false, constructorArgs: [managerAddr] },
    { name: 'EnygmaJoinSplitImpl', contractName: 'EnygmaJoinSplitVerifier', isProxy: false, constructorArgs: [] },
    { name: 'Erc721OwnershipImpl', contractName: 'Erc721OwnershipVerifier', isProxy: false, constructorArgs: [] },
    { name: 'Erc1155JoinSplitImpl', contractName: 'Erc1155JoinSplitVerifier', isProxy: false, constructorArgs: [] }
  ], nonceManager, hre);

  const proxyBatch = await deployBatch([
    { name: 'EnygmaJoinSplitProxy', contractName: 'EnygmaJoinSplitVerifierProxy', isProxy: false, constructorArgs: [dvpBatch[1].address, managerAddr] },
    { name: 'Erc721OwnershipProxy', contractName: 'Erc721OwnershipVerifierProxy', isProxy: false, constructorArgs: [dvpBatch[2].address, managerAddr] },
    { name: 'Erc1155JoinSplitProxy', contractName: 'Erc1155JoinSplitVerifierProxy', isProxy: false, constructorArgs: [dvpBatch[3].address, managerAddr] }
  ], nonceManager, hre);

  await executeBatchConfig([
    { name: 'ConfigEnygmaJS', contractName: 'EnygmaJoinSplitVerifierProxy', address: proxyBatch[0].address, method: 'setVerifierAddress', args: [dvpBatch[1].address] },
    { name: 'Config721', contractName: 'Erc721OwnershipVerifierProxy', address: proxyBatch[1].address, method: 'setVerifierAddress', args: [dvpBatch[2].address] },
    { name: 'Config1155', contractName: 'Erc1155JoinSplitVerifierProxy', address: proxyBatch[2].address, method: 'setVerifierAddress', args: [dvpBatch[3].address] }
  ], nonceManager, hre);

  // DvpTeleport must be deployed before Dvp so its address can be passed to the constructor
  const dvpTeleport = await deployWithNonce({ name: 'DvpTeleport', contractName: 'DvpTeleport', isProxy: false, constructorArgs: [managerAddr] }, nonceManager.allocateNonce(), hre);

  const dvp = await deployWithNonce({ name: 'Dvp', contractName: 'Dvp', isProxy: false, constructorArgs: [wrapper.address, enygmaFactoryAddress, dvpErc721FactoryAddress, dvpErc1155FactoryAddress, dvpTeleport.address, managerAddr] }, nonceManager.allocateNonce(), hre);

  // Initialize verifier aggregator and Dvp in parallel
  const initVerifierNonce = nonceManager.allocateNonce();
  const initNonce = nonceManager.allocateNonce();

  await Promise.all([
    executeConfigWithNonce({ name: 'InitVerifierAggregator', contractName: 'DvpVerifierAggregator', address: dvpBatch[0].address, method: 'initializeVerifier', args: [{ enygmaJoinSplit: proxyBatch[0].address, erc721Ownership: proxyBatch[1].address, erc1155JoinSplit: proxyBatch[2].address }] }, initVerifierNonce, hre),
    executeConfigWithNonce({ name: 'InitDvp', contractName: 'Dvp', address: dvp.address, method: 'initializeDvp', args: [dvpBatch[0].address] }, initNonce, hre)
  ]);

  // Grant TOKEN_OWNER (contract-scoped to Dvp) to all three factories.
  // They need this to call registerVault, addVaultToGroup, addTokenToGroup on Dvp.
  // TOKEN_OWNER = 2 (well-known constant in RaylsAccessManagerV1)
  const TOKEN_OWNER_ROLE_ID = 2n;
  await executeBatchConfig([
    { name: 'GrantDvpOwner_EnygmaFactory', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantContractScopedRole', args: [TOKEN_OWNER_ROLE_ID, enygmaFactoryAddress, dvp.address, 0] },
    { name: 'GrantDvpOwner_Dvp721Factory', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantContractScopedRole', args: [TOKEN_OWNER_ROLE_ID, dvpErc721FactoryAddress, dvp.address, 0] },
    { name: 'GrantDvpOwner_Dvp1155Factory', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantContractScopedRole', args: [TOKEN_OWNER_ROLE_ID, dvpErc1155FactoryAddress, dvp.address, 0] },
  ], nonceManager, hre);

  // Deploy AssetGroups for fungible and non-fungible tokens
  console.log('\n📦 Deploying AssetGroups...');
  const [fungibleAssetGroup, nonFungibleAssetGroup] = await deployBatch([
    { name: 'FungibleAssetGroup', contractName: 'AssetGroup', isProxy: false, constructorArgs: [dvp.address, managerAddr] },
    { name: 'NonFungibleAssetGroup', contractName: 'AssetGroup', isProxy: false, constructorArgs: [dvp.address, managerAddr] }
  ], nonceManager, hre);

  console.log(`  ✓ FungibleAssetGroup deployed at ${fungibleAssetGroup.address}`);
  console.log(`  ✓ NonFungibleAssetGroup deployed at ${nonFungibleAssetGroup.address}`);

  return {
    dvpAddress: dvp.address,
    dvpTeleportAddress: dvpTeleport.address,
    poseidonWrapperAddress: wrapper.address,
    fungibleAssetGroupAddress: fungibleAssetGroup.address,
    nonFungibleAssetGroupAddress: nonFungibleAssetGroup.address
  };
}

export async function deployMessageModulesBatch(nonceManager: NonceManager, hre: HardhatRuntimeEnvironment, pnhChainId: string, participantStorageAddress: string, tokenRegistryAddress: string, resourceManager: string, messageExecutor: string, endpointAddress: string, initialOwner: string, managerAddr: string) {
  console.log('\n📦 BATCH 17: Message modules');

  const batch = await deployBatch([
    { name: 'MessageSender', contractName: 'MessageSender', isProxy: false, constructorArgs: [pnhChainId, pnhChainId, participantStorageAddress, tokenRegistryAddress, endpointAddress, initialOwner, managerAddr] },
    { name: 'MessageReceiver', contractName: 'MessageReceiver', isProxy: false, constructorArgs: [resourceManager, messageExecutor, endpointAddress, initialOwner, managerAddr] },
    { name: 'BatchMessageSender', contractName: 'BatchMessageSender', isProxy: false, constructorArgs: [pnhChainId, participantStorageAddress, tokenRegistryAddress, endpointAddress, initialOwner, managerAddr] }
  ], nonceManager, hre);

  return { messageSender: batch[0].address, messageReceiver: batch[1].address, batchMessageSender: batch[2].address };
}
