import { ethers } from 'ethers';
import { Artifact, HardhatRuntimeEnvironment } from 'hardhat/types';
import { validateImplementation, ValidationOptions } from './validation-helpers';
import { ManifestManager } from './manifest-manager';
import fs from 'fs';
import path from 'path';

/**
 * Manages nonce allocation for parallel transaction submission
 */
export class NonceManager {
  private nextNonce: number = 0;
  private provider: ethers.Provider;
  private address: string;

  constructor(provider: ethers.Provider, address: string) {
    this.provider = provider;
    this.address = address;
  }

  async initialize(): Promise<void> {
    this.nextNonce = await this.provider.getTransactionCount(this.address, 'pending');
    console.log(`📊 NonceManager initialized with starting nonce: ${this.nextNonce}`);
  }

  allocateNonce(): number {
    const nonce = this.nextNonce++;
    console.log(`  🎫 Allocated nonce: ${nonce}`);
    return nonce;
  }

  async sync(): Promise<void> {
    const chainNonce = await this.provider.getTransactionCount(this.address, 'pending');
    if (chainNonce > this.nextNonce) {
      console.log(`🔄 Syncing nonce: ${this.nextNonce} → ${chainNonce}`);
      this.nextNonce = chainNonce;
    }
  }

  getCurrentNonce(): number {
    return this.nextNonce;
  }
}

/**
 * Deployment task configuration
 */
export interface DeploymentTask {
  name: string;
  contractName: string;
  // Optional explicit artifact override for duplicated contract names. Use
  // artifactName for Hardhat FQNs and artifactPath for Forge-only artifacts.
  // Leave unset for unique contract names so the normal Hardhat lookup is used.
  artifactName?: string;
  artifactPath?: string;
  artifactSourceName?: string;
  isProxy: boolean;
  initArgs?: any[];
  initializer?: string;
  constructorArgs?: any[];
  libraries?: { [key: string]: string };
  validationOpts?: ValidationOptions;
}

/**
 * Configuration task
 */
export interface ConfigTask {
  name: string;
  contractName: string;
  // Optional explicit artifact override for duplicated contract names. Use
  // artifactName for Hardhat FQNs and artifactPath for Forge-only artifacts.
  // Leave unset for unique contract names so the normal Hardhat lookup is used.
  artifactName?: string;
  artifactPath?: string;
  artifactSourceName?: string;
  address: string;
  method: string;
  args: any[];
}

/**
 * Deployment result
 */
export interface DeploymentResult {
  name: string;
  address: string;
  txHash?: string;
  deploymentTime?: number;
}

/**
 * Configuration result
 */
export interface ConfigResult {
  name: string;
  success: boolean;
  txHash?: string;
}

/**
 * Retries an async operation on transient connection errors (socket closed, ECONNRESET, etc.).
 * Contract-level reverts are NOT retried — only network/transport failures.
 */
async function retryOnTransientError<T>(
  fn: () => Promise<T>,
  label: string,
  maxRetries: number = 3
): Promise<T> {
  for (let attempt = 0; ; attempt++) {
    try {
      return await fn();
    } catch (error: any) {
      const msg = error?.message ?? '';
      const isTransient =
        msg.includes('other side closed') ||
        msg.includes('ECONNRESET') ||
        msg.includes('ECONNREFUSED') ||
        msg.includes('ETIMEDOUT') ||
        msg.includes('socket hang up') ||
        msg.includes('network timeout') ||
        msg.includes('getaddrinfo');

      if (!isTransient || attempt >= maxRetries) {
        throw error;
      }

      const delay = 1000 * (attempt + 1);
      console.log(`    ⚠️  [${label}] Transient error (attempt ${attempt + 1}/${maxRetries}), retrying in ${delay}ms...`);
      await new Promise(resolve => setTimeout(resolve, delay));
    }
  }
}

export interface ExplicitArtifactRef {
  contractName: string;
  // Use exactly one override when the simple contract name is ambiguous.
  artifactName?: string;
  artifactPath?: string;
  artifactSourceName?: string;
}

function normalizeBytecode(rawBytecode: any): string {
  const bytecode = typeof rawBytecode === 'string' ? rawBytecode : rawBytecode?.object;
  if (!bytecode) {
    return '0x';
  }
  return bytecode.startsWith('0x') ? bytecode : `0x${bytecode}`;
}

