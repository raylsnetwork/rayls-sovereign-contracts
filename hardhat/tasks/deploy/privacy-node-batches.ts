import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { Wallet } from 'ethers';
import { NonceManager, DeploymentTask, deployBatch, deployWithNonce, deployProxyWithoutNonce, executeBatchConfig, executeConfigWithNonce } from './batch-helpers';

// The PN TokenRegistry contracts are PN-prefixed (PNTokenRegistryV1/PNTokenCoreV1/
// PNTokenFreezeManagerV1) so their filenames no longer collide with the private-hub
// contracts (TokenRegistryV1/TokenCoreV1/TokenFreezeManagerV1). Forge therefore emits
// them at flat, unambiguous artifact paths.
export const PN_TOKEN_REGISTRY_ARTIFACT = 'out/PNTokenRegistryV1.sol/PNTokenRegistryV1.json';
export const PN_TOKEN_CORE_ARTIFACT = 'out/PNTokenCoreV1.sol/PNTokenCoreV1.json';
export const PN_TOKEN_FREEZE_MANAGER_ARTIFACT = 'out/PNTokenFreezeManagerV1.sol/PNTokenFreezeManagerV1.json';
export const PN_TOKEN_REGISTRY_SOURCE = 'src/rayls-protocol/TokenRegistry/PNTokenRegistryV1.sol';
export const PN_TOKEN_CORE_SOURCE = 'src/rayls-protocol/TokenRegistry/modules/TokenCore/PNTokenCoreV1.sol';
export const PN_TOKEN_FREEZE_MANAGER_SOURCE = 'src/rayls-protocol/TokenRegistry/modules/TokenFreezeManager/PNTokenFreezeManagerV1.sol';

export async function deployRegistriesBatch(nonceManager: NonceManager, hre: HardhatRuntimeEnvironment, initialOwner: string, managerAddr: string) {
  console.log('\n📦 BATCH 1 (COMBINED): Registries + RN Independent Contracts');
  
  // OPTIMIZED: Deploy DeploymentProxyRegistry + 3 independent RN contracts together
  // This saves ~4s by combining what were 2 sequential 4s batches into 1 batch
  const batch = await deployBatch([
    { name: 'DeploymentProxyRegistry', contractName: 'DeploymentProxyRegistryV1', isProxy: true, initArgs: [managerAddr], initializer: 'initialize(address)', validationOpts: {} },
    { name: 'RNUserGovernance', contractName: 'RNUserGovernanceV1', isProxy: true, initArgs: [managerAddr], initializer: 'initialize(address)', validationOpts: {} },
    { name: 'RNMessageExecutor', contractName: 'RNMessageExecutorV1', isProxy: true, initArgs: [managerAddr], initializer: 'initialize(address)', validationOpts: {} },
    { name: 'RNMessageDispatcher', contractName: 'RNMessageDispatcherV1', isProxy: true, initArgs: [managerAddr], initializer: 'initialize(address)', validationOpts: {} }
  ], nonceManager, hre);

  return {
    deploymentProxyRegistryAddress: batch[0].address,
    raylsNodeUserGovernanceAddress: batch[1].address,
    raylsNodeMessageExecutorAddress: batch[2].address,
    raylsNodeMessageDispatcherAddress: batch[3].address
  };
}

export async function deployRaylsNodeSystemBatch(nonceManager: NonceManager, hre: HardhatRuntimeEnvironment, initialOwner: string, chainId: string, managerAddr: string) {
  console.log('\n📦 BATCH 2: Rayls Node Dependent Contracts');

  const envValue = process.env.PUBLIC_CHAIN_ID;
  if (!envValue) throw new Error("PUBLIC_CHAIN_ID not set");
  const publicChainId = BigInt(envValue);

  // No separate node-local token governance contract is deployed here. Token lifecycle
  // state now lives behind the PN TokenRegistryV1 facade deployed in batches 5-6.
  // Keep the Rayls Node system split into dependent sub-batches for nonce predictability.
  // Sub-batch 1: RNEndpoint.
  const batch1 = await deployBatch([
    { name: 'RNEndpoint', contractName: 'RNEndpointV1', isProxy: true, initArgs: [chainId, publicChainId.toString(), managerAddr], initializer: 'initialize(uint256,uint256,address)', validationOpts: {} }
  ], nonceManager, hre);

  // Sub-batch 2: RNContractFactory depends on RNEndpoint (from batch1)
  const batch2 = await deployBatch([
    { name: 'RNContractFactory', contractName: 'RNContractFactoryV1', isProxy: true, initArgs: [batch1[0].address, batch1[0].address, initialOwner, managerAddr], initializer: 'initialize(address,address,address,address)', validationOpts: {} }
  ], nonceManager, hre);

  return {
    raylsNodeEndpointAddress: batch1[0].address,
    raylsNodeContractFactoryAddress: batch2[0].address
  };
}

