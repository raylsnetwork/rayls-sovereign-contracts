import '@nomicfoundation/hardhat-ethers';
import { task } from 'hardhat/config';
import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { NonceManager, executeConfigWithNonce, executeBatchConfig, deployWithNonce, deployBatch } from './batch-helpers';
import {
  deployCoreBatch,
  deployEnygmaSystemBatch,
  deployParticipantSystemBatch,
  deployTokenSystemBatch,
  deployAllVerifiersBatched,
  deployDvpSystemBatch,
  deployMessageModulesBatch,
  PNH_TOKEN_REGISTRY_ARTIFACT_NAME
} from './private-hub-batches';
import { exec as execCallback } from 'child_process';
import { promisify } from 'util';
import * as fs from 'fs';
import { ManifestManager } from './manifest-manager';


async function raylsViewKeyGen() {
  const exec = promisify(execCallback);
  try {
    const { stdout, stderr } = await exec('./hardhat/tasks/utils/mlkemgen/mlkemgen');
    if (stderr) {
      console.error(`Error on RaylsViewKeyGen: ${stderr}`);
    }
    const rawData = fs.readFileSync('./keypair.json', { encoding: 'utf-8' });
    const jsonData = JSON.parse(rawData);
    return {
      raylsViewPublicKey: jsonData.raylsViewPublicKey,
      raylsViewSecretKey: jsonData.raylsViewSecretKey,
    };
  } catch (error: any) {
    console.error(`Error on RaylsViewKeyGen: ${error.message}`);
    throw error;
  }
}

