import { task } from 'hardhat/config';
import { TokenRegistryV1 } from '../../../typechain-types';
import { PrivateHub, GAS_LIMIT } from '../../test/utils/Constants';

const HUB_STATUS_APPROVED = 1n; // hub TokenRegistry status
const PN_STATUS_AUTHORIZED = 2; // PNTokenRegistry privacyNodeStatus

/**
 * Approve all registered tokens on the private hub `TokenRegistryV1` (status = APPROVED).
 */
async function approveAllHubTokens(_taskArgs: any, hre: any) {
  const privateHub = new PrivateHub(hre);
  await privateHub.initialize();

  const tokenRegistry = privateHub.getContract<TokenRegistryV1>('TokenRegistryV1');

  const tokens = await tokenRegistry.getAllTokens({ gasLimit: GAS_LIMIT });

  for (const token of tokens) {
    if (token.status === HUB_STATUS_APPROVED) {
      console.log(`Token ${token.symbol} already approved`);
      continue;
    }
    console.log(`Approving ${token.symbol}...`);
    await privateHub.wait(
      tokenRegistry.updateStatus(token.resourceId, HUB_STATUS_APPROVED, { gasLimit: GAS_LIMIT }),
      `Approving ${token.symbol}...`
    );
  }
}

/**
 * Authorize all registered tokens on the PN `PNTokenRegistryV1` (privacyNodeStatus = AUTHORIZED).
 */
async function approveAllPnTokens(taskArgs: any, hre: any) {
  const { ethers } = hre;
  await hre.run('compile');

  const rpcUrl = process.env[`PRIVACY_NODE_${taskArgs.pn}_RPC_URL`];
  const privateKey = process.env['PRIVATE_KEY_SYSTEM'];
  const tokenRegistryAddress = process.env[`PRIVACY_NODE_${taskArgs.pn}_TOKEN_REGISTRY_ADDRESS`];

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

  for (const token of tokens) {
    if (Number(token.privacyNodeStatus) === PN_STATUS_AUTHORIZED) {
      console.log(`Token ${token.symbol} already AUTHORIZED`);
      continue;
    }
    console.log(`Authorizing ${token.symbol}...`);
    const tx = await tokenRegistry.updatePrivacyNodeStatus(token.tokenAddress, PN_STATUS_AUTHORIZED);
    const receipt = await tx.wait();
    if (receipt?.status !== 1) {
      throw new Error(`The token "${token.name}" (${token.symbol}) failed to be authorized`);
    }
    console.log(`The token "${token.name}" (${token.symbol}) got authorized!`);
  }
}

task('tokens:approve-all-hub', 'Approve all registered tokens on the private hub TokenRegistry')
  .setAction(approveAllHubTokens);

task('tokens:approve-all-pn', 'Authorize all registered tokens on the PN TokenRegistry')
  .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D)')
  .setAction(approveAllPnTokens);
