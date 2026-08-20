import hre, { ethers } from 'hardhat';
import { mockRelayerEthersLastTransaction } from './RelayerMockEthers';
import { EndpointV1 } from '../../../../typechain-types';
import '@nomicfoundation/hardhat-ethers';
import { token } from '../../../../typechain-types/@openzeppelin/contracts';
import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/signers';

export const genRanHex = (size: number) => [...Array(size)].map(() => Math.floor(Math.random() * 16).toString(16)).join('');

export async function basicDeploySetupUpgrade() {
  // Contracts are deployed using the first signer/account by default
  //logar cada endereco signer

  const [owner, otherAccount, account3, account4, account5, account6] = await ethers.getSigners();
  const chainIdPN1 = '123';
  const chainIdPN2 = '456';
  const chainIdPN3 = '789';
  const chainIdPN4 = '901';
  const chainIdPNH = '1789';
  const dvpMerkleTreeDepth = '8';

  const ownerAddress = await owner.getAddress();

  const token = await ethers.getContractFactory('TokenExample');
  const tokenCustom = await ethers.getContractFactory('CustomTokenExample');

  // ─────────────────────────────────────────────────────────────────────────
  // AUTH-V3: Deploy shared access manager FIRST — all contracts need it at initialize time
  // ─────────────────────────────────────────────────────────────────────────
  console.log('\n📋 AUTH-V3: Deploying access manager...');
  const managerFactory = await ethers.getContractFactory('RaylsAccessManagerV1');
  const managerProxy = await deployUUPSProxy(managerFactory, 'initialize(address)', [ownerAddress]);
  await managerProxy.waitForDeployment();
  const manager = await ethers.getContractAt('RaylsAccessManagerV1', await managerProxy.getAddress());
  const managerAddr = await manager.getAddress();

  // Deploy core contracts
  const raylsMessageExecutorPN1 = await deployRaylsMessageExecutor(managerAddr);
  const raylsMessageExecutorPN2 = await deployRaylsMessageExecutor(managerAddr);
  const raylsMessageExecutorPN3 = await deployRaylsMessageExecutor(managerAddr);
  const raylsMessageExecutorPN4 = await deployRaylsMessageExecutor(managerAddr);
  const raylsMessageExecutorCC = await deployRaylsMessageExecutor(managerAddr);

  const raylsMessageExecutorPN1Address = await raylsMessageExecutorPN1.getAddress();
  const raylsMessageExecutorPN2Address = await raylsMessageExecutorPN2.getAddress();
  const raylsMessageExecutorPN3Address = await raylsMessageExecutorPN3.getAddress();
  const raylsMessageExecutorPN4Address = await raylsMessageExecutorPN4.getAddress();
  const raylsMessageExecutorCCAddress = await raylsMessageExecutorCC.getAddress();

  // Deploy endpoints
  const endpointPN1 = await deployEndpointPNH(chainIdPN1, chainIdPNH, managerAddr);
  const endpointPN2 = await deployEndpointPNH(chainIdPN2, chainIdPNH, managerAddr);
  const endpointPN3 = await deployEndpointPNH(chainIdPN3, chainIdPNH, managerAddr);
  const endpointPN4 = await deployEndpointPNH(chainIdPN4, chainIdPNH, managerAddr);
  const endpointPNH = await deployEndpointPNH(chainIdPNH, chainIdPNH, managerAddr);

  const endpointPN1Addresss = await endpointPN1.getAddress();
  const endpointPN2Addresss = await endpointPN2.getAddress();
  const endpointPN3Addresss = await endpointPN3.getAddress();
  const endpointPN4Addresss = await endpointPN4.getAddress();
  const endpointPNHAddresss = await endpointPNH.getAddress();

  // Deploy core registries
  const resourceRegistry = await deployResourceRegistry(managerAddr);
  const resourceRegistryAddress = await resourceRegistry.getAddress();

  // Deploy contract factories
  const raylsContractFactoryPN1 = await deployContractFactory(ownerAddress, endpointPN1Addresss, managerAddr);
  const raylsContractFactoryPN2 = await deployContractFactory(ownerAddress, endpointPN2Addresss, managerAddr);
  const raylsContractFactoryPN3 = await deployContractFactory(ownerAddress, endpointPN3Addresss, managerAddr);
  const raylsContractFactoryPN4 = await deployContractFactory(ownerAddress, endpointPN4Addresss, managerAddr);

  const raylsContractFactoryPN1Address = await raylsContractFactoryPN1.getAddress();
  const raylsContractFactoryPN2Address = await raylsContractFactoryPN2.getAddress();
  const raylsContractFactoryPN3Address = await raylsContractFactoryPN3.getAddress();
  const raylsContractFactoryPN4Address = await raylsContractFactoryPN4.getAddress();

  // Register roles
  await (await manager['registerRole(string)']('ENDPOINT_SENDER')).wait();
  const endpointSenderRoleId = await manager.getRoleIdByName('ENDPOINT_SENDER');
  await (await manager['registerRole(string)']('FACTORY_ADMIN')).wait();
  const factoryAdminRoleId = await manager.getRoleIdByName('FACTORY_ADMIN');
  // FACTORY_ADMIN is admin of ENDPOINT_SENDER — factories can grant ENDPOINT_SENDER to deployed tokens
  await (await manager.setRoleAdmin(endpointSenderRoleId, factoryAdminRoleId)).wait();

  // Map all send-path selectors on every endpoint
  const endpointSelectors = [
    ethers.id('send(uint256,address,bytes)').slice(0, 10),
    ethers.id('send(uint256,address,bytes,(uint256,bytes32,bytes32,uint256,bytes32,address,address,bytes32))').slice(0, 10),
    ethers.id('sendBatch((uint256,address,bytes)[])').slice(0, 10),
    ethers.id('sendToResourceId(uint256,bytes32,bytes)').slice(0, 10),
    ethers.id('sendBatchToResourceId((uint256,bytes32,bytes)[])').slice(0, 10),
    ethers.id('sendToResourceId(uint256,bytes32,bytes,bytes,bytes,bytes,(uint256,bytes32,bytes32,uint256,bytes32,address,address,bytes32))').slice(0, 10),
    ethers.id('sendBatchToResourceId((uint256,bytes32,bytes,bytes,bytes,bytes,(uint256,bytes32,bytes32,uint256,bytes32,address,address,bytes32))[])').slice(0, 10),
    ethers.id('registerResourceId(bytes32,address)').slice(0, 10),
  ];
  for (const epAddr of [endpointPN1Addresss, endpointPN2Addresss, endpointPN3Addresss, endpointPN4Addresss, endpointPNHAddresss]) {
    await (await manager.addFunctionAllowedRoles(epAddr, endpointSelectors, [endpointSenderRoleId])).wait();
  }

  // Grant FACTORY_ADMIN_ROLE to PN contract factories so they can grant ENDPOINT_SENDER to new tokens
  for (const factoryAddr of [raylsContractFactoryPN1Address, raylsContractFactoryPN2Address, raylsContractFactoryPN3Address, raylsContractFactoryPN4Address]) {
    await (await manager.grantRole(factoryAdminRoleId, factoryAddr, 0)).wait();
  }
  console.log('✓ AUTH-V3 setup complete: manager deployed, all endpoints bound, roles registered');

  // Deploy ResourceManager for endpoints FIRST (before ParticipantStorage)
  const resourceManagerPN1 = await deployResourceManager(raylsContractFactoryPN1Address, ownerAddress);
  const resourceManagerPN2 = await deployResourceManager(raylsContractFactoryPN2Address, ownerAddress);
  const resourceManagerPN3 = await deployResourceManager(raylsContractFactoryPN3Address, ownerAddress);
  const resourceManagerPN4 = await deployResourceManager(raylsContractFactoryPN4Address, ownerAddress);
  const resourceManagerCC = await deployResourceManager('0x0000000000000000000000000000000000099999', ownerAddress);

  // Configure ResourceManager in endpoints FIRST (like in private-hub)
  await endpointPN1.configureModules(
    resourceManagerPN1,
    ethers.ZeroAddress, // Will be configured later
    ethers.ZeroAddress, // Will be configured later
    ethers.ZeroAddress  // Will be configured later
  );

  await endpointPN2.configureModules(
    resourceManagerPN2,
    ethers.ZeroAddress, // Will be configured later
    ethers.ZeroAddress, // Will be configured later
    ethers.ZeroAddress  // Will be configured later
  );

  await endpointPNH.configureModules(
    resourceManagerCC,
    ethers.ZeroAddress, // Will be configured later
    ethers.ZeroAddress, // Will be configured later
    ethers.ZeroAddress  // Will be configured later
  );

  await endpointPN3.configureModules(
    resourceManagerPN3,
    ethers.ZeroAddress, // Will be configured later
    ethers.ZeroAddress, // Will be configured later
    ethers.ZeroAddress  // Will be configured later
  );

  await endpointPN4.configureModules(
    resourceManagerPN4,
    ethers.ZeroAddress, // Will be configured later
    ethers.ZeroAddress, // Will be configured later
    ethers.ZeroAddress  // Will be configured later
  );

  // NOW deploy ParticipantStorage with modules (after ResourceManager is configured)
  const { participantStorage, participantCoreAddress, auditManagerAddress, enygmaManagerAddress } = await deployParticipantStorageWithModules(endpointPNHAddresss, managerAddr);
  const participantStorageAddress = await participantStorage.getAddress();


  console.log('\n📋 STEP 4: DEPLOYING ENYGMA FACTORY SYSTEM');

  const {
    factoryAddress: enygmaFactoryAddress,
    settingsAddress: enygmaFactorySettingsAddress,
    registryAddress: enygmaRegistryAddress,
    integrationCreatorAddress: enygmaIntegrationCreatorAddress
  } = await deployEnygmaFactorySystem(ownerAddress);

  console.log('\n📋 STEP 4.5: DEPLOYING DVP SETTINGS');
  const DvpSettings = await ethers.getContractFactory('DvpSettings');
  const dvpSettings = await DvpSettings.deploy(ownerAddress);
  await dvpSettings.waitForDeployment();
  const dvpSettingsAddress = await dvpSettings.getAddress();
  console.log(`  ✓ DvpSettings deployed at ${dvpSettingsAddress}`);

  // Deploy TokenRegistry with modules (like in private-hub)
  const { tokenRegistry, tokenCoreAddress, enygmaTokenManagerAddress, tokenFreezeManagerAddress } = await deployTokenRegistryWithModules(participantStorageAddress, resourceRegistryAddress, endpointPNHAddresss, enygmaFactoryAddress, enygmaFactorySettingsAddress, dvpSettingsAddress, managerAddr);
  const tokenRegistryAddress = await tokenRegistry.getAddress();
  await resourceRegistry.setTokenRegistry(tokenRegistryAddress);

  // Deploy ParticipantStorage with modules (like in private-hub)
  const participantStorageReplicaPN1 = await deployRaylsParticipantReplica(endpointPN1Addresss, managerAddr);
  const participantStorageReplicaPN2 = await deployRaylsParticipantReplica(endpointPN2Addresss, managerAddr);
  const tokenRegistryReplicaPN1 = await deployTokenRegistryV1Replica(endpointPN1Addresss, managerAddr);
  const tokenRegistryReplicaPN2 = await deployTokenRegistryV1Replica(endpointPN2Addresss, managerAddr);
  const tokenRegistryReplicaPN3 = await deployTokenRegistryV1Replica(endpointPN3Addresss, managerAddr);
  const tokenRegistryReplicaPN4 = await deployTokenRegistryV1Replica(endpointPN4Addresss, managerAddr);

  const tokenRegistryReplicaPN1Address = await tokenRegistryReplicaPN1.getAddress();
  const tokenRegistryReplicaPN2Address = await tokenRegistryReplicaPN2.getAddress();
  const tokenRegistryReplicaPN3Address = await tokenRegistryReplicaPN3.getAddress();
  const tokenRegistryReplicaPN4Address = await tokenRegistryReplicaPN4.getAddress();

  const participantStorageReplicaPN3 = await deployRaylsParticipantReplica(endpointPN3Addresss, managerAddr);
  const participantStorageReplicaPN4 = await deployRaylsParticipantReplica(endpointPN4Addresss, managerAddr);

  const participantStorageReplicaPN1Address = await participantStorageReplicaPN1.getAddress();
  const participantStorageReplicaPN2Address = await participantStorageReplicaPN2.getAddress();
  const participantStorageReplicaPN3Address = await participantStorageReplicaPN3.getAddress();
  const participantStorageReplicaPN4Address = await participantStorageReplicaPN4.getAddress();

  // Deploy modules for endpoints
  const messageSenderPN1 = await deployMessageSender(chainIdPN1, chainIdPNH, participantStorageReplicaPN1Address, tokenRegistryReplicaPN1Address, ownerAddress);
  const messageSenderPN2 = await deployMessageSender(chainIdPN2, chainIdPNH, participantStorageReplicaPN2Address, tokenRegistryReplicaPN2Address, ownerAddress);
  const messageSenderPN3 = await deployMessageSender(chainIdPN3, chainIdPNH, participantStorageReplicaPN3Address, tokenRegistryReplicaPN3Address, ownerAddress);
  const messageSenderPN4 = await deployMessageSender(chainIdPN4, chainIdPNH, participantStorageReplicaPN4Address, tokenRegistryReplicaPN4Address, ownerAddress);
  const messageSenderPNH = await deployMessageSender(chainIdPNH, chainIdPNH, participantStorageAddress, tokenRegistryAddress, ownerAddress);

  const messageReceiverPN1 = await deployMessageReceiver(resourceManagerPN1, raylsMessageExecutorPN1Address);
  const messageReceiverPN2 = await deployMessageReceiver(resourceManagerPN2, raylsMessageExecutorPN2Address);
  const messageReceiverPN3 = await deployMessageReceiver(resourceManagerPN3, raylsMessageExecutorPN3Address);
  const messageReceiverPN4 = await deployMessageReceiver(resourceManagerPN4, raylsMessageExecutorPN4Address);
  const messageReceiverCC = await deployMessageReceiver(resourceManagerCC, raylsMessageExecutorCCAddress);

  const batchMessageSenderPN1 = await deployBatchMessageSender(chainIdPNH, participantStorageReplicaPN1Address, tokenRegistryReplicaPN1Address, endpointPN1Addresss, ownerAddress);
  const batchMessageSenderPN2 = await deployBatchMessageSender(chainIdPNH, participantStorageReplicaPN2Address, tokenRegistryReplicaPN2Address, endpointPN2Addresss, ownerAddress);
  const batchMessageSenderPN3 = await deployBatchMessageSender(chainIdPNH, participantStorageReplicaPN3Address, tokenRegistryReplicaPN3Address, endpointPN3Addresss, ownerAddress);
  const batchMessageSenderPN4 = await deployBatchMessageSender(chainIdPNH, participantStorageReplicaPN4Address, tokenRegistryReplicaPN4Address, endpointPN4Addresss, ownerAddress);
  const batchMessageSenderPNH = await deployBatchMessageSender(chainIdPNH, participantStorageAddress, tokenRegistryAddress, endpointPNHAddresss, ownerAddress);

  // ─────────────────────────────────────────────────────────────────────────
  // AUTH-V3: Grant ENDPOINT_SENDER_ROLE to all contracts that call endpoint
  // ─────────────────────────────────────────────────────────────────────────
  console.log('\n📋 AUTH-V3: Granting ENDPOINT_SENDER_ROLE to all protocol contracts...');

  // PNH endpoint — all contracts that call send/registerResourceId on endpointPNH
  const pnhGrantees = [
    participantStorageAddress, participantCoreAddress, auditManagerAddress, enygmaManagerAddress,
    tokenRegistryAddress, tokenCoreAddress, enygmaTokenManagerAddress, tokenFreezeManagerAddress,
    resourceRegistryAddress,
    raylsMessageExecutorPN1Address, raylsMessageExecutorPN2Address,
    raylsMessageExecutorPN3Address, raylsMessageExecutorPN4Address, raylsMessageExecutorCCAddress,
    messageSenderPNH, batchMessageSenderPNH,
  ];
  for (const addr of pnhGrantees) {
    await (await manager.grantRole(endpointSenderRoleId, addr, 0)).wait();
  }

  // PN1 endpoint
  for (const addr of [participantStorageReplicaPN1Address, tokenRegistryReplicaPN1Address, messageSenderPN1, batchMessageSenderPN1]) {
    await (await manager.grantRole(endpointSenderRoleId, addr, 0)).wait();
  }
  // PN2 endpoint
  for (const addr of [participantStorageReplicaPN2Address, tokenRegistryReplicaPN2Address, messageSenderPN2, batchMessageSenderPN2]) {
    await (await manager.grantRole(endpointSenderRoleId, addr, 0)).wait();
  }
  // PN3 endpoint
  for (const addr of [participantStorageReplicaPN3Address, tokenRegistryReplicaPN3Address, messageSenderPN3, batchMessageSenderPN3]) {
    await (await manager.grantRole(endpointSenderRoleId, addr, 0)).wait();
  }
  // PN4 endpoint
  for (const addr of [participantStorageReplicaPN4Address, tokenRegistryReplicaPN4Address, messageSenderPN4, batchMessageSenderPN4]) {
    await (await manager.grantRole(endpointSenderRoleId, addr, 0)).wait();
  }
  console.log('✓ ENDPOINT_SENDER_ROLE granted to all protocol contracts');

  const messageIdsAlreadyProcessed: { [messageIdConcatWithChainId: string]: boolean | null } = {};
  const endpointMappings: { [chainId: string]: EndpointV1 | null } = {};
  endpointMappings[chainIdPN1] = endpointPN1;
  endpointMappings[chainIdPN2] = endpointPN2;
  endpointMappings[chainIdPN3] = endpointPN3;
  endpointMappings[chainIdPN4] = endpointPN4;
  endpointMappings[chainIdPNH] = endpointPNH;

  await endpointPN1.registerPrivateHubAddress('TokenRegistry', tokenRegistryAddress);
  await endpointPN2.registerPrivateHubAddress('TokenRegistry', tokenRegistryAddress);
  await endpointPN3.registerPrivateHubAddress('TokenRegistry', tokenRegistryAddress);
  await endpointPN4.registerPrivateHubAddress('TokenRegistry', tokenRegistryAddress);

  // Then configure all modules and contracts in endpoints
  await endpointPN1.configureEndpoint(
    raylsContractFactoryPN1Address,
    participantStorageReplicaPN1Address,
    tokenRegistryReplicaPN1Address,
    resourceManagerPN1,
    messageSenderPN1,
    messageReceiverPN1,
    batchMessageSenderPN1
  );

  await endpointPN2.configureEndpoint(
    raylsContractFactoryPN2Address,
    participantStorageReplicaPN2Address,
    tokenRegistryReplicaPN2Address,
    resourceManagerPN2,
    messageSenderPN2,
    messageReceiverPN2,
    batchMessageSenderPN2
  );

  await endpointPNH.configureEndpoint(
    '0x0000000000000000000000000000000000000002',
    participantStorageAddress,
    tokenRegistryAddress,
    resourceManagerCC,
    messageSenderPNH,
    messageReceiverCC,
    batchMessageSenderPNH
  );

  await endpointPN3.configureEndpoint(
    raylsContractFactoryPN3Address,
    participantStorageReplicaPN3Address,
    tokenRegistryReplicaPN3Address,
    resourceManagerPN3,
    messageSenderPN3,
    messageReceiverPN3,
    batchMessageSenderPN3
  );

  await endpointPN4.configureEndpoint(
    raylsContractFactoryPN4Address,
    participantStorageReplicaPN4Address,
    tokenRegistryReplicaPN4Address,
    resourceManagerPN4,
    messageSenderPN4,
    messageReceiverPN4,
    batchMessageSenderPN4
  );

  // Set up authorization for MessageReceiver and RaylsMessageExecutor
  console.log('\n📋 SETTING UP MESSAGE AUTHORIZATION');

  const messageReceiverContractPN1 = await ethers.getContractAt('MessageReceiver', messageReceiverPN1);
  const messageReceiverContractPN2 = await ethers.getContractAt('MessageReceiver', messageReceiverPN2);
  const messageReceiverContractPN3 = await ethers.getContractAt('MessageReceiver', messageReceiverPN3);
  const messageReceiverContractPN4 = await ethers.getContractAt('MessageReceiver', messageReceiverPN4);
  const messageReceiverContractPNH = await ethers.getContractAt('MessageReceiver', messageReceiverCC);

  await messageReceiverContractPN1.setAuthorizedEndpoint(endpointPN1Addresss);
  await messageReceiverContractPN2.setAuthorizedEndpoint(endpointPN2Addresss);
  await messageReceiverContractPN3.setAuthorizedEndpoint(endpointPN3Addresss);
  await messageReceiverContractPN4.setAuthorizedEndpoint(endpointPN4Addresss);
  await messageReceiverContractPNH.setAuthorizedEndpoint(endpointPNHAddresss);

  await raylsMessageExecutorPN1.setAuthorizedMessageReceiver(messageReceiverPN1);
  await raylsMessageExecutorPN2.setAuthorizedMessageReceiver(messageReceiverPN2);
  await raylsMessageExecutorPN3.setAuthorizedMessageReceiver(messageReceiverPN3);
  await raylsMessageExecutorPN4.setAuthorizedMessageReceiver(messageReceiverPN4);
  await raylsMessageExecutorCC.setAuthorizedMessageReceiver(messageReceiverCC);

  console.log('✓ Message authorization configured successfully');

  // Add participants with the correct structure
  await participantStorage.addParticipant({
    chainId: chainIdPN1,
    role: 1,
    ownerId: ownerAddress,
    name: 'PN1',
    allowedToBroadcast: true
  });
  await participantStorage.updateStatus(chainIdPN1, 1);

  await participantStorage.addParticipant({
    chainId: chainIdPN2,
    role: 1,
    ownerId: ownerAddress,
    name: 'PN2',
    allowedToBroadcast: true
  });
  await participantStorage.updateStatus(chainIdPN2, 1);

  await participantStorage.addParticipant({
    chainId: chainIdPN3,
    role: 1,
    ownerId: ownerAddress,
    name: 'PN3',
    allowedToBroadcast: true
  });
  await participantStorage.updateStatus(chainIdPN3, 1);

  await participantStorage.addParticipant({
    chainId: chainIdPN4,
    role: 1,
    ownerId: ownerAddress,
    name: 'PN4',
    allowedToBroadcast: true
  });
  await participantStorage.updateStatus(chainIdPN4, 1);

  await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);


  console.log('→ Deploying Proofs...');
  const proofsAddress = await deployProofs();

  await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);
  // --------------------------------------------------------------------------
  // 6. DEPLOY DVP SYSTEM
  // --------------------------------------------------------------------------
  console.log('\n📋 STEP 6: DEPLOYING DVP SYSTEM');

  console.log('→ Deploying Dvp contracts...');
  const { dvpAddress, dvpVerifierAddress, merkleTreeRegistryMap } = await deployDvp(enygmaFactoryAddress);

  console.log('→ Initializing Dvp with verification keys...');
  await initializeDvp(dvpAddress, dvpVerifierAddress, merkleTreeRegistryMap, dvpMerkleTreeDepth);

  console.log('→ Deploying DvpTeleport...');
  const dvpTeleportAddress = await deployDvpTeleport(ownerAddress);
  await (await manager.grantRole(endpointSenderRoleId, dvpTeleportAddress, 0)).wait();

  await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);
  // --------------------------------------------------------------------------
  // 7. DEPLOY VERIFIERS
  // --------------------------------------------------------------------------
  console.log('\n📋 STEP 7: DEPLOYING VERIFIERS');

  // Deploy all Enygma verifiers (k=2 to k=6)
  const enygmaVerifierk2Address = await deployEnygmaVerifierk2();
  const enygmaVerifierk3Address = await deployEnygmaVerifierk3();
  const enygmaVerifierk4Address = await deployEnygmaVerifierk4();
  const enygmaVerifierk5Address = await deployEnygmaVerifierk5();
  const enygmaVerifierk6Address = await deployEnygmaVerifierk6();

  // Deploy all deposit verifiers (k=2 to k=6)
  const depositToDvpVerifierk2Address = await deployEnygmaDepositToDvpVerifierk2();
  const depositToDvpVerifierk3Address = await deployEnygmaDepositToDvpVerifierk3();
  const depositToDvpVerifierk4Address = await deployEnygmaDepositToDvpVerifierk4();
  const depositToDvpVerifierk5Address = await deployEnygmaDepositToDvpVerifierk5();
  const depositToDvpVerifierk6Address = await deployEnygmaDepositToDvpVerifierk6();

  // Deploy all withdraw verifiers (k=2 to k=6)
  const withdrawFromDvpVerifierk2Address = await deployEnygmaWithdrawFromDvpVerifierk2();
  const withdrawFromDvpVerifierk3Address = await deployEnygmaWithdrawFromDvpVerifierk3();
  const withdrawFromDvpVerifierk4Address = await deployEnygmaWithdrawFromDvpVerifierk4();
  const withdrawFromDvpVerifierk5Address = await deployEnygmaWithdrawFromDvpVerifierk5();
  const withdrawFromDvpVerifierk6Address = await deployEnygmaWithdrawFromDvpVerifierk6();

  console.log('  [7/7] Configuring EnygmaFactorySettings...');


  const verifierAddresses = {
    enygmaK2: enygmaVerifierk2Address,
    enygmaK3: enygmaVerifierk3Address,
    enygmaK4: enygmaVerifierk4Address,
    enygmaK5: enygmaVerifierk5Address,
    enygmaK6: enygmaVerifierk6Address,
    depositK2: depositToDvpVerifierk2Address,
    depositK3: depositToDvpVerifierk3Address,
    depositK4: depositToDvpVerifierk4Address,
    depositK5: depositToDvpVerifierk5Address,
    depositK6: depositToDvpVerifierk6Address,
    withdrawK2: withdrawFromDvpVerifierk2Address,
    withdrawK3: withdrawFromDvpVerifierk3Address,
    withdrawK4: withdrawFromDvpVerifierk4Address,
    withdrawK5: withdrawFromDvpVerifierk5Address,
    withdrawK6: withdrawFromDvpVerifierk6Address,
    dvp: dvpAddress
  };

  const enygmaFactorySettingsContract = await ethers.getContractAt('EnygmaFactorySettings', enygmaFactorySettingsAddress);
  await enygmaFactorySettingsContract.setAllVerifiers(
    verifierAddresses
  );
  console.log('  ✓ EnygmaFactorySettings configured with all verifiers');

  // -------------------------------------------------------------------------
  // 8. DEPLOY ENYGMA PNH EVENTS
  // -------------------------------------------------------------------------
  console.log('\n→ Deploying EnygmaPNHEvents after participant setup...');
  const enygmaPNHEventsAddress = await deployEnygmaPNHEvents(endpointPNHAddresss);
  console.log(`✓ EnygmaPNHEvents deployed at ${enygmaPNHEventsAddress}`);
  await (await manager.grantRole(endpointSenderRoleId, enygmaPNHEventsAddress, 0)).wait();

  await deployEnygmaPNEvents(owner, endpointPN1Addresss, managerAddr);
  await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);
  await deployEnygmaPNEvents(owner, endpointPN2Addresss, managerAddr);
  await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);
  await deployEnygmaPNEvents(owner, endpointPN3Addresss, managerAddr);
  await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);
  await deployEnygmaPNEvents(owner, endpointPN4Addresss, managerAddr);
  await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);

  console.log('✅ All contracts deployed and configured successfully');

  // AUTH-V3: All endpoint authorizations are handled via manager.grantRole above.
  // ENDPOINT_SENDER_ROLE was granted to PNH and PN protocol contracts earlier in setup.

  //const resourceId = '0x7265736f757263652d6964000000000000000000000000000000000000000000'; // 'resource-id' padded to bytes32

  /*
  // Deploy the main Enygma contract - kept the same
  const enygma = await deployEnygma(
    ownerAddress,
    participantStorageAddress,
    endpointPNHAddresss, // Pass the endpoint for the private hub
    tokenRegistryAddress, // Token Registry contract address
  );
  */
  //await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);


  //const tokenPN1 = await token.deploy('TokenTest', 'TT', endpointPN1Addresss);

  //await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);

  //const tokenCustomPN1 = await tokenCustom.deploy('TokenCustomTest', 'TCT', endpointPN1Addresss, endpointPN1Addresss, endpointPN1Addresss);

  //await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);


  // Deploy the Enygma example contract


  //const enygmaFactory = await ethers.getContractFactory('EnygmaTokenExample');
  //const enygma = await enygmaFactory.deploy('enygma', 'eny', endpointPN1Addresss);
  //await enygma.waitForDeployment();
  //await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);
  //await enygma.submitTokenRegistration(0);

  //await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);

  //const allTokens = await tokenRegistry.getAllTokens();
  //console.log('allTokens', allTokens);

  //tokenRegistry.updateStatus(allTokens[0].resourceId, 1);

  //await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);

 // console.log('✅✅ All contracts deployed and configured successfully && Setup done');


  return {
    owner,
    otherAccount,
    endpointPN2,
    raylsContractFactoryPN2,
    endpointPN1,
    endpointPNH,
    chainIdPN1,
    chainIdPN2,
    chainIdPN3,
    chainIdPN4,
    chainIdPNH,
    endpointMappings,
    account3,
    account4,
    account5,
    account6,
    messageIdsAlreadyProcessedOnDeploy: { ...messageIdsAlreadyProcessed },
    tokenRegistry,
    resourceRegistry,
    participantStorage,
    participantStorageReplicaPN1,
    participantStorageReplicaPN2,
    participantStorageReplicaPN3,
    participantStorageReplicaPN4,
    raylsMessageExecutorPN1,
    raylsMessageExecutorPN2,
    raylsMessageExecutorPN3,
    raylsMessageExecutorPN4,
    raylsMessageExecutorCC,
    tokenCoreAddress,
    manager,
    managerAddr,
    endpointSenderRoleId,
  };
}

