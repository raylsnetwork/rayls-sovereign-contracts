/**
 * @deprecated Decommissioning Teleport (vanilla, atomic).
 */
import '@nomicfoundation/hardhat-ethers';
import { task } from 'hardhat/config';
import { Wallet } from 'ethers';
import { NonceManager, executeConfigWithNonce, deployBatch, DeploymentTask } from './batch-helpers';
import { ManifestManager } from './manifest-manager';

task('deploy:public-chain', 'Deploys the Rayls Node contracts to the public chain')
    .setAction(async (taskArgs, hre) => {
        const overallStartTime = Date.now();
        console.log('🚀🚀🚀 FAST BATCH DEPLOYMENT STARTED (PUBLIC CHAIN) 🚀🚀🚀');
        console.log('='.repeat(80));

        const { ethers } = hre;
        const chainId = (await ethers.provider.getNetwork()).chainId;

        console.log(`📋 NETWORK: ${hre.network.name}`);
        console.log(`📋 CHAIN ID: ${chainId}`);

        // Check for existing deployments - BLOCK if found
        const participantName = process.env.PARTICIPANT_NAME || undefined;
        const manifest = new ManifestManager('.openzeppelin', participantName);
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

        const signer = await hre.ethers.provider.getSigner();
        const initialOwner = signer.address;
        const deployer = signer as any as Wallet;
        console.log(`→ Deployer Address: ${initialOwner}`);

        const nonceManager = new NonceManager(hre.ethers.provider, initialOwner);
        await nonceManager.initialize();
        console.log(`📊 NonceManager initialized with starting nonce: ${await nonceManager.getCurrentNonce()}`);

        // STEP 1: Deploy all contracts in parallel
        console.log('\n📋 STEP 1: DEPLOYING CONTRACTS IN BATCH');
        const addresses = await deployAllContracts(nonceManager, hre, initialOwner, chainId.toString());

        // STEP 2: Configure contracts in parallel
        console.log('\n📋 STEP 2: CONFIGURING CONTRACTS IN PARALLEL');
        const configBlockNumber = await configureContracts(nonceManager, hre, addresses, deployer);

        // STEP 3: Register contracts
        console.log('\n📋 STEP 3: REGISTERING CONTRACTS');
        await registerProxyAddresses(
            addresses,
            addresses.deploymentProxyRegistryAddress,
            ethers
        );

        // Print summary
        console.log('\n📋 DEPLOYMENT SUMMARY');
        console.log('===========================================')
        console.log('✅ CONTRACTS DEPLOYED SUCCESSFULLY');
        console.log('===========================================')
        console.log('👉 Public Chain Contract Addresses 👈');
        console.log(`DEPLOYMENT_PROXY_REGISTRY: ${addresses.deploymentProxyRegistryAddress}`);
        console.log(`RAYLS_ACCESS_MANAGER: ${addresses.accessManagerAddress}`);
        console.log(`PUBLIC_RN_ENDPOINT: ${addresses.publicRaylsNodeEndpointAddress}`);
        console.log(`RN_MESSAGE_EXECUTOR: ${addresses.raylsNodeMessageExecutorAddress}`);
        console.log(`RN_MESSAGE_DISPATCHER: ${addresses.raylsNodeMessageDispatcherAddress}`);
        console.log('-------------------------------------------');

        const participantInfo = process.env.PARTICIPANT_NAME ? ` (Participant ${process.env.PARTICIPANT_NAME}${process.env.NODE_PN_CHAIN_ID ? `, PN Chain ID: ${process.env.NODE_PN_CHAIN_ID}` : ''})` : '';
        const totalTime = ((Date.now() - overallStartTime) / 1000).toFixed(2);
        console.log('\n' + '='.repeat(80));
        console.log(`✅✅✅ PUBLIC CHAIN DEPLOYMENT COMPLETE IN ${totalTime} SECONDS${participantInfo} ✅✅✅`);
        console.log('='.repeat(80));

        console.log('\n👉👉👉👉 Configuration Output 👈👈👈👈');
        console.log('-------------------------------------------');
        console.log(`PUBLIC_CHAIN_DEPLOYMENT_PROXY_REGISTRY=${addresses.deploymentProxyRegistryAddress}`);
        console.log(`PC_PUBLIC_RN_ENDPOINT=${addresses.publicRaylsNodeEndpointAddress}`);
        console.log(`PC_RAYLS_ACCESS_MANAGER=${addresses.accessManagerAddress}`);
        console.log(`PC_RN_MESSAGE_EXECUTOR=${addresses.raylsNodeMessageExecutorAddress}`);
        console.log(`PC_RN_MESSAGE_DISPATCHER=${addresses.raylsNodeMessageDispatcherAddress}`);
        console.log(`PUBLIC_CHAIN_STARTING_BLOCK=${configBlockNumber}`);
        console.log('-------------------------------------------');
        console.log('✅ PUBLIC CHAIN DEPLOYMENT COMPLETED SUCCESSFULLY');
        console.log('-------------------------------------------');
    });

