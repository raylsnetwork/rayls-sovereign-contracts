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

const STATUS_NAMES = ['UNDEFINED', 'WAITING_APPROVAL', 'AUTHORIZED', 'UNAUTHORIZED', 'FROZEN'];

/**
 * Approve the last registered token on the private hub `TokenRegistryV1` (set its status to APPROVED (1)).
 */
async function approveLastHubToken(_taskArgs: any, { ethers }: any) {
  const privateHubRpcUrl = process.env['PNH_RPC_URL'];
  const provider = new ethers.JsonRpcProvider(privateHubRpcUrl);
  const venOperatorWallet = new ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);
  const signer = venOperatorWallet.connect(provider);

  // Load the Deployment Registry contract
  const deploymentRegistry = await ethers.getContractAt('DeploymentProxyRegistryV1', process.env['PNH_DEPLOYMENT_PROXY_REGISTRY']!, signer);

  const tokenRegistryAddress = await deploymentRegistry.getContract('TokenRegistry');

  // Load the TokenRegistry contract
  const TokenRegistry = await ethers.getContractAt('TokenRegistryV1', tokenRegistryAddress, signer);
  // Call getAllTokens function
  const tokens = await TokenRegistry.getAllTokens();
  let lastToken = tokens[tokens.length - 1];
  console.log('Trying to approve token with symbol:', lastToken.symbol, 'and name:', lastToken.name, 'and resourceId:', lastToken.resourceId);
  let tx = await TokenRegistry.updateStatus(lastToken.resourceId, 1, { gasLimit: 5000000 });
  let receipt = await tx.wait(2);
  if (receipt?.status === 0) {
    let err = `The token "${lastToken.name}" (${lastToken.symbol}) failed to be approved`;
    throw new Error(err);
  }
  console.log(`The token "${lastToken.name}" (${lastToken.symbol}) got approved!`);
}

/**
 * Approve the last token added to the PN `PNTokenRegistryV1` (set to AUTHORIZED).
 */