async function deployEnygmaPNEvents(deployer: HardhatEthersSigner, endpointAddress: string, authorityAddress: string): Promise<string> {
  console.log('→ Deploying EnygmaPNEvents contract...');

  try {
    // Step 1: Deploy the contract
    console.log('  [1/2] Creating deployment transaction...');
    const factory = await ethers.getContractFactory('EnygmaPNEvents', deployer);
    // Constructor: (endpointAddress, participantValidator, tokenValidator, authority)
    const contract = await factory.deploy(endpointAddress, ethers.ZeroAddress, ethers.ZeroAddress, authorityAddress);

    console.log('  → Waiting for deployment transaction to be mined...');
    await contract.waitForDeployment();

    const address = await contract.getAddress();
    console.log(`  ✓ EnygmaPNEvents deployed at ${address}`);

    // Step 2: Initialize the contract
    console.log('  [2/2] Initializing EnygmaPNEvents...');
    try {
      const tx = await contract.initialize();
      console.log('  → Waiting for initialization transaction to be mined...');
      await tx.wait();
      console.log('  ✓ EnygmaPNEvents initialized successfully');
    } catch (error: any) {
      console.error('  ✗ Failed to initialize EnygmaPNEvents:', error.message);

      // Try to decode the revert reason if available
      if (error.data) {
        try {
          const decodedError = ethers.AbiCoder.defaultAbiCoder().decode(['string'], error.data);
          console.error('  → Revert reason:', decodedError[0]);
        } catch (decodeError) {
          console.error('  → Could not decode error data');
        }
      }

      console.error('\n⚠️ TROUBLESHOOTING TIPS:');
      console.error('  1. Check if the Endpoint is properly configured with ResourceManager module');
      console.error('  2. Ensure that all required modules are deployed and configured');
      console.error('  3. Verify that the contract has the correct dependencies');

      throw new Error('EnygmaPNEvents initialization failed. See above for details.');
    }

    return address;
  } catch (error) {
    console.error('  ✗ Error deploying EnygmaPNEvents:', error);
    throw error;
  }
}