// BATCH DEPLOYMENT FUNCTIONS

async function deployAllContracts(nonceManager: NonceManager, hre: any, initialOwner: string, chainId: string) {
    // Deploy AccessManager libraries first (stateless, no proxy needed).
    // AuthLib must deploy before ScheduleLib (library-to-library dependency).
    console.log('  📦 Deploying AccessManager libraries...');
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

    // Deploy RaylsAccessManager — DeploymentProxyRegistry.initialize() needs its address (authority_)
    console.log('  📦 Deploying RaylsAccessManager...');
    const managerBatch = await deployBatch([
        {
            name: 'RaylsAccessManager',
            contractName: 'RaylsAccessManagerV1',
            isProxy: true,
            initArgs: [initialOwner],
            initializer: 'initialize(address)',
            libraries: amLibraries,
            validationOpts: { unsafeAllow: ['external-library-linking'] }
        }
    ], nonceManager, hre);
    const managerAddr = managerBatch[0].address;

    console.log('  📦 Deploying remaining 4 contracts in parallel...');
    const tasks: DeploymentTask[] = [
        {
            name: 'DeploymentProxyRegistry',
            contractName: 'DeploymentProxyRegistryV1',
            isProxy: true,
            initArgs: [managerAddr],
            initializer: 'initialize(address)',
            validationOpts: {}
        },
        {
            name: 'PublicRNEndpoint',
            contractName: 'PublicRNEndpointV1',
            isProxy: true,
            initArgs: [chainId, managerAddr],
            initializer: 'initialize(uint256,address)',
            validationOpts: {}
        },
        {
            name: 'RNMessageExecutor',
            contractName: 'RNMessageExecutorV1',
            isProxy: true,
            initArgs: [managerAddr],
            initializer: 'initialize(address)',
            validationOpts: {}
        },
        {
            name: 'RNMessageDispatcher',
            contractName: 'RNMessageDispatcherV1',
            isProxy: true,
            initArgs: [managerAddr],
            initializer: 'initialize(address)',
            validationOpts: {}
        }
    ];

    // Deploy remaining 4 contracts in parallel
    const batch = await deployBatch(tasks, nonceManager, hre);

    // -------------------------------------------------------------------------
    // TOKEN FACTORY STACK — lets ops-api deploy tokens (e.g. RAYLS_STABLECOIN)
    // on the public chain via RNContractFactory.deployRegistered.
    //
    // The factory's _buildTrustedInit calls endpoint.getUserGovernanceAddress(),
    // which PublicRNEndpointV1 does NOT implement — so the factory's `endpoint`
    // must be a full EndpointV1. raylsNodeEndpoint must be non-zero (init guards
    // it); a deployed-token stablecoin ignores it (no teleport on public chain),
    // so we reuse EndpointV1 as a harmless non-zero placeholder. RNUserGovernance
    // is wired into the endpoint (setUserGovernance) in configureContracts.
    // -------------------------------------------------------------------------
    console.log('  📦 Deploying token-factory stack (EndpointV1, RNUserGovernance)...');
    const factoryStack = await deployBatch([
        {
            name: 'Endpoint',
            contractName: 'EndpointV1',
            isProxy: true,
            // (chainId, privateHubId, maxBatchMessages, authority). No PNH on the public
            // chain — privateHubId is unused by the stablecoin deploy path; pass chainId.
            initArgs: [chainId, chainId, '500', managerAddr],
            initializer: 'initialize(uint256,uint256,uint256,address)',
            validationOpts: {}
        },
        {
            name: 'RNUserGovernance',
            contractName: 'RNUserGovernanceV1',
            isProxy: true,
            initArgs: [managerAddr],
            initializer: 'initialize(address)',
            validationOpts: {}
        }
    ], nonceManager, hre);
    const endpointAddr = factoryStack[0].address;
    const userGovernanceAddr = factoryStack[1].address;

    console.log('  📦 Deploying RNContractFactory...');
    const factoryBatch = await deployBatch([
        {
            name: 'RNContractFactory',
            contractName: 'RNContractFactoryV1',
            isProxy: true,
            initArgs: [endpointAddr, endpointAddr, initialOwner, managerAddr],
            initializer: 'initialize(address,address,address,address)',
            validationOpts: {}
        }
    ], nonceManager, hre);
    const contractFactoryAddr = factoryBatch[0].address;

    return {
        deploymentProxyRegistryAddress: batch[0].address,
        accessManagerAddress: managerAddr,
        publicRaylsNodeEndpointAddress: batch[1].address,
        raylsNodeMessageExecutorAddress: batch[2].address,
        raylsNodeMessageDispatcherAddress: batch[3].address,
        endpointAddress: endpointAddr,
        userGovernanceAddress: userGovernanceAddr,
        contractFactoryAddress: contractFactoryAddr
    };
}