function validateArtifactOverride(ref: ExplicitArtifactRef, label: string) {
  if (ref.artifactName && ref.artifactPath) {
    throw new Error(`${label} must use either artifactName or artifactPath, not both`);
  }
}

function loadForgeArtifact(ref: ExplicitArtifactRef): Artifact {
  if (!ref.artifactPath) {
    throw new Error(`Missing artifactPath for ${ref.contractName}`);
  }
  const absolutePath = path.resolve(process.cwd(), ref.artifactPath);
  const artifact = JSON.parse(fs.readFileSync(absolutePath, 'utf8'));
  return {
    _format: artifact._format ?? 'hh-sol-artifact-1',
    contractName: artifact.contractName ?? ref.contractName,
    sourceName: artifact.sourceName ?? ref.artifactSourceName ?? ref.artifactPath,
    abi: artifact.abi,
    bytecode: normalizeBytecode(artifact.bytecode),
    deployedBytecode: normalizeBytecode(artifact.deployedBytecode),
    linkReferences: artifact.linkReferences ?? artifact.bytecode?.linkReferences ?? {},
    deployedLinkReferences: artifact.deployedLinkReferences ?? artifact.deployedBytecode?.linkReferences ?? {},
  };
}

async function getExplicitArtifact(ref: ExplicitArtifactRef, hre: HardhatRuntimeEnvironment, label: string): Promise<Artifact | undefined> {
  validateArtifactOverride(ref, label);
  if (ref.artifactName) {
    return hre.artifacts.readArtifact(ref.artifactName);
  }
  if (ref.artifactPath) {
    return loadForgeArtifact(ref);
  }
  return undefined;
}

export async function getInterfaceForArtifactRef(ref: ExplicitArtifactRef, hre: HardhatRuntimeEnvironment): Promise<any> {
  const artifact = await getExplicitArtifact(ref, hre, ref.contractName);
  if (!artifact) {
    const factory = await hre.ethers.getContractFactory(ref.contractName);
    return factory.interface;
  }
  return new hre.ethers.Interface(artifact.abi);
}

export async function getContractAtForArtifactRef(
  ref: ExplicitArtifactRef,
  hre: HardhatRuntimeEnvironment,
  address: string,
  signer?: any
): Promise<any> {
  const artifact = await getExplicitArtifact(ref, hre, ref.contractName);
  if (!artifact) {
    return hre.ethers.getContractAt(ref.contractName, address, signer);
  }
  return hre.ethers.getContractAtFromArtifact(artifact, address, signer);
}

async function getFactoryForTask(task: DeploymentTask, hre: HardhatRuntimeEnvironment): Promise<any> {
  const artifact = await getExplicitArtifact(task, hre, task.name);
  if (!artifact) {
    return hre.ethers.getContractFactory(
      task.contractName,
      task.libraries ? { libraries: task.libraries } : undefined
    );
  }
  if (
    task.artifactPath &&
    task.libraries &&
    (!artifact.linkReferences || Object.keys(artifact.linkReferences).length === 0)
  ) {
    // Only reject when the Forge artifact carries no link references to resolve — otherwise
    // getContractFactoryFromArtifact links the provided libraries into the placeholder bytecode.
    throw new Error(`artifactPath deployment for ${task.name} declares libraries but its artifact has no linkReferences`);
  }
  if (artifact.bytecode === '0x') {
    throw new Error(`Missing bytecode in artifact for ${task.name}: ${task.artifactPath}`);
  }
  return hre.ethers.getContractFactoryFromArtifact(
    artifact,
    task.libraries ? { libraries: task.libraries } : undefined
  );
}

async function getContractForConfigTask(task: ConfigTask, hre: HardhatRuntimeEnvironment, signer: any): Promise<any> {
  const artifact = await getExplicitArtifact(task, hre, task.name);
  if (!artifact) {
    return hre.ethers.getContractAt(task.contractName, task.address, signer);
  }
  return hre.ethers.getContractAtFromArtifact(artifact, task.address, signer);
}