async function deployEnygmaPNHEvents(endpointAddress: string) {
  console.log('\n→ Deploying EnygmaPNHEvents contract...');

  try {
    console.log('  [1/1] Creating deployment transaction...');
    const enygmaPNHEventsFactory = await ethers.getContractFactory('EnygmaPNHEvents');
    const enygmaPNHEvents = await enygmaPNHEventsFactory.deploy(endpointAddress);

    console.log('  → Waiting for deployment transaction to be mined...');
    await enygmaPNHEvents.waitForDeployment();

    const finalAddress = await enygmaPNHEvents.getAddress();
    console.log(`  ✓ EnygmaPNHEvents deployed at ${finalAddress}`);

    return finalAddress;
  } catch (error) {
    console.error('  ✗ Error deploying EnygmaPNHEvents:', error);
    throw error;
  }
}


async function deployEnygmaFactorySystem(initialOwner: string) {
  console.log('Deploying Enygma Factory System...');

  console.log('Deploying EnygmaFactorySettings...');
  const enygmaFactorySettingsFactory = await ethers.getContractFactory('EnygmaFactorySettings');
  // Deploy with zero addresses; actual verifier/dvp addresses configured later in step 7
  const enygmaFactorySettings = await enygmaFactorySettingsFactory.deploy(
    ethers.ZeroAddress, ethers.ZeroAddress, ethers.ZeroAddress, ethers.ZeroAddress, ethers.ZeroAddress,
    ethers.ZeroAddress, ethers.ZeroAddress, ethers.ZeroAddress
  );
  const settingsAddress = await enygmaFactorySettings.getAddress();
  console.log('EnygmaFactorySettings deployed to:', settingsAddress);

  console.log('Deploying EnygmaRegistry...');
  const enygmaRegistryFactory = await ethers.getContractFactory('EnygmaRegistry');
  const enygmaRegistry = await enygmaRegistryFactory.deploy(initialOwner);
  const registryAddress = await enygmaRegistry.getAddress();
  console.log('EnygmaRegistry deployed to:', registryAddress);

  console.log('Deploying EnygmaCreator...');
  const enygmaCreatorFactory = await ethers.getContractFactory('EnygmaCreator');
  const enygmaCreator = await enygmaCreatorFactory.deploy();
  const enygmaCreatorAddress = await enygmaCreator.getAddress();
  console.log('EnygmaCreator deployed to:', enygmaCreatorAddress);

  console.log('Deploying DvpIntegrationCreator...');
  const dvpIntegrationCreatorFactory = await ethers.getContractFactory('DvpIntegrationCreator');
  const dvpIntegrationCreator = await dvpIntegrationCreatorFactory.deploy();
  const integrationCreatorAddress = await dvpIntegrationCreator.getAddress();
  console.log('DvpIntegrationCreator deployed to:', integrationCreatorAddress);

  console.log('Deploying EnygmaTeleport...');
  const enygmaTeleportFactory = await ethers.getContractFactory('EnygmaTeleport');
  const enygmaTeleport = await enygmaTeleportFactory.deploy();
  const enygmaTeleportAddress = await enygmaTeleport.getAddress();
  console.log('EnygmaTeleport deployed to:', enygmaTeleportAddress);

  console.log('Deploying main EnygmaFactory...');
  const enygmaFactoryFactory = await ethers.getContractFactory('EnygmaFactory');
  const enygmaFactory = await enygmaFactoryFactory.deploy(registryAddress, integrationCreatorAddress, settingsAddress, enygmaTeleportAddress, enygmaCreatorAddress);
  const factoryAddress = await enygmaFactory.getAddress();
  console.log('EnygmaFactory deployed to:', factoryAddress);

  return {
    factoryAddress,
    settingsAddress,
    registryAddress,
    integrationCreatorAddress
  };
}