async function configureContracts(nonceManager: NonceManager, hre: any, addresses: any, deployer: Wallet): Promise<number> {
    console.log('  ⚙️  Configuring all contracts in parallel...');

    // OPTIMIZATION: Run all 3 configurations in parallel
    const results = await Promise.all([
        executeConfigWithNonce({
            name: 'ConfigurePublicRNEndpoint',
            contractName: 'PublicRNEndpointV1',
            address: addresses.publicRaylsNodeEndpointAddress,
            method: 'configureContracts',
            args: [
                addresses.raylsNodeMessageExecutorAddress,
                addresses.raylsNodeMessageDispatcherAddress
            ]
        }, nonceManager.allocateNonce(), hre),

        executeConfigWithNonce({
            name: 'SetRNDispatcherAuth',
            contractName: 'RNMessageDispatcherV1',
            address: addresses.raylsNodeMessageDispatcherAddress,
            method: 'setAuthorizedEndpoint',
            args: [addresses.publicRaylsNodeEndpointAddress]
        }, nonceManager.allocateNonce(), hre),

        executeConfigWithNonce({
            name: 'SetRNExecutorAuth',
            contractName: 'RNMessageExecutorV1',
            address: addresses.raylsNodeMessageExecutorAddress,
            method: 'setAuthorizedEndpoint',
            args: [addresses.publicRaylsNodeEndpointAddress]
        }, nonceManager.allocateNonce(), hre)
    ]);

    await nonceManager.sync();
    console.log('  ✅ All contracts configured successfully');

    // -------------------------------------------------------------------------
    // AUTH-V3: Register roles and map selectors
    // -------------------------------------------------------------------------
    console.log('\n🔐 Setting up AUTH-V3 roles for PublicRNEndpoint access...');

    // 2. Register roles on the access manager
    const managerContract = await hre.ethers.getContractAt('RaylsAccessManagerV1', addresses.accessManagerAddress);

    await (await managerContract['registerRole(string)']('RELAYER')).wait();
    await (await managerContract['registerRole(string)']('AUTHORIZED_SENDER')).wait();
    await (await managerContract['registerRole(string)']('MESSAGE_EXECUTOR')).wait();

    const relayerRoleId = await managerContract.getRoleIdByName('RELAYER');
    const authorizedSenderRoleId = await managerContract.getRoleIdByName('AUTHORIZED_SENDER');
    const messageExecutorRoleId = await managerContract.getRoleIdByName('MESSAGE_EXECUTOR');

    // 3. Map selectors on PublicRNEndpointV1 to the corresponding roles
    const endpointFactory = await hre.ethers.getContractFactory('PublicRNEndpointV1');

    // receivePayload → RELAYER
    const receivePayloadSelectors = [
        endpointFactory.interface.getFunction('receivePayload').selector
    ];
    await (await managerContract.addFunctionAllowedRoles(
        addresses.publicRaylsNodeEndpointAddress, receivePayloadSelectors, [relayerRoleId]
    )).wait();

    // send / sendToAddress → AUTHORIZED_SENDER
    const senderSelectors = [
        endpointFactory.interface.getFunction('send').selector,
        endpointFactory.interface.getFunction('sendToAddress').selector
    ];
    await (await managerContract.addFunctionAllowedRoles(
        addresses.publicRaylsNodeEndpointAddress, senderSelectors, [authorizedSenderRoleId]
    )).wait();

    // Delegate AUTHORIZED_SENDER admin to RELAYER so the public relayer
    // can grant it to newly deployed token contracts at runtime.
    await (await managerContract.setRoleAdmin(authorizedSenderRoleId, relayerRoleId)).wait();

    // Grant MESSAGE_EXECUTOR to the RN MessageExecutor so it can call restricted
    // receive functions (receiveTeleportFromPrivacyNode etc.) on public chain tokens.
    await (await managerContract.grantRole(messageExecutorRoleId, addresses.raylsNodeMessageExecutorAddress, 0)).wait();

    console.log(`  ✓ RELAYER (${relayerRoleId}) registered`);
    console.log(`  ✓ AUTHORIZED_SENDER (${authorizedSenderRoleId}) registered, admin → RELAYER`);
    console.log(`  ✓ MESSAGE_EXECUTOR (${messageExecutorRoleId}) registered, granted to RN MessageExecutor`);
    console.log(`  ✓ receivePayload → RELAYER`);
    console.log(`  ✓ send, sendToAddress → AUTHORIZED_SENDER`);
    console.log('✅ AUTH-V3 role setup complete\n');

    // -------------------------------------------------------------------------
    // TOKEN FACTORY SETUP — make RNContractFactory.deployRegistered usable so
    // ops-api can deploy tokens (RAYLS_STABLECOIN) on the public chain.
    // -------------------------------------------------------------------------
    if (addresses.contractFactoryAddress) {
        console.log('🏭 Setting up token factory (endpoint wiring, FACTORY_DEPLOYER, bytecode seeding)...');

        // Wire the user-governance module into the endpoint. The factory's _buildTrustedInit
        // reads endpoint.getUserGovernanceAddress() on every deploy; without this it returns
        // address(0), which the handler's _initializeUserGovernance tolerates but we set it
        // properly so governance-aware paths resolve.
        const endpoint = await hre.ethers.getContractAt('EndpointV1', addresses.endpointAddress);
        await (await endpoint.setUserGovernance(addresses.userGovernanceAddress)).wait();

        // Register FACTORY_DEPLOYER and map the factory's deploy selectors to it. deployRegistered
        // is AccessManager-`restricted`; ops-api signs token deploys with the END USER's custody
        // wallet, so that wallet must hold FACTORY_DEPLOYER (granted at runtime via
        // `grant-business-role --role FACTORY_DEPLOYER --account <wallet>`). The bootstrap deployer
        // EOA is granted it here so the initial/admin flow can deploy immediately.
        await (await managerContract['registerRole(string)']('FACTORY_DEPLOYER')).wait();
        const factoryDeployerRoleId = await managerContract.getRoleIdByName('FACTORY_DEPLOYER');

        const rnFactory = await hre.ethers.getContractFactory('RNContractFactoryV1');
        const factoryDeploySelectors = [
            'deploy', 'deployRegistered', 'deployErc20', 'deployErc721', 'deployErc1155',
            'deployEnygma', 'deployErc721Dvp', 'deployErc1155Dvp', 'deployStableCoin', 'deployFromTeleport',
        ]
            .map((fn) => rnFactory.interface.getFunction(fn)?.selector)
            .filter((sel): sel is string => sel !== undefined);

        await (await managerContract.addFunctionAllowedRoles(
            addresses.contractFactoryAddress, factoryDeploySelectors, [factoryDeployerRoleId]
        )).wait();
        await (await managerContract.grantRole(factoryDeployerRoleId, deployer.address, 0)).wait();

        // Seed canonical token-standard runtime bytecodes so deployRegistered(key, …) works.
        // setBytecode is ADMIN-only; the deployer holds ADMIN_ROLE (role 0). The ops-api can deploy
        // any standard, so seed the full set — otherwise deployErc721/deployErc1155/… revert with
        // FactoryV1__BytecodeNotRegistered. Kept in sync with the privacy-node task's table.
        const rnFactoryContract = await hre.ethers.getContractAt('RNContractFactoryV1', addresses.contractFactoryAddress);
        const standards: { label: string; keyFn: string; artifact: string }[] = [
            { label: 'StableCoin', keyFn: 'RAYLS_STABLECOIN_KEY',  artifact: 'ProductionStableCoin' },
            { label: 'Enygma',     keyFn: 'RAYLS_ENYGMA_KEY',      artifact: 'ProductionEnygmaToken' },
            { label: 'ERC20',      keyFn: 'RAYLS_ERC20_KEY',       artifact: 'ProductionErc20Token' },
            { label: 'ERC721',     keyFn: 'RAYLS_ERC721_KEY',      artifact: 'ProductionErc721Token' },
            { label: 'ERC1155',    keyFn: 'RAYLS_ERC1155_KEY',     artifact: 'ProductionErc1155Token' },
            { label: 'ERC721Dvp',  keyFn: 'RAYLS_ERC721_DVP_KEY',  artifact: 'ProductionErc721Dvp' },
            { label: 'ERC1155Dvp', keyFn: 'RAYLS_ERC1155_DVP_KEY', artifact: 'ProductionErc1155Dvp' },
        ];
        for (const s of standards) {
            const key = await (rnFactoryContract as any)[s.keyFn]();
            const artifact = await hre.artifacts.readArtifact(s.artifact);
            const runtime = artifact.deployedBytecode;
            if (!runtime || runtime === '0x') {
                throw new Error(`Artifact '${s.artifact}' has empty deployedBytecode — cannot seed ${s.keyFn}.`);
            }
            await (await rnFactoryContract.setBytecode(key, runtime)).wait();
            console.log(`  ✓ setBytecode(${s.keyFn}) ${(runtime.length - 2) / 2} bytes`);
        }

        console.log(`  ✓ FACTORY_DEPLOYER (${factoryDeployerRoleId}) registered, mapped to factory deploys, granted to deployer`);
        console.log('✅ Token factory setup complete\n');
    }

    // Get block number from first config transaction
    const receipt = await hre.ethers.provider.getTransactionReceipt(results[0].txHash!);
    return receipt?.blockNumber || 0;
}

