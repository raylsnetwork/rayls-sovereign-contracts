/**
 * @deprecated Decommissioning Teleport (vanilla, atomic).
 */
import { task } from 'hardhat/config';
import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { EndpointV1, ParticipantStorageV1, TokenExample, TokenRegistryV1 } from '../../../typechain-types';
import { genRanHex, pollCondition } from '../../utils/polling';

task('e2e:erc20-light', 'Runs a lightweight E2E test for ERC20 token operations').setAction(async (_, hre: HardhatRuntimeEnvironment) => {
  console.log('Starting E2E ERC20 Light Task...');

  const { ethers } = hre;

  const rpcUrlA = process.env['PRIVACY_NODE_A_RPC_URL']!;
  const rpcUrlB = process.env['PRIVACY_NODE_B_RPC_URL']!;
  const rpcUrlPNH = process.env['PNH_RPC_URL']!;  
  const deploymentProxyRegistryPNHAddress = process.env['PNH_DEPLOYMENT_PROXY_REGISTRY'] as string;
  const deploymentProxyRegistryAAddress = process.env['PRIVACY_NODE_A_DEPLOYMENT_PROXY_REGISTRY'] as string;;
  const deploymentProxyRegistryBAddress = process.env['PRIVACY_NODE_A_DEPLOYMENT_PROXY_REGISTRY'] as string;;
  let tokenRegistryAddress = '' as string;
  let participantStorageAddress = '' as string;
  const chainIdB = process.env['PRIVACY_NODE_B_CHAIN_ID'] as string;

  if (!rpcUrlA || !rpcUrlB || !rpcUrlPNH || !deploymentProxyRegistryAAddress || !deploymentProxyRegistryBAddress || !deploymentProxyRegistryPNHAddress || !chainIdB || !process.env['PRIVATE_KEY_SYSTEM']) {
    throw new Error('Please set all required environment variables: PRIVACY_NODE_A_RPC_URL, PRIVACY_NODE_B_RPC_URL, PNH_RPC_URL, PRIVACY_NODE_A_DEPLOYMENT_PROXY_REGISTRY, PRIVACY_NODE_B_DEPLOYMENT_PROXY_REGISTRY, PNH_DEPLOYMENT_PROXY_REGISTRY, PRIVACY_NODE_B_CHAIN_ID, PRIVATE_KEY_SYSTEM');
  }

  const providerA = new ethers.JsonRpcProvider(rpcUrlA);
  const providerB = new ethers.JsonRpcProvider(rpcUrlB);
  const providerPNH = new ethers.JsonRpcProvider(rpcUrlPNH);
  providerA.pollingInterval = 200;
  providerB.pollingInterval = 200;
  providerPNH.pollingInterval = 200;

  const venOperatorWallet = new ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM']!);
  const userWalletA = ethers.Wallet.createRandom();
  const userWalletB = ethers.Wallet.createRandom();

  const signerA = userWalletA.connect(providerA);
  const signerB = userWalletB.connect(providerB);
  const signerPNH = venOperatorWallet.connect(providerPNH);

  let tokenOnPNA: TokenExample;
  let tokenOnPNB: TokenExample;
  let tokenRegistry: TokenRegistryV1;
  let endpointB: EndpointV1;

  const randomSuffix = genRanHex(6);
  const tokenName = `Token ${randomSuffix}`;
  const tokenSymbol = `T_${randomSuffix}`;
  let tokenResourceId: string = '';

  enum TokenStatus {
    PENDING = 2,
    APPROVED = 1
  }

  // Setup
  console.log(`[${new Date().toISOString()}] --- Starting setup.`);
  try {
    const deploymentRegistry = await hre.ethers.getContractAt('DeploymentProxyRegistry', deploymentProxyRegistryPNHAddress, signerPNH);
    const deployment = await deploymentRegistry.getDeployment();
    tokenRegistryAddress = deployment.tokenRegistryAddress;
    participantStorageAddress = deployment.participantStorageAddress;

    const TokenErc20Factory = await hre.ethers.getContractFactory('TokenExample', signerA);

    tokenRegistry = await hre.ethers.getContractAt('TokenRegistryV1', tokenRegistryAddress, signerPNH);
    await hre.ethers.getContractAt('ParticipantStorageV1', participantStorageAddress, signerPNH);

    await hre.ethers.getContractAt('EndpointV1', endpointAddressA, signerA);
    endpointB = await hre.ethers.getContractAt('EndpointV1', endpointAddressB, signerB);

    tokenOnPNA = await TokenErc20Factory.deploy(tokenName, tokenSymbol, endpointAddressA);
    await tokenOnPNA.waitForDeployment();

    console.log(`[${new Date().toISOString()}] - Token deployed at: ${await tokenOnPNA.getAddress()}, name: ${tokenName}, symbol: ${tokenSymbol}`);
  } catch (error) {
    console.error(`[${new Date().toISOString()}] - ERROR in setup: ${error}`);
    throw error;
  }

  // Register and approve token
  console.log(`[${new Date().toISOString()}] --- Registering and approving the token on PrivateHub.`);
  await tokenOnPNA.submitTokenRegistration(TokenStatus.PENDING);

  let resourceIdToApprove: string = '';
  const tokenAppeared = await pollCondition(
    async (): Promise<boolean> => {
      const allTokens = await tokenRegistry.getAllTokens();
      const tokenOnPNH = allTokens.find((x) => x.name == tokenName);
      if (!tokenOnPNH) return false;
      resourceIdToApprove = tokenOnPNH.resourceId;
      return true;
    },
    1000,
    300
  );

  if (!tokenAppeared) {
    throw new Error(`Token '${tokenName}' did not appear in PrivateHub registry`);
  }
  if (!resourceIdToApprove) {
    throw new Error('resourceIdToApprove is empty');
  }

  await tokenRegistry.connect(signerPNH).updateStatus(resourceIdToApprove, TokenStatus.APPROVED, { gasLimit: 5000000 });

  const resourceIdSet = await pollCondition(
    async (): Promise<boolean> => {
      const resourceId = await tokenOnPNA.resourceId();
      if (resourceId === ethers.ZeroHash) return false;
      tokenResourceId = resourceId;
      return true;
    },
    1000,
    300
  );

  if (!resourceIdSet) {
    throw new Error(`Token resourceId was not set on Chain A after approval`);
  }
  if (!tokenResourceId || tokenResourceId === ethers.ZeroHash) {
    throw new Error(`tokenResourceId is ZeroHash or empty`);
  }
  console.log(`[${new Date().toISOString()}] --- Token ${tokenName} (resourceId: ${tokenResourceId}) was approved.`);

  // Teleport tokens
  console.log(`[${new Date().toISOString()}] --- Teleporting atomic tokens from Chain A to Chain B.`);
  const teleportAmount = 30;

  console.log(`[${new Date().toISOString()}] - Calling teleportAtomic from ${await tokenOnPNA.getAddress()} on Chain A for ${signerA.address} with amount ${teleportAmount} to chainId ${chainIdB}.`);
  await tokenOnPNA.teleportAtomic(signerB.address, teleportAmount, chainIdB);

  const teleportSuccessful = await pollCondition(
    async (): Promise<boolean> => {
      const tokenBAddress = await endpointB.getAddressByResourceId(tokenResourceId);
      if (tokenBAddress === ethers.ZeroAddress) return false;

      tokenOnPNB = await hre.ethers.getContractAt('TokenExample', tokenBAddress, signerB);

      const balanceOnB = await tokenOnPNB.balanceOf(signerB.address);
      return balanceOnB === BigInt(teleportAmount);
    },
    1000,
    300
  );

  if (!teleportSuccessful) {
    throw new Error(`Teleport from A to B did not complete or balance on B is not ${teleportAmount}`);
  }

  const finalBalance = await tokenOnPNB!.balanceOf(signerB.address);
  console.log(`[${new Date().toISOString()}] - Token successfully sent from A to B. PN B address: ${await tokenOnPNB!.getAddress()}. PN B balance: ${finalBalance}`);

  if (finalBalance !== BigInt(teleportAmount)) {
    throw new Error(`Final balance of ${signerB.address} on Chain B is ${finalBalance}, expected ${teleportAmount}`);
  }
  console.log(`[${new Date().toISOString()}] --- E2E test for ERC20 token operations finished successfully!`);
}); 