task('deploy:private-hub', 'Deploys PNH contracts')
  .setAction(async (taskArgs, hre) => {
    console.log('✅ Task started - deploy:private-hub');

    const overallStartTime = Date.now();
    console.log('🚀🚀🚀 FAST BATCH DEPLOYMENT STARTED 🚀🚀🚀');
    console.log('='.repeat(80));

    // Check for existing deployments - BLOCK if found
    const manifest = new ManifestManager();
    const hasExisting = await manifest.hasExistingDeployments(hre);
    if (hasExisting) {
      const proxies = await manifest.listProxies(hre);
      const impls = await manifest.listImplementations(hre);
      const manifestPath = await manifest.getManifestFilePath(hre);
      console.log('\n❌ ERROR: Existing deployments detected in manifest');
      console.log(`   Found: ${proxies.length} proxies, ${impls.length} implementations`);
      console.log(`   Manifest: ${manifestPath}`);
      console.log(`\n   To redeploy, first delete the manifest:`);
      console.log(`   rm ${manifestPath}\n`);
      throw new Error('Cannot deploy: manifest already exists. Delete it first to redeploy.');
    }

    // Initialize
    const pnhStartingBlock = await hre.ethers.provider.getBlockNumber();
    const signer = await hre.ethers.provider.getSigner();
    const initialOwner = signer.address;
    const pnhChainId = process.env.PNH_CHAIN_ID!;
    const endpointMaxBatchMessages = process.env.ENDPOINT_MAX_BATCH_MESSAGES || '500';
    let raylsViewPublicKey = process.env.RAYLS_VIEW_PUBLIC_KEY!;
    let raylsViewSecretKey = process.env.RAYLS_VIEW_SECRET_KEY!;
    let privateKeySystem = process.env.PRIVATE_KEY_SYSTEM!;
    const operatorChainId = '999';

    if (!privateKeySystem) {
      privateKeySystem = hre.ethers.Wallet.createRandom().privateKey;
      console.log(`🔑 Generated random private key: ${privateKeySystem}`);
    }

    if (!raylsViewPublicKey) {
      const raylsViewKeyPair = await raylsViewKeyGen();
      raylsViewPublicKey = raylsViewKeyPair.raylsViewPublicKey;
      raylsViewSecretKey = raylsViewKeyPair.raylsViewSecretKey;
      console.log(`🔑 Generated Rayls View KeyPair`);
    }

    console.log(`📋 Chain ID: ${pnhChainId}`);
    console.log(`👤 Owner: ${initialOwner}`);

    const nonceManager = new NonceManager(hre.ethers.provider, initialOwner);
    await nonceManager.initialize();

    // -------------------------------------------------------------------------
    // DEPLOY ACCESS MANAGER FIRST (consumer contracts need it before restricted calls)
    // -------------------------------------------------------------------------
    // Deploy AccessManager libraries (stateless, no proxy needed).
    // AuthLib must deploy first — ScheduleLib links against it.
    console.log('\n📦 Deploying AccessManager libraries...');
    const amLibBatch1 = await deployBatch([
      { name: 'AccessManagerAuthLib', contractName: 'AccessManagerAuthLib', isProxy: false, constructorArgs: [] },
      { name: 'AccessManagerEnumerationLib', contractName: 'AccessManagerEnumerationLib', isProxy: false, constructorArgs: [] },
      { name: 'AccessManagerContractScopedLib', contractName: 'AccessManagerContractScopedLib', isProxy: false, constructorArgs: [] },
      { name: 'AccessManagerRoleConfigLib', contractName: 'AccessManagerRoleConfigLib', isProxy: false, constructorArgs: [] },
    ], nonceManager, hre);
    const amLibBatch2 = await deployBatch([
      { name: 'AccessManagerScheduleLib', contractName: 'AccessManagerScheduleLib', isProxy: false, constructorArgs: [], libraries: { AccessManagerAuthLib: amLibBatch1[0].address } },
    ], nonceManager, hre);
    const amLibraries = {
      AccessManagerAuthLib: amLibBatch1[0].address,
      AccessManagerEnumerationLib: amLibBatch1[1].address,
      AccessManagerContractScopedLib: amLibBatch1[2].address,
      AccessManagerRoleConfigLib: amLibBatch1[3].address,
      AccessManagerScheduleLib: amLibBatch2[0].address,
    };
    console.log('  ✓ AccessManager libraries deployed');

    console.log('\n📦 Deploying RaylsAccessManagerV1 (access authority)...');
    const accessManagerBatch = await deployBatch([
      { name: 'RaylsAccessManager', contractName: 'RaylsAccessManagerV1', isProxy: true, initArgs: [initialOwner], initializer: 'initialize(address)', libraries: amLibraries, validationOpts: { unsafeAllow: ['external-library-linking'] } }
    ], nonceManager, hre);
    const managerAddr = accessManagerBatch[0].address;
    console.log(`  ✓ RaylsAccessManagerV1 deployed at ${managerAddr}`);

    // ─────────────────────────────────────────────────────────────────────────
    // REGISTER ALL ROLES immediately after AccessManager deployment.
    // Contracts call selfRegisterManagedContract in their constructors, which
    // looks up roles by name — they must exist before any contract is deployed.
    // ─────────────────────────────────────────────────────────────────────────
    console.log('\n🔐 Registering all AUTH-V3 roles...');
    const allRoleNames = [
      'ENYGMA_CREATOR',       // → 3
      'DVP_FACTORY_CALLER',   // → 4
      'REGISTRY_CALLER',      // → 5
      'ENDPOINT_SENDER',      // → 6
      'FACTORY_ADMIN',        // → 7
      'ENYGMA_V1',            // → 8
      'COIN_VAULT',           // → 9
      'DVP_CONTRACT',         // → 10
      'RELAYER',         // → 11
      'MESSAGE_EXECUTOR',// → 12
      'MESSAGE_RECEIVER',// → 13
      'RESOURCE_REGISTRAR',   // → 14
    ];
    await executeBatchConfig(
      allRoleNames.map((name, i) => ({ name: `RegisterRole_${name}`, contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'registerRole(string)', args: [name] })),
      nonceManager, hre
    );

    // Look up role IDs by name (safe regardless of _nextRoleId starting point).
    const managerContract = await hre.ethers.getContractAt('RaylsAccessManagerV1', managerAddr);
    const [enygmaCreatorRoleId, dvpFactoryCallerRoleId, registryCallerRoleId,
           endpointSenderRoleId, factoryAdminRoleId, enygmaV1RoleId,
           coinVaultRoleId, dvpContractRoleId, relayerRoleId,
           messageExecutorRoleId, messageReceiverRoleId,
           resourceRegistrarRoleId] = await Promise.all(
      allRoleNames.map(name => managerContract.getRoleIdByName(name))
    );
    console.log(`  ✓ ${allRoleNames.length} roles registered (IDs ${enygmaCreatorRoleId}-${resourceRegistrarRoleId})`);

    // ─────────────────────────────────────────────────────────────────────────
    // PHASE 1: Deploy Endpoint+ResourceManager, DeploymentProxyRegistry, and
    //          Core contracts (MessageExecutor, Teleport, etc.) IN PARALLEL.
    //          BATCH 2+3 only need managerAddr, not endpointAddress.
    // ─────────────────────────────────────────────────────────────────────────
    console.log('\n⚡ PHASE 1: Core + DeploymentProxy + Endpoint (parallel)');
    const [coreAddresses, /* verifiers started below */] = await Promise.all([
      deployCoreBatch(nonceManager, hre, initialOwner, pnhChainId, endpointMaxBatchMessages, managerAddr),
    ]);
    const addresses: any = { ...coreAddresses, accessManagerAddress: managerAddr };

    // ─────────────────────────────────────────────────────────────────────────
    // PHASE 2: Enygma + Participant systems IN PARALLEL (both only need endpointAddress).
    //          Also deploy DvpSettings + Verifiers in parallel (only need managerAddr).
    // ─────────────────────────────────────────────────────────────────────────
    console.log('\n⚡ PHASE 2: Enygma + Participant + DvpSettings + Verifiers + TemplateRegistry (parallel)');
    const [enygmaAddresses, participantAddresses, dvpSettingsResult, verifierAddresses, templateRegistryResult] = await Promise.all([
      deployEnygmaSystemBatch(nonceManager, hre, addresses.endpointAddress, initialOwner, managerAddr),
      deployParticipantSystemBatch(nonceManager, hre, initialOwner, addresses.endpointAddress, managerAddr),
      deployWithNonce({ name: 'DvpSettings', contractName: 'DvpSettings', isProxy: false, constructorArgs: [managerAddr] }, nonceManager.allocateNonce(), hre),
      deployAllVerifiersBatched(nonceManager, hre, managerAddr),
      deployBatch([
        { name: 'TemplateRegistry', contractName: 'TemplateRegistryV1', isProxy: true, initArgs: [addresses.endpointAddress, managerAddr], initializer: 'initialize(address,address)', validationOpts: {} },
      ], nonceManager, hre),
    ]);
    Object.assign(addresses, enygmaAddresses, participantAddresses, verifierAddresses);
    const dvpSettingsAddress = dvpSettingsResult.address;
    Object.assign(addresses, { dvpSettingsAddress, templateRegistryAddress: templateRegistryResult[0].address });

    // ─────────────────────────────────────────────────────────────────────────
    // PHASE 3: DvpFactories (need enygmaFactorySettingsAddress + dvpSettingsAddress)
    //          + Token system + Dvp system + Message modules — maximize overlap.
    // ─────────────────────────────────────────────────────────────────────────
    console.log('\n⚡ PHASE 3: DvpFactories + Token + Dvp + Message (pipelined)');

    // DvpFactories (need EnygmaFactorySettings from Phase 2)
    const [dvpErc721Factory, dvpErc1155Factory] = await Promise.all([
      deployWithNonce({ name: 'DvpErc721Factory', contractName: 'DvpErc721Factory', isProxy: false, constructorArgs: [enygmaAddresses.enygmaFactorySettingsAddress, dvpSettingsAddress, managerAddr] }, nonceManager.allocateNonce(), hre),
      deployWithNonce({ name: 'DvpErc1155Factory', contractName: 'DvpErc1155Factory', isProxy: false, constructorArgs: [enygmaAddresses.enygmaFactorySettingsAddress, dvpSettingsAddress, managerAddr] }, nonceManager.allocateNonce(), hre),
    ]);
    Object.assign(addresses, { dvpErc721FactoryAddress: dvpErc721Factory.address, dvpErc1155FactoryAddress: dvpErc1155Factory.address });

    // Token system (needs many addresses from Phase 1+2)
    const tokenAddresses = await deployTokenSystemBatch(nonceManager, hre, initialOwner, addresses.endpointAddress, addresses.resourceRegistryAddress, participantAddresses.participantStorageAddress, enygmaAddresses.enygmaFactoryAddress, enygmaAddresses.enygmaFactorySettingsAddress, dvpSettingsAddress, dvpErc721Factory.address, dvpErc1155Factory.address, managerAddr);
    Object.assign(addresses, tokenAddresses);

    // Dvp + Message in parallel (Dvp needs verifiers from Phase 2, Message needs Token from above)
    console.log('\n⚡ Dvp + Message (parallel)');
    const [dvpAddresses, messageAddresses] = await Promise.all([
      deployDvpSystemBatch(nonceManager, hre, enygmaAddresses.enygmaFactoryAddress, verifierAddresses, dvpErc721Factory.address, dvpErc1155Factory.address, addresses.endpointAddress, initialOwner, managerAddr),
      deployMessageModulesBatch(nonceManager, hre, pnhChainId, participantAddresses.participantStorageAddress, tokenAddresses.tokenRegistryAddress, addresses.resourceManager, addresses.messageExecutorAddress, addresses.endpointAddress, initialOwner, managerAddr),
    ]);
    Object.assign(addresses, dvpAddresses, messageAddresses);

    // ─────────────────────────────────────────────────────────────────────────
    // CRITICAL: configureEndpoint MUST run before PN relayers start sending
    // receivePayload to PNH. Without messageReceiver set, receivePayload reverts
    // with "MessageReceiver module not configured" and permanently breaks the
    // inbound nonce for that PN chain.
    // ─────────────────────────────────────────────────────────────────────────
    console.log('\n🔐 Configuring PNH Endpoint modules (must complete before PN relayers connect)...');
    await executeConfigWithNonce({
      name: 'ConfigureEndpoint_Early',
      contractName: 'EndpointV1',
      address: addresses.endpointAddress,
      method: 'configureEndpoint',
      args: [
        '0x0000000000000000000000000000000000099999', // contractFactory placeholder (PNH uses ResourceRegistry)
        addresses.participantStorageAddress,
        addresses.tokenRegistryAddress,
        addresses.resourceManager,
        addresses.messageSender,
        addresses.messageReceiver,
        addresses.batchMessageSender,
      ]
    }, nonceManager.allocateNonce(), hre);

    // ─────────────────────────────────────────────────────────────────────────
    // PHASE 4: Role mapping + grants (roles already registered after AccessManager deploy).
    // ─────────────────────────────────────────────────────────────────────────
    console.log('\n🔐 Setting up AUTH-V3 role mappings and grants...');
    await nonceManager.sync();

    // ── Collect all selectors (local computation, no RPC) ──────────────
    const [messageExecutorFactory, tokenRegistryFactory, participantStorageFactory,
           enygmaPNHEventsFactory, resourceManagerFactory, endpointV1Factory,
           enygmaFactoryFactory, dvp721IfaceFactory, dvp1155IfaceFactory, registryIfaceFactory,
           etIfaceFactory, dtIfaceFactory, tpIfaceFactory, proofsIfaceFactory] = await Promise.all([
      hre.ethers.getContractFactory('RaylsMessageExecutorV1'),
      // TokenRegistryV1 is duplicated across PN and PNH; use the PNH FQN here.
      hre.ethers.getContractFactory(PNH_TOKEN_REGISTRY_ARTIFACT_NAME),
      hre.ethers.getContractFactory('ParticipantStorageV1'),
      hre.ethers.getContractFactory('EnygmaPNHEvents'),
      hre.ethers.getContractFactory('ResourceManager'),
      hre.ethers.getContractFactory('EndpointV1'),
      hre.ethers.getContractFactory('EnygmaFactory'),
      hre.ethers.getContractFactory('DvpErc721Factory'),
      hre.ethers.getContractFactory('DvpErc1155Factory'),
      hre.ethers.getContractFactory('EnygmaRegistry'),
      hre.ethers.getContractFactory('EnygmaTeleport'),
      hre.ethers.getContractFactory('DvpTeleport'),
      // TeleportV1 retained (block-header relay); its atomic functions are decommissioned.
      hre.ethers.getContractFactory('TeleportV1'),
      hre.ethers.getContractFactory('Proofs'),
    ]);

    const epIface = endpointV1Factory.interface;
    const etIface = etIfaceFactory.interface;
    const dtIface = dtIfaceFactory.interface;
    const tpIface = tpIfaceFactory.interface;
    const psIface = participantStorageFactory.interface;

    const endpointSendSelectors = [
      epIface.getFunction('send(uint256,address,bytes)')!.selector,
      epIface.getFunction('send(uint256,address,bytes,(uint8,uint256,address,address,address,uint256))')!.selector,
      epIface.getFunction('sendBatch')!.selector,
      epIface.getFunction('sendToResourceId(uint256,bytes32,bytes)')!.selector,
      epIface.getFunction('sendBatchToResourceId((uint256,bytes32,bytes)[])')!.selector,
      epIface.getFunction('sendToResourceId(uint256,bytes32,bytes,bytes,bytes,bytes,(uint8,uint256,address,address,address,uint256))')!.selector,
      epIface.getFunction('sendBatchToResourceId((uint256,bytes32,bytes,bytes,bytes,bytes,(uint8,uint256,address,address,address,uint256))[])')!.selector,
    ];
    const endpointRegisterSelector = epIface.getFunction('registerResourceId')!.selector;

    // ENDPOINT_SENDER grants — only contracts that actually call endpoint.send*()
    // (verified via static analysis of Solidity source — module pattern uses regular call,
    // so msg.sender at the Endpoint is the module contract, not the parent facade)
    const contractsToGrant = [
      addresses.tokenCoreAddress,
      addresses.tokenFreezeManagerAddress,
      addresses.participantCoreAddress,
      // Phase 2: TemplateRegistry broadcasts onTemplateApproved/onTemplateRevoked
      // to every PN replica via endpoint.sendToResourceId(CHAIN_ID_ALL_PARTICIPANTS, ...).
      addresses.templateRegistryAddress,
    ];

    // ── ALL mappings + grants in ONE batch (no sequential getRoleIdByName needed) ──
    const batchTasks = [
      // ── ENYGMA_CREATOR (was separate section) ──
      { name: 'MapEnygmaCreator', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [enygmaAddresses.enygmaFactoryAddress, [enygmaFactoryFactory.interface.getFunction('initiateEnygmaCreation')!.selector], [enygmaCreatorRoleId]] },
      { name: 'GrantEnygmaCreator', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantRole', args: [enygmaCreatorRoleId, addresses.enygmaTokenManagerAddress, 0] },
      // ── DVP_FACTORY_CALLER + REGISTRY_CALLER (was separate section) ──
      { name: 'MapDvp721Factory', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.dvpErc721FactoryAddress, [dvp721IfaceFactory.interface.getFunction('createDvpErc721')!.selector], [dvpFactoryCallerRoleId]] },
      { name: 'MapDvp1155Factory', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.dvpErc1155FactoryAddress, [dvp1155IfaceFactory.interface.getFunction('createDvpErc1155')!.selector], [dvpFactoryCallerRoleId]] },
      { name: 'GrantDvpFactoryCaller', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantRole', args: [dvpFactoryCallerRoleId, addresses.tokenCoreAddress, 0] },
      { name: 'MapEnygmaRegistry', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.enygmaRegistryAddress, [
          registryIfaceFactory.interface.getFunction('registerEnygma')!.selector,
          registryIfaceFactory.interface.getFunction('registerVault')!.selector,
          registryIfaceFactory.interface.getFunction('registerMerkle')!.selector,
          registryIfaceFactory.interface.getFunction('registerDvpIntegration')!.selector,
      ], [registryCallerRoleId]] },
      { name: 'GrantRegistryCaller', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantRole', args: [registryCallerRoleId, enygmaAddresses.enygmaFactoryAddress, 0] },
      // ── ENDPOINT_SENDER (send functions) + RESOURCE_REGISTRAR (registerResourceId) ──
      { name: 'MapEndpointSend', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.endpointAddress, endpointSendSelectors, [endpointSenderRoleId]] },
      { name: 'MapEndpointRegister', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.endpointAddress, [endpointRegisterSelector], [resourceRegistrarRoleId]] },
      ...contractsToGrant.map((addr, i) => ({
        name: `GrantEPSender_${i}`, contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantRole', args: [endpointSenderRoleId, addr, 0]
      })),
      // ── ENYGMA_V1 / COIN_VAULT / DVP_CONTRACT ──
      { name: 'MapEnygmaTeleportV1', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.enygmaTeleportAddress, [
          etIface.getFunction('transfer')!.selector, etIface.getFunction('enygmaSupplyUpdated')!.selector,
          etIface.getFunction('finalizeBalances')!.selector, etIface.getFunction('enygmaDvpBalanceUpdated')!.selector,
      ], [enygmaV1RoleId]] },
      { name: 'MapDvpTeleportCoinVault', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.dvpTeleportAddress, [dtIface.getFunction('emitCommitments')!.selector, dtIface.getFunction('emitNullifiers')!.selector], [coinVaultRoleId]] },
      { name: 'MapDvpTeleportDvpContract', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.dvpTeleportAddress, [
          dtIface.getFunction('ercDvpBalanceUpdated')!.selector,
          dtIface.getFunction('emitSwapInitiated')!.selector,
          dtIface.getFunction('emitSwapCompleted')!.selector,
          dtIface.getFunction('emitSwapCancelled')!.selector,
          dtIface.getFunction('emitSwapTimedOut')!.selector,
      ], [dvpContractRoleId]] },
      // ── FACTORY_ADMIN + DVP_CONTRACT grants ──
      { name: 'GrantFactoryAdmin_Enygma', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantRole', args: [factoryAdminRoleId, enygmaAddresses.enygmaFactoryAddress, 0] },
      { name: 'GrantFactoryAdmin_Dvp', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantRole', args: [factoryAdminRoleId, addresses.dvpAddress, 0] },
      { name: 'GrantFactoryAdmin_Dvp721', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantRole', args: [factoryAdminRoleId, addresses.dvpErc721FactoryAddress, 0] },
      { name: 'GrantFactoryAdmin_Dvp1155', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantRole', args: [factoryAdminRoleId, addresses.dvpErc1155FactoryAddress, 0] },
      { name: 'GrantDvpContract', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantRole', args: [dvpContractRoleId, addresses.dvpAddress, 0] },
      // ── RELAYER ──
      { name: 'MapEndpointRelayer', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.endpointAddress, [epIface.getFunction('receivePayload')!.selector], [relayerRoleId]] },
      // Decommissioning Teleport (vanilla, atomic): the atomic-batch selectors below are decommissioned; the header / encrypted-data selectors are retained.
      { name: 'MapTeleportRelayer', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.teleportAddress, [
          tpIface.getFunction('storeEncryptedDataBatch')!.selector, tpIface.getFunction('addHeader')!.selector,
          tpIface.getFunction('addSingleHeader')!.selector, tpIface.getFunction('executeAtomicMessageBatch')!.selector,
          tpIface.getFunction('EmitAdditionalAtomicDataBatchFor')!.selector, tpIface.getFunction('revertAtomicMessageBatch')!.selector,
      ], [relayerRoleId]] },
      { name: 'MapEnygmaTeleportRelayer', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [enygmaAddresses.enygmaTeleportAddress, [etIface.getFunction('enygmaTransferCompleted')!.selector], [relayerRoleId]] },
      { name: 'MapParticipantRelayer', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.participantStorageAddress, [
          psIface.getFunction('setChainViewData')!.selector, psIface.getFunction('setAuditInfo')!.selector, psIface.getFunction('setPaymentSpendPublicKey')!.selector,
          // F12 fix: facade is now `restricted`. The relayer calls
          // `initiateKeyAgreement` during key bootstrap (see
          // rayls-privacy-relayer-api/private-relayer/keymanager/keymanager.go:151).
          // Grant RELAYER the authority to call it on ParticipantStorage.
          psIface.getFunction('initiateKeyAgreement')!.selector,
      ], [relayerRoleId]] },
      { name: 'MapProofsRelayer', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.proofsAddress, [
          proofsIfaceFactory.interface.getFunction('addBatchHeaders')!.selector, proofsIfaceFactory.interface.getFunction('tryAddHeader')!.selector, proofsIfaceFactory.interface.getFunction('storeEncryptedStorageProofs')!.selector,
      ], [relayerRoleId]] },
      // ── MESSAGE_RECEIVER ──
      { name: 'MapMessageExecutorReceiver', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.messageExecutorAddress, [
          messageExecutorFactory.interface.getFunction('executeMessage')!.selector, messageExecutorFactory.interface.getFunction('executeMessageBatch')!.selector,
      ], [messageReceiverRoleId]] },
      { name: 'MapResourceManagerReceiver', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.resourceManager, [
          resourceManagerFactory.interface.getFunction('handleWithResourceId')!.selector,
      ], [messageReceiverRoleId]] },
      { name: 'MapResourceManagerRegister', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.resourceManager, [
          resourceManagerFactory.interface.getFunction('registerResourceId')!.selector,
      ], [resourceRegistrarRoleId]] },
      { name: 'GrantResourceRegistrarEndpoint', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantRole', args: [resourceRegistrarRoleId, addresses.endpointAddress, 0] },
      { name: 'GrantResourceRegistrarEnygmaManager', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantRole', args: [resourceRegistrarRoleId, addresses.enygmaTokenManagerAddress, 0] },
      // TokenCore calls endpoint.registerResourceId() for DvpERC721/DvpERC1155 token registration
      { name: 'GrantResourceRegistrarTokenCore', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantRole', args: [resourceRegistrarRoleId, addresses.tokenCoreAddress, 0] },
      // ── MESSAGE_EXECUTOR ──
      { name: 'MapTokenRegistryExecutor', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.tokenRegistryAddress, [
          tokenRegistryFactory.interface.getFunction('addToken')!.selector, tokenRegistryFactory.interface.getFunction('updateTokenBalance')!.selector,
          tokenRegistryFactory.interface.getFunction('broadcastCurrentFrozenResourcesForNewParticipant')!.selector,
          tokenRegistryFactory.interface.getFunction('broadcastUnfrozenToken')!.selector, tokenRegistryFactory.interface.getFunction('broadcastFrozenToken')!.selector,
      ], [messageExecutorRoleId]] },
      { name: 'MapParticipantStorageExecutor', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.participantStorageAddress, [
          participantStorageFactory.interface.getFunction('broadcastCurrentParticipants')!.selector,
      ], [messageExecutorRoleId]] },
      { name: 'MapEnygmaPNHEventsExecutor', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.enygmaPnhEventsAddress, [
          enygmaPNHEventsFactory.interface.getFunction('enygmaPnTransferCompleted')!.selector, enygmaPNHEventsFactory.interface.getFunction('mintCompleted')!.selector,
      ], [messageExecutorRoleId]] },
      // ── Grants ──
      { name: 'GrantMessageExecutor', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantRole', args: [messageExecutorRoleId, addresses.messageExecutorAddress, 0] },
      { name: 'GrantMessageReceiver', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantRole', args: [messageReceiverRoleId, addresses.messageReceiver, 0] },
      // ── setRoleAdmin ──
      // Factory-managed roles: FACTORY_ADMIN grants these at runtime to newly deployed contracts.
      { name: 'SetAdminEnygmaCreator', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'setRoleAdmin', args: [enygmaCreatorRoleId, factoryAdminRoleId] },
      { name: 'SetAdminEnygmaV1', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'setRoleAdmin', args: [enygmaV1RoleId, factoryAdminRoleId] },
      { name: 'SetAdminCoinVault', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'setRoleAdmin', args: [coinVaultRoleId, factoryAdminRoleId] },
      { name: 'SetAdminDvpContract', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'setRoleAdmin', args: [dvpContractRoleId, factoryAdminRoleId] },
    ];

    await executeBatchConfig(batchTasks, nonceManager, hre);

    console.log('✅ AUTH-V3 PNH role setup complete (all roles, mappings, grants)');

    // Verify critical mappings persisted (use a zero-address probe — not ADMIN, so canCall relies on actual mappings)
    const managerVerify = await hre.ethers.getContractAt('RaylsAccessManagerV1', managerAddr);
    const epRecvSel = epIface.getFunction('receivePayload')!.selector;
    const epSendSel = epIface.getFunction('send(uint256,address,bytes)')!.selector;
    // Check that receivePayload is mapped (non-admin probe should fail unless mapped to PUBLIC)
    // Instead, check that send is mapped to ENDPOINT_SENDER by verifying a known holder can call it
    const [canSend] = await managerVerify.canCall(addresses.tokenCoreAddress, addresses.endpointAddress, epSendSel);
    console.log(`  🔍 Verify: canCall(tokenCore, endpoint, send) = ${canSend} (should be true — tokenCore has ENDPOINT_SENDER)`);
    if (!canSend) {
      throw new Error('CRITICAL: PNH role mappings did not persist! ENDPOINT_SENDER mapping on Endpoint is missing. The PHASE 4 batch may have had nonce issues.');
    }
    console.log('');

    // -------------------------------------------------------------------------
    // REGISTER RESOURCE IDs (AFTER ROLE SETUP - EndpointV1 needs ENDPOINT_SENDER_ROLE
    // to call ResourceManager.registerResourceId which is restricted)
    // -------------------------------------------------------------------------
    console.log('\n🔐 Registering resource IDs for deployed contracts...');

    const RESOURCE_ID_PARTICIPANT_STORAGE = '0x0000000000000000000000000000000000000000000000000000000000000001';
    const RESOURCE_ID_ENYGMA_PNH_EVENTS = '0x0000000000000000000000000000000000000000000000000000000000000004';
    const RESOURCE_ID_TOKEN_REGISTRY = '0x0000000000000000000000000000000000000000000000000000000000000003';
    const RESOURCE_ID_TEMPLATE_REGISTRY = '0x0000000000000000000000000000000000000000000000000000000000000006';

    console.log(`→ Registering resource IDs for:`);
    console.log(`   - ParticipantStorageV1: ${addresses.participantStorageAddress} (${RESOURCE_ID_PARTICIPANT_STORAGE})`);
    console.log(`   - TokenRegistryV1: ${addresses.tokenRegistryAddress} (${RESOURCE_ID_TOKEN_REGISTRY})`);
    console.log(`   - EnygmaPNHEvents: ${addresses.enygmaPnhEventsAddress} (${RESOURCE_ID_ENYGMA_PNH_EVENTS})`);
    console.log(`   - TemplateRegistryV1: ${addresses.templateRegistryAddress} (${RESOURCE_ID_TEMPLATE_REGISTRY})`);

    await executeBatchConfig([
      {
        name: 'RegisterResourceId_ParticipantStorage',
        contractName: 'EndpointV1',
        address: addresses.endpointAddress,
        method: 'registerResourceId',
        args: [RESOURCE_ID_PARTICIPANT_STORAGE, addresses.participantStorageAddress]
      },
      {
        name: 'RegisterResourceId_TokenRegistry',
        contractName: 'EndpointV1',
        address: addresses.endpointAddress,
        method: 'registerResourceId',
        args: [RESOURCE_ID_TOKEN_REGISTRY, addresses.tokenRegistryAddress]
      },
      {
        name: 'RegisterResourceId_EnygmaPNHEvents',
        contractName: 'EndpointV1',
        address: addresses.endpointAddress,
        method: 'registerResourceId',
        args: [RESOURCE_ID_ENYGMA_PNH_EVENTS, addresses.enygmaPnhEventsAddress]
      },
      {
        name: 'RegisterResourceId_TemplateRegistry',
        contractName: 'EndpointV1',
        address: addresses.endpointAddress,
        method: 'registerResourceId',
        args: [RESOURCE_ID_TEMPLATE_REGISTRY, addresses.templateRegistryAddress]
      }
    ], nonceManager, hre);

    console.log('✅ All resource IDs registered successfully\n');

    // Final configurations (registration and config can run in parallel!)
    console.log('\n📦 FINAL: Register all contracts & configure (parallel)');
    await Promise.all([
      registerAllContracts(nonceManager, hre, addresses),
      finalConfiguration(nonceManager, hre, addresses, initialOwner, raylsViewPublicKey, operatorChainId, verifierAddresses)
    ]);

    const totalTime = ((Date.now() - overallStartTime) / 1000).toFixed(2);
    console.log('\n' + '='.repeat(80));
    console.log(`✅✅✅ PNH DEPLOYMENT COMPLETE IN ${totalTime} SECONDS ✅✅✅`);
    console.log('='.repeat(80));

    printDeploymentConfig(addresses, pnhChainId, pnhStartingBlock, privateKeySystem, raylsViewPublicKey, raylsViewSecretKey, endpointMaxBatchMessages, managerAddr);
  });

