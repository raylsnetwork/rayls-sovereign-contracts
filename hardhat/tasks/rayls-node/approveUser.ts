import { task } from 'hardhat/config';
import { Spinner } from '../../utils/spinner';
import { Logger, LogLevel } from '../../test/unit/utils/moca-logger';

const logger = new Logger();
const logLevel = Number(process.env['TEST_LOGGING_LEVEL'] || LogLevel.INFO);
logger.setLogLevel(logLevel);

task('approveUser', 'Approve all pending address pairs for a user in the UserGovernance contract')
  .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D)')
  .addParam('userId', 'The user ID as a hex string (bytes32)')
  .addOptionalParam('rpcUrl', 'Custom RPC URL (overrides environment variable)')
  .addOptionalParam('privateKey', 'Custom private key (overrides environment variable)')
  .addOptionalParam('userGovernanceAddress', 'Custom UserGovernance contract address (overrides environment variable)')
  .setAction(async (taskArgs, { ethers, run }) => {
    await run('compile');
    
    const spinner: Spinner = new Spinner();
    
    try {
      // Validate parameters
      if (!taskArgs.userId.startsWith('0x') || taskArgs.userId.length !== 66) {
        throw new Error('Invalid user ID format. Must be a 32-byte hex string starting with 0x');
      }


      // Load environment variables or use provided parameters
      const rpcUrl = taskArgs.rpcUrl || process.env[`PRIVACY_NODE_${taskArgs.pn}_RPC_URL`];
      const privateKey = taskArgs.privateKey || process.env['PRIVATE_KEY_SYSTEM'];
      const userGovernanceAddress = taskArgs.userGovernanceAddress || process.env[`PRIVACY_NODE_${taskArgs.pn}_RAYLS_NODE_USER_GOVERNANCE`];

      if (!rpcUrl) {
        throw new Error(`RPC URL not found. Set PRIVACY_NODE_${taskArgs.pn}_RPC_URL environment variable or use --rpc-url parameter`);
      }
      if (!privateKey) {
        throw new Error('Private key not found. Set PRIVATE_KEY_SYSTEM environment variable or use --private-key parameter');
      }
      if (!userGovernanceAddress) {
        throw new Error(`UserGovernance address not found. Set PRIVACY_NODE_${taskArgs.pn}_RAYLS_NODE_USER_GOVERNANCE environment variable or use --user-governance-address parameter`);
      }

      logger.debug(`Approving user on UserGovernance on ${taskArgs.pn}...`);
      logger.debug(`User ID: ${taskArgs.userId}`);
      
      spinner.start();

      // Setup provider and signer
      const provider = new ethers.JsonRpcProvider(rpcUrl);
      const wallet = new ethers.Wallet(privateKey);
      const signer = new ethers.NonceManager(wallet.connect(provider));

      // Get UserGovernance contract
      const userGovernance = await ethers.getContractAt('RNUserGovernanceV1', userGovernanceAddress, signer);

      // Check if user exists
      const userExists = await userGovernance.userExists(taskArgs.userId);
      if (!userExists) {
        spinner.stop();
        throw new Error(`User does not exist with ID: ${taskArgs.userId}`);
      }

      // Check if user has address pairs
      const addressPairCount = await userGovernance.getUserAddressPairCount(taskArgs.userId);
      if (addressPairCount === 0n) {
        spinner.stop();
        throw new Error(`User has no address pairs: ${taskArgs.userId}`);
      }

      logger.debug(`User has ${addressPairCount} address pairs`);
      logger.debug('Calling approveUser...');

      // Call approveUser
      const approveUserTx = await userGovernance.approveUser(taskArgs.userId);
      logger.debug(`ApproveUser transaction submitted: ${approveUserTx.hash}`);
      
      // Wait for transaction confirmation
      const approveUserReceipt = await approveUserTx.wait();
      spinner.stop();

      if (approveUserReceipt?.status === 1) {
        logger.info(`✅ User successfully approved!`);
        logger.info(`📄 Transaction Hash: ${approveUserTx.hash}`);
        logger.info(`👤 User ID: ${taskArgs.userId}`);
        logger.info(`⚡ Status: APPROVED & ACTIVE`);
        logger.info(`🔗 Affected address pairs: ${addressPairCount}`);
        logger.info('');
        logger.info('📋 Result:');
        logger.info(`All pending address pair(s) for this user have been approved and activated`);

        return {
          success: true,
          userId: taskArgs.userId,
          status: 'APPROVED',
          affectedAddressPairs: Number(addressPairCount),
          txHash: approveUserTx.hash
        };

      } else {
        throw new Error('ApproveUser transaction failed');
      }

    } catch (error: any) {
      spinner.stop();
      logger.error('❌ Failed to approve user');
      logger.error(`Error: ${error.message}`);

      return { success: false, error: error.message };
    }
  });