async function deployEndpointPNH(chainId: string, pnhChainId: string, managerAddr: string) {
  const maxBatchMessages = 200;

  const endpointFactory = await ethers.getContractFactory('EndpointV1');
  const implementation = await deployUUPSProxy(endpointFactory, 'initialize(uint256,uint256,uint256,address)', [chainId, pnhChainId, maxBatchMessages, managerAddr]);

  return ethers.getContractAt('EndpointV1', await implementation.getAddress());
}

async function deployRaylsMessageExecutor(managerAddr: string) {
  const raylsMessageExecutorV1Factory = await ethers.getContractFactory('RaylsMessageExecutorV1');
  const implementation = await deployUUPSProxy(raylsMessageExecutorV1Factory, 'initialize(address)', [managerAddr]);
  return ethers.getContractAt('RaylsMessageExecutorV1', await implementation.getAddress());
}

async function deployRaylsParticipantReplica(endpoint: string, managerAddr: string) {
  const ParticipantStorageReplicaV1 = await ethers.getContractFactory('ParticipantStorageReplicaV1');

  const implementation = await deployUUPSProxy(ParticipantStorageReplicaV1, 'initialize(address,address)', [endpoint, managerAddr]);

  return ethers.getContractAt('ParticipantStorageReplicaV1', await implementation.getAddress());
}

async function deployResourceRegistry(managerAddr: string) {
  const registryFactory = await ethers.getContractFactory('ResourceRegistryV1');
  const implementation = await deployUUPSProxy(registryFactory, 'initialize(address)', [managerAddr]);

  return ethers.getContractAt('ResourceRegistryV1', await implementation.getAddress());
}