async function registerAllContracts(nonceManager: NonceManager, hre: HardhatRuntimeEnvironment, addresses: any) {
  console.log('  📝 Registering all contracts in DeploymentProxyRegistry...');

  const names = [
    "RaylsAccessManager",
    "ResourceRegistry", "Teleport", "Endpoint", "TokenRegistry", "Proofs",
    "ParticipantStorage", "Dvp", "DvpTeleport",
    "EnygmaPNHEvents", "EnygmaTeleport", "EnygmaTokenManager", "TokenCore",
    "TokenFreezeManager", "ParticipantCore", "AuditManager", "EnygmaManager",
    "EnygmaFactory", "EnygmaFactorySettings", "EnygmaRegistry",
    "EnygmaIntegrationCreator", "ResourceManager", "MessageSender",
    "MessageReceiver", "BatchMessageSender", "DvpErc721Factory", "DvpErc1155Factory",
    "FungibleAssetGroup", "NonFungibleAssetGroup", "TemplateRegistry"
  ];

  const addressList = [
    addresses.accessManagerAddress,
    addresses.resourceRegistryAddress, addresses.teleportAddress, addresses.endpointAddress,
    addresses.tokenRegistryAddress, addresses.proofsAddress, addresses.participantStorageAddress,
    addresses.dvpAddress, addresses.dvpTeleportAddress,
    addresses.enygmaPnhEventsAddress, addresses.enygmaTeleportAddress, addresses.enygmaTokenManagerAddress,
    addresses.tokenCoreAddress, addresses.tokenFreezeManagerAddress, addresses.participantCoreAddress,
    addresses.auditManagerAddress, addresses.enygmaManagerAddress, addresses.enygmaFactoryAddress,
    addresses.enygmaFactorySettingsAddress, addresses.enygmaRegistryAddress,
    addresses.enygmaIntegrationCreatorAddress, addresses.resourceManager, addresses.messageSender,
    addresses.messageReceiver, addresses.batchMessageSender, addresses.dvpErc721FactoryAddress,
    addresses.dvpErc1155FactoryAddress, addresses.fungibleAssetGroupAddress,
    addresses.nonFungibleAssetGroupAddress, addresses.templateRegistryAddress
  ];

  await executeConfigWithNonce({
    name: 'RegisterContracts',
    contractName: 'DeploymentProxyRegistryV1',
    address: addresses.deploymentProxyRegistryAddress,
    method: 'registerContracts',
    args: [names, addressList]
  }, nonceManager.allocateNonce(), hre, 5000000);
}