/**
 * Deploys a single contract with explicit nonce (regular contracts only)
 * For UUPS proxies, use deployProxyWithoutNonce instead
 */
export async function deployWithNonce(
  task: DeploymentTask,
  nonce: number,
  hre: HardhatRuntimeEnvironment,
  gasLimit: number = 16700000
): Promise<DeploymentResult> {
  const startTime = Date.now();
  console.log(`    [Nonce ${nonce}] 🚀 Deploying ${task.name}...`);

  try {
    const t0 = Date.now();
    const signer = await hre.ethers.provider.getSigner();
    const t1 = Date.now();
    const factory = await getFactoryForTask(task, hre);
    const t2 = Date.now();

    let address: string;
    let txHash: string | undefined;

    if (task.isProxy) {
      throw new Error(`UUPS proxies cannot use explicit nonce. Use deployProxyWithoutNonce for ${task.name}`);
    }

    // Regular contract deployment
    const contract = await factory.deploy(...(task.constructorArgs || []), {
      nonce,
      gasLimit
    });
    const t3 = Date.now();
    
    const deploymentTx = contract.deploymentTransaction();
    if (deploymentTx) {
      txHash = deploymentTx.hash;
    }
    await contract.waitForDeployment();
    const t4 = Date.now();
    
    address = await contract.getAddress();
    const t5 = Date.now();

    const deploymentTime = Date.now() - startTime;
    console.log(`    ✅ [Nonce ${nonce}] ${task.name} deployed to ${address} (${deploymentTime}ms)`);
    console.log(`       ⏱️  Breakdown: getSigner=${t1-t0}ms | getFactory=${t2-t1}ms | deploy=${t3-t2}ms | waitDeploy=${t4-t3}ms | getAddr=${t5-t4}ms`);

    return {
      name: task.name,
      address,
      txHash,
      deploymentTime
    };
  } catch (error: any) {
    if (error?.code === 'NONCE_EXPIRED') {
      const signer = await hre.ethers.provider.getSigner();
      const from = await signer.getAddress();
      const computed = hre.ethers.getCreateAddress({ from, nonce });
      console.log(`    ✓ [Nonce ${nonce}] ${task.name} already deployed at ${computed} (NONCE_EXPIRED on retry) — treating as success`);
      return { name: task.name, address: computed };
    }
    throw error;
  }
}

/**
 * Deploy UUPS proxy MANUALLY (faster than upgrades plugin for dev environments)
 * This skips all the validation overhead and does raw deployments
 * 
 * NOTE: You can enable validation by setting task.validationOpts
 */
export async function deployProxyWithoutNonce(
  task: DeploymentTask,
  hre: HardhatRuntimeEnvironment,
  gasLimit: number
): Promise<DeploymentResult> {
  const startTime = Date.now();
  console.log(`    🚀 Deploying UUPS proxy ${task.name}...`);

  try {
    const t0 = Date.now();
    
    // Optional validation (if enabled)
    if (task.validationOpts && !task.validationOpts.skipValidation) {
      const factory = await getFactoryForTask(task, hre);
      await validateImplementation(hre, factory, task.validationOpts, task.contractName);
    }
    const t0_5 = Date.now();
    
    // Get implementation factory
    const implFactory = await getFactoryForTask(task, hre);
    const t1 = task.validationOpts ? Date.now() : t0_5;
    
    // Deploy implementation
    const implContract = await implFactory.deploy({ gasLimit });
    await implContract.waitForDeployment();
    const implAddress = await implContract.getAddress();
    const t2 = Date.now();
    
    // Get proxy factory
    const proxyFactory = await hre.ethers.getContractFactory('RaylsERC1967Proxy');
    const t3 = Date.now();
    
    // Encode initializer call
    const initData = implFactory.interface.encodeFunctionData(
      task.initializer || 'initialize',
      task.initArgs || []
    );
    const t4 = Date.now();
    
    // Deploy proxy pointing to implementation
    const proxyContract = await proxyFactory.deploy(implAddress, initData, { gasLimit });
    await proxyContract.waitForDeployment();
    const proxyAddress = await proxyContract.getAddress();
    const t5 = Date.now();

    const deploymentTime = Date.now() - startTime;
    
    console.log(`    ✅ ${task.name} deployed to ${proxyAddress} (${deploymentTime}ms)`);
    const validationTime = task.validationOpts ? `validate=${t0_5-t0}ms | ` : '';
    console.log(`       ⏱️  Breakdown: ${validationTime}getImplFactory=${t1-(task.validationOpts ? t0_5 : t0)}ms | deployImpl=${t2-t1}ms | getProxyFactory=${t3-t2}ms | encodeInit=${t4-t3}ms | deployProxy=${t5-t4}ms`);

    // Record in manifest
    const participantName = process.env.PARTICIPANT_NAME || undefined;
    const manifest = new ManifestManager('.openzeppelin', participantName);
    const proxyTx = proxyContract.deploymentTransaction();
    const implTx = implContract.deploymentTransaction();
    if (proxyTx && implTx) {
      await manifest.recordProxy(hre, proxyAddress, proxyTx.hash, 'uups');
      await manifest.recordImplementation(hre, implAddress, implTx.hash, task.contractName);
    }

    return {
      name: task.name,
      address: proxyAddress,
      deploymentTime,
      txHash: proxyTx?.hash
    };
  } catch (error: any) {
    console.error(`    ❌ Failed to deploy ${task.name}:`, error.message);
    throw error;
  }
}