async function deployParticipantStorageWithModules(endpointAddress: string, managerAddr: string) {
  console.log('Deploying ParticipantStorageV1 and modules...');

  // Deploy ParticipantStorageV1
  console.log('→ Deploying ParticipantStorageV1...');
  const participantStorageFactory = await ethers.getContractFactory("ParticipantStorageV1");

  const participantStorage = await deployUUPSProxy(participantStorageFactory, 'initialize(address,address)', [endpointAddress, managerAddr]);
  await participantStorage.waitForDeployment();
  const participantStorageAddress = await participantStorage.getAddress();
  console.log(`  ✓ ParticipantStorageV1 deployed at ${participantStorageAddress}`);

  // Deploy module proxies
  console.log('→ Deploying module proxies...');

  console.log('  → Deploying ParticipantCore proxy...');
  const participantCoreFactory = await ethers.getContractFactory('ParticipantCoreV1');
  const participantCoreProxy = await deployUUPSProxy(participantCoreFactory, 'initialize(address,address)', [endpointAddress, managerAddr]);
  await participantCoreProxy.waitForDeployment();
  const participantCoreAddress = await participantCoreProxy.getAddress();
  console.log(`  ✓ ParticipantCore proxy deployed at ${participantCoreAddress}`);

  console.log('  → Deploying AuditManager proxy...');
  const auditManagerFactory = await ethers.getContractFactory('AuditManagerV1');
  const auditManagerProxy = await deployUUPSProxy(auditManagerFactory, 'initialize(address,address,address)', [participantCoreAddress, participantStorageAddress, managerAddr]);
  await auditManagerProxy.waitForDeployment();
  const auditManagerAddress = await auditManagerProxy.getAddress();
  console.log(`  ✓ AuditManager proxy deployed at ${auditManagerAddress}`);

  console.log('  → Deploying EnygmaManager proxy...');
  const enygmaManagerFactory = await ethers.getContractFactory("EnygmaManagerV1");
  const enygmaManagerProxy = await deployUUPSProxy(enygmaManagerFactory, 'initialize(address,address,address)', [participantCoreAddress, participantStorageAddress, managerAddr]);
  await enygmaManagerProxy.waitForDeployment();
  const enygmaManagerAddress = await enygmaManagerProxy.getAddress();
  console.log(`  ✓ EnygmaManager proxy deployed at ${enygmaManagerAddress}`);

  const participantStorageContract = await ethers.getContractAt("ParticipantStorageV1", participantStorageAddress);

  // Configure ParticipantStorageV1 with all modules
  console.log('→ Configuring ParticipantStorageV1 with all modules...');
  const configTx = await participantStorageContract.configureModules(
    participantCoreAddress,
    auditManagerAddress,
    enygmaManagerAddress
  );
  await configTx.wait();
  console.log('  ✓ ParticipantStorageV1 configured with all modules');

  // Configure ParticipantCore with ParticipantStorageV1 address
  console.log('→ Configuring ParticipantCore with ParticipantStorageV1 address...');
  const participantCore = await ethers.getContractAt('ParticipantCoreV1', participantCoreAddress);
  const setAddressTx = await participantCore.setParticipantStorageAddress(participantStorageAddress);
  await setAddressTx.wait();
  console.log(`  ✓ ParticipantCore configured with ParticipantStorageV1 address: ${participantStorageAddress}`);



  return { participantStorage, participantCoreAddress, auditManagerAddress, enygmaManagerAddress };
}

async function deployTokenRegistryWithModules(participantStorageAddress: string, resourceRegistryAddress: string, endpointAddress: string, enygmaFactoryAddress: string, enygmaFactorySettingsAddress: string, dvpSettingsAddress: string, managerAddr: string) {
  console.log('Deploying TokenRegistryV1 and modules...');

  const tokenRegistryFactory = await ethers.getContractFactory('TokenRegistryV1');
  const tokenRegistry = await deployUUPSProxy(tokenRegistryFactory, 'initialize(address,address)', [endpointAddress, managerAddr]);
  const tokenRegistryAddress = await tokenRegistry.getAddress();

  console.log(`  ✓ TokenRegistryV1 deployed at ${tokenRegistryAddress}`);


  const enygmaTokenManagerFactory = await ethers.getContractFactory('EnygmaTokenManagerV1');
  const enygmaTokenManager = await deployUUPSProxy(enygmaTokenManagerFactory, 'initialize(address,address,address,address)', [endpointAddress, tokenRegistryAddress, enygmaFactoryAddress, managerAddr]);

  const enygmaTokenManagerAddress = await enygmaTokenManager.getAddress();

  console.log(`  ✓ EnygmaTokenManagerV1 deployed at ${enygmaTokenManagerAddress}`);


  console.log('  → Deploying TokenCoreV1...');
  //deploy modules
  const tokenCoreFactory = await ethers.getContractFactory('TokenCoreV1');
  const tokenCore = await deployUUPSProxy(tokenCoreFactory, 'initialize(address,address,address,address,address,address,address,address)', [tokenRegistryAddress, participantStorageAddress, resourceRegistryAddress, enygmaTokenManagerAddress, endpointAddress, enygmaFactorySettingsAddress, dvpSettingsAddress, managerAddr]);
  const tokenCoreAddress = await tokenCore.getAddress();

  console.log(`  ✓ TokenCoreV1 deployed at ${tokenCoreAddress}`);


  const enygmaTokenManagerContract = await ethers.getContractAt('EnygmaTokenManagerV1', enygmaTokenManagerAddress);
  const setTokenCoreAddressTx = await enygmaTokenManagerContract.setTokenCoreAddress(tokenCoreAddress);
  await setTokenCoreAddressTx.wait();

  console.log(`  ✓ EnygmaTokenManagerV1 configured with TokenCoreV1 address: ${tokenCoreAddress}`);

  console.log('  → Deploying TokenFreezeManagerV1...');
  const tokenFreezeManagerFactory = await ethers.getContractFactory('TokenFreezeManagerV1');
  const tokenFreezeManager = await deployUUPSProxy(tokenFreezeManagerFactory, 'initialize(address,address,address)', [endpointAddress, tokenRegistryAddress, managerAddr]);
  const tokenFreezeManagerAddress = await tokenFreezeManager.getAddress();
  console.log(`  ✓ TokenFreezeManagerV1 deployed at ${tokenFreezeManagerAddress}`);

  console.log('  → Deploying EnygmaTokenManagerV1...');


  //configure token registry
  const tokenRegistryContract = await ethers.getContractAt('TokenRegistryV1', tokenRegistryAddress);
  const configTx = await tokenRegistryContract.configureModules(
    tokenCore.getAddress(),
    tokenFreezeManager.getAddress(),
    enygmaTokenManager.getAddress()
  );
  await configTx.wait();
  console.log('  ✓ TokenRegistry configured with all modules');

  return { tokenRegistry, tokenCoreAddress, enygmaTokenManagerAddress, tokenFreezeManagerAddress };
}

/**
 * Deploys the ResourceManager module
 *
 * @param contractFactoryAddress The contract factory address
 * @param hre The Hardhat runtime environment
 * @returns The deployed ResourceManager contract address
 */
async function deployResourceManager(contractFactoryAddress: string, ownerAddress: string): Promise<string> {
  console.log('\n→ Deploying ResourceManager module...');
  try {
    const ResourceManager = await ethers.getContractFactory('ResourceManager');
    console.log('  → Creating deployment transaction...');
    const resourceManager = await ResourceManager.deploy(contractFactoryAddress, ownerAddress);

    console.log('  → Waiting for deployment transaction to be mined...');
    await resourceManager.waitForDeployment();

    const address = await resourceManager.getAddress();
    console.log(`  ✓ ResourceManager deployed to ${address}`);
    return address;
  } catch (error) {
    console.error('  ✗ Error deploying ResourceManager:', error);
    throw error;
  }
}

/**
 * Deploys the MessageSender module
 *
 * @param chainId The chain ID
 * @param privateHubChainId The private hub chain ID
 * @param participantValidatorAddress The participant validator address
 * @param tokenValidatorAddress The token validator address
 * @param hre The Hardhat runtime environment
 * @returns The deployed MessageSender contract address
 */
async function deployMessageSender(
  chainId: string,
  privateHubChainId: string,
  participantValidatorAddress: string,
  tokenValidatorAddress: string,
  ownerAddress: string,
  endpointAddress?: string
): Promise<string> {
  console.log('\n→ Deploying MessageSender module...');
  try {
    const MessageSender = await ethers.getContractFactory('MessageSender');
    console.log('  → Creating deployment transaction with parameters:');
    console.log(`    - Chain ID: ${chainId}`);
    console.log(`    - Private Hub ID: ${privateHubChainId}`);
    console.log(`    - Participant Validator: ${participantValidatorAddress}`);
    console.log(`    - Token Validator: ${tokenValidatorAddress}`);
    console.log(`    - Owner: ${ownerAddress}`);

    const messageSender = await MessageSender.deploy(
      chainId,
      privateHubChainId,
      participantValidatorAddress,
      tokenValidatorAddress,
      endpointAddress || ownerAddress,
      ownerAddress,
      ethers.ZeroAddress
    );

    console.log('  → Waiting for deployment transaction to be mined...');
    await messageSender.waitForDeployment();

    const address = await messageSender.getAddress();
    console.log(`  ✓ MessageSender deployed to ${address}`);
    return address;
  } catch (error) {
    console.error('  ✗ Error deploying MessageSender:', error);
    throw error;
  }
}

/**
 * Deploys the MessageReceiver module
 *
 * @param resourceManagerAddress The resource manager address
 * @param messageExecutorAddress The message executor address
 * @param hre The Hardhat runtime environment
 * @returns The deployed MessageReceiver contract address
 */
async function deployMessageReceiver(
  resourceManagerAddress: string,
  messageExecutorAddress: string
): Promise<string> {
  console.log('\n→ Deploying MessageReceiver module...');
  try {
    const [owner] = await ethers.getSigners();
    const ownerAddress = await owner.getAddress();

    const MessageReceiver = await ethers.getContractFactory('MessageReceiver');
    console.log('  → Creating deployment transaction with parameters:');
    console.log(`    - Resource Manager: ${resourceManagerAddress}`);
    console.log(`    - Message Executor: ${messageExecutorAddress}`);
    console.log(`    - Owner: ${ownerAddress}`);

    const messageReceiver = await MessageReceiver.deploy(
      resourceManagerAddress,
      messageExecutorAddress,
      ownerAddress,
      ownerAddress,
      ethers.ZeroAddress
    );

    console.log('  → Waiting for deployment transaction to be mined...');
    await messageReceiver.waitForDeployment();

    const address = await messageReceiver.getAddress();
    console.log(`  ✓ MessageReceiver deployed to ${address}`);
    return address;
  } catch (error) {
    console.error('  ✗ Error deploying MessageReceiver:', error);
    throw error;
  }
}

/**
 * Deploys the BatchMessageSender module
 *
 * @param privateHubChainId The private hub chain ID
 * @param participantValidatorAddress The participant validator address
 * @param tokenValidatorAddress The token validator address

 * @returns The deployed BatchMessageSender contract address
 */
