import { task } from 'hardhat/config';
import { Spinner } from '../../utils/spinner';
import { Logger, LogLevel } from '../../test/unit/utils/moca-logger';

const logger = new Logger();
const logLevel = Number(process.env['TEST_LOGGING_LEVEL'] || LogLevel.INFO);
logger.setLogLevel(logLevel);

// PrivacyNodeStatus enum value required before the token may be submitted to the hub.
const PRIVACY_NODE_STATUS_AUTHORIZED = 2n;

// Use case A — register the token with the Private Hub for private cross-chain (PN <-> PNH <-> PNs).
// This is independent of the public-chain path (submitTokenToPublicChain); both fork off PN AUTHORIZED.
task('submitTokenToHub', 'Submit a PN-authorized token to the Private Hub (private cross-chain registration)')
  .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D)')
  .addParam('tokenAddress', 'The private address (token contract address) to submit to the hub')
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

      logger.debug(`Submitting token to the Private Hub on ${taskArgs.pn}...`);
      logger.debug(`Token Address: ${taskArgs.tokenAddress}`);

      spinner.start();

      const provider = new ethers.JsonRpcProvider(rpcUrl);
      const wallet = new ethers.Wallet(privateKey);
      const signer = new ethers.NonceManager(wallet.connect(provider));

      const tokenRegistry = await hre.ethers.getContractAt('PNTokenRegistryV1', tokenRegistryAddress, signer);

      // Preflight: submitToHub requires privacyNodeStatus == AUTHORIZED (TokenCoreV1__PrivacyNodeAuthorizationRequired).
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
          `Token privacyNodeStatus must be AUTHORIZED (2) before submitting to the hub (current: ${tokenInfo.privacyNodeStatus}). ` +
          `Approve it first with \`npx hardhat tokens:approve-pn --pn ${taskArgs.pn} --token-address ${taskArgs.tokenAddress}\``
        );
      }

      logger.debug('Calling submitToHub...');
      const tx = await tokenRegistry.submitToHub(taskArgs.tokenAddress);

      logger.debug(`Transaction submitted: ${tx.hash}`);
      const receipt = await tx.wait();
      spinner.stop();

      if (receipt?.status !== 1) {
        throw new Error('Transaction failed');
      }

      logger.info('✅ Token submitted to the Private Hub!');
      logger.info(`📄 Transaction Hash: ${tx.hash}`);
      logger.info(`🏪 Private Address: ${taskArgs.tokenAddress}`);
      logger.info(`📛 Token Name: ${tokenInfo.name} (${tokenInfo.symbol})`);
      logger.info('📊 hubStatus is now WAITING_APPROVAL (1)');
      logger.info('');
      logger.info('📋 Next steps (hub path):');
      logger.info('');
      logger.info('1) Once the relayer has registered the token on the Private Hub, fetch its resourceId from the hub:');
      logger.info(`     npx hardhat tokens:check-resource-id --symbol ${tokenInfo.symbol}`);
      logger.info(`   Add the printed TOKEN_${String(tokenInfo.symbol).toUpperCase()}_RESOURCE_ID=0x... line to your .env.`);
      logger.info('');
      logger.info('2) The PNH operator approves the token on the Private Hub:');
      logger.info(`     npx hardhat tokens:approve-hub --symbol ${tokenInfo.symbol}`);
      logger.info('');
      logger.info('Once approved, the PNH callback sets hubStatus = AUTHORIZED (2) and private cross-chain operations are enabled.');

      return {
        success: true,
        privateAddress: taskArgs.tokenAddress,
        name: tokenInfo.name,
        symbol: tokenInfo.symbol,
        transactionHash: tx.hash
      };
    } catch (error: any) {
      spinner.stop();
      logger.error('❌ Failed to submit token to the Private Hub');
      logger.error(`Error: ${error.message}`);
      return { success: false, error: error.message };
    }
  });
