import { task } from 'hardhat/config';
import { Spinner } from '../../utils/spinner';
import { Logger, LogLevel } from '../../test/unit/utils/moca-logger';

const logger = new Logger();
const logLevel = Number(process.env['TEST_LOGGING_LEVEL'] || LogLevel.INFO);
logger.setLogLevel(logLevel);

// PrivacyNodeStatus enum value required before the token may be submitted to the public chain.
const PRIVACY_NODE_STATUS_AUTHORIZED = 2n;

// Use case B — make the token available on the public chain (external-chain bridging).
// This is independent of the hub path (submitTokenToHub); both fork off PN AUTHORIZED and neither
// requires the other. `isTokenActiveForPublicChain` only checks privacyNodeStatus + publicChainStatus.
task('submitTokenToPublicChain', 'Submit a PN-authorized token to the public chain (external-chain bridging)')
  .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D)')
  .addParam('tokenAddress', 'The private address (token contract address) to submit to the public chain')
  .setAction(async (taskArgs, hre) => {
    const { ethers, run } = hre;
    await run('compile');

    const spinner: Spinner = new Spinner();

    try {
      if (!ethers.isAddress(taskArgs.tokenAddress)) {
        throw new Error('Invalid token address format. Must be a valid Ethereum address');
      }

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

      logger.debug(`Submitting token to the public chain on ${taskArgs.pn}...`);
      logger.debug(`Token Address: ${taskArgs.tokenAddress}`);

      spinner.start();

      const provider = new ethers.JsonRpcProvider(rpcUrl);
      const wallet = new ethers.Wallet(privateKey);
      const signer = new ethers.NonceManager(wallet.connect(provider));

      const tokenRegistry = await hre.ethers.getContractAt('PNTokenRegistryV1', tokenRegistryAddress, signer);

      // Preflight: submitToPublicChain requires privacyNodeStatus == AUTHORIZED (independent of hubStatus).
      let tokenInfo;
      try {
        tokenInfo = await tokenRegistry.getTokenByAddress(taskArgs.tokenAddress);
      } catch (error) {
        spinner.stop();
        throw new Error('Token with this private address does not exist. Register it first with `tokens:register`');
      }

      if (tokenInfo.privacyNodeStatus !== PRIVACY_NODE_STATUS_AUTHORIZED) {
        spinner.stop();
        throw new Error(
          `Token privacyNodeStatus must be AUTHORIZED (2) before submitting to the public chain (current: ${tokenInfo.privacyNodeStatus}). ` +
          `Approve it first with \`npx hardhat tokens:approve-pn --pn ${taskArgs.pn} --token-address ${taskArgs.tokenAddress}\``
        );
      }

      logger.debug('Calling submitToPublicChain...');
      const tx = await tokenRegistry.submitToPublicChain(taskArgs.tokenAddress);

      logger.debug(`Transaction submitted: ${tx.hash}`);
      const receipt = await tx.wait();
      spinner.stop();

      if (receipt?.status !== 1) {
        throw new Error('Transaction failed');
      }

      logger.info('✅ Token submitted to the public chain!');
      logger.info(`📄 Transaction Hash: ${tx.hash}`);
      logger.info(`🏪 Private Address: ${taskArgs.tokenAddress}`);
      logger.info(`📛 Token Name: ${tokenInfo.name} (${tokenInfo.symbol})`);
      logger.info('📊 publicChainStatus is now PENDING_DEPLOYMENT (1)');
      logger.info('');
      logger.info('📋 Next step (public-chain path):');
      logger.info('The relayer deploys the token on the public chain and calls updatePublicTokenAddress,');
      logger.info('which sets publicChainStatus = DEPLOYED (2). Only then is the token bridgeable');
      logger.info('(isTokenActiveForPublicChain == true) and usable for public-chain transfers.');

      return {
        success: true,
        privateAddress: taskArgs.tokenAddress,
        name: tokenInfo.name,
        symbol: tokenInfo.symbol,
        transactionHash: tx.hash
      };
    } catch (error: any) {
      spinner.stop();
      logger.error('❌ Failed to submit token to the public chain');
      logger.error(`Error: ${error.message}`);
      return { success: false, error: error.message };
    }
  });