/**
 * Deploys a UUPS proxy manually with explicit nonce (PARALLEL-SAFE!)
 * Deploys implementation + proxy using RaylsERC1967Proxy
 * Waits for both deployments simultaneously for true parallelization
 */
async function deployManualProxy(
  task: DeploymentTask,
  nonce: number,
  hre: HardhatRuntimeEnvironment,
  gasLimit: number = 16700000
): Promise<DeploymentResult> {
  const startTime = Date.now();
  console.log(`    [Nonce ${nonce}] 🚀 Deploying UUPS proxy ${task.name} (parallel mode)...`);

  try {
    const t0 = Date.now();
    const signer = await hre.ethers.provider.getSigner();
    const t1 = Date.now();
    
    // Get factories first
    const implFactory = await getFactoryForTask(task, hre);
    const t2 = Date.now();
    const proxyFactory = await hre.ethers.getContractFactory('RaylsERC1967Proxy');
    const t3 = Date.now();
    
    // Deploy implementation (don't wait yet)
    const implContract = await implFactory.deploy({ nonce, gasLimit });
    const t4 = Date.now();
    
    // Get implementation address from deterministic deployment
    const implTx = implContract.deploymentTransaction();
    
    // Wait for impl deployment to get address
    await implContract.waitForDeployment();
    const implAddress = await implContract.getAddress();
    const t5 = Date.now();
    
    // Encode initialization call
    const initData = implFactory.interface.encodeFunctionData(
      task.initializer || 'initialize',
      task.initArgs || []
    );
    const t6 = Date.now();
    
    // Deploy proxy (now we can do this immediately after impl is deployed)
    const proxyNonce = nonce + 1;
    const proxyContract = await proxyFactory.deploy(implAddress, initData, { nonce: proxyNonce, gasLimit });
    const t7 = Date.now();
    
    // Wait for proxy deployment
    await proxyContract.waitForDeployment();
    const proxyAddress = await proxyContract.getAddress();
    const t8 = Date.now();

    const deploymentTime = Date.now() - startTime;
    console.log(`    ✅ [Nonce ${nonce}-${proxyNonce}] ${task.name} deployed to ${proxyAddress} (${deploymentTime}ms)`);
    console.log(`       ⏱️  Breakdown: getSigner=${t1-t0}ms | getImplFactory=${t2-t1}ms | getProxyFactory=${t3-t2}ms | submitImpl=${t4-t3}ms | waitImpl=${t5-t4}ms | encodeInit=${t6-t5}ms | submitProxy=${t7-t6}ms | waitProxy=${t8-t7}ms`);

    // Record in manifest
    const participantName = process.env.PARTICIPANT_NAME || undefined;
    const manifest = new ManifestManager('.openzeppelin', participantName);
    const proxyTx = proxyContract.deploymentTransaction();
    if (proxyTx && implTx) {
      await manifest.recordProxy(hre, proxyAddress, proxyTx.hash, 'uups');
      await manifest.recordImplementation(hre, implAddress, implTx.hash, task.contractName);
    }

    return {
      name: task.name,
      address: proxyAddress,
      deploymentTime,
      txHash: proxyTx?.hash
    };
  } catch (error: any) {
    if (error?.code === 'NONCE_EXPIRED') {
      const signer = await hre.ethers.provider.getSigner();
      const from = await signer.getAddress();
      const proxyAddress = hre.ethers.getCreateAddress({ from, nonce: nonce + 1 });
      console.log(`    ✓ [Nonce ${nonce}-${nonce + 1}] ${task.name} already deployed (proxy at ${proxyAddress}, NONCE_EXPIRED on retry) — treating as success`);
      return { name: task.name, address: proxyAddress };
    }
    console.error(`    ❌ [Nonce ${nonce}] Failed to deploy ${task.name}:`, error.message);
    throw error;
  }
}

