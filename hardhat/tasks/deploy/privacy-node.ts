// Decommissioning Teleport (vanilla, atomic): the RN public-chain bridge deploy/config/role steps below
// are marked; the generic EndpointV1 deploy, RNContractFactoryV1, and RNUserGovernanceV1 are retained.
import '@nomicfoundation/hardhat-ethers';
import { task } from 'hardhat/config';
import { Wallet } from 'ethers';
import {
    NonceManager,
    executeConfigWithNonce,
    executeBatchConfig,
    deployWithNonce,
    deployBatch,
    getContractAtForArtifactRef,
    getInterfaceForArtifactRef
} from './batch-helpers';
import {
    deployRegistriesBatch,
    deployRaylsNodeSystemBatch,
    deployCoreContractsBatch,
    deployAdditionalContractsBatch,
    deployMessageModulesBatch,
    PN_TOKEN_CORE_ARTIFACT,
    PN_TOKEN_CORE_SOURCE,
    PN_TOKEN_FREEZE_MANAGER_ARTIFACT,
    PN_TOKEN_FREEZE_MANAGER_SOURCE,
    PN_TOKEN_REGISTRY_ARTIFACT,
    PN_TOKEN_REGISTRY_SOURCE
} from './privacy-node-batches';
import { ManifestManager } from './manifest-manager';

/**
 * Selectors for every caller-facing deploy path on a V1 contract factory: the raw `deploy`,
 * the registered-key `deployRegistered`, the six typed convenience deploys, and the owner-attested
 * `deployFromTeleport` (RN factory only). These are the functions gated to FACTORY_ADMIN +
 * FACTORY_DEPLOYER. Registry/admin setters are intentionally excluded (ADMIN-only). Resolved off
 * the contract interface so adding a typed deploy here is the single place to update. Names absent
 * on a given factory (e.g. `deployFromTeleport` on the Rayls hub factory) are skipped.
 */
function factoryDeploySelectors(factory: { interface: { getFunction: (n: string) => { selector: string } | null } }): string[] {
    return [
        'deploy',
        'deployRegistered',
        'deployErc20',
        'deployErc721',
        'deployErc1155',
        'deployEnygma',
        'deployErc721Dvp',
        'deployErc1155Dvp',
        'deployStableCoin',
        'deployFromTeleport',
        'deployExternal',
        'deployRegisteredExternal',
    ]
        .map((fn) => factory.interface.getFunction(fn)?.selector)
        .filter((sel): sel is string => sel !== undefined);
}

