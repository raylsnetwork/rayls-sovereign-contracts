import { task } from 'hardhat/config';
import { Spinner } from '../../utils/spinner';
import { Logger, LogLevel } from '../../test/unit/utils/moca-logger';

const logger = new Logger();
const logLevel = Number(process.env['TEST_LOGGING_LEVEL'] || LogLevel.INFO);
logger.setLogLevel(logLevel);

// PrivacyNodeStatus enum values
const TOKEN_STATUSES = {
  UNDEFINED: 0,
  WAITING_APPROVAL: 1,
  AUTHORIZED: 2,
  UNAUTHORIZED: 3,
  FROZEN: 4
} as const;

/**
 * Approve a token on the private hub `TokenRegistryV1` by symbol.
 * Resolves the token's resourceId from `TOKEN_<SYMBOL>_RESOURCE_ID` and sets its status to APPROVED (1).
 */
async function approveHubToken(taskArgs: any, { ethers }: any) {
  const privateHubRpcUrl = process.env['PNH_RPC_URL'];
  const provider = new ethers.JsonRpcProvider(privateHubRpcUrl);
  const venOperatorWallet = new ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);
  const signer = venOperatorWallet.connect(provider);

  const deploymentRegistryAddress = process.env['PNH_DEPLOYMENT_PROXY_REGISTRY'] as string;
  // Load the Deployment Registry contract
  const deploymentRegistry = await ethers.getContractAt('DeploymentProxyRegistryV1', deploymentRegistryAddress!, signer);
  const tokenRegistryAddress = await deploymentRegistry.getContract('TokenRegistry');

  // Load the TokenRegistry contract
  const TokenRegistry = await ethers.getContractAt('TokenRegistryV1', tokenRegistryAddress, signer);
  const symbol = String(taskArgs.symbol).toUpperCase();
  const resourceIdEnvName = `TOKEN_${symbol}_RESOURCE_ID`;
  const resourceId = process.env[resourceIdEnvName];

  if (!resourceId) {
    throw new Error(
      `No resource ID configured for symbol "${symbol}". Add ${resourceIdEnvName}=0x... to .env before approving this token.`,
    );
  }

  if (!ethers.isHexString(resourceId, 32)) {
    throw new Error(
      `Invalid resource ID configured for symbol "${symbol}": ${resourceId}. Expected a 32-byte hex value in ${resourceIdEnvName}.`,
    );
  }

  // Call approve token function
  const tx = await TokenRegistry.updateStatus(resourceId, 1, { gasLimit: 5000000 });
  const receipt = await tx.wait();

  if (receipt?.status !== 1) {
    throw new Error(`Failed to approve token ${resourceId}`);
  }

  console.log(`✅ The token with resourceId ${resourceId} got approved!`);
}

/**
 * Authorize a token on the PN `PNTokenRegistryV1` by its token (contract) address
 * (sets privacyNodeStatus = AUTHORIZED).
 */