export async function deployCoreContractsBatch(nonceManager: NonceManager, hre: HardhatRuntimeEnvironment, initialOwner: string, chainId: string, raylsNodeEndpointAddress: string, managerAddr: string, deployHubModules: boolean = false) {
  console.log('\n📦 BATCH 4: Core Contracts - Deploy Endpoint and ResourceManager FIRST');

  const privateHubChainId = process.env.PNH_CHAIN_ID;
  const maxBatchMessages = '500';

  // Deploy Endpoint FIRST (must exist before contracts that call registerResourceId)
  nonceManager.allocateNonce(); // Allocate nonce for Endpoint impl
  nonceManager.allocateNonce(); // Allocate nonce for Endpoint proxy
  const endpoint = await deployProxyWithoutNonce({
    name: 'Endpoint',
    contractName: 'EndpointV1',
    isProxy: true,
    initArgs: [chainId, privateHubChainId, maxBatchMessages, managerAddr],
    initializer: 'initialize(uint256,uint256,uint256,address)',
    validationOpts: {}
  }, hre, 33000000);

  // Deploy RaylsContractFactory (needed for ResourceManager)
  nonceManager.allocateNonce(); // Allocate nonce for ContractFactory impl
  nonceManager.allocateNonce(); // Allocate nonce for ContractFactory proxy
  const contractFactory = await deployProxyWithoutNonce({
    name: 'RaylsContractFactory',
    contractName: 'RaylsContractFactoryV1',
    isProxy: true,
    initArgs: [endpoint.address, raylsNodeEndpointAddress, initialOwner, managerAddr],
    initializer: 'initialize(address,address,address,address)',
    validationOpts: {}
  }, hre, 33000000);

  // Deploy ResourceManager with contractFactory and owner
  const resourceManager = await deployWithNonce({
    name: 'ResourceManager',
    contractName: 'ResourceManager',
    isProxy: false,
    constructorArgs: [contractFactory.address, initialOwner, managerAddr]
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

  // Hub-connected messaging needs a RaylsMessageExecutor — the on-PN executor the
  // MessageReceiver dispatches cross-chain messages into. Skipped in hubless mode; the
  // gate keeps the hubless nonce sequence identical to the lean deploy. BATCH 4b must
  // stay AFTER the config Promise.all so the executor's impl/proxy nonces follow the
  // ConfigEndpoint/SetResourceManagerEndpoint nonces (matches the pre-regression order).
  let messageExecutorAddress: string | undefined;
  if (deployHubModules) {
    console.log('\n📦 BATCH 4b: RaylsMessageExecutor');
    nonceManager.allocateNonce(); // Allocate nonce for MessageExecutor impl
    nonceManager.allocateNonce(); // Allocate nonce for MessageExecutor proxy
    const messageExecutor = await deployProxyWithoutNonce({
      name: 'RaylsMessageExecutor',
      contractName: 'RaylsMessageExecutorV1',
      isProxy: true,
      initArgs: [managerAddr],
      initializer: 'initialize(address)',
      validationOpts: {}
    }, hre, 33000000);
    messageExecutorAddress = messageExecutor.address;
  }

  return {
    endpointAddress: endpoint.address,
    contractFactoryAddress: contractFactory.address,
    resourceManagerAddress: resourceManager.address,
    ...(messageExecutorAddress ? { messageExecutorAddress } : {})
  };
}

export async function deployAdditionalContractsBatch(nonceManager: NonceManager, hre: HardhatRuntimeEnvironment, initialOwner: string, endpointAddress: string, managerAddr: string, deployHubModules: boolean = false) {
  console.log('\n📦 BATCH 5-6: Additional Contracts (PN Registry Modules & Events) - SEQUENTIAL for nonce predictability');

  // Always deploy the PN base (ParticipantStorageReplica) + the modular TokenRegistry facade
  // stack (TokenRegistry/TokenCore/TokenFreezeManager). These are proxies and consume
  // predictable implementation/proxy nonce pairs before the non-proxy EnygmaPNEvents below.
  // Hub-only modules (PNCommunicator: shares participant/token info with the PNH;
  // TemplateRegistryReplica: receives PNH template broadcasts) are appended only when
  // deployHubModules is set. Addresses are captured by name below so downstream code never
  // depends on raw batch indices, which shift between hubless and hub-full modes.
  // The PN TokenCore implementation DELEGATECALL-links the storage-free PNTokenCoreLib
  // (metadata/encoding/standard-mapping helpers) to stay under the EIP-170 24,576-byte code-size
  // limit. Deploy the library first (regular contract) so its address can be linked into the
  // TokenCore implementation bytecode below. This allocates one nonce before the proxy batch;
  // addresses here are captured by name, so the extra nonce does not affect downstream wiring.
  const pnTokenCoreLib = await deployWithNonce(
    { name: 'PNTokenCoreLib', contractName: 'PNTokenCoreLib', isProxy: false, constructorArgs: [] },
    nonceManager.allocateNonce(),
    hre
  );

  const additionalSpecs: DeploymentTask[] = [
    { name: 'ParticipantStorageReplica', contractName: 'ParticipantStorageReplicaV1', isProxy: true, initArgs: [endpointAddress, managerAddr], initializer: 'initialize(address,address)', validationOpts: {} },
    // Duplicate simple names are resolved through explicit PN Forge artifacts.
    { name: 'TokenRegistry', contractName: 'PNTokenRegistryV1', artifactPath: PN_TOKEN_REGISTRY_ARTIFACT, artifactSourceName: PN_TOKEN_REGISTRY_SOURCE, isProxy: true, initArgs: [endpointAddress, managerAddr], initializer: 'initialize(address,address)', validationOpts: {} },
    { name: 'TokenCore', contractName: 'PNTokenCoreV1', artifactPath: PN_TOKEN_CORE_ARTIFACT, artifactSourceName: PN_TOKEN_CORE_SOURCE, isProxy: true, initArgs: [managerAddr], initializer: 'initialize(address)', libraries: { PNTokenCoreLib: pnTokenCoreLib.address }, validationOpts: { unsafeAllow: ['external-library-linking'] } },
    { name: 'TokenFreezeManager', contractName: 'PNTokenFreezeManagerV1', artifactPath: PN_TOKEN_FREEZE_MANAGER_ARTIFACT, artifactSourceName: PN_TOKEN_FREEZE_MANAGER_SOURCE, isProxy: true, initArgs: [managerAddr], initializer: 'initialize(address)', validationOpts: {} }
  ];
  if (deployHubModules) {
    additionalSpecs.push(
      { name: 'PNCommunicator', contractName: 'PNCommunicatorV1', isProxy: true, initArgs: [endpointAddress, managerAddr], initializer: 'initialize(address,address)', validationOpts: {} },
      { name: 'TemplateRegistryReplica', contractName: 'TemplateRegistryReplicaV1', isProxy: true, initArgs: [endpointAddress, managerAddr], initializer: 'initialize(address,address)', validationOpts: {} }
    );
  }
  const batch = await deployBatch(additionalSpecs, nonceManager, hre);

  const participantStorageAddress = batch[0].address;
  const tokenRegistryAddress = batch[1].address;
  const tokenCoreAddress = batch[2].address;
  const tokenFreezeManagerAddress = batch[3].address;
  const raylsCommunicatorAddress = deployHubModules ? batch[4].address : undefined;
  const templateRegistryReplicaAddress = deployHubModules ? batch[5].address : undefined;

  // Deploy EnygmaPNEvents AFTER proxies (to maintain predictable nonce).
  // Pass managerAddr as the 4th constructor arg so restricted() functions work immediately.
  const enygmaEvents = await deployWithNonce({
    name: 'EnygmaPNEvents',
    contractName: 'EnygmaPNEvents',
    isProxy: false,
    constructorArgs: [
      endpointAddress,
      participantStorageAddress,
      tokenRegistryAddress,
      managerAddr
    ]
  }, nonceManager.allocateNonce(), hre);

  // Initialize EnygmaPNEvents
  await executeConfigWithNonce({
    name: 'InitEnygmaPNEvents',
    contractName: 'EnygmaPNEvents',
    address: enygmaEvents.address,
    method: 'initialize',
    args: []
  }, nonceManager.allocateNonce(), hre);

  const relayAuthorizationRegistryAddress =
    process.env.PN_RELAY_AUTHORIZATION_REGISTRY_ADDRESS ||
    process.env.RELAY_AUTHORIZATION_REGISTRY_ADDRESS ||
    hre.ethers.ZeroAddress;

  if (
    relayAuthorizationRegistryAddress !== hre.ethers.ZeroAddress &&
    !hre.ethers.isAddress(relayAuthorizationRegistryAddress)
  ) {
    throw new Error(`Invalid relay authorization registry address: ${relayAuthorizationRegistryAddress}`);
  }

  // Hub-only ProgrammabilityExecutor proxy: depends on the TemplateRegistryReplica deployed
  // above (hub modules). It is a UUPS proxy, so it uses deployProxyWithoutNonce
  // (deployWithNonce rejects proxies); allocate impl + proxy nonces first to keep the
  // sequence predictable. Deployed AFTER enygma to match the pre-regression nonce order.
  let programmabilityExecutorAddress: string | undefined;
  if (deployHubModules) {
    nonceManager.allocateNonce(); // Allocate nonce for ProgrammabilityExecutor impl
    nonceManager.allocateNonce(); // Allocate nonce for ProgrammabilityExecutor proxy
    const programmabilityExecutor = await deployProxyWithoutNonce({
      name: 'ProgrammabilityExecutor',
      contractName: 'ProgrammabilityExecutorV1',
      isProxy: true,
      initArgs: [endpointAddress, templateRegistryReplicaAddress, managerAddr],
      initializer: 'initialize(address,address,address)',
      validationOpts: {}
    }, hre, 33000000);
    programmabilityExecutorAddress = programmabilityExecutor.address;
  }

  // Wire the PN TokenRegistry facade to its modules and configure the modules'
  // back-references. Explicit artifact refs are required because PN and PNH
  // registries share simple contract names but expose different ABIs.
  await executeBatchConfig([
    { name: 'SetTokenRegistryCore', contractName: 'PNTokenRegistryV1', artifactPath: PN_TOKEN_REGISTRY_ARTIFACT, artifactSourceName: PN_TOKEN_REGISTRY_SOURCE, address: tokenRegistryAddress, method: 'setTokenCore', args: [tokenCoreAddress] },
    { name: 'SetTokenRegistryFreezeManager', contractName: 'PNTokenRegistryV1', artifactPath: PN_TOKEN_REGISTRY_ARTIFACT, artifactSourceName: PN_TOKEN_REGISTRY_SOURCE, address: tokenRegistryAddress, method: 'setTokenFreezeManager', args: [tokenFreezeManagerAddress] },
    { name: 'SetTokenCoreRegistry', contractName: 'PNTokenCoreV1', artifactPath: PN_TOKEN_CORE_ARTIFACT, artifactSourceName: PN_TOKEN_CORE_SOURCE, address: tokenCoreAddress, method: 'setTokenRegistry', args: [tokenRegistryAddress] },
    { name: 'SetTokenCoreFreezeManager', contractName: 'PNTokenCoreV1', artifactPath: PN_TOKEN_CORE_ARTIFACT, artifactSourceName: PN_TOKEN_CORE_SOURCE, address: tokenCoreAddress, method: 'setTokenFreezeManager', args: [tokenFreezeManagerAddress] },
    { name: 'SetTokenCoreEndpoint', contractName: 'PNTokenCoreV1', artifactPath: PN_TOKEN_CORE_ARTIFACT, artifactSourceName: PN_TOKEN_CORE_SOURCE, address: tokenCoreAddress, method: 'setEndpoint', args: [endpointAddress] },
    { name: 'SetTokenCoreEnygmaPNEvents', contractName: 'PNTokenCoreV1', artifactPath: PN_TOKEN_CORE_ARTIFACT, artifactSourceName: PN_TOKEN_CORE_SOURCE, address: tokenCoreAddress, method: 'setEnygmaPNEvents', args: [enygmaEvents.address] },
    { name: 'SetTokenCoreRelayAuthorizationRegistry', contractName: 'PNTokenCoreV1', artifactPath: PN_TOKEN_CORE_ARTIFACT, artifactSourceName: PN_TOKEN_CORE_SOURCE, address: tokenCoreAddress, method: 'setRelayAuthorizationRegistry', args: [relayAuthorizationRegistryAddress] },
    { name: 'SetTokenFreezeManagerRegistry', contractName: 'PNTokenFreezeManagerV1', artifactPath: PN_TOKEN_FREEZE_MANAGER_ARTIFACT, artifactSourceName: PN_TOKEN_FREEZE_MANAGER_SOURCE, address: tokenFreezeManagerAddress, method: 'setTokenRegistry', args: [tokenRegistryAddress] },
    { name: 'SetTokenFreezeManagerCore', contractName: 'PNTokenFreezeManagerV1', artifactPath: PN_TOKEN_FREEZE_MANAGER_ARTIFACT, artifactSourceName: PN_TOKEN_FREEZE_MANAGER_SOURCE, address: tokenFreezeManagerAddress, method: 'setTokenCore', args: [tokenCoreAddress] },
    { name: 'SetTokenFreezeManagerEndpoint', contractName: 'PNTokenFreezeManagerV1', artifactPath: PN_TOKEN_FREEZE_MANAGER_ARTIFACT, artifactSourceName: PN_TOKEN_FREEZE_MANAGER_SOURCE, address: tokenFreezeManagerAddress, method: 'setEndpoint', args: [endpointAddress] },
    { name: 'SetTokenFreezeManagerRelayAuthorizationRegistry', contractName: 'PNTokenFreezeManagerV1', artifactPath: PN_TOKEN_FREEZE_MANAGER_ARTIFACT, artifactSourceName: PN_TOKEN_FREEZE_MANAGER_SOURCE, address: tokenFreezeManagerAddress, method: 'setRelayAuthorizationRegistry', args: [relayAuthorizationRegistryAddress] },
  ], nonceManager, hre);

  return {
    participantStorageAddress,
    tokenRegistryAddress,
    tokenCoreAddress,
    tokenFreezeManagerAddress,
    enygmaPNEventsAddress: enygmaEvents.address,
    relayAuthorizationRegistryAddress,
    ...(raylsCommunicatorAddress ? { raylsCommunicatorAddress } : {}),
    ...(templateRegistryReplicaAddress ? { templateRegistryReplicaAddress } : {}),
    ...(programmabilityExecutorAddress ? { programmabilityExecutorAddress } : {}),
  };
}

// Hub-connected messaging modules (non-proxy): MessageSender/MessageReceiver/
// BatchMessageSender. These wire the PN's EndpointV1 to the cross-chain send/receive
// path the private relayer drives, and are required by STEP 4 (synchronizeWithPrivateHub).
// Only deployed in hub-full mode (see deploy:privacy-node, gated on !hubless).
export async function deployMessageModulesBatch(nonceManager: NonceManager, hre: HardhatRuntimeEnvironment, chainId: string, participantStorageAddress: string, tokenRegistryAddress: string, resourceManagerAddress: string, messageExecutorAddress: string, endpointAddress: string, initialOwner: string, managerAddr: string) {
  console.log('\n📦 BATCH 7: Message Modules');

  const privateHubChainId = process.env.PNH_CHAIN_ID;
  if (!privateHubChainId) {
    throw new Error('PNH_CHAIN_ID environment variable is not set');
  }

  const batch = await deployBatch([
    { name: 'MessageSender', contractName: 'MessageSender', isProxy: false, constructorArgs: [chainId, privateHubChainId, participantStorageAddress, tokenRegistryAddress, endpointAddress, initialOwner, managerAddr] },
    { name: 'MessageReceiver', contractName: 'MessageReceiver', isProxy: false, constructorArgs: [resourceManagerAddress, messageExecutorAddress, endpointAddress, initialOwner, managerAddr] },
    { name: 'BatchMessageSender', contractName: 'BatchMessageSender', isProxy: false, constructorArgs: [privateHubChainId, participantStorageAddress, tokenRegistryAddress, endpointAddress, initialOwner, managerAddr] }
  ], nonceManager, hre);

  return {
    messageSenderAddress: batch[0].address,
    messageReceiverAddress: batch[1].address,
    batchMessageSenderAddress: batch[2].address
  };
}