/**
 * Deploys multiple contracts in parallel with nonce management
 * NOW SUPPORTS PARALLEL UUPS PROXY DEPLOYMENT!
 * Results are returned in the ORIGINAL ORDER of the input tasks array
 */
export async function deployBatch(
  tasks: DeploymentTask[],
  nonceManager: NonceManager,
  hre: HardhatRuntimeEnvironment,
  gasLimit: number = 16700000,  // ~16.7M — public-chain node caps per-tx gas at 2^24 (16,777,216); stay just under it. Bumped from 16M to fit EnygmaCreator's constructor, which SSTOREs EnygmaV1's ~25KB creationCode (~16.4M gas). See refactor to SSTORE2 for the durable fix.
  useParallelProxies: boolean = true  // ENABLED with timeout protection
): Promise<DeploymentResult[]> {
  const batchStartTime = Date.now();
  console.log(`  📦 Deploying batch of ${tasks.length} contracts...`);
  
  const txOptions: any = { gasLimit };

  // Separate proxies from regular contracts, but track original indices
  const proxyTasks = tasks.map((task, index) => ({ task, index })).filter(({ task }) => task.isProxy);
  const regularTasks = tasks.map((task, index) => ({ task, index })).filter(({ task }) => !task.isProxy);

  // Create results map indexed by original position
  const resultsMap = new Map<number, DeploymentResult>();

  if (useParallelProxies && proxyTasks.length > 0) {
    // PARALLEL MANUAL PROXY DEPLOYMENT with aggressive timeout protection
    console.log(`    📦 Deploying ${proxyTasks.length} UUPS proxies in PARALLEL...`);
    const t0 = Date.now();
    
    // Timeout helper - fails fast instead of hanging
    const withTimeout = <T>(promise: Promise<T>, timeoutMs: number, label: string): Promise<T> => {
      return Promise.race([
        promise,
        new Promise<T>((_, reject) => 
          setTimeout(() => reject(new Error(`TIMEOUT: ${label} exceeded ${timeoutMs}ms`)), timeoutMs)
        )
      ]);
    };
    
    try {
      // Phase 0: Validate contracts IN PARALLEL (if enabled)
      const validationTasks = proxyTasks.filter(({ task }) => task.validationOpts && !task.validationOpts.skipValidation);
      if (validationTasks.length > 0) {
        console.log(`       🔍 Phase 0: Validating ${validationTasks.length} contracts IN PARALLEL...`);
        const tVal0 = Date.now();
        await Promise.all(validationTasks.map(async ({ task }) => {
          const factory = await getFactoryForTask(task, hre);
          await validateImplementation(hre, factory, task.validationOpts, task.contractName);
        }));
        const tVal1 = Date.now();
        console.log(`       ✅ Validation complete (${tVal1-tVal0}ms)`);
      }
      
      // Phase 1: Prepare factories
      console.log(`       🔧 Phase 1: Preparing ${proxyTasks.length} factories...`);
      const deploymentPlan = [];
      for (const { task, index } of proxyTasks) {
        const implFactory = await withTimeout(
          getFactoryForTask(task, hre),
          60000,
          `getContractFactory(${task.contractName})`
        );
        deploymentPlan.push({ task, index, implFactory });
      }
      
      const proxyFactory = await withTimeout(
        hre.ethers.getContractFactory('RaylsERC1967Proxy'),
        60000,
        'getContractFactory(RaylsERC1967Proxy)'
      );
      const t1 = Date.now();
      console.log(`       ✅ Factories ready (${t1-t0}ms)`);
      
      // Phase 2: Deploy ALL impls IN PARALLEL with consecutive nonces
      console.log(`       🔧 Phase 2: Deploying ${deploymentPlan.length} implementations IN PARALLEL...`);
      const implDeployments = [];
      for (let i = 0; i < deploymentPlan.length; i++) {
        const plan = deploymentPlan[i];
        const implNonce = nonceManager.allocateNonce();
        console.log(`         [${i+1}/${deploymentPlan.length}] Submitting impl ${plan.task.name} (nonce ${implNonce})...`);
        const implTxOpts = { ...txOptions, nonce: implNonce };
        const implPromise = withTimeout(
          retryOnTransientError(
            () => plan.implFactory.deploy(implTxOpts),
            `deploy impl ${plan.task.name}`
          ),
          30000,
          `deploy impl ${plan.task.name}`
        );
        implDeployments.push({ ...plan, implPromise, implNonce });
      }
      
      // Wait for ALL impls in parallel
      console.log(`       🔧 Phase 2b: Waiting for ${implDeployments.length} impls to mine...`);
      const implsWithAddresses = await withTimeout(
        Promise.all(implDeployments.map(async (d, idx) => {
          const implContract: any = await d.implPromise;
          await implContract.waitForDeployment();
          const implAddress = await implContract.getAddress();
          const implTx = implContract.deploymentTransaction();
          console.log(`         [${idx+1}] ✓ Impl ${d.task.name} mined at ${implAddress}`);
          return { ...d, implAddress, implTx };
        })),
        60000,
        'wait for all impls'
      );
      const t2 = Date.now();
      console.log(`       ✅ All impls deployed (${t2-t1}ms)`);
      
      // Phase 3: Deploy ALL proxies IN PARALLEL with consecutive nonces
      console.log(`       🔧 Phase 3: Deploying ${implsWithAddresses.length} proxies IN PARALLEL...`);
      const proxyDeployments = [];
      for (let i = 0; i < implsWithAddresses.length; i++) {
        const d = implsWithAddresses[i];
        const proxyNonce = nonceManager.allocateNonce();
        console.log(`         [${i+1}/${implsWithAddresses.length}] Submitting proxy ${d.task.name} (nonce ${proxyNonce})...`);
        const initData = d.implFactory.interface.encodeFunctionData(
          d.task.initializer || 'initialize',
          d.task.initArgs || []
        );
        const proxyTxOpts = { ...txOptions, nonce: proxyNonce };
        const proxyPromise = withTimeout(
          retryOnTransientError(
            () => proxyFactory.deploy(d.implAddress, initData, proxyTxOpts),
            `deploy proxy ${d.task.name}`
          ),
          30000,
          `deploy proxy ${d.task.name}`
        );
        proxyDeployments.push({ ...d, proxyPromise, proxyNonce });
      }
      
      // Wait for ALL proxies in parallel
      console.log(`       🔧 Phase 3b: Waiting for ${proxyDeployments.length} proxies to mine...`);
      const finalResults = await withTimeout(
        Promise.all(proxyDeployments.map(async (d, idx) => {
          const proxyContract = await d.proxyPromise;
          await proxyContract.waitForDeployment();
          const proxyAddress = await proxyContract.getAddress();
          const proxyTx = proxyContract.deploymentTransaction();
          console.log(`         [${idx+1}] ✓ Proxy ${d.task.name} mined at ${proxyAddress}`);
          return {
            result: { name: d.task.name, address: proxyAddress, txHash: proxyTx?.hash },
            index: d.index,
            implAddress: d.implAddress,
            proxyTx,
            contractName: d.task.contractName
          };
        })),
        60000,
        'wait for all proxies'
      );
      const t3 = Date.now();
      console.log(`       ✅ All proxies deployed (${t3-t2}ms)`);
      console.log(`       🎯 TOTAL: ${t3-t0}ms for ${proxyTasks.length} proxies`);
      
      // Record in manifest - must be sequential to avoid file race conditions
      console.log(`       📝 Recording ${finalResults.length} deployments to manifest...`);
      const tManifest0 = Date.now();
      const participantName = process.env.PARTICIPANT_NAME || undefined;
      const manifest = new ManifestManager('.openzeppelin', participantName);
      for (const { result, implAddress, proxyTx, contractName } of finalResults) {
        if (proxyTx) {
          await manifest.recordProxy(hre, result.address, proxyTx.hash, 'uups');
          
          // Get impl tx hash from the implsWithAddresses
          const implData = implsWithAddresses.find(d => d.implAddress === implAddress);
          if (implData && implData.implTx) {
            await manifest.recordImplementation(hre, implAddress, implData.implTx.hash, contractName);
          }
        }
      }
      const tManifest1 = Date.now();
      console.log(`       ✅ Manifest recording complete (${tManifest1-tManifest0}ms)`);
      
      finalResults.forEach(({ result, index }) => resultsMap.set(index, result));
    } catch (error: any) {
      console.error(`    ❌ PARALLEL FAILED: ${error.message}`);
      console.error(`    ❌ Stack: ${error.stack}`);
      throw new Error(`Parallel proxy deployment failed: ${error.message}`);
    }
  } else if (proxyTasks.length > 0) {
    // SEQUENTIAL PROXY DEPLOYMENT (Original method)
    console.log(`    📦 Deploying ${proxyTasks.length} UUPS proxies sequentially...`);
    for (const { task, index } of proxyTasks) {
      const result = await deployProxyWithoutNonce(task, hre, gasLimit);
      resultsMap.set(index, result);
    }
    await nonceManager.sync();
  }

  // Deploy regular contracts in parallel with explicit nonces, chunked to avoid socket overload
  if (regularTasks.length > 0) {
    const DEPLOY_CHUNK_SIZE = 10;
    console.log(`    📦 Deploying ${regularTasks.length} regular contracts in parallel...`);
    // Pre-allocate nonces
    const tasksWithNonces = regularTasks.map(({ task, index }) => ({ task, index, nonce: nonceManager.allocateNonce() }));
    for (let i = 0; i < tasksWithNonces.length; i += DEPLOY_CHUNK_SIZE) {
      const chunk = tasksWithNonces.slice(i, i + DEPLOY_CHUNK_SIZE);
      const chunkResults = await retryOnTransientError(
        () => Promise.all(chunk.map(({ task, index, nonce }) =>
          deployWithNonce(task, nonce, hre, gasLimit).then(result => ({ result, index }))
        )),
        `deployChunk[${i}..${i + chunk.length - 1}]`
      );
      chunkResults.forEach(({ result, index }) => resultsMap.set(index, result));
    }
  }

  // Return results in original order
  const results = tasks.map((_, index) => resultsMap.get(index)!);

  const batchTotalTime = Date.now() - batchStartTime;
  console.log(`  ✅ Batch complete - ${results.length} contracts deployed in ${batchTotalTime}ms`);

  return results;
}