async function deployBatchMessageSender(
  privateHubChainId: string,
  participantValidatorAddress: string,
  tokenValidatorAddress: string,
  endpointAddress: string,
  ownerAddress: string
): Promise<string> {
  console.log('\n→ Deploying BatchMessageSender module...');
  try {
    const BatchMessageSender = await ethers.getContractFactory('BatchMessageSender');
    console.log('  → Creating deployment transaction with parameters:');
    console.log(`    - Private Hub ID: ${privateHubChainId}`);
    console.log(`    - Participant Validator: ${participantValidatorAddress}`);
    console.log(`    - Token Validator: ${tokenValidatorAddress}`);
    console.log(`    - Endpoint: ${endpointAddress}`);
    console.log(`    - Owner: ${ownerAddress}`);

    const batchMessageSender = await BatchMessageSender.deploy(
      privateHubChainId,
      participantValidatorAddress,
      tokenValidatorAddress,
      endpointAddress,
      ownerAddress,
      ethers.ZeroAddress
    );

    console.log('  → Waiting for deployment transaction to be mined...');
    await batchMessageSender.waitForDeployment();

    const address = await batchMessageSender.getAddress();
    console.log(`  ✓ BatchMessageSender deployed to ${address}`);
    return address;
  } catch (error) {
    console.error('  ✗ Error deploying BatchMessageSender:', error);
    throw error;
  }
}

async function deployContractFactory(initialOwner: string, endpoint: string, managerAddr: string) {
  const raylsContractFactory = await ethers.getContractFactory('RaylsContractFactoryV1');
  const factory: any = await raylsContractFactory.deploy();
  await factory.waitForDeployment();
  await factory.initialize(endpoint, ethers.ZeroAddress, initialOwner, managerAddr);
  return factory;
}

async function deployTokenRegistryV1Replica(endpointAddress: string, managerAddr: string) {
  const factory = await ethers.getContractFactory('TokenRegistryReplicaV1');

  const implementation = await deployUUPSProxy(factory, 'initialize(address,address)', [endpointAddress, managerAddr]);

  return ethers.getContractAt('TokenRegistryReplicaV1', await implementation.getAddress());
}

async function deployEnygmaVerifierk2() {
  const enygmaValidatorFactory = await ethers.getContractFactory('EnygmaVerifierk2');

  const txDeploy = await enygmaValidatorFactory.deploy();
  txDeploy.waitForDeployment();

  var implementationAddress = await txDeploy.getAddress();

  console.log('Deploying Enygma Verifier Proxy k=2...');

  const enygmaValidatorProxyFactory = await ethers.getContractFactory('EnygmaVerifierk2Proxy');

  const txDeployProxy = await enygmaValidatorProxyFactory.deploy(implementationAddress);
  txDeployProxy.waitForDeployment();

  var proxyAddress = await txDeployProxy.getAddress();

  console.log('Enygma Verifier k=2 Proxy', proxyAddress);

  console.log('Setting up Enygma Verifier k=2 Proxy', proxyAddress);

  const enygmaValidatorProxy = await ethers.getContractAt('EnygmaVerifierk2Proxy', proxyAddress);

  await enygmaValidatorProxy.setVerifierAddress(implementationAddress);

  console.log('Enygma Verifier k=2 deploy & configuration OK');

  return proxyAddress;
}

async function deployEnygmaVerifierk3() {
  const enygmaValidatorFactory = await ethers.getContractFactory('EnygmaVerifierk3');

  const txDeploy = await enygmaValidatorFactory.deploy();
  txDeploy.waitForDeployment();

  var implementationAddress = await txDeploy.getAddress();

  console.log('Deploying Enygma Verifier Proxy k=3...');

  const enygmaValidatorProxyFactory = await ethers.getContractFactory('EnygmaVerifierk3Proxy');

  const txDeployProxy = await enygmaValidatorProxyFactory.deploy(implementationAddress);
  txDeployProxy.waitForDeployment();

  var proxyAddress = await txDeployProxy.getAddress();

  console.log('Enygma Verifier k=3 Proxy', proxyAddress);

  console.log('Setting up Enygma Verifier k=3 Proxy', proxyAddress);

  const enygmaValidatorProxy = await ethers.getContractAt('EnygmaVerifierk3Proxy', proxyAddress);

  await enygmaValidatorProxy.setVerifierAddress(implementationAddress);

  console.log('Enygma Verifier k=3 deploy & configuration OK');

  return proxyAddress;
}

async function deployEnygmaVerifierk4() {
  const enygmaValidatorFactory = await ethers.getContractFactory('EnygmaVerifierk4');

  const txDeploy = await enygmaValidatorFactory.deploy();
  txDeploy.waitForDeployment();

  var implementationAddress = await txDeploy.getAddress();

  console.log('Deploying Enygma Verifier Proxy k=4...');

  const enygmaValidatorProxyFactory = await ethers.getContractFactory('EnygmaVerifierk4Proxy');

  const txDeployProxy = await enygmaValidatorProxyFactory.deploy(implementationAddress);
  txDeployProxy.waitForDeployment();

  var proxyAddress = await txDeployProxy.getAddress();

  console.log('Enygma Verifier k=4 Proxy', proxyAddress);

  console.log('Setting up Enygma Verifier k=4 Proxy', proxyAddress);

  const enygmaValidatorProxy = await ethers.getContractAt('EnygmaVerifierk4Proxy', proxyAddress);

  await enygmaValidatorProxy.setVerifierAddress(implementationAddress);

  console.log('Enygma Verifier k=4 deploy & configuration OK');

  return proxyAddress;
}

async function deployEnygmaVerifierk5() {
  const enygmaValidatorFactory = await ethers.getContractFactory('EnygmaVerifierk5');

  const txDeploy = await enygmaValidatorFactory.deploy();
  txDeploy.waitForDeployment();

  var implementationAddress = await txDeploy.getAddress();

  console.log('Deploying Enygma Verifier Proxy k=5...');

  const enygmaValidatorProxyFactory = await ethers.getContractFactory('EnygmaVerifierk5Proxy');

  const txDeployProxy = await enygmaValidatorProxyFactory.deploy(implementationAddress);
  txDeployProxy.waitForDeployment();

  var proxyAddress = await txDeployProxy.getAddress();

  console.log('Enygma Verifier k=5 Proxy', proxyAddress);

  console.log('Setting up Enygma Verifier k=5 Proxy', proxyAddress);

  const enygmaValidatorProxy = await ethers.getContractAt('EnygmaVerifierk5Proxy', proxyAddress);

  await enygmaValidatorProxy.setVerifierAddress(implementationAddress);

  console.log('Enygma Verifier k=5 deploy & configuration OK');

  return proxyAddress;
}

async function deployEnygmaVerifierk6() {
  console.log('Deploying Enygma Verifier for k=6...');

  const enygmaValidatorFactory = await ethers.getContractFactory('EnygmaVerifierk6');

  const txDeploy = await enygmaValidatorFactory.deploy();
  txDeploy.waitForDeployment();

  var implementationAddress = await txDeploy.getAddress();

  console.log('Deploying Enygma Verifier Proxy k=6...');

  const enygmaValidatorProxyFactory = await ethers.getContractFactory('EnygmaVerifierk6Proxy');

  const txDeployProxy = await enygmaValidatorProxyFactory.deploy(implementationAddress);
  txDeployProxy.waitForDeployment();

  var proxyAddress = await txDeployProxy.getAddress();

  console.log('Enygma Verifier k=6 Proxy', proxyAddress);

  console.log('Setting up Enygma Verifier k=6 Proxy', proxyAddress);

  const enygmaValidatorProxy = await ethers.getContractAt('EnygmaVerifierk6Proxy', proxyAddress);

  await enygmaValidatorProxy.setVerifierAddress(implementationAddress);

  console.log('Enygma Verifier k=6 deploy & configuration OK');

  return proxyAddress;
}
async function deployEnygma(initialOwner: string, participantStorageAt: string, endpointAt: string, tokenRegistryAt: string) {
  const enygmaFactory = await ethers.getContractFactory('EnygmaV1');
  const resourceId = `0x${genRanHex(64)}`;
  const enygma = await enygmaFactory.deploy('enygma', 'eny', 18, initialOwner, participantStorageAt, endpointAt, tokenRegistryAt, resourceId, initialOwner);
  await enygma.waitForDeployment();
  return enygma;
}

async function deployEnygmaExample(initialOwner: string, endpointAt: string) {
  const enygmaFactory = await ethers.getContractFactory('EnygmaTokenExample');
  const enygma = await enygmaFactory.deploy('enygma', 'eny', endpointAt);
  await enygma.waitForDeployment();
  await enygma.submitTokenRegistration(0);
  return enygma;
}

async function deployProofs() {
  console.log('Deploying Proofs...');

  const proofsFactory = await ethers.getContractFactory('Proofs');
  const proofsTx = await proofsFactory.deploy();
  const proofsContract = await proofsTx.waitForDeployment();

  return proofsContract.getAddress();
}

async function deployDvpTeleport(ownerAddress: string) {
  console.log('Deploying DvpTeleport (following EnygmaTeleport pattern)...');
  const dvpTeleportFactory = await ethers.getContractFactory('DvpTeleport');
  const dvpTeleport = await dvpTeleportFactory.deploy(ownerAddress);
  const dvpTeleportAddress = await dvpTeleport.getAddress();
  console.log('DvpTeleport deployed to:', dvpTeleportAddress);

  return dvpTeleportAddress;
}

