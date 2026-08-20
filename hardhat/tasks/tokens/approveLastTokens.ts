import { task } from 'hardhat/config';

const HUB_STATUS_APPROVED = 1; // hub TokenRegistry status
const PN_STATUS_AUTHORIZED = 2; // PNTokenRegistry privacyNodeStatus

/**
 * Approve the last n registered tokens on the private hub `TokenRegistryV1` (status = APPROVED).
 */
async function approveLastHubTokensBatch(taskArgs: any, { ethers }: any) {
  const privateHubRpcUrl = process.env['PNH_RPC_URL'];
  const provider = new ethers.JsonRpcProvider(privateHubRpcUrl);
  const venOperatorWallet = new ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);
  const signer = venOperatorWallet.connect(provider);
  const numberOfTokens = parseInt(taskArgs.n);

  // Load the Deployment Registry contract
  const deploymentRegistry = await ethers.getContractAt('DeploymentProxyRegistryV1', process.env['PNH_DEPLOYMENT_PROXY_REGISTRY']!, signer);
  const tokenRegistryAddress = await deploymentRegistry.getContract('TokenRegistry');

  const TokenRegistry = await ethers.getContractAt('TokenRegistryV1', tokenRegistryAddress, signer);
  const tokens = await TokenRegistry.getAllTokens({ gasLimit: 5000000 });

  for (let i = tokens.length - 1; i >= tokens.length - numberOfTokens; i--) {
    let token = tokens[i];

    console.log(`Trying to approve token with name: ${token.name} and resourceId: ${token.resourceId}`);
    let tx = await TokenRegistry.updateStatus(token.resourceId, HUB_STATUS_APPROVED, { gasLimit: 5000000 });
    let receipt = await tx.wait(2);
    if (receipt?.status === 0) {
      let err = `The token "${token.name}" failed to be approved`;
      throw new Error(err);
    }
    console.log(`The token "${token.name}" got approved!`);
  }
}

/**
 * Authorize the last n registered tokens on the PN `PNTokenRegistryV1` (privacyNodeStatus = AUTHORIZED).
 */
async function approveLastPnTokensBatch(taskArgs: any, hre: any) {
  const { ethers } = hre;
  await hre.run('compile');

  const rpcUrl = process.env[`PRIVACY_NODE_${taskArgs.pn}_RPC_URL`];
  const privateKey = process.env['PRIVATE_KEY_SYSTEM'];
  const tokenRegistryAddress = process.env[`PRIVACY_NODE_${taskArgs.pn}_TOKEN_REGISTRY_ADDRESS`];
  const numberOfTokens = parseInt(taskArgs.n);

  if (!rpcUrl) {
    throw new Error(`RPC URL not found. Set PRIVACY_NODE_${taskArgs.pn}_RPC_URL environment variable`);
  }
  if (!privateKey) {
    throw new Error('Private key not found. Set PRIVATE_KEY_SYSTEM environment variable');
  }
  if (!tokenRegistryAddress) {
    throw new Error(`TokenRegistry address not found. Set PRIVACY_NODE_${taskArgs.pn}_TOKEN_REGISTRY_ADDRESS environment variable`);
  }

  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const wallet = new ethers.Wallet(privateKey);
  const signer = new ethers.NonceManager(wallet.connect(provider));

  const tokenRegistry = await ethers.getContractAt('PNTokenRegistryV1', tokenRegistryAddress, signer);
  const tokens = await tokenRegistry.getAllTokens();

  for (let i = tokens.length - 1; i >= tokens.length - numberOfTokens; i--) {
    const token = tokens[i];

    console.log(`Authorizing token "${token.name}" (${token.symbol}) at ${token.tokenAddress}...`);
    const tx = await tokenRegistry.updatePrivacyNodeStatus(token.tokenAddress, PN_STATUS_AUTHORIZED);
    const receipt = await tx.wait();
    if (receipt?.status !== 1) {
      throw new Error(`The token "${token.name}" (${token.symbol}) failed to be authorized`);
    }
    console.log(`The token "${token.name}" (${token.symbol}) got authorized!`);
  }
}

task('tokens:approve-last-batch-hub', 'Approve last n registered tokens on the private hub TokenRegistry')
  .addParam('n', 'Number of tokens to be approved')
  .setAction(approveLastHubTokensBatch);

task('tokens:approve-last-batch-pn', 'Authorize last n registered tokens on the PN TokenRegistry')
  .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D)')
  .addParam('n', 'Number of tokens to be authorized')
  .setAction(approveLastPnTokensBatch);