async function registerProxyAddresses(
    addresses: any,
    deploymentProxyRegistryAddress: string,
    ethers: any
): Promise<void> {
    console.log('  → Registering all contract addresses...');

    const names = [
        'RaylsAccessManager',
        'PublicRNEndpoint',
        'RNMessageExecutor',
        'RNMessageDispatcher'
    ];

    const addrs = [
        addresses.accessManagerAddress,
        addresses.publicRaylsNodeEndpointAddress,
        addresses.raylsNodeMessageExecutorAddress,
        addresses.raylsNodeMessageDispatcherAddress
    ];

    // Token-factory stack — registered so ops-api resolves "RNContractFactory" (token deploy)
    // and the business-roles task resolves "RNUserGovernance". Only present when the factory
    // stack was deployed (always, on the current public-chain path).
    if (addresses.contractFactoryAddress) {
        names.push('RNContractFactory', 'RNUserGovernance', 'Endpoint');
        addrs.push(addresses.contractFactoryAddress, addresses.userGovernanceAddress, addresses.endpointAddress);
    }

    const deploymentProxyRegistry = await ethers.getContractAt('DeploymentProxyRegistryV1', deploymentProxyRegistryAddress);

    const tx = await deploymentProxyRegistry.registerContracts(names, addrs, { gasLimit: 5000000 });
    await tx.wait();

    console.log('  ✅ All contracts registered in DeploymentProxyRegistry');
}