async function approvePnToken(taskArgs: any, hre: any) {
  const { ethers, run } = hre;
  await run('compile');

  const spinner: Spinner = new Spinner();

  try {
    const status = TOKEN_STATUSES.AUTHORIZED;

    // Validate token address format
    if (!ethers.isAddress(taskArgs.tokenAddress)) {
      throw new Error('Invalid token address format. Must be a valid Ethereum address');
    }

    // Load environment variables or use provided parameters
    const rpcUrl = process.env[`PRIVACY_NODE_${taskArgs.pn}_RPC_URL`];
    const privateKey = process.env['PRIVATE_KEY_SYSTEM'];
    const tokenRegistryAddress = process.env[`PRIVACY_NODE_${taskArgs.pn}_TOKEN_REGISTRY_ADDRESS`];

    if (!rpcUrl) {
      throw new Error(`RPC URL not found. Set PRIVACY_NODE_${taskArgs.pn}_RPC_URL environment variable or use --rpc-url parameter`);
    }
    if (!privateKey) {
      throw new Error('Private key not found. Set PRIVATE_KEY_SYSTEM environment variable or use --private-key parameter');
    }
    if (!tokenRegistryAddress) {
      throw new Error(`TokenRegistry address not found. Set PRIVACY_NODE_${taskArgs.pn}_TOKEN_REGISTRY_ADDRESS environment variable`);
    }

    logger.debug(`Authorizing token on ${taskArgs.pn}...`);
    logger.debug(`Token Address: ${taskArgs.tokenAddress}`);

    spinner.start();

    // Setup provider and signer
    const provider = new ethers.JsonRpcProvider(rpcUrl);
    const wallet = new ethers.Wallet(privateKey);
    const signer = new ethers.NonceManager(wallet.connect(provider));

    // Get TokenRegistry contract
    const tokenRegistry = await hre.ethers.getContractAt('PNTokenRegistryV1', tokenRegistryAddress, signer);

    // Check if token exists and get current status
    let tokenInfo;
    try {
      tokenInfo = await tokenRegistry.getTokenByAddress(taskArgs.tokenAddress);
    } catch (error) {
      spinner.stop();
      throw new Error('Token with this token address does not exist');
    }

    if (tokenInfo.privacyNodeStatus === status) {
      spinner.stop();
      logger.info('Token is already AUTHORIZED');
      return { success: false, reason: 'Status unchanged' };
    }

    // Call updatePrivacyNodeStatus function
    logger.debug('Calling updatePrivacyNodeStatus...');
    const tx = await tokenRegistry.updatePrivacyNodeStatus(taskArgs.tokenAddress, status);

    logger.debug(`Transaction submitted: ${tx.hash}`);

    // Wait for transaction confirmation
    const receipt = await tx.wait();
    spinner.stop();

    if (receipt?.status === 1) {
      logger.info('✅ Token status successfully updated!');
      logger.info(`📄 Transaction Hash: ${tx.hash}`);
      logger.info(`🏪 Token Address: ${taskArgs.tokenAddress}`);
      logger.info(`📛 Token Name: ${tokenInfo.name} (${tokenInfo.symbol})`);
      logger.info(`⏰ Updated: ${new Date(Number(tokenInfo.updatedAt) * 1000).toISOString()}`);

      logger.info('');
      logger.info('🚀 Token is now AUTHORIZED on the Privacy Node.');
      logger.info('ℹ️  Nothing is cross-chain yet — no hub or public-chain action is triggered automatically.');
      logger.info('📋 Next, depending on the use case (the two paths are independent — pick either or both):');
      logger.info('   • Private cross-chain (PN <-> PNH): `submitTokenToHub`, then the PNH operator approves via `tokens:approve-hub`.');
      logger.info(`     \$ npx hardhat submitTokenToHub --pn ${taskArgs.pn} --token-address ${taskArgs.tokenAddress}`);
      logger.info('   • Public-chain bridging: `submitTokenToPublicChain`, then the relayer deploys on the public chain.');
      logger.info(`     \$ npx hardhat submitTokenToPublicChain --pn ${taskArgs.pn} --token-address ${taskArgs.tokenAddress}`);

      return {
        success: true,
        tokenAddress: tokenInfo.tokenAddress,
        name: tokenInfo.name,
        symbol: tokenInfo.symbol,
        transactionHash: tx.hash
      };

    } else {
      throw new Error('Transaction failed');
    }

  } catch (error: any) {
    spinner.stop();
    logger.error('❌ Failed to update token status');
    logger.error(`Error: ${error.message}`);

    // Provide helpful error context
    if (error.message.includes('Ownable: caller is not the owner')) {
      logger.error('💡 Make sure you are using the owner private key for this TokenRegistry contract');
    } else if (error.message.includes('Token does not exist')) {
      logger.error('💡 Check that the token address is correct and the token exists');
    } else if (error.message.includes('Invalid token address format')) {
      logger.error('💡 Token address must be a valid Ethereum address');
    }

    return { success: false, error: error.message };
  }
}

task('tokens:approve-hub', 'Approve token on the private hub TokenRegistry by symbol')
  .addParam('symbol', 'The token symbol')
  .setAction(approveHubToken);

task('tokens:approve-pn', 'Authorize a token on the PN TokenRegistry by address (sets privacyNodeStatus = AUTHORIZED)')
  .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D)')
  .addParam('tokenAddress', 'The token contract address to authorize')
  .setAction(approvePnToken);