async function approveLastPnToken(taskArgs: any, hre: any) {
  const { ethers, run } = hre;
  await run('compile');

  const spinner: Spinner = new Spinner();

  try {
    // Load environment variables or use provided parameters
    const rpcUrl = taskArgs.rpcUrl || process.env[`PRIVACY_NODE_${taskArgs.pn}_RPC_URL`];
    const privateKey = taskArgs.privateKey || process.env['PRIVATE_KEY_SYSTEM'];
    const tokenRegistryAddress = taskArgs.tokenRegistryAddress || process.env[`PRIVACY_NODE_${taskArgs.pn}_TOKEN_REGISTRY_ADDRESS`];

    if (!rpcUrl) {
      throw new Error(`RPC URL not found. Set PRIVACY_NODE_${taskArgs.pn}_RPC_URL environment variable or use --rpc-url parameter`);
    }
    if (!privateKey) {
      throw new Error('Private key not found. Set PRIVATE_KEY_SYSTEM environment variable or use --private-key parameter');
    }
    if (!tokenRegistryAddress) {
      throw new Error(`TokenRegistry address not found. Set PRIVACY_NODE_${taskArgs.pn}_TOKEN_REGISTRY_ADDRESS environment variable or use --token-registry-address parameter`);
    }

    logger.debug(`Getting last token from TokenRegistry on ${taskArgs.pn}...`);

    spinner.start();

    // Setup provider and signer
    const provider = new ethers.JsonRpcProvider(rpcUrl);
    const wallet = new ethers.Wallet(privateKey);
    const signer = new ethers.NonceManager(wallet.connect(provider));

    // Get TokenRegistry contract
    const tokenRegistry = await hre.ethers.getContractAt('PNTokenRegistryV1', tokenRegistryAddress, signer);

    // Get all tokens
    logger.debug('Fetching all tokens...');
    const allTokens = await tokenRegistry.getAllTokens();

    if (allTokens.length === 0) {
      spinner.stop();
      logger.info('No tokens found in TokenRegistry');
      return { success: false, reason: 'No tokens found' };
    }

    // Get the last token (highest index)
    const lastToken = allTokens[allTokens.length - 1];
    const privateAddress = lastToken.tokenAddress;
    const currentStatus = lastToken.privacyNodeStatus;
    const currentStatusName = STATUS_NAMES[currentStatus];
    const targetStatus = TOKEN_STATUSES.AUTHORIZED; // 2 = AUTHORIZED (PrivacyNodeStatus)
    const targetStatusName = STATUS_NAMES[targetStatus];

    logger.debug(`Found ${allTokens.length} tokens`);
    logger.debug(`Last token: ${lastToken.name} (${lastToken.symbol})`);
    logger.debug(`Private Address: ${privateAddress}`);
    logger.debug(`Current Status: ${currentStatus} (${currentStatusName})`);

    // Check if already active
    if (currentStatus === targetStatus) {
      spinner.stop();
      logger.info(`Last token "${lastToken.name}" is already AUTHORIZED`);
      logger.info(`🏪 Private Address: ${privateAddress}`);
      return {
        success: false,
        reason: 'Already active',
        tokenInfo: {
          privateAddress: privateAddress,
          tokenAddress: lastToken.tokenAddress,
          name: lastToken.name,
          symbol: lastToken.symbol,
          status: currentStatusName
        }
      };
    }

    // Update status to AUTHORIZED
    logger.debug('Updating token status to AUTHORIZED...');
    const tx = await tokenRegistry.updatePrivacyNodeStatus(privateAddress, targetStatus);

    logger.debug(`Transaction submitted: ${tx.hash}`);

    // Wait for transaction confirmation
    const receipt = await tx.wait();
    spinner.stop();

    if (receipt?.status === 1) {
      // Parse the TokenStatusChanged event
      let statusChangedEvent = null;

      for (const log of receipt.logs) {
        try {
          const parsedLog = tokenRegistry.interface.parseLog(log);
          if (parsedLog?.name === 'TokenStatusChanged') {
            statusChangedEvent = parsedLog;
            break;
          }
        } catch (e) {
          // Not a log from our contract, skip
        }
      }

      logger.info('✅ Last token successfully approved (set to AUTHORIZED)!');
      logger.info(`📄 Transaction Hash: ${tx.hash}`);
      logger.info(`🏪 Private Address: ${privateAddress}`);
      logger.info(`📛 Token Name: ${lastToken.name} (${lastToken.symbol})`);
      logger.info(`📊 Status Change: ${currentStatusName} → ${targetStatusName}`);
      logger.info(`🔢 Token Index: ${allTokens.length - 1} (last of ${allTokens.length} tokens)`);

      if (statusChangedEvent) {
        logger.debug('TokenStatusChanged event emitted successfully');
      }

      logger.info('');
      logger.info('🚀 Token is now AUTHORIZED on the Privacy Node.');
      logger.info('ℹ️  Nothing is cross-chain yet — no hub or public-chain action is triggered automatically.');
      logger.info('📋 Next, depending on the use case (the two paths are independent — pick either or both):');
      logger.info('   • Private cross-chain (PN <-> PNH): `submitTokenToHub`, then the PNH operator approves via `tokens:approve-hub`.');
      logger.info(`     \$ npx hardhat submitTokenToHub --pn ${taskArgs.pn} --token-address ${privateAddress}`);
      logger.info('   • Public-chain bridging: `submitTokenToPublicChain`, then the relayer deploys on the public chain.');
      logger.info(`     \$ npx hardhat submitTokenToPublicChain --pn ${taskArgs.pn} --token-address ${privateAddress}`);

      return {
        success: true,
        privateAddress: privateAddress,
        tokenAddress: lastToken.tokenAddress,
        name: lastToken.name,
        symbol: lastToken.symbol,
        oldStatus: currentStatusName,
        newStatus: targetStatusName,
        tokenIndex: allTokens.length - 1,
        totalTokens: allTokens.length,
        transactionHash: tx.hash
      };

    } else {
      throw new Error('Transaction failed');
    }

  } catch (error: any) {
    spinner.stop();
    logger.error('❌ Failed to approve last token');
    logger.error(`Error: ${error.message}`);

    // Provide helpful error context
    if (error.message.includes('Ownable: caller is not the owner')) {
      logger.error('💡 Make sure you are using the owner private key for this TokenRegistry contract');
    } else if (error.message.includes('No tokens found')) {
      logger.error('💡 Add some tokens first using the tokens:register task');
    }

    return { success: false, error: error.message };
  }
}

task('tokens:approve-last-hub', 'Approve last registered token on the private hub TokenRegistry')
  .setAction(approveLastHubToken);

task('tokens:approve-last-pn', 'Approve the last token added to the PN TokenRegistry (set to AUTHORIZED)')
  .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D)')
  .addOptionalParam('rpcUrl', 'Custom RPC URL (overrides environment variable)')
  .addOptionalParam('privateKey', 'Custom private key (overrides environment variable)')
  .addOptionalParam('tokenRegistryAddress', 'Custom TokenRegistry contract address (overrides environment variable)')
  .setAction(approveLastPnToken);