/**
 * Executes a single configuration transaction with explicit nonce
 */
export async function executeConfigWithNonce(
  task: ConfigTask,
  nonce: number,
  hre: HardhatRuntimeEnvironment,
  gasLimit: number = 16700000
): Promise<ConfigResult> {
  const startTime = Date.now();
  console.log(`    [Nonce ${nonce}] ⚙️  Configuring ${task.name}...`);

  try {
    const t0 = Date.now();
    const signer = await hre.ethers.provider.getSigner();
    const t1 = Date.now();
    const contract = await getContractForConfigTask(task, hre, signer);
    const t2 = Date.now();

    const tx = await contract[task.method](...task.args, { nonce, gasLimit });
    const t3 = Date.now();
    const receipt = await tx.wait();
    const t4 = Date.now();

    const totalTime = Date.now() - startTime;
    const success = receipt.status === 1;
    console.log(`    ${success ? '✅' : '❌'} [Nonce ${nonce}] ${task.name} ${success ? 'succeeded' : 'FAILED (status=0, tx reverted on-chain)'} (${totalTime}ms)`);
    console.log(`       ⏱️  Breakdown: getSigner=${t1-t0}ms | getContract=${t2-t1}ms | sendTx=${t3-t2}ms | waitReceipt=${t4-t3}ms`);

    if (!success) {
      throw new Error(`Transaction reverted on-chain: ${task.name} (nonce=${nonce}, tx=${tx.hash}). The deployment cannot continue with failed configuration transactions.`);
    }

    return {
      name: task.name,
      success,
      txHash: tx.hash
    };
  } catch (error: any) {
    if (error?.code === 'NONCE_EXPIRED') {
      console.log(`    ✓ [Nonce ${nonce}] ${task.name} already mined (NONCE_EXPIRED on retry) — treating as success`);
      return { name: task.name, success: true };
    }
    console.error(`    ❌ [Nonce ${nonce}] Failed to configure ${task.name}:`, error.message);
    throw error;
  }
}