async function deployDvp(enygmaFactoryAddress: string) {
  console.log('Deploying Dvp contracts...');
  const g16VerifierFactory = await ethers.getContractFactory('GenericGroth16Verifier');
  const g16Verifier = await g16VerifierFactory.deploy();
  const g16VerifierAddress = await g16Verifier.getAddress();
  await g16Verifier.waitForDeployment();

  const [deployer] = await ethers.getSigners();
  const verifierFactory = await ethers.getContractFactory('DvpVerifierAggregator');
  const verifier = await verifierFactory.deploy(deployer.address);
  const verifierAddress = await verifier.getAddress();
  await verifier.waitForDeployment();

  console.log('Deploying Poseidon...');
  const poseidonT3Factory = await ethers.getContractFactory('poseidon-solidity/PoseidonT3.sol:PoseidonT3');
  const poseidonT3 = await poseidonT3Factory.deploy();
  const poseidonT3Address = await poseidonT3.getAddress();
  await poseidonT3.waitForDeployment();

  const poseidonWrapperFactory = await ethers.getContractFactory('PoseidonWrapper', {
    libraries: {
      PoseidonT3: poseidonT3Address
    }
  });
  const poseidonWrapper = await poseidonWrapperFactory.deploy();
  const poseidonWrapperAddress = await poseidonWrapper.getAddress();
  await poseidonWrapper.waitForDeployment();

  console.log('Deploying Dvp...');
  const dvpFactory = await ethers.getContractFactory('Dvp');
  const dvp = await dvpFactory.deploy(poseidonWrapperAddress, g16VerifierAddress, enygmaFactoryAddress);
  const dvpAddress = await dvp.getAddress();
  await dvp.waitForDeployment();

  // Deploy Merkle Trees
  console.log('Deploying Merkle Trees...');
  const merkleERC721Factory = await ethers.getContractFactory('Merkle');
  const merkleERC721 = await merkleERC721Factory.deploy(poseidonWrapperAddress);
  const merkleERC721Address = await merkleERC721.getAddress();
  await merkleERC721.waitForDeployment();

  const merkleERC20Factory = await ethers.getContractFactory('Merkle');
  const merkleERC20 = await merkleERC20Factory.deploy(poseidonWrapperAddress);
  const merkleERC20Address = await merkleERC20.getAddress();
  await merkleERC20.waitForDeployment();

  const merkleERC1155Factory = await ethers.getContractFactory('Merkle');
  const merkleERC1155 = await merkleERC1155Factory.deploy(poseidonWrapperAddress);
  const merkleERC1155Address = await merkleERC1155.getAddress();
  await merkleERC1155.waitForDeployment();

  const merkleEnygmaFactory = await ethers.getContractFactory('Merkle');
  const merkleEnygma = await merkleEnygmaFactory.deploy(poseidonWrapperAddress);
  const merkleEnygmaAddress = await merkleEnygma.getAddress();
  await merkleEnygma.waitForDeployment();

  const merkleTreeRegistryMap = {
    [0]: merkleERC721Address,
    [1]: merkleERC20Address,
    [2]: merkleERC1155Address,
    [3]: merkleEnygmaAddress
  };

  return {
    dvpAddress,
    dvpVerifierAddress: verifierAddress,
    merkleTreeRegistryMap
  };
}

async function initializeDvp(dvpAddress: string, verifierAddress: string, merkleTreeRegistryMap: { [id: number]: string }, dvpMerkleTreeDepth: string) {
  const dvp = await ethers.getContractAt('Dvp', dvpAddress);

  console.log('Initializing Dvp & registering Merkle Trees...');

  for (const [treeId, treeAddress] of Object.entries(merkleTreeRegistryMap)) {
    await dvp.registerMerkleTree(treeAddress, treeId, dvpMerkleTreeDepth);
  }

  await dvp.initializeDvp(verifierAddress);
}

// Deposit Verifiers k=2 to k=6
async function deployEnygmaDepositToDvpVerifierk2() {
  console.log('Deploying EnygmaDepositToDvpVerifierk2...');
  const depositVerifierFactory = await ethers.getContractFactory('EnygmaDepositToDvpVerifierk2');
  const txDeploy = await depositVerifierFactory.deploy();
  await txDeploy.waitForDeployment();
  var implementationAddress = await txDeploy.getAddress();
  console.log('Deploying DepositToDvp Verifier Proxy k=2...');
  const depositVerifierProxyFactory = await ethers.getContractFactory('EnygmaDepositToDvpVerifierk2Proxy');
  const txDeployProxy = await depositVerifierProxyFactory.deploy(implementationAddress);
  await txDeployProxy.waitForDeployment();
  var proxyAddress = await txDeployProxy.getAddress();
  console.log('DepositToDvp Verifier k=2 Proxy', proxyAddress);
  console.log('Setting up DepositToDvp Verifier k=2 Proxy', proxyAddress);
  const depositVerifierProxy = await ethers.getContractAt('EnygmaDepositToDvpVerifierk2Proxy', proxyAddress);
  await depositVerifierProxy.setVerifierAddress(implementationAddress);
  console.log('DepositToDvp Verifier k=2 deploy & configuration OK');
  return proxyAddress;
}

async function deployEnygmaDepositToDvpVerifierk3() {
  console.log('Deploying EnygmaDepositToDvpVerifierk3...');
  const depositVerifierFactory = await ethers.getContractFactory('EnygmaDepositToDvpVerifierk3');
  const txDeploy = await depositVerifierFactory.deploy();
  await txDeploy.waitForDeployment();
  var implementationAddress = await txDeploy.getAddress();
  console.log('Deploying DepositToDvp Verifier Proxy k=3...');
  const depositVerifierProxyFactory = await ethers.getContractFactory('EnygmaDepositToDvpVerifierk3Proxy');
  const txDeployProxy = await depositVerifierProxyFactory.deploy(implementationAddress);
  await txDeployProxy.waitForDeployment();
  var proxyAddress = await txDeployProxy.getAddress();
  console.log('DepositToDvp Verifier k=3 Proxy', proxyAddress);
  console.log('Setting up DepositToDvp Verifier k=3 Proxy', proxyAddress);
  const depositVerifierProxy = await ethers.getContractAt('EnygmaDepositToDvpVerifierk3Proxy', proxyAddress);
  await depositVerifierProxy.setVerifierAddress(implementationAddress);
  console.log('DepositToDvp Verifier k=3 deploy & configuration OK');
  return proxyAddress;
}

async function deployEnygmaDepositToDvpVerifierk4() {
  console.log('Deploying EnygmaDepositToDvpVerifierk4...');
  const depositVerifierFactory = await ethers.getContractFactory('EnygmaDepositToDvpVerifierk4');
  const txDeploy = await depositVerifierFactory.deploy();
  await txDeploy.waitForDeployment();
  var implementationAddress = await txDeploy.getAddress();
  console.log('Deploying DepositToDvp Verifier Proxy k=4...');
  const depositVerifierProxyFactory = await ethers.getContractFactory('EnygmaDepositToDvpVerifierk4Proxy');
  const txDeployProxy = await depositVerifierProxyFactory.deploy(implementationAddress);
  await txDeployProxy.waitForDeployment();
  var proxyAddress = await txDeployProxy.getAddress();
  console.log('DepositToDvp Verifier k=4 Proxy', proxyAddress);
  console.log('Setting up DepositToDvp Verifier k=4 Proxy', proxyAddress);
  const depositVerifierProxy = await ethers.getContractAt('EnygmaDepositToDvpVerifierk4Proxy', proxyAddress);
  await depositVerifierProxy.setVerifierAddress(implementationAddress);
  console.log('DepositToDvp Verifier k=4 deploy & configuration OK');
  return proxyAddress;
}

async function deployEnygmaDepositToDvpVerifierk5() {
  console.log('Deploying EnygmaDepositToDvpVerifierk5...');
  const depositVerifierFactory = await ethers.getContractFactory('EnygmaDepositToDvpVerifierk5');
  const txDeploy = await depositVerifierFactory.deploy();
  await txDeploy.waitForDeployment();
  var implementationAddress = await txDeploy.getAddress();
  console.log('Deploying DepositToDvp Verifier Proxy k=5...');
  const depositVerifierProxyFactory = await ethers.getContractFactory('EnygmaDepositToDvpVerifierk5Proxy');
  const txDeployProxy = await depositVerifierProxyFactory.deploy(implementationAddress);
  await txDeployProxy.waitForDeployment();
  var proxyAddress = await txDeployProxy.getAddress();
  console.log('DepositToDvp Verifier k=5 Proxy', proxyAddress);
  console.log('Setting up DepositToDvp Verifier k=5 Proxy', proxyAddress);
  const depositVerifierProxy = await ethers.getContractAt('EnygmaDepositToDvpVerifierk5Proxy', proxyAddress);
  await depositVerifierProxy.setVerifierAddress(implementationAddress);
  console.log('DepositToDvp Verifier k=5 deploy & configuration OK');
  return proxyAddress;
}

async function deployEnygmaDepositToDvpVerifierk6() {
  console.log('Deploying EnygmaDepositToDvpVerifierk6...');
  const depositVerifierFactory = await ethers.getContractFactory('EnygmaDepositToDvpVerifierk6');
  const txDeploy = await depositVerifierFactory.deploy();
  await txDeploy.waitForDeployment();
  var implementationAddress = await txDeploy.getAddress();
  console.log('Deploying DepositToDvp Verifier Proxy k=6...');
  const depositVerifierProxyFactory = await ethers.getContractFactory('EnygmaDepositToDvpVerifierk6Proxy');
  const txDeployProxy = await depositVerifierProxyFactory.deploy(implementationAddress);
  await txDeployProxy.waitForDeployment();
  var proxyAddress = await txDeployProxy.getAddress();
  console.log('DepositToDvp Verifier k=6 Proxy', proxyAddress);
  console.log('Setting up DepositToDvp Verifier k=6 Proxy', proxyAddress);
  const depositVerifierProxy = await ethers.getContractAt('EnygmaDepositToDvpVerifierk6Proxy', proxyAddress);
  await depositVerifierProxy.setVerifierAddress(implementationAddress);
  console.log('DepositToDvp Verifier k=6 deploy & configuration OK');
  return proxyAddress;
}