async function finalConfiguration(nonceManager: NonceManager, hre: HardhatRuntimeEnvironment, addresses: any, initialOwner: string, raylsViewPublicKey: string, operatorChainId: string, verifierAddresses: any) {
  console.log('  ⚙️  Applying final configurations...');

  // Get block number upfront for auditor setup
  const currBlockNumber = await hre.ethers.provider.getBlockNumber();

  // NOTE: ConfigureEndpoint is now called early (before role setup) to prevent the race
  // condition where PN relayers send receivePayload before messageReceiver is set.
  await executeBatchConfig([
    {
      name: 'AddAuditorParticipant',
      contractName: 'ParticipantStorageV1',
      address: addresses.participantStorageAddress,
      method: 'addParticipant',
      args: [{
        chainId: parseInt(operatorChainId),
        role: 2,
        ownerId: initialOwner,
        name: 'Auditor',
        allowedToBroadcast: true
      }]
    },
    {
      name: 'UpdateAuditorStatus',
      contractName: 'ParticipantStorageV1',
      address: addresses.participantStorageAddress,
      method: 'updateStatus',
      args: [parseInt(operatorChainId), 1]
    }
  ], nonceManager, hre);

  // SetChainViewData must run AFTER AddAuditorParticipant + UpdateAuditorStatus are confirmed
  // AND after ConfigureEndpoint is confirmed (messageReceiver must be set for onlyAuthorizedCaller).
  // Running it in a separate sequential step ensures all prerequisites are fully settled.
  await executeConfigWithNonce({
    name: 'SetChainViewData',
    contractName: 'ParticipantStorageV1',
    address: addresses.participantStorageAddress,
    method: 'setChainViewData',
    args: [parseInt(operatorChainId), raylsViewPublicKey, currBlockNumber]
  }, nonceManager.allocateNonce(), hre);

  // Add regular participants from PARTICIPANTS environment variable - BATCHED!
  const participantsEnv = process.env.PARTICIPANTS;
  if (participantsEnv) {
    console.log('\n📦 Adding regular participants in parallel...');
    const participantChainIds = participantsEnv.split(',').map(id => parseInt(id.trim()));
    
    // Build all participant config tasks at once for parallel execution
    const participantConfigTasks = participantChainIds.flatMap(chainId => [
      {
        name: `AddParticipant${chainId}`,
        contractName: 'ParticipantStorageV1',
        address: addresses.participantStorageAddress,
        method: 'addParticipant',
        args: [{
          chainId: chainId,
          role: 1, // ISSUER role (0=PARTICIPANT, 1=ISSUER, 2=AUDITOR)
          ownerId: initialOwner,
          name: `Participant-${chainId}`,
          allowedToBroadcast: true
        }]
      },
      {
        name: `UpdateParticipantStatus${chainId}`,
        contractName: 'ParticipantStorageV1',
        address: addresses.participantStorageAddress,
        method: 'updateStatus',
        args: [chainId, 1] // Set to ACTIVE
      }
    ]);
    
    // Execute all participant additions in parallel
    await executeBatchConfig(participantConfigTasks, nonceManager, hre);
    
    console.log(`✅ Added ${participantChainIds.length} regular participants (parallel batch)`);
  } else {
    console.log('⚠️  PARTICIPANTS env var not set, skipping regular participant registration');
  }

  // Configure EnygmaFactorySettings
  const verifierConfig = {
    enygmaK2: verifierAddresses.enygmaVerifierk2Address,
    enygmaK3: verifierAddresses.enygmaVerifierk3Address,
    enygmaK4: verifierAddresses.enygmaVerifierk4Address,
    enygmaK5: verifierAddresses.enygmaVerifierk5Address,
    enygmaK6: verifierAddresses.enygmaVerifierk6Address,
    depositK2: verifierAddresses.depositToDvpVerifierk2Address,
    depositK3: verifierAddresses.depositToDvpVerifierk3Address,
    depositK4: verifierAddresses.depositToDvpVerifierk4Address,
    depositK5: verifierAddresses.depositToDvpVerifierk5Address,
    depositK6: verifierAddresses.depositToDvpVerifierk6Address,
    withdrawK2: verifierAddresses.withdrawFromDvpVerifierk2Address,
    withdrawK3: verifierAddresses.withdrawFromDvpVerifierk3Address,
    withdrawK4: verifierAddresses.withdrawFromDvpVerifierk4Address,
    withdrawK5: verifierAddresses.withdrawFromDvpVerifierk5Address,
    withdrawK6: verifierAddresses.withdrawFromDvpVerifierk6Address
  };

  // Set verifiers and dvp addresses separately, and configure DvpSettings
  await executeBatchConfig([
    {
      name: 'SetAllVerifiers',
      contractName: 'EnygmaFactorySettings',
      address: addresses.enygmaFactorySettingsAddress,
      method: 'setAllVerifiers',
      args: [verifierConfig]
    },
    {
      name: 'SetDvpAddress',
      contractName: 'EnygmaFactorySettings',
      address: addresses.enygmaFactorySettingsAddress,
      method: 'setDvpAddress',
      args: [addresses.dvpAddress]
    },
    {
      name: 'SetDvpTeleportAddress',
      contractName: 'EnygmaFactorySettings',
      address: addresses.enygmaFactorySettingsAddress,
      method: 'setDvpTeleportAddress',
      args: [addresses.dvpTeleportAddress]
    },
    {
      name: 'SetPoseidonWrapperAddress',
      contractName: 'EnygmaFactorySettings',
      address: addresses.enygmaFactorySettingsAddress,
      method: 'setPoseidonWrapperAddress',
      args: [addresses.poseidonWrapperAddress]
    },
    {
      name: 'SetDvpVaultCreators',
      contractName: 'DvpSettings',
      address: addresses.dvpSettingsAddress,
      method: 'setAllVaultCreators',
      args: [addresses.erc721CoinVaultCreatorAddress, addresses.erc1155CoinVaultCreatorAddress]
    }
  ], nonceManager, hre);

  // Initialize AssetGroups and register group pairs
  console.log('\n📦 Initializing AssetGroups and registering group pairs...');
  const TREE_DEPTH = 20; // Standard merkle tree depth for asset groups

  await executeBatchConfig([
    {
      name: 'RegisterFungibleAssetGroup',
      contractName: 'Dvp',
      address: addresses.dvpAddress,
      method: 'registerAssetGroup',
      args: [
        addresses.fungibleAssetGroupAddress,
        'Fungibles',
        true,  // isFungible = true
        TREE_DEPTH
      ]
    },
    {
      name: 'RegisterNonFungibleAssetGroup',
      contractName: 'Dvp',
      address: addresses.dvpAddress,
      method: 'registerAssetGroup',
      args: [
        addresses.nonFungibleAssetGroupAddress,
        'NonFungibles',
        false,  // isFungible = false
        TREE_DEPTH
      ]
    },
    {
      name: 'RegisterSwapGroupPair',
      contractName: 'Dvp',
      address: addresses.dvpAddress,
      method: 'registerSwapGroupPair',
      args: [0, 1]  // groupId 0 (Fungibles) paired with groupId 1 (NonFungibles) for delivery-vs-payment
    },
    {
      name: 'RegisterExchangeGroupPair',
      contractName: 'Dvp',
      address: addresses.dvpAddress,
      method: 'registerExchangeGroupPair',
      args: [0, 0]  // groupId 0 (Fungibles) paired with groupId 0 (Fungibles) for payment-vs-payment
    }
  ], nonceManager, hre);

  console.log('✅ AssetGroups initialized and group pairs registered');

  await nonceManager.sync(); // Sync after final configs
}