/**
 * Executes multiple configuration transactions in parallel, chunked to avoid
 * overwhelming the RPC node. Each chunk fires N tasks at once; on a transient
 * socket error the entire chunk is retried (nonces are already allocated and
 * the node will accept them once the connection is re-established).
 */
export async function executeBatchConfig(
  tasks: ConfigTask[],
  nonceManager: NonceManager,
  hre: HardhatRuntimeEnvironment,
  gasLimit: number = 16700000
): Promise<ConfigResult[]> {
  const CHUNK_SIZE = 20;
  console.log(`  🔧 Executing batch of ${tasks.length} configurations in parallel...`);

  // Pre-allocate all nonces up-front so they are sequential regardless of chunking.
  const taskNonces = tasks.map(task => ({ task, nonce: nonceManager.allocateNonce() }));

  const allResults: ConfigResult[] = [];
  for (let i = 0; i < taskNonces.length; i += CHUNK_SIZE) {
    const chunk = taskNonces.slice(i, i + CHUNK_SIZE);
    const results = await retryOnTransientError(
      () => Promise.all(chunk.map(({ task, nonce }) => executeConfigWithNonce(task, nonce, hre, gasLimit))),
      `configChunk[${i}..${i + chunk.length - 1}]`
    );
    allResults.push(...results);
  }

  const failedResults = allResults.filter(r => !r.success);
  if (failedResults.length > 0) {
    const failedNames = failedResults.map(r => r.name).join(', ');
    throw new Error(`Batch config failed: ${failedResults.length}/${allResults.length} transactions reverted: ${failedNames}`);
  }
  console.log(`  ✅ Batch config complete - ${allResults.length}/${allResults.length} succeeded`);

  await nonceManager.sync();
  return allResults;
}