// Withdraw Verifiers k=2 to k=6
async function deployEnygmaWithdrawFromDvpVerifierk2() {
  console.log('Deploying EnygmaWithdrawFromDvpVerifierk2...');
  const withdrawVerifierFactory = await ethers.getContractFactory('EnygmaWithdrawFromDvpVerifierk2');
  const txDeploy = await withdrawVerifierFactory.deploy();
  await txDeploy.waitForDeployment();
  var implementationAddress = await txDeploy.getAddress();
  console.log('Deploying WithdrawFromDvp Verifier Proxy k=2...');
  const withdrawVerifierProxyFactory = await ethers.getContractFactory('EnygmaWithdrawFromDvpVerifierk2Proxy');
  const txDeployProxy = await withdrawVerifierProxyFactory.deploy(implementationAddress);
  await txDeployProxy.waitForDeployment();
  var proxyAddress = await txDeployProxy.getAddress();
  console.log('WithdrawFromDvp Verifier k=2 Proxy', proxyAddress);
  console.log('Setting up WithdrawFromDvp Verifier k=2 Proxy', proxyAddress);
  const withdrawVerifierProxy = await ethers.getContractAt('EnygmaWithdrawFromDvpVerifierk2Proxy', proxyAddress);
  await withdrawVerifierProxy.setVerifierAddress(implementationAddress);
  console.log('WithdrawFromDvp Verifier k=2 deploy & configuration OK');
  return proxyAddress;
}

async function deployEnygmaWithdrawFromDvpVerifierk3() {
  console.log('Deploying EnygmaWithdrawFromDvpVerifierk3...');
  const withdrawVerifierFactory = await ethers.getContractFactory('EnygmaWithdrawFromDvpVerifierk3');
  const txDeploy = await withdrawVerifierFactory.deploy();
  await txDeploy.waitForDeployment();
  var implementationAddress = await txDeploy.getAddress();
  console.log('Deploying WithdrawFromDvp Verifier Proxy k=3...');
  const withdrawVerifierProxyFactory = await ethers.getContractFactory('EnygmaWithdrawFromDvpVerifierk3Proxy');
  const txDeployProxy = await withdrawVerifierProxyFactory.deploy(implementationAddress);
  await txDeployProxy.waitForDeployment();
  var proxyAddress = await txDeployProxy.getAddress();
  console.log('WithdrawFromDvp Verifier k=3 Proxy', proxyAddress);
  console.log('Setting up WithdrawFromDvp Verifier k=3 Proxy', proxyAddress);
  const withdrawVerifierProxy = await ethers.getContractAt('EnygmaWithdrawFromDvpVerifierk3Proxy', proxyAddress);
  await withdrawVerifierProxy.setVerifierAddress(implementationAddress);
  console.log('WithdrawFromDvp Verifier k=3 deploy & configuration OK');
  return proxyAddress;
}

async function deployEnygmaWithdrawFromDvpVerifierk4() {
  console.log('Deploying EnygmaWithdrawFromDvpVerifierk4...');
  const withdrawVerifierFactory = await ethers.getContractFactory('EnygmaWithdrawFromDvpVerifierk4');
  const txDeploy = await withdrawVerifierFactory.deploy();
  await txDeploy.waitForDeployment();
  var implementationAddress = await txDeploy.getAddress();
  console.log('Deploying WithdrawFromDvp Verifier Proxy k=4...');
  const withdrawVerifierProxyFactory = await ethers.getContractFactory('EnygmaWithdrawFromDvpVerifierk4Proxy');
  const txDeployProxy = await withdrawVerifierProxyFactory.deploy(implementationAddress);
  await txDeployProxy.waitForDeployment();
  var proxyAddress = await txDeployProxy.getAddress();
  console.log('WithdrawFromDvp Verifier k=4 Proxy', proxyAddress);
  console.log('Setting up WithdrawFromDvp Verifier k=4 Proxy', proxyAddress);
  const withdrawVerifierProxy = await ethers.getContractAt('EnygmaWithdrawFromDvpVerifierk4Proxy', proxyAddress);
  await withdrawVerifierProxy.setVerifierAddress(implementationAddress);
  console.log('WithdrawFromDvp Verifier k=4 deploy & configuration OK');
  return proxyAddress;
}

async function deployEnygmaWithdrawFromDvpVerifierk5() {
  console.log('Deploying EnygmaWithdrawFromDvpVerifierk5...');
  const withdrawVerifierFactory = await ethers.getContractFactory('EnygmaWithdrawFromDvpVerifierk5');
  const txDeploy = await withdrawVerifierFactory.deploy();
  await txDeploy.waitForDeployment();
  var implementationAddress = await txDeploy.getAddress();
  console.log('Deploying WithdrawFromDvp Verifier Proxy k=5...');
  const withdrawVerifierProxyFactory = await ethers.getContractFactory('EnygmaWithdrawFromDvpVerifierk5Proxy');
  const txDeployProxy = await withdrawVerifierProxyFactory.deploy(implementationAddress);
  await txDeployProxy.waitForDeployment();
  var proxyAddress = await txDeployProxy.getAddress();
  console.log('WithdrawFromDvp Verifier k=5 Proxy', proxyAddress);
  console.log('Setting up WithdrawFromDvp Verifier k=5 Proxy', proxyAddress);
  const withdrawVerifierProxy = await ethers.getContractAt('EnygmaWithdrawFromDvpVerifierk5Proxy', proxyAddress);
  await withdrawVerifierProxy.setVerifierAddress(implementationAddress);
  console.log('WithdrawFromDvp Verifier k=5 deploy & configuration OK');
  return proxyAddress;
}

async function deployEnygmaWithdrawFromDvpVerifierk6() {
  console.log('Deploying EnygmaWithdrawFromDvpVerifierk6...');
  const withdrawVerifierFactory = await ethers.getContractFactory('EnygmaWithdrawFromDvpVerifierk6');
  const txDeploy = await withdrawVerifierFactory.deploy();
  await txDeploy.waitForDeployment();
  var implementationAddress = await txDeploy.getAddress();
  console.log('Deploying WithdrawFromDvp Verifier Proxy k=6...');
  const withdrawVerifierProxyFactory = await ethers.getContractFactory('EnygmaWithdrawFromDvpVerifierk6Proxy');
  const txDeployProxy = await withdrawVerifierProxyFactory.deploy(implementationAddress);
  await txDeployProxy.waitForDeployment();
  var proxyAddress = await txDeployProxy.getAddress();
  console.log('WithdrawFromDvp Verifier k=6 Proxy', proxyAddress);
  console.log('Setting up WithdrawFromDvp Verifier k=6 Proxy', proxyAddress);
  const withdrawVerifierProxy = await ethers.getContractAt('EnygmaWithdrawFromDvpVerifierk6Proxy', proxyAddress);
  await withdrawVerifierProxy.setVerifierAddress(implementationAddress);
  console.log('WithdrawFromDvp Verifier k=6 deploy & configuration OK');
  return proxyAddress;
}


async function deployEnygmaFactory() {
  const [signer] = await ethers.getSigners();
  const signerAddress = await signer.getAddress();
  console.log('Deploying Enygma Factory System...');

  console.log('Deploying EnygmaFactorySettings...');
  const enygmaFactorySettingsFactory = await ethers.getContractFactory('EnygmaFactorySettings');
  // Deploy with zero addresses; actual verifier/dvp addresses configured later in step 7
  const enygmaFactorySettings = await enygmaFactorySettingsFactory.deploy(
    ethers.ZeroAddress, ethers.ZeroAddress, ethers.ZeroAddress, ethers.ZeroAddress, ethers.ZeroAddress,
    ethers.ZeroAddress, ethers.ZeroAddress, ethers.ZeroAddress
  );
  const settingsAddress = await enygmaFactorySettings.getAddress();
  console.log('EnygmaFactorySettings deployed to:', settingsAddress);

  console.log('Deploying EnygmaRegistry...');
  const enygmaRegistryFactory = await ethers.getContractFactory('EnygmaRegistry');
  const enygmaRegistry = await enygmaRegistryFactory.deploy(signerAddress);
  const registryAddress = await enygmaRegistry.getAddress();
  console.log('EnygmaRegistry deployed to:', registryAddress);

  console.log('Deploying DvpIntegrationCreator...');
  const dvpIntegrationCreatorFactory = await ethers.getContractFactory('DvpIntegrationCreator');
  const dvpIntegrationCreator = await dvpIntegrationCreatorFactory.deploy();
  const integrationCreatorAddress = await dvpIntegrationCreator.getAddress();
  console.log('DvpIntegrationCreator deployed to:', integrationCreatorAddress);

  console.log('Deploying main EnygmaFactory...');
  const enygmaFactoryFactory = await ethers.getContractFactory('EnygmaFactory');
  const enygmaFactory = await enygmaFactoryFactory.deploy(registryAddress, integrationCreatorAddress, settingsAddress);
  const factoryAddress = await enygmaFactory.getAddress();
  console.log('EnygmaFactory deployed to:', factoryAddress);

  return {
    factoryAddress,
    settingsAddress,
    registryAddress,
    integrationCreatorAddress
  };
}

// Manual UUPS proxy deployment (no @openzeppelin/hardhat-upgrades needed)
async function deployUUPSProxy(contractFactory: any, initializerSig: string, initArgs: any[]): Promise<any> {
  const impl = await contractFactory.deploy();
  await impl.waitForDeployment();
  const proxyFactory = await ethers.getContractFactory('ERC1967Proxy');
  const initData = contractFactory.interface.encodeFunctionData(initializerSig, initArgs);
  const proxy = await proxyFactory.deploy(await impl.getAddress(), initData);
  await proxy.waitForDeployment();
  return proxy;
}
