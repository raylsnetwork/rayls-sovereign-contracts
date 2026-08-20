/**
 * @deprecated Decommissioning Teleport (vanilla, atomic).
 */
import { task } from 'hardhat/config';
import { Spinner } from '../../utils/spinner';
import { Logger, LogLevel } from '../../test/unit/utils/moca-logger';
import {getTokenByPrivateAddress} from '../tokens/checkTokenAllChains';

const logger = new Logger();
const logLevel = Number(process.env['TEST_LOGGING_LEVEL'] || LogLevel.INFO);
logger.setLogLevel(logLevel);

task('sendTokenToPublicChain', 'Send token from privacy node to public chain by locking on sender side')
  .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D)')
  .addParam('tokenAddress', 'The token private address')
  .addParam('destinationAddress', 'The destination address on public chain')
  .addParam('amount', 'The amount to be transferred')
  .addParam('destinationChainId', 'The destination public chain ID')
  .addOptionalParam('rpcUrl', 'Custom RPC URL (overrides environment variable)')
  .addOptionalParam('privateKey', 'Custom private key (overrides environment variable)')
  .setAction(async (taskArgs, hre) => {
    await hre.run('compile');
    
    const spinner: Spinner = new Spinner();
    
    try {
      // Load environment variables or use provided parameters
      const rpcUrl = taskArgs.rpcUrl || process.env[`PRIVACY_NODE_${taskArgs.pn}_RPC_URL`];
      const privateKey = taskArgs.privateKey || process.env['PRIVATE_KEY_USER'];

      if (!rpcUrl) {
        throw new Error(`RPC URL not found. Set PRIVACY_NODE_${taskArgs.pn}_RPC_URL environment variable or use --rpc-url parameter`);
      }
      if (!privateKey) {
        throw new Error('Private key not found. Set PRIVATE_KEY_SYSTEM environment variable or use --private-key parameter');
      }

      logger.debug(`Sending token to public chain from ${taskArgs.pn}...`);
      logger.debug(`Token Address: ${taskArgs.tokenAddress}`);
      logger.debug(`Destination Address: ${taskArgs.destinationAddress}`);
      logger.debug(`Amount: ${taskArgs.amount}`);
      logger.debug(`Destination Chain ID: ${taskArgs.destinationChainId}`);
      
      spinner.start();

      // Get token contract using existing utility
      const token = await getTokenByPrivateAddress(hre, taskArgs.pn, taskArgs.tokenAddress);
      
      // Setup provider and signer for the transaction
      const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
      const wallet = new hre.ethers.Wallet(privateKey);
      const signer = new hre.ethers.NonceManager(wallet.connect(provider));
      
      // Connect token contract with signer
      const tokenWithSigner = token.connect(signer);
      
      logger.debug('Calling teleportToPublicChain...');
      
      // Call teleportToPublicChain function
      const tx = await tokenWithSigner.teleportToPublicChain(
        taskArgs.destinationAddress,       // to: recipient on public chain
        taskArgs.amount,                   // value: amount to bridge
        taskArgs.destinationChainId        // destinationChainId: target public chain
      );
      
      logger.debug(`Transaction submitted: ${tx.hash}`);
      
      // Wait for transaction confirmation
      const receipt = await tx.wait();
      spinner.stop();

      if (receipt?.status === 1) {
        logger.info('✅ Token successfully sent to public chain!');
        logger.info(`📄 Transaction Hash: ${tx.hash}`);
        logger.info(`🪙 Token Address: ${taskArgs.tokenAddress}`);
        logger.info(`💰 Amount: ${taskArgs.amount}`);
        logger.info(`🌐 From PN: ${taskArgs.pn}`);
        logger.info(`📍 To Address: ${taskArgs.destinationAddress}`);
        logger.info(`⛓️  To Chain ID: ${taskArgs.destinationChainId}`);
        logger.info('');
        logger.info('📋 Next steps:');
        logger.info('• Relayers will detect the bridge event');
        logger.info('• Tokens will be minted on the target public chain');
        logger.info('• Check the destination address on the public chain for received tokens');

        return {
          success: true,
          txHash: tx.hash,
          tokenAddress: taskArgs.tokenAddress,
          amount: taskArgs.amount,
          fromPN: taskArgs.pn,
          toAddress: taskArgs.destinationAddress,
          toChainId: taskArgs.destinationChainId
        };

      } else {
        throw new Error('Transaction failed');
      }

    } catch (error: any) {
      spinner.stop();
      logger.error('❌ Failed to send token to public chain');
      logger.error(`Error: ${error.message}`);

      return { success: false, error: error.message };
    }
  });