/**
 * Deploys a batch with retry logic
 */
export async function deployBatchWithRetry(
  tasks: DeploymentTask[],
  nonceManager: NonceManager,
  hre: HardhatRuntimeEnvironment,
  maxRetries: number = 3,
  gasLimit: number = 16700000
): Promise<DeploymentResult[]> {
  for (let attempt = 0; attempt < maxRetries; attempt++) {
    try {
      return await deployBatch(tasks, nonceManager, hre, gasLimit);
    } catch (error: any) {
      console.error(`  ⚠️  Batch deployment attempt ${attempt + 1} failed:`, error.message);

      // Re-sync nonce with chain
      await nonceManager.sync();

      if (attempt < maxRetries - 1) {
        const delay = 2000 * (attempt + 1);
        console.log(`  🕐 Waiting ${delay}ms before retry...`);
        await new Promise(resolve => setTimeout(resolve, delay));
      } else {
        throw new Error(`Batch deployment failed after ${maxRetries} attempts`);
      }
    }
  }

  throw new Error('Unexpected error in deployBatchWithRetry');
}

/**
 * Utility to wait for a specific number of blocks
 */
export async function waitForBlocks(
  provider: ethers.Provider,
  blockCount: number = 1
): Promise<void> {
  const startBlock = await provider.getBlockNumber();
  console.log(`  ⏳ Waiting for ${blockCount} block(s)... (current: ${startBlock})`);

  return new Promise((resolve) => {
    const checkBlock = async () => {
      const currentBlock = await provider.getBlockNumber();
      if (currentBlock >= startBlock + blockCount) {
        console.log(`  ✅ Block ${currentBlock} reached`);
        resolve();
      } else {
        setTimeout(checkBlock, 100);
      }
    };
    checkBlock();
  });
}