function printDeploymentConfig(addresses: any, pnhChainId: string, pnhStartingBlock: number, privateKeySystem: string, raylsViewPublicKey: string, raylsViewSecretKey: string, endpointMaxBatchMessages: string, accessManagerAddress: string) {

  const governanceConfig = `
PNH_DEPLOYMENT_PROXY_REGISTRY=${addresses.deploymentProxyRegistryAddress}
PNH_PRIVATE_KEY=${privateKeySystem}
PNH_CHAIN_ID=${pnhChainId}
PNH_RAYLS_VIEW_PUBLIC_KEY=${raylsViewPublicKey}
PNH_RAYLS_VIEW_SECRET_KEY=${raylsViewSecretKey}
PNH_STARTING_BLOCK=${pnhStartingBlock}
PNH_OPERATOR_CHAIN_ID=999
PNH_BATCH_SIZE=20
PNH_HEADER_PROOF_EXPIRATION_PERIOD=5m
`;

  const relayerConfig = `
PNH_CHAIN_ID=${pnhChainId}
PNH_CHAIN_STARTING_BLOCK=${pnhStartingBlock}
PNH_OPERATOR_CHAIN_ID=999
PNH_DEPLOYMENT_PROXY_REGISTRY=${addresses.deploymentProxyRegistryAddress}
PNH_ENDPOINT_MAX_BATCH_MESSAGES=${endpointMaxBatchMessages}
PNH_EXPIRATION_REVERT_TIME_IN_MINUTES=1m
`;

  const contractsConfig = `
PNH_DEPLOYMENT_PROXY_REGISTRY=${addresses.deploymentProxyRegistryAddress}
PNH_ACCESS_MANAGER_ADDRESS=${accessManagerAddress}
PNH_STARTING_BLOCK=${pnhStartingBlock}
`;

  console.log('');
  console.log(`✅ Finished deploy of PNH PROXY contracts 👽`);
  console.log('');
  console.log(`===========================================`);
  console.log(`👉👉👉👉 Relayer Configuration 👈👈👈👈`);
  console.log(`-------------------------------------------`);
  console.log('ENV FORMAT:');
  console.log(relayerConfig);
  console.log('');
  console.log(`===========================================`);
  console.log(`👉 Governance, Listener & Flagger Configuration 👈`);
  console.log(`-------------------------------------------`);
  console.log('ENV FORMAT:');
  console.log(governanceConfig);
  console.log(`===========================================`);
  console.log(`👉 Contracts Configuration 👈`);
  console.log(`-------------------------------------------`);
  console.log('ENV FORMAT:');
  console.log(contractsConfig);
  console.log(`===========================================`);
}