task('deploy:privacy-node', 'Deploys the Privacy Node contracts')
    .addParam('privacyNode', 'The Privacy Node identification (ex: A, B, C, D)')
    .setAction(async (taskArgs, hre) => {
        const overallStartTime = Date.now();
        console.log('🚀🚀🚀 FAST BATCH DEPLOYMENT STARTED (PRIVACY NODE) 🚀🚀🚀');
        console.log('='.repeat(80));

        const { ethers } = hre;
        const version = '2.0';
        const chainId = (await ethers.provider.getNetwork()).chainId;

        console.log(`📋 PRIVACY NODE: ${taskArgs.privacyNode}`);
        console.log(`📋 CHAIN ID: ${chainId}`);
        console.log(`📋 VERSION: ${version}`);

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

        // Validation
        console.log('\n📋 STEP 1: ENVIRONMENT VALIDATION');
        // Hub-less mode (RayUp / --no-hub): deploy a self-contained privacy node
        // without a Private Hub. STEP 4 (synchronizeWithPrivateHub) is skipped, so
        // the PNH registry/RPC are not required. Every contract, role and resource-id
        // registration still runs — only the cross-chain hub sync is omitted.
        const hubless = process.env['HUB_ENABLED'] === 'false';
        const pnhDeploymentRegistryAddress = process.env['PNH_DEPLOYMENT_PROXY_REGISTRY'] as string;
        if (!hubless && !pnhDeploymentRegistryAddress) {
            throw new Error('PNH_DEPLOYMENT_PROXY_REGISTRY is not set in the .env file');
        }
        if (hubless) {
            console.log('→ Hub-less mode (HUB_ENABLED=false): skipping Private Hub synchronization');
        } else {
            console.log(`→ PNH Deployment Registry Address: ${pnhDeploymentRegistryAddress}`);
        }

        const privateKey = process.env.PRIVATE_KEY_SYSTEM;
        if (!privateKey) {
            throw new Error('PRIVATE_KEY_SYSTEM is not set in the .env file');
        }

        const deployer = new ethers.Wallet(privateKey, ethers.provider);
        console.log(`→ Deployer Address: ${deployer.address}`);

        const signer = await hre.ethers.provider.getSigner();
        const initialOwner = signer.address;
        const nonceManager = new NonceManager(hre.ethers.provider, initialOwner);
        await nonceManager.initialize();
        console.log(`📊 NonceManager initialized with starting nonce: ${await nonceManager.getCurrentNonce()}`);

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
        // Capture the chain tip immediately BEFORE the AccessManager deploys. This is
        // guaranteed <= the AM deploy block, so the ops-worker's AM role-event indexer can
        // backfill from here without skipping the AM's initialize() RoleGranted event. It is
        // deliberately distinct from PRIVACY_NODE_<X>_STARTING_BLOCK (captured at STEP 4,
        // after the AM deploy — too late for the indexer; that one feeds the audit suite).
        const accessManagerStartingBlock = await ethers.provider.getBlockNumber();
        const accessManagerBatch = await deployBatch([
            { name: 'RaylsAccessManager', contractName: 'RaylsAccessManagerV1', isProxy: true, initArgs: [initialOwner], initializer: 'initialize(address)', libraries: amLibraries, validationOpts: { unsafeAllow: ['external-library-linking'] } }
        ], nonceManager, hre);
        const managerAddr = accessManagerBatch[0].address;
        console.log(`  ✓ RaylsAccessManagerV1 deployed at ${managerAddr}`);

        // Deploy in batches with maximum parallelization
        console.log('\n📋 STEP 2: DEPLOYING CONTRACTS IN BATCHES');

        const addresses: any = await deployRegistriesBatch(nonceManager, hre, initialOwner, managerAddr);
        Object.assign(addresses, { accessManagerAddress: managerAddr });

        //RN System
        console.log('\n📋  RN System');
        const [rnAddresses] = await Promise.all([
            deployRaylsNodeSystemBatch(nonceManager, hre, initialOwner, chainId.toString(), managerAddr),
        ]);

        // Core Contracts
        console.log('\n📋  Core Contracts');
        const [coreAddresses] = await Promise.all([
            deployCoreContractsBatch(nonceManager, hre, initialOwner, chainId.toString(), rnAddresses.raylsNodeEndpointAddress, managerAddr, !hubless)
        ]);

        Object.assign(addresses, rnAddresses);
        Object.assign(addresses, coreAddresses);

        // Point the ResourceManager at the RN factory. It is constructed with the generic
        // RaylsContractFactoryV1 (deployCoreContractsBatch), but on a Privacy Node, FACTORY-mode
        // deploys must route through RNContractFactoryV1 — that is the factory the seeding loop
        // populates (setBytecode) and whose RN-specific trusted-init wires the PN endpoint/manager.
        // Without this, ResourceManager.deployRegistered hits the unseeded Rayls factory and reverts
        // with FactoryV1__BytecodeNotRegistered.
        await executeConfigWithNonce(
            { name: 'SetResourceManagerFactory', contractName: 'ResourceManager', address: addresses.resourceManagerAddress, method: 'setContractFactory', args: [addresses.raylsNodeContractFactoryAddress] },
            nonceManager.allocateNonce(), hre
        );

        // Repoint RNContractFactoryV1 at the Rayls EndpointV1. It was initialized in
        // deployRaylsNodeSystemBatch (before the PN EndpointV1 existed) with the privacy-node
        // endpoint, but the factory stamps `endpoint` into every handler's RaylsTrustedInit as its
        // `IRaylsEndpoint`. Handlers resolve protocol contracts (e.g. EnygmaPNEvents via
        // RESOURCE_ID_ENYGMA_PN_EVENTS) through that endpoint, and only EndpointV1 owns the resource
        // registry / implements getAddressByResourceId. Leaving it as the privacy-node endpoint makes
        // every events-emitting handler path (crossTransferRevertBatch, mint, crossRevertMint,
        // sendTransferPNH) revert. setEndpoint is `restricted`; the deployer holds ADMIN_ROLE.
        await executeConfigWithNonce(
            { name: 'SetRNFactoryEndpoint', contractName: 'RNContractFactoryV1', address: addresses.raylsNodeContractFactoryAddress, method: 'setEndpoint', args: [addresses.endpointAddress] },
            nonceManager.allocateNonce(), hre
        );

        // Bind the RN endpoint (RNEndpointV1) the factory stamps into every handler's
        // trusted-init as `raylsNodeEndpoint`. ResourceManager routes destination-side resource
        // deploys through THIS factory (SetResourceManagerFactory above), so without this every
        // replicated token is "unbound" and teleportToPublicChain reverts calling address(0)
        // (caught by the cross-node B->public e2e suite). setRaylsNodeEndpoint is `restricted`;
        // the deployer holds ADMIN_ROLE.
        await executeConfigWithNonce(
            { name: 'SetRNFactoryRaylsNodeEndpoint', contractName: 'RNContractFactoryV1', address: addresses.raylsNodeContractFactoryAddress, method: 'setRaylsNodeEndpoint', args: [addresses.raylsNodeEndpointAddress] },
            nonceManager.allocateNonce(), hre
        );

        // Deploy the PN registry modules + additional contracts
        const additionalAddresses = await deployAdditionalContractsBatch(nonceManager, hre, initialOwner, addresses.endpointAddress, managerAddr, !hubless);
        Object.assign(addresses, additionalAddresses);

        // Wire the PN TokenRegistry facade into the RN factory so its receiver-side teleport
        // auto-deploy (deployRegisteredExternal / deployExternal, driven by ResourceManager) records the mirror via
        // registerHubToken. The factory is deployed early (before the registry existed), so this is a
        // post-deploy setter rather than an init arg — same pattern as SetRNFactoryEndpoint above.
        // Must run AFTER deployAdditionalContractsBatch, which populates addresses.tokenRegistryAddress.
        // setTokenRegistry is `restricted`; the deployer holds ADMIN_ROLE.
        await executeConfigWithNonce(
            { name: 'SetRNFactoryTokenRegistry', contractName: 'RNContractFactoryV1', address: addresses.raylsNodeContractFactoryAddress, method: 'setTokenRegistry', args: [addresses.tokenRegistryAddress] },
            nonceManager.allocateNonce(), hre
        );

        // NOTE: Destination-chain mirror tokens are recorded in the PN TokenRegistry by the RN
        // factory itself (deployRegisteredExternal / deployExternal -> facade registerHubToken, mapped to
        // FACTORY_DEPLOYER in MapTokenRegistryRegisterHubToken). The factory holds FACTORY_DEPLOYER
        // (GrantFactoryDeployerRNFactory), so no separate wiring on the TokenCore is needed.

        // NOTE: Resource ID registration moved to after role setup (EndpointV1 needs
        // ENDPOINT_SENDER_ROLE on ResourceManager before it can call registerResourceId).

        // Hub-connected messaging modules (skipped in hubless mode). Requires the
        // messageExecutorAddress (from deployCoreContractsBatch), the participant storage
        // replica, the PN TokenRegistry facade, the resource manager and the endpoint. STEP 4's
        // synchronizeWithPrivateHub sends through these, so hub-full deploys must have them.
        if (!hubless) {
            const messageAddresses = await deployMessageModulesBatch(nonceManager, hre, chainId.toString(), addresses.participantStorageAddress, addresses.tokenRegistryAddress, addresses.resourceManagerAddress, addresses.messageExecutorAddress, addresses.endpointAddress, initialOwner, managerAddr);
            Object.assign(addresses, messageAddresses);
        }

        // Final configurations
        console.log('\n📋 STEP 3: FINAL CONFIGURATIONS');
        await configureContracts(nonceManager, hre, addresses, deployer, managerAddr);

        // -------------------------------------------------------------------------
        // AUTH-V3: ALL ROLES — fire TXs in parallel, wait for all receipts at the end.
        // The order within a nonce-managed signer is guaranteed by the EVM.
        // We register roles first (they get sequential IDs), then map selectors and
        // grant roles using those IDs.
        // -------------------------------------------------------------------------
        console.log('\n🔐 Setting up AUTH-V3 roles...');

        const managerContract = await hre.ethers.getContractAt('RaylsAccessManagerV1', managerAddr, deployer);
        await nonceManager.sync();

        // ── Step 1: Register all roles (must complete before mapping/granting) ──
        await executeBatchConfig([
            { name: 'RegisterPnTokenRegistryAdminRole', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'registerRole(string)', args: ['PN_TOKEN_REGISTRY_ADMIN'] },
            { name: 'RegisterPnTokenRegistryUpgraderRole', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'registerRole(string)', args: ['PN_TOKEN_REGISTRY_UPGRADER'] },
            { name: 'RegisterEndpointSender', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'registerRole(string)', args: ['ENDPOINT_SENDER'] },
            { name: 'RegisterFactoryAdmin', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'registerRole(string)', args: ['FACTORY_ADMIN'] },
            { name: 'RegisterRelayerRole', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'registerRole(string)', args: ['RELAYER'] },
            { name: 'RegisterTokenCreatorRole', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'registerRole(string)', args: ['TOKEN_CREATOR'] },
            { name: 'RegisterMessageExecutorRole', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'registerRole(string)', args: ['MESSAGE_EXECUTOR'] },
            { name: 'RegisterMessageReceiverRole', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'registerRole(string)', args: ['MESSAGE_RECEIVER'] },
            { name: 'RegisterResourceRegistrar', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'registerRole(string)', args: ['RESOURCE_REGISTRAR'] },
            { name: 'RegisterFactoryDeployer', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'registerRole(string)', args: ['FACTORY_DEPLOYER'] },
        ], nonceManager, hre);

        const pnTokenRegistryAdminRoleId = await managerContract.getRoleIdByName('PN_TOKEN_REGISTRY_ADMIN');
        const pnTokenRegistryUpgraderRoleId = await managerContract.getRoleIdByName('PN_TOKEN_REGISTRY_UPGRADER');
        const endpointSenderRoleId      = await managerContract.getRoleIdByName('ENDPOINT_SENDER');
        const factoryAdminRoleId        = await managerContract.getRoleIdByName('FACTORY_ADMIN');
        const relayerRoleId             = await managerContract.getRoleIdByName('RELAYER');
        const tokenCreatorRoleId        = await managerContract.getRoleIdByName('TOKEN_CREATOR');
        const messageExecutorRoleId     = await managerContract.getRoleIdByName('MESSAGE_EXECUTOR');
        const messageReceiverRoleId     = await managerContract.getRoleIdByName('MESSAGE_RECEIVER');
        const resourceRegistrarRoleId   = await managerContract.getRoleIdByName('RESOURCE_REGISTRAR');
        const factoryDeployerRoleId     = await managerContract.getRoleIdByName('FACTORY_DEPLOYER');
        console.log(`  ✓ Roles registered: PN_TOKEN_REGISTRY_ADMIN=${pnTokenRegistryAdminRoleId}, PN_TOKEN_REGISTRY_UPGRADER=${pnTokenRegistryUpgraderRoleId}, ENDPOINT_SENDER=${endpointSenderRoleId}, FACTORY_ADMIN=${factoryAdminRoleId}, FACTORY_DEPLOYER=${factoryDeployerRoleId}, RELAYER=${relayerRoleId}, TOKEN_CREATOR=${tokenCreatorRoleId}, MESSAGE_EXECUTOR=${messageExecutorRoleId}, MESSAGE_RECEIVER=${messageReceiverRoleId}, RESOURCE_REGISTRAR=${resourceRegistrarRoleId}`);

        // Grant the PN TokenRegistry governance roles to the deploy owner. These named roles are
        // used by the PN TokenRegistryV1 facade introduced in #187.
        const registryGovernanceAccounts = [initialOwner];

        await executeBatchConfig(
            registryGovernanceAccounts.flatMap((account, index) => ([
                { name: `GrantPnTokenRegistryAdmin_${index}`, contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantRole', args: [pnTokenRegistryAdminRoleId, account, 0] },
                { name: `GrantPnTokenRegistryUpgrader_${index}`, contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantRole', args: [pnTokenRegistryUpgraderRoleId, account, 0] },
            ])),
            nonceManager,
            hre
        );
        console.log(`  ✓ Granted PN_TOKEN_REGISTRY_ADMIN and PN_TOKEN_REGISTRY_UPGRADER to: ${registryGovernanceAccounts.join(', ')}`);

        // ── Collect selectors ──────────────────────────────────────────
        const endpointV1Factory = await hre.ethers.getContractFactory('EndpointV1');
        const enygmaPNEventsFactory = await hre.ethers.getContractFactory('EnygmaPNEvents');
        // Decommissioning Teleport (vanilla, atomic): RNEndpointV1 / RNTokenGovernanceV1 selector sources.
        const rnEndpointV1Factory = await hre.ethers.getContractFactory('RNEndpointV1');
        const rnContractFactoryV1 = await hre.ethers.getContractFactory('RNContractFactoryV1');
        const raylsContractFactoryV1 = await hre.ethers.getContractFactory('RaylsContractFactoryV1');
        const resourceManagerFactory = await hre.ethers.getContractFactory('ResourceManager');
        const participantStorageReplicaFactory = await hre.ethers.getContractFactory('ParticipantStorageReplicaV1');
        // Token registry module names are duplicated between PN and PNH, so use
        // explicit PN artifact refs for selector calculation. Unique contracts
        // above keep the normal getContractFactory('Name') path.
        const [tokenRegistryInterface, tokenCoreInterface, tokenFreezeManagerInterface] = await Promise.all([
            getInterfaceForArtifactRef({ contractName: 'PNTokenRegistryV1', artifactPath: PN_TOKEN_REGISTRY_ARTIFACT, artifactSourceName: PN_TOKEN_REGISTRY_SOURCE }, hre),
            getInterfaceForArtifactRef({ contractName: 'PNTokenCoreV1', artifactPath: PN_TOKEN_CORE_ARTIFACT, artifactSourceName: PN_TOKEN_CORE_SOURCE }, hre),
            getInterfaceForArtifactRef({ contractName: 'PNTokenFreezeManagerV1', artifactPath: PN_TOKEN_FREEZE_MANAGER_ARTIFACT, artifactSourceName: PN_TOKEN_FREEZE_MANAGER_SOURCE }, hre),
        ]);
        // Hub-only contract factories — used solely by the !hubless selector maps below.
        // getContractFactory only loads the ABI (no chain interaction), so it is harmless
        // to resolve them unconditionally.
        const raylsMessageExecutorFactory = await hre.ethers.getContractFactory('RaylsMessageExecutorV1');
        const pnCommunicatorFactory = await hre.ethers.getContractFactory('PNCommunicatorV1');
        const templateRegistryReplicaFactory = await hre.ethers.getContractFactory('TemplateRegistryReplicaV1');
        const programmabilityExecutorFactory = await hre.ethers.getContractFactory('ProgrammabilityExecutorV1');

        const endpointSendSelectors = [
            endpointV1Factory.interface.getFunction('send(uint256,address,bytes)')!.selector,
            endpointV1Factory.interface.getFunction('send(uint256,address,bytes,(uint8,uint256,address,address,address,uint256))')!.selector,
            endpointV1Factory.interface.getFunction('sendBatch((uint256,address,bytes)[])')!.selector,
            endpointV1Factory.interface.getFunction('sendToResourceId(uint256,bytes32,bytes)')!.selector,
            endpointV1Factory.interface.getFunction('sendBatchToResourceId((uint256,bytes32,bytes)[])')!.selector,
            endpointV1Factory.interface.getFunction('sendToResourceId(uint256,bytes32,bytes,bytes,bytes,bytes,(uint8,uint256,address,address,address,uint256))')!.selector,
            endpointV1Factory.interface.getFunction('sendBatchToResourceId((uint256,bytes32,bytes,bytes,bytes,bytes,(uint8,uint256,address,address,address,uint256))[])')!.selector,
        ];
        const endpointRegisterSelector = endpointV1Factory.interface.getFunction('registerResourceId(bytes32,address)')!.selector;

        const tokenRegistryCreatorSelectors = [
            tokenRegistryInterface.getFunction('registerToken')!.selector,
        ];
        const tokenRegistryAdminSelectors = [
            'setTokenCore',
            'setTokenFreezeManager',
            'updatePrivacyNodeStatus',
            'submitToHub',
            'submitToPublicChain',
            'rejectToken',
            'deprecateOnPublicChain',
            'requestAllFrozenTokensDataFromPrivateHub',
        ].map(fn => tokenRegistryInterface.getFunction(fn)!.selector);
        const tokenRegistryExecutorSelectors = [
            'activateToken',
            'freezeOnPrivacyNode',
            'unfreezeOnPrivacyNode',
            'syncFrozenTokens',
            'updateFrozenToken',
            'removeFrozenToken',
            'freezeOnPublicChain',
            'unfreezeOnPublicChain',
        ].map(fn => tokenRegistryInterface.getFunction(fn)!.selector);
        // validateTokenForParticipant / getFrozenTokenForParticipant are unrestricted
        // read-only views on the facade (no `restricted` modifier), so they need no
        // selector-role mapping.
        const tokenRegistryUpgradeSelectors = [
            tokenRegistryInterface.getFunction('upgradeToAndCall')!.selector,
        ];
        const tokenCoreAdminSelectors = [
            'setTokenRegistry',
            'setTokenFreezeManager',
            'setEndpoint',
            'setEnygmaPNEvents',
            'setRelayAuthorizationRegistry',
        ].map(fn => tokenCoreInterface.getFunction(fn)!.selector);
        const tokenCoreUpgradeSelectors = [
            tokenCoreInterface.getFunction('upgradeToAndCall')!.selector,
        ];
        const tokenFreezeManagerAdminSelectors = [
            'setTokenRegistry',
            'setTokenCore',
            'setEndpoint',
            'setRelayAuthorizationRegistry',
        ].map(fn => tokenFreezeManagerInterface.getFunction(fn)!.selector);
        const tokenFreezeManagerUpgradeSelectors = [
            tokenFreezeManagerInterface.getFunction('upgradeToAndCall')!.selector,
        ];

        const enygmaRuntimeSelectors = [
            'mint', 'burn', 'revertMint', 'sendTransferPNH',
            'depositToDvp', 'withdrawFromDvp', 'cancelSwap',
            'dvp721Mint', 'dvp721Burn', 'dvp721DepositIntoDvp', 'dvp721WithdrawFromDvp', 'dvp721SwapCompleted', 'dvp721SwapForEnygma',
            'dvp1155Mint', 'dvp1155Burn', 'dvp1155DepositIntoDvp', 'dvp1155WithdrawFromDvp', 'dvp1155SwapCompleted', 'dvp1155SwapForEnygma',
            'swapWithDvpForERC721', 'swapWithDvpForERC1155',
        ].map(fn => enygmaPNEventsFactory.interface.getFunction(fn)!.selector);

        const enygmaCreationSelectors = [
            'creation', 'dvp721Creation', 'dvp1155Creation',
        ].map(fn => enygmaPNEventsFactory.interface.getFunction(fn)!.selector);

        // ── Step 2: Map selectors + grant roles (parallel via NonceManager) ──
        await executeBatchConfig([
            // Selector mappings
            { name: 'MapEndpointSend', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.endpointAddress, endpointSendSelectors, [endpointSenderRoleId]] },
            { name: 'MapEnygmaRuntime', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.enygmaPNEventsAddress, enygmaRuntimeSelectors, [endpointSenderRoleId]] },
            ...(!hubless ? [
                { name: 'MapPNCommunicator', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.raylsCommunicatorAddress, [pnCommunicatorFactory.interface.getFunction('addSharedInfo')!.selector], [endpointSenderRoleId]] },
            ] : []),
            // Decommissioning Teleport (vanilla, atomic); the generic MapEndpointRelayer below is retained.
            { name: 'MapRNEndpointRelayer', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.raylsNodeEndpointAddress, [rnEndpointV1Factory.interface.getFunction('receivePayload')!.selector], [relayerRoleId]] },
            { name: 'MapEndpointRelayer', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.endpointAddress, [endpointV1Factory.interface.getFunction('receivePayload')!.selector], [relayerRoleId]] },
            { name: 'MapTokenRegistryCreator', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.tokenRegistryAddress, tokenRegistryCreatorSelectors, [tokenCreatorRoleId]] },
            { name: 'MapTokenRegistryAdmin', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.tokenRegistryAddress, tokenRegistryAdminSelectors, [pnTokenRegistryAdminRoleId]] },
            // updatePublicTokenAddress is relayer-only per the Token Registry SDD: the relayer
            // writes back the public-chain mirror address it just deployed. Gate it on RELAYER
            // (the public relayer's PN key holds this role), not PN_TOKEN_REGISTRY_ADMIN.
            { name: 'MapTokenRegistryUpdatePublicAddressRelayer', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.tokenRegistryAddress, [tokenRegistryInterface.getFunction('updatePublicTokenAddress')!.selector], [relayerRoleId]] },
            { name: 'MapTokenRegistryExecutor', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.tokenRegistryAddress, tokenRegistryExecutorSelectors, [messageExecutorRoleId]] },
            // registerHubToken is called by the RN contract factory (holds FACTORY_DEPLOYER, granted
            // below) from deployRegisteredExternal / deployExternal, right after it auto-deploys a destination-chain
            // mirror on the ResourceManager inbound-teleport path. The deployer records what it just
            // deployed (dependency inverted from the old ResourceManager -> TokenRegistry call).
            { name: 'MapTokenRegistryRegisterHubToken', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.tokenRegistryAddress, [tokenRegistryInterface.getFunction('registerHubToken')!.selector], [factoryDeployerRoleId]] },
            { name: 'MapTokenRegistryUpgrade', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.tokenRegistryAddress, tokenRegistryUpgradeSelectors, [pnTokenRegistryUpgraderRoleId]] },
            { name: 'MapTokenCoreAdmin', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.tokenCoreAddress, tokenCoreAdminSelectors, [pnTokenRegistryAdminRoleId]] },
            { name: 'MapTokenCoreUpgrade', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.tokenCoreAddress, tokenCoreUpgradeSelectors, [pnTokenRegistryUpgraderRoleId]] },
            { name: 'MapTokenFreezeManagerAdmin', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.tokenFreezeManagerAddress, tokenFreezeManagerAdminSelectors, [pnTokenRegistryAdminRoleId]] },
            { name: 'MapTokenFreezeManagerUpgrade', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.tokenFreezeManagerAddress, tokenFreezeManagerUpgradeSelectors, [pnTokenRegistryUpgraderRoleId]] },
            ...(!hubless ? [
                // ProgrammabilityExecutor.executeProgramData is RELAYER-gated — only the relayer's
                // signed tx may dispatch program-data on the PN. The bare name resolves uniquely since
                // the executor exposes a single executeProgramData overload.
                { name: 'MapProgrammabilityExecutorRelayer', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.programmabilityExecutorAddress, [
                    programmabilityExecutorFactory.interface.getFunction('executeProgramData')!.selector,
                ], [relayerRoleId]] },
            ] : []),
            { name: 'MapEnygmaCreation', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.enygmaPNEventsAddress, enygmaCreationSelectors, [tokenCreatorRoleId]] },
            ...(!hubless ? [
                // ── MESSAGE_RECEIVER mappings (MessageReceiver calls these) ──
                { name: 'MapMessageExecutorReceiver', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.messageExecutorAddress, [
                    raylsMessageExecutorFactory.interface.getFunction('executeMessage')!.selector,
                    raylsMessageExecutorFactory.interface.getFunction('executeMessageBatch')!.selector,
                ], [messageReceiverRoleId]] },
            ] : []),
            { name: 'MapResourceManagerReceiver', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.resourceManagerAddress, [
                resourceManagerFactory.interface.getFunction('handleWithResourceId')!.selector,
            ], [messageReceiverRoleId]] },
            { name: 'MapResourceManagerRegister', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.resourceManagerAddress, [
                resourceManagerFactory.interface.getFunction('registerResourceId')!.selector,
            ], [resourceRegistrarRoleId]] },
            // Map Endpoint.registerResourceId to RESOURCE_REGISTRAR only.
            // Contracts that need to register resources (TokenCore, Endpoint) are granted this role explicitly.
            { name: 'MapEndpointRegister', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.endpointAddress, [endpointRegisterSelector], [resourceRegistrarRoleId]] },
            // ── MESSAGE_EXECUTOR mappings (MessageExecutor delivers cross-chain messages to these targets) ──
            // NOTE: PN TokenRegistry/TokenCore/TokenFreezeManager executor selectors are mapped above
            // via MapTokenRegistryExecutor and the freeze-manager maps (modular design).
            { name: 'MapParticipantReplicaExecutor', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.participantStorageAddress, [
                participantStorageReplicaFactory.interface.getFunction('addOrUpdateParticipants')!.selector,
            ], [messageExecutorRoleId]] },
            ...(!hubless ? [
                // ── TemplateRegistryReplica: receives onTemplateApproved / onTemplateRevoked
                //    broadcasts from PNH. MESSAGE_EXECUTOR is the relayer's dispatcher role;
                //    the replica enforces a second-level `fromChainId == hubId` check inside
                //    each method, so the AccessManager only needs to admit the dispatcher.
                { name: 'MapTemplateRegistryReplicaExecutor', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.templateRegistryReplicaAddress, [
                    templateRegistryReplicaFactory.interface.getFunction('onTemplateApproved')!.selector,
                    templateRegistryReplicaFactory.interface.getFunction('onTemplateRevoked')!.selector,
                ], [messageExecutorRoleId]] },
            ] : []),
            // Map deploy() to FACTORY_ADMIN + FACTORY_DEPLOYER on both factories
            // Map the factory deploy paths to FACTORY_ADMIN + FACTORY_DEPLOYER on both factories.
            // FACTORY_ADMIN: factories themselves (need role-admin power to grant ENDPOINT_SENDER after deploy)
            // FACTORY_DEPLOYER: ResourceManager/RNEndpoint/Ops Service (only need to call deploy paths)
            //
            // Every deploy path is a distinct selector under the V1 factory rewrite: the raw
            // `deploy`, the registered-key `deployRegistered`, and the six typed convenience
            // functions. The registry/admin setters (`setBytecode`, `setEndpoint`,
            // `setFactoryOwner`, `setRaylsNodeEndpoint`) are NOT mapped here —
            // they remain ADMIN-only (role 0 bypasses these maps) so only the deployer-of-record
            // can register bytecodes or change trusted-init wiring.
            { name: 'MapRNContractFactoryDeploy', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.raylsNodeContractFactoryAddress, factoryDeploySelectors(rnContractFactoryV1), [factoryAdminRoleId, factoryDeployerRoleId]] },
            { name: 'MapRaylsContractFactoryDeploy', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'addFunctionAllowedRoles', args: [addresses.contractFactoryAddress, factoryDeploySelectors(raylsContractFactoryV1), [factoryAdminRoleId, factoryDeployerRoleId]] },
            // FACTORY_ADMIN grants (contracts that need to grant ENDPOINT_SENDER at runtime)
            { name: 'GrantFactoryAdmin', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantRole', args: [factoryAdminRoleId, addresses.contractFactoryAddress, 0] },
            { name: 'GrantFactoryAdminTokenCore', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantRole', args: [factoryAdminRoleId, addresses.tokenCoreAddress, 0] },
            // ResourceManager grants ENDPOINT_SENDER to receiver-side auto-deployed instances
            // (ResourceManager.handleWithResourceId), so it must hold FACTORY_ADMIN (admin of
            // ENDPOINT_SENDER). Issuer-side tokens get the grant via the PN TokenCoreV1 activation path.
            { name: 'GrantFactoryAdminResourceManager', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantRole', args: [factoryAdminRoleId, addresses.resourceManagerAddress, 0] },
            // FACTORY_DEPLOYER grants (contracts that only need to call deploy(), not grant roles)
            // Decommissioning Teleport (vanilla, atomic): FACTORY_DEPLOYER → RNEndpoint.
            { name: 'GrantFactoryDeployerRNEndpoint', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantRole', args: [factoryDeployerRoleId, addresses.raylsNodeEndpointAddress, 0] },
            { name: 'GrantFactoryDeployerResourceManager', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantRole', args: [factoryDeployerRoleId, addresses.resourceManagerAddress, 0] },
            // The RN factory calls the PN TokenRegistry facade's `registerHubToken` (FACTORY_DEPLOYER-
            // gated) from deployRegisteredExternal / deployExternal, so the factory itself must hold FACTORY_DEPLOYER.
            { name: 'GrantFactoryDeployerRNFactory', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantRole', args: [factoryDeployerRoleId, addresses.raylsNodeContractFactoryAddress, 0] },
            { name: 'GrantEPSenderParticipant', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantRole', args: [endpointSenderRoleId, addresses.participantStorageAddress, 0] },
            { name: 'GrantEPSenderTokenCore', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantRole', args: [endpointSenderRoleId, addresses.tokenCoreAddress, 0] },
            { name: 'GrantEPSenderTokenFreezeManager', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantRole', args: [endpointSenderRoleId, addresses.tokenFreezeManagerAddress, 0] },
            { name: 'GrantTokenCreatorFactory', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantRole', args: [tokenCreatorRoleId, addresses.contractFactoryAddress, 0] },
            // TokenCore emits enygmaPNEvents.creation(...) during the constructor-deploy activateToken callback
            // (Enygma/DVP). That selector is TOKEN_CREATOR-gated, so TokenCore must hold TOKEN_CREATOR — otherwise
            // the hub→PN activation reverts RaylsAccessManaged__Unauthorized(tokenCore).
            { name: 'GrantTokenCreatorTokenCore', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantRole', args: [tokenCreatorRoleId, addresses.tokenCoreAddress, 0] },
            ...(!hubless ? [
                // MESSAGE_EXECUTOR → MessageExecutor (so it can call restricted receive functions on targets)
                { name: 'GrantMessageExecutor', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantRole', args: [messageExecutorRoleId, addresses.messageExecutorAddress, 0] },
            ] : []),
            // MESSAGE_EXECUTOR → RN MessageExecutor (handles public chain → PN message delivery)
            // Decommissioning Teleport (vanilla, atomic): MESSAGE_EXECUTOR → RN MessageExecutor.
            { name: 'GrantRNMessageExecutor', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantRole', args: [messageExecutorRoleId, addresses.raylsNodeMessageExecutorAddress, 0] },
            ...(!hubless ? [
                // RELAYER → ProgrammabilityExecutor: the executor dispatches gated calls (e.g. crossMint)
                // via target.call, so the token handlers' RELAYER-gated `restricted` modifier must admit
                // the executor's own address. Both the relayer key (gate on executeProgramData) and the
                // executor address (gate on crossMint) hold RELAYER.
                { name: 'GrantRelayerProgrammabilityExecutor', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantRole', args: [relayerRoleId, addresses.programmabilityExecutorAddress, 0] },
                // MESSAGE_RECEIVER → MessageReceiver (so it can call restricted executeMessage on MessageExecutor)
                { name: 'GrantMessageReceiver', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantRole', args: [messageReceiverRoleId, addresses.messageReceiverAddress, 0] },
            ] : []),
            // RESOURCE_REGISTRAR → Endpoint (so it can call ResourceManager.registerResourceId)
            { name: 'GrantResourceRegistrarEndpoint', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantRole', args: [resourceRegistrarRoleId, addresses.endpointAddress, 0] },
            // RESOURCE_REGISTRAR → TokenCore (so activateToken can call endpoint.registerResourceId)
            { name: 'GrantResourceRegistrarTokenCore', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'grantRole', args: [resourceRegistrarRoleId, addresses.tokenCoreAddress, 0] },
        ], nonceManager, hre);

        // ── Step 3: setRoleAdmin ──
        // ENDPOINT_SENDER admin → FACTORY_ADMIN (factories grant it at runtime to deployed tokens).
        // Must be LAST for ENDPOINT_SENDER because deployer loses ability to grant it after this.
        await executeConfigWithNonce(
            { name: 'SetEPSenderAdmin', contractName: 'RaylsAccessManagerV1', address: managerAddr, method: 'setRoleAdmin', args: [endpointSenderRoleId, factoryAdminRoleId] },
            nonceManager.allocateNonce(), hre
        );


        console.log('✅ AUTH-V3 setup complete\n');

        // -------------------------------------------------------------------------
        // REGISTER STANDARD BYTECODES ON THE PN FACTORY
        // setBytecode is `restricted`; the deployer can call it because it holds ADMIN_ROLE (role 0),
        // which bypasses the role check (it is NOT itself a FACTORY_ADMIN member — that role is
        // granted to the factory/replica contracts for runtime ENDPOINT_SENDER grants). Must run
        // after the factory proxy is deployed. Records the RUNTIME bytecode of
        // each token-standard handler keyed by its well-known *_KEY constant, so FACTORY-mode
        // deploys (ResourceDeployType.FACTORY) succeed and every instance of a standard shares an
        // identical extcodehash — letting a single seeded PNH template cover all instances.
        // -------------------------------------------------------------------------
        console.log('\n🧬 Registering standard bytecodes on RNContractFactory...');
        {
            const rnFactory = await hre.ethers.getContractAt('RNContractFactoryV1', addresses.raylsNodeContractFactoryAddress, deployer);

            // The *Handler SDK bases are `abstract` and compile to empty bytecode, so they cannot
            // be seeded directly — the factory deploys RUNTIME bytecode via InitCodeStub, so the
            // artifact must be a concrete, deployable subclass. Point each standard at its
            // production example contract (src/rayls-protocol/prod-example-contracts/), whose
            // runtime carries ONLY the canonical `initialize` + handler surface. These deliberately
            // replace the test-contracts/ examples, which expose test-only public surfaces (e.g.
            // RaylsErc721Example.awardItem was an unrestricted public mint) that must never reach
            // deployed instances.
            const standards: { label: string; keyFn: string; artifact: string }[] = [
                { label: 'Enygma',     keyFn: 'RAYLS_ENYGMA_KEY',      artifact: 'ProductionEnygmaToken' },
                { label: 'ERC20',      keyFn: 'RAYLS_ERC20_KEY',       artifact: 'ProductionErc20Token' },
                { label: 'ERC721',     keyFn: 'RAYLS_ERC721_KEY',      artifact: 'ProductionErc721Token' },
                { label: 'ERC1155',    keyFn: 'RAYLS_ERC1155_KEY',     artifact: 'ProductionErc1155Token' },
                { label: 'ERC721Dvp',  keyFn: 'RAYLS_ERC721_DVP_KEY',  artifact: 'ProductionErc721Dvp' },
                { label: 'ERC1155Dvp', keyFn: 'RAYLS_ERC1155_DVP_KEY', artifact: 'ProductionErc1155Dvp' },
                { label: 'StableCoin', keyFn: 'RAYLS_STABLECOIN_KEY',  artifact: 'ProductionStableCoin' },
                // Test-only variants: same standard surface as above, but seeded with the *Example
                // runtime under a dedicated *_TEST_KEY. FACTORY-mode deploys of an ErcStandard.*Test
                // token resolve here (see ResourceManager._keyForTemplate), giving tests the example
                // surfaces (addressToFail, receiveTeleportAtomic revert, receiveMsgA). Never selected
                // by a normal deploy.
                { label: 'ERC20Test',      keyFn: 'RAYLS_ERC20_TEST_KEY',       artifact: 'TokenExample' },
                { label: 'ERC721Test',     keyFn: 'RAYLS_ERC721_TEST_KEY',      artifact: 'RaylsErc721Example' },
                { label: 'ERC1155Test',    keyFn: 'RAYLS_ERC1155_TEST_KEY',     artifact: 'RaylsErc1155Example' },
                { label: 'EnygmaTest',     keyFn: 'RAYLS_ENYGMA_TEST_KEY',      artifact: 'EnygmaTokenExample' },
                { label: 'ERC721DvpTest',  keyFn: 'RAYLS_ERC721_DVP_TEST_KEY',  artifact: 'Erc721DvpExample' },
                { label: 'ERC1155DvpTest', keyFn: 'RAYLS_ERC1155_DVP_TEST_KEY', artifact: 'Erc1155DvpExample' },
            ];

            for (const s of standards) {
                const keyGetter = (rnFactory as any)[s.keyFn];
                if (typeof keyGetter !== 'function') {
                    throw new Error(`RNContractFactoryV1 has no key getter '${s.keyFn}' — check the standards table.`);
                }
                const key = await keyGetter();
                const artifact = await hre.artifacts.readArtifact(s.artifact);
                const runtime = artifact.deployedBytecode;       // RUNTIME bytecode, not init
                // Guard: an abstract/interface artifact compiles to '0x'. Seeding empty bytecode
                // silently breaks every FACTORY-mode deploy (FactoryV1__BytecodeNotRegistered) and
                // the downstream PNH template seeding (getBytecodeHash returns 0). Fail loudly here.
                if (!runtime || runtime === '0x') {
                    throw new Error(`Artifact '${s.artifact}' has empty deployedBytecode — cannot seed ${s.keyFn}. It is likely abstract; point the standards table at a concrete subclass.`);
                }
                await executeConfigWithNonce(
                    { name: `SetBytecode${s.label}`, contractName: 'RNContractFactoryV1', address: addresses.raylsNodeContractFactoryAddress, method: 'setBytecode', args: [key, runtime] },
                    nonceManager.allocateNonce(), hre
                );
                // runtime is a 0x-prefixed hex string: drop the 2 prefix chars, 2 chars per byte.
                const runtimeBytes = (runtime.length - 2) / 2;
                console.log(`  ✓ setBytecode(${s.keyFn}=${key})  runtime ${runtimeBytes} bytes`);
            }
        }

        // -------------------------------------------------------------------------
        // REGISTER RESOURCE IDs (AFTER ROLE SETUP - EndpointV1 needs ENDPOINT_SENDER_ROLE
        // to call ResourceManager.registerResourceId which is restricted)
        // -------------------------------------------------------------------------
        console.log('\n🔐 Registering resource IDs for deployed contracts...');

        const RESOURCE_ID_PARTICIPANT_STORAGE = '0x0000000000000000000000000000000000000000000000000000000000000001';
        const RESOURCE_ID_ENYGMA_PN_EVENTS = '0x0000000000000000000000000000000000000000000000000000000000000002';
        const RESOURCE_ID_TOKEN_REGISTRY = '0x0000000000000000000000000000000000000000000000000000000000000003';
        const RESOURCE_ID_PN_COMMUNICATOR = '0x0000000000000000000000000000000000000000000000000000000000000005';
        const RESOURCE_ID_TEMPLATE_REGISTRY = '0x0000000000000000000000000000000000000000000000000000000000000006';

        console.log(`→ Registering resource IDs for:`);
        console.log(`   - ParticipantStorageReplicaV1: ${addresses.participantStorageAddress} (${RESOURCE_ID_PARTICIPANT_STORAGE})`);
        console.log(`   - TokenRegistryV1: ${addresses.tokenRegistryAddress} (${RESOURCE_ID_TOKEN_REGISTRY})`);
        console.log(`   - EnygmaPNEvents: ${addresses.enygmaPNEventsAddress} (${RESOURCE_ID_ENYGMA_PN_EVENTS})`);
        if (!hubless) {
            console.log(`   - PNCommunicatorV1: ${addresses.raylsCommunicatorAddress} (${RESOURCE_ID_PN_COMMUNICATOR})`);
            console.log(`   - TemplateRegistryReplicaV1: ${addresses.templateRegistryReplicaAddress} (${RESOURCE_ID_TEMPLATE_REGISTRY})`);
        }

        await executeBatchConfig([
            {
                name: 'RegisterResourceId_ParticipantStorageReplica',
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
            ...(!hubless ? [
                {
                    name: 'RegisterResourceId_PNCommunicator',
                    contractName: 'EndpointV1',
                    address: addresses.endpointAddress,
                    method: 'registerResourceId',
                    args: [RESOURCE_ID_PN_COMMUNICATOR, addresses.raylsCommunicatorAddress]
                },
            ] : []),
            {
                name: 'RegisterResourceId_EnygmaPNEvents',
                contractName: 'EndpointV1',
                address: addresses.endpointAddress,
                method: 'registerResourceId',
                args: [RESOURCE_ID_ENYGMA_PN_EVENTS, addresses.enygmaPNEventsAddress]
            },
            ...(!hubless ? [
                {
                    name: 'RegisterResourceId_TemplateRegistryReplica',
                    contractName: 'EndpointV1',
                    address: addresses.endpointAddress,
                    method: 'registerResourceId',
                    args: [RESOURCE_ID_TEMPLATE_REGISTRY, addresses.templateRegistryReplicaAddress]
                }
            ] : [])
        ], nonceManager, hre);

        const endpointContract = await hre.ethers.getContractAt('EndpointV1', addresses.endpointAddress, deployer);
        const tokenRegistryFromResourceId = await endpointContract.getAddressByResourceId(RESOURCE_ID_TOKEN_REGISTRY);
        if (tokenRegistryFromResourceId.toLowerCase() !== addresses.tokenRegistryAddress.toLowerCase()) {
            throw new Error(`RESOURCE_ID_TOKEN_REGISTRY lookup mismatch: expected ${addresses.tokenRegistryAddress}, got ${tokenRegistryFromResourceId}`);
        }
        console.log(`  ✓ TokenRegistryV1 reachable via RESOURCE_ID_TOKEN_REGISTRY: ${tokenRegistryFromResourceId}`);

        console.log('✅ All resource IDs registered successfully\n');

        // Synchronization with Private Hub (skipped in hub-less mode).
        let startingBlock: number;
        if (hubless) {
            console.log('\n📋 STEP 4: SYNCHRONIZING WITH PRIVATE HUB — skipped (hub-less mode)');
            startingBlock = await ethers.provider.getBlockNumber();
        } else {
            console.log('\n📋 STEP 4: SYNCHRONIZING WITH PRIVATE HUB');
            startingBlock = await synchronizeWithPrivateHub(hre, addresses, deployer, pnhDeploymentRegistryAddress);
        }

        // Register all contracts
        console.log('\n📋 STEP 5: REGISTERING CONTRACTS');
        await registerAllContracts(hre, addresses, deployer, managerAddr, hubless);

        console.log(`PN_ACCESS_MANAGER_ADDRESS=${managerAddr}`);
        console.log(`PRIVACY_NODE_${taskArgs.privacyNode}_ACCESS_MANAGER_ADDRESS=${managerAddr}`);
        console.log(`PRIVACY_NODE_${taskArgs.privacyNode}_ACCESS_MANAGER_STARTING_BLOCK=${accessManagerStartingBlock}`);

        // Print deployment summary
        console.log('\n📋 DEPLOYMENT SUMMARY');
        console.log('===========================================')
        console.log('✅ CONTRACTS DEPLOYED SUCCESSFULLY');
        console.log('===========================================')
        console.log('👉 Contract Addresses 👈');
        console.log(`PN_ENDPOINT: ${addresses.endpointAddress}`);
        console.log(`RAYLS_CONTRACT_FACTORY: ${addresses.contractFactoryAddress}`);
        console.log(`PARTICIPANT_STORAGE_REPLICA: ${addresses.participantStorageAddress}`);
        console.log(`ENYGMA_PN_EVENTS: ${addresses.enygmaPNEventsAddress}`);
        console.log(`RESOURCE_MANAGER: ${addresses.resourceManagerAddress}`);
        if (!hubless) {
            console.log(`RAYLS_MESSAGE_EXECUTOR: ${addresses.messageExecutorAddress}`);
            console.log(`RAYLS_COMMUNICATOR: ${addresses.raylsCommunicatorAddress}`);
            console.log(`MESSAGE_SENDER: ${addresses.messageSenderAddress}`);
            console.log(`MESSAGE_RECEIVER: ${addresses.messageReceiverAddress}`);
            console.log(`BATCH_MESSAGE_SENDER: ${addresses.batchMessageSenderAddress}`);
            console.log(`PROGRAMMABILITY_EXECUTOR: ${addresses.programmabilityExecutorAddress}`);
        }
        console.log(`RAYLS_NODE_USER_GOVERNANCE: ${addresses.raylsNodeUserGovernanceAddress}`);
        console.log(`RAYLS_NODE_ENDPOINT: ${addresses.raylsNodeEndpointAddress}`);
        console.log(`RAYLS_NODE_MESSAGE_EXECUTOR: ${addresses.raylsNodeMessageExecutorAddress}`);
        console.log(`RAYLS_NODE_MESSAGE_DISPATCHER: ${addresses.raylsNodeMessageDispatcherAddress}`);
        console.log(`RAYLS_NODE_CONTRACT_FACTORY: ${addresses.raylsNodeContractFactoryAddress}`);
        console.log(`TOKEN_REGISTRY: ${addresses.tokenRegistryAddress}`);
        console.log(`TOKEN_CORE: ${addresses.tokenCoreAddress}`);
        console.log(`TOKEN_FREEZE_MANAGER: ${addresses.tokenFreezeManagerAddress}`);
        console.log('-------------------------------------------');

        const totalTime = ((Date.now() - overallStartTime) / 1000).toFixed(2);
        console.log('\n' + '='.repeat(80));
        console.log(`✅✅✅ PN-${taskArgs.privacyNode} DEPLOYMENT COMPLETE IN ${totalTime} SECONDS ✅✅✅`);
        console.log('='.repeat(80));

        // Print configuration
        printDeploymentConfig(addresses, taskArgs.privacyNode, startingBlock, managerAddr);
    });

async function configureContracts(nonceManager: NonceManager, hre: any, addresses: any, deployer: Wallet, _managerAddr: string) {
    console.log('  ⚙️  Configuring all contracts...');

    // Configure all contracts in parallel (they're independent)
    await Promise.all([
        executeConfigWithNonce({
            name: 'ConfigureEndpoint',
            contractName: 'EndpointV1',
            address: addresses.endpointAddress,
            method: 'configureEndpoint',
            args: [
                addresses.contractFactoryAddress,
                addresses.participantStorageAddress,
                addresses.tokenRegistryAddress,
                addresses.resourceManagerAddress,
                // Hub-connected messaging modules: real addresses in hub-full mode, ZeroAddress
                // in hubless mode (cross-chain messaging via the Endpoint is then disabled).
                addresses.messageSenderAddress ?? hre.ethers.ZeroAddress,
                addresses.messageReceiverAddress ?? hre.ethers.ZeroAddress,
                addresses.batchMessageSenderAddress ?? hre.ethers.ZeroAddress
            ]
        }, nonceManager.allocateNonce(), hre),

        // Decommissioning Teleport (vanilla, atomic).
        executeConfigWithNonce({
            name: 'ConfigureRNEndpoint',
            contractName: 'RNEndpointV1',
            address: addresses.raylsNodeEndpointAddress,
            method: 'configureContracts',
            args: [
                addresses.raylsNodeMessageExecutorAddress,
                // RNEndpointV1 consumes the PN TokenRegistryV1 facade for token status
                // and public-chain address resolution.
                addresses.tokenRegistryAddress,
                addresses.raylsNodeUserGovernanceAddress,
                addresses.raylsNodeMessageDispatcherAddress
            ]
        }, nonceManager.allocateNonce(), hre),

        // Decommissioning Teleport (vanilla, atomic).
        executeConfigWithNonce({
            name: 'SetRNDispatcherAuth',
            contractName: 'RNMessageDispatcherV1',
            address: addresses.raylsNodeMessageDispatcherAddress,
            method: 'setAuthorizedEndpoint',
            args: [addresses.raylsNodeEndpointAddress]
        }, nonceManager.allocateNonce(), hre),

        // Decommissioning Teleport (vanilla, atomic).
        executeConfigWithNonce({
            name: 'SetRNExecutorAuth',
            contractName: 'RNMessageExecutorV1',
            address: addresses.raylsNodeMessageExecutorAddress,
            method: 'setAuthorizedEndpoint',
            args: [addresses.raylsNodeEndpointAddress]
        }, nonceManager.allocateNonce(), hre),

        // NOTE: SetResourceManagerEndpoint is called early in privacy-node-batches.ts right after ResourceManager deployment
    ]);

    await nonceManager.sync();
    console.log('  ✅ All contracts configured successfully');
}

async function synchronizeWithPrivateHub(hre: any, addresses: any, deployer: Wallet, pnhDeploymentRegistryAddress: string): Promise<number> {
    console.log('  → Synchronizing participant data from Private Hub...');
    const psrContract = await hre.ethers.getContractAt('ParticipantStorageReplicaV1', addresses.participantStorageAddress, deployer);

    const syncTx = await psrContract.requestAllParticipantsDataFromPrivateHub();
    const receipt = await syncTx.wait();

    if (!receipt || !receipt.blockNumber) {
        throw new Error('Failed to retrieve the transaction receipt or block number.');
    }
    console.log('  ✅ Participant data synchronization complete.');

    console.log('  → Synchronizing frozen tokens from Private Hub...');
    // Resolve the PN TokenRegistryV1 explicitly; the PNH registry has the same
    // simple contract name and a different ABI.
    const tokenRegistryContract = await getContractAtForArtifactRef(
        { contractName: 'PNTokenRegistryV1', artifactPath: PN_TOKEN_REGISTRY_ARTIFACT, artifactSourceName: PN_TOKEN_REGISTRY_SOURCE },
        hre,
        addresses.tokenRegistryAddress,
        deployer
    );

    const syncTrrTx = await tokenRegistryContract.requestAllFrozenTokensDataFromPrivateHub();
    const receiptTrr = await syncTrrTx.wait();

    if (!receiptTrr || !receiptTrr.blockNumber || receiptTrr.status !== 1) {
        throw new Error('Failed to retrieve the transaction receipt or block number from TokenRegistryV1 requestAllFrozenTokensDataFromPrivateHub call');
    }
    console.log('  ✅ Frozen tokens synchronization complete.');

    console.log('  → Getting TokenRegistry from Private Hub...');
    const rpcUrlPNH = process.env['PNH_RPC_URL'] as string;
    const providerPNH = new hre.ethers.JsonRpcProvider(rpcUrlPNH);
    const signerPNH = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string).connect(providerPNH);

    const pnhDeploymentRegistry = await hre.ethers.getContractAt('DeploymentProxyRegistryV1', pnhDeploymentRegistryAddress, signerPNH);
    const tokenRegistryAddress = await pnhDeploymentRegistry.getContract('TokenRegistry');
    const dvpTeleportAddress = await pnhDeploymentRegistry.getContract('DvpTeleport');

    console.log('  → Registering Token Registry in EndpointV1...');
    const endpointContract = await hre.ethers.getContractAt('EndpointV1', addresses.endpointAddress, deployer);
    const tx1 = await endpointContract.registerPrivateHubAddress('TokenRegistry', tokenRegistryAddress);
    await tx1.wait();
    console.log('  ✅ Token Registry registered successfully.');

    console.log('→ Registering Dvp Teleport in EndpointV1...');
    const dvpTeleportCCaddressTx = await endpointContract.registerPrivateHubAddress('DvpTeleport', dvpTeleportAddress);
    await dvpTeleportCCaddressTx.wait(2);
    console.log('✅ Dvp Teleport registered successfully.');


    return receipt.blockNumber;
}

async function registerAllContracts(hre: any, addresses: any, deployer: Wallet, managerAddr: string, hubless: boolean) {
    console.log('  → Registering all contract addresses...');
    const deploymentRegistry = await hre.ethers.getContractAt('DeploymentProxyRegistryV1', addresses.deploymentProxyRegistryAddress, deployer);

    // Hub-only contracts (MessageExecutor, PNCommunicator, TemplateRegistryReplica,
    // MessageSender/Receiver/BatchMessageSender, ProgrammabilityExecutor) are registered
    // only in hub-full mode. names[] and addressArray[] MUST stay index-aligned, so the
    // hub-only entries are spread into BOTH arrays at the same positions.
    const names = [
        'RaylsAccessManager',
        ...(!hubless ? ['MessageExecutor'] : []),
        'Endpoint',
        'ContractFactory',
        'EnygmaPNEvents',
        'ParticipantStorage',
        'TokenRegistry',
        'TokenCore',
        'TokenFreezeManager',
        ...(!hubless ? ['PNCommunicator', 'TemplateRegistryReplica'] : []),
        'ResourceManager',
        ...(!hubless ? ['MessageSender', 'MessageReceiver', 'BatchMessageSender'] : []),
        'RNUserGovernance',
        'RNEndpoint',
        'RNMessageExecutor',
        'RNMessageDispatcher',
        'RNContractFactory',
        ...(!hubless ? ['ProgrammabilityExecutor'] : [])
    ];

    const addressArray = [
        managerAddr,
        ...(!hubless ? [addresses.messageExecutorAddress] : []),
        addresses.endpointAddress,
        addresses.contractFactoryAddress,
        addresses.enygmaPNEventsAddress,
        addresses.participantStorageAddress,
        addresses.tokenRegistryAddress,
        addresses.tokenCoreAddress,
        addresses.tokenFreezeManagerAddress,
        ...(!hubless ? [addresses.raylsCommunicatorAddress, addresses.templateRegistryReplicaAddress] : []),
        addresses.resourceManagerAddress,
        ...(!hubless ? [addresses.messageSenderAddress, addresses.messageReceiverAddress, addresses.batchMessageSenderAddress] : []),
        addresses.raylsNodeUserGovernanceAddress,
        addresses.raylsNodeEndpointAddress,
        addresses.raylsNodeMessageExecutorAddress,
        addresses.raylsNodeMessageDispatcherAddress,
        addresses.raylsNodeContractFactoryAddress,
        ...(!hubless ? [addresses.programmabilityExecutorAddress] : [])
    ];

    const tx = await deploymentRegistry.registerContracts(names, addressArray, { gasLimit: 5000000 });
    await tx.wait();

    console.log('  ✅ All contracts registered in DeploymentProxyRegistry');
}

function printDeploymentConfig(addresses: any, privacyNode: string, startingBlock: number, accessManagerAddress: string) {
    console.log('\n👉👉👉👉 Relayer Configuration 👈👈👈👈');
    console.log('-------------------------------------------');
    console.log(`PRIVACY_NODE_STARTING_BLOCK=${startingBlock}`);
    console.log(`PRIVACY_NODE_EXECUTOR_BATCH_MESSAGES=500`);
    console.log(`PRIVACY_NODE_EXECUTOR_ENYGMA_BATCH_MESSAGES=1000`);
    console.log(`PRIVACY_NODE_LISTENER_BATCH_BLOCKS=50`);
    console.log(`PRIVACY_NODE_DEPLOYMENT_PROXY_REGISTRY=${addresses.deploymentProxyRegistryAddress}`);
    console.log('-------------------------------------------');
    console.log(`PRIVACY_NODE_${privacyNode}_DEPLOYMENT_PROXY_REGISTRY=${addresses.deploymentProxyRegistryAddress}`);
    console.log(`PRIVACY_NODE_${privacyNode}_STARTING_BLOCK=${startingBlock}`);
    console.log(`PRIVACY_NODE_${privacyNode}_ENDPOINT_ADDRESS=${addresses.endpointAddress}`);
    console.log(`PRIVACY_NODE_${privacyNode}_RAYLS_NODE_ENDPOINT_ADDRESS=${addresses.raylsNodeEndpointAddress}`);
    console.log(`PRIVACY_NODE_${privacyNode}_RAYLS_NODE_USER_GOVERNANCE=${addresses.raylsNodeUserGovernanceAddress}`);
    console.log(`PRIVACY_NODE_${privacyNode}_TOKEN_REGISTRY_ADDRESS=${addresses.tokenRegistryAddress}`);
    console.log(`PRIVACY_NODE_${privacyNode}_TOKEN_CORE_ADDRESS=${addresses.tokenCoreAddress}`);
    console.log(`PRIVACY_NODE_${privacyNode}_TOKEN_FREEZE_MANAGER_ADDRESS=${addresses.tokenFreezeManagerAddress}`);
    console.log(`PRIVACY_NODE_${privacyNode}_RAYLS_NODE_CONTRACT_FACTORY=${addresses.raylsNodeContractFactoryAddress}`);
    console.log(`PRIVACY_NODE_${privacyNode}_ACCESS_MANAGER_ADDRESS=${accessManagerAddress}`);
    console.log(`RAYLS_NODE_MESSAGE_DISPATCHER: ${addresses.raylsNodeMessageDispatcherAddress}`);
    console.log('\n-------------------------------------------');
    console.log('✅ PRIVACY NODE DEPLOYMENT COMPLETED SUCCESSFULLY');
    console.log('-------------------------------------------');
}
