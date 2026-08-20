import { task } from 'hardhat/config';
import { Spinner } from '../../utils/spinner';
import { Logger, LogLevel } from '../../test/unit/utils/moca-logger';

const logger = new Logger();
const logLevel = Number(process.env['TEST_LOGGING_LEVEL'] || LogLevel.INFO);
logger.setLogLevel(logLevel);

task('createUser', 'Create a user and add address pair to the UserGovernance contract on Privacy Node. Auto-generates credentials if not provided.')
  .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D)')
  .addOptionalParam('userId', 'The user ID as a hex string (bytes32). If not provided, will be auto-generated')
  .addOptionalParam('publicAddress', 'The public address to associate with the user. If not provided, will be auto-generated')
  .addOptionalParam('privateAddress', 'The private address to associate with the user. If not provided, will be auto-generated')
  .addOptionalParam('rpcUrl', 'Custom RPC URL (overrides environment variable)')
  .addOptionalParam('privateKey', 'Custom private key (overrides environment variable)')
  .addOptionalParam('userGovernanceAddress', 'Custom UserGovernance contract address (overrides environment variable)')
  .setAction(async (taskArgs, { ethers, run }) => {
  await run('compile');
    
  const spinner: Spinner = new Spinner();
    
    try {
      // Auto-generation logic or validation
      let generatedCredentials: {
        publicWallet?: any;
        privateWallet?: any;
        isGenerated: boolean;
      } = { isGenerated: false };

      // Check if we need to generate credentials
      const hasUserId = taskArgs.userId && taskArgs.userId !== '';
      const hasPublicAddress = taskArgs.publicAddress && taskArgs.publicAddress !== '';
      const hasPrivateAddress = taskArgs.privateAddress && taskArgs.privateAddress !== '';
      const providedParams = [hasUserId, hasPublicAddress, hasPrivateAddress];
      const providedCount = providedParams.filter(Boolean).length;

      if (providedCount === 0) {
        // Generate all credentials
        logger.info('🎲 No credentials provided. Auto-generating user credentials...');
        
        // Generate userId
        taskArgs.userId = ethers.keccak256(ethers.randomBytes(32));
        
        // Generate wallet pairs
        const publicWallet = ethers.Wallet.createRandom();
        const privateWallet = ethers.Wallet.createRandom();
        
        taskArgs.publicAddress = publicWallet.address;
        taskArgs.privateAddress = privateWallet.address;
        
        generatedCredentials = {
          publicWallet,
          privateWallet,
          isGenerated: true
        };

        logger.info('✨ Credentials generated successfully!');
        
      } else if (providedCount !== 3) {
        // Partial parameters provided - this is not allowed
        throw new Error('Invalid parameter combination. Either provide all three parameters (userId, publicAddress, privateAddress) or none for auto-generation.');
      } else {
        // All parameters provided - validate them
        if (!taskArgs.userId.startsWith('0x') || taskArgs.userId.length !== 66) {
          throw new Error('Invalid user ID format. Must be a 32-byte hex string starting with 0x');
        }

        if (!ethers.isAddress(taskArgs.publicAddress)) {
          throw new Error('Invalid public address format');
        }
        
        if (!ethers.isAddress(taskArgs.privateAddress)) {
          throw new Error('Invalid private address format');
        }
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

      logger.debug(`Creating user on UserGovernance on ${taskArgs.pn}...`);
      logger.debug(`User ID: ${taskArgs.userId}`);
      logger.debug(`Public Address: ${taskArgs.publicAddress}`);
      logger.debug(`Private Address: ${taskArgs.privateAddress}`);
      
      spinner.start();

      // Setup provider and signer
      const provider = new ethers.JsonRpcProvider(rpcUrl);
      const wallet = new ethers.Wallet(privateKey);
      const signer = new ethers.NonceManager(wallet.connect(provider));

      // Get UserGovernance contract
      const userGovernance = await ethers.getContractAt('RNUserGovernanceV1', userGovernanceAddress, signer);

      // Check if user already exists
      try {
        const userExists = await userGovernance.userExists(taskArgs.userId);
        if (userExists) {
          spinner.stop();
          logger.info(`⚠️  User already exists with ID: ${taskArgs.userId}`);
          logger.info('Proceeding to add address pair...');
        } else {
          // Create user first
          logger.debug('Calling createUser...');
          const createUserTx = await userGovernance.createUser(taskArgs.userId);
          logger.debug(`CreateUser transaction submitted: ${createUserTx.hash}`);
          
          // Wait for transaction confirmation
          const createUserReceipt = await createUserTx.wait();
          
          if (createUserReceipt?.status !== 1) {
            throw new Error('CreateUser transaction failed');
          }

          logger.info('✅ User successfully created!');
          logger.info(`📄 CreateUser Transaction Hash: ${createUserTx.hash}`);
        }
      } catch (error: any) {
        if (!error.message.includes('User already exists')) {
          throw error;
        }
      }

      // Now add the address pair
      logger.debug('Calling addAddressPair...');
      const addAddressPairTx = await userGovernance.addAddressPair(
        taskArgs.userId,
        taskArgs.publicAddress,
        taskArgs.privateAddress
      );

      logger.debug(`AddAddressPair transaction submitted: ${addAddressPairTx.hash}`);
      
      // Wait for transaction confirmation
      const addAddressPairReceipt = await addAddressPairTx.wait();
      spinner.stop();

      if (addAddressPairReceipt?.status === 1) {
        logger.info('✅ User successfully created with address pair!');
        logger.info(`📄 AddAddressPair Transaction Hash: ${addAddressPairTx.hash}`);
        
        if (generatedCredentials.isGenerated) {
          logger.info('');
          logger.info('🎉 AUTO-GENERATED USER CREDENTIALS:');
          logger.info('════════════════════════════════════════════════');
          logger.info(`👤 User ID: ${taskArgs.userId}`);
          logger.info('');
          logger.info('🌐 PUBLIC WALLET (for public chain interactions):');
          logger.info(`   Address: ${taskArgs.publicAddress}`);
          logger.info(`   Private Key: ${generatedCredentials.publicWallet.privateKey}`);
          logger.info('');
          logger.info('🔐 PRIVATE WALLET (for privacy node interactions):');
          logger.info(`   Address: ${taskArgs.privateAddress}`);
          logger.info(`   Private Key: ${generatedCredentials.privateWallet.privateKey}`);
          logger.info('════════════════════════════════════════════════');
          logger.info('');
          logger.info('🔴 SECURITY WARNING:');
          logger.info('• SAVE these private keys securely - they cannot be recovered!');
          logger.info('• Store them in a secure password manager or encrypted file');
          logger.info('• Never share private keys or commit them to version control');
          logger.info('• You are responsible for the security of these credentials');
          logger.info('');
        } else {
          logger.info(`👤 User ID: ${taskArgs.userId}`);
          logger.info(`🌐 Public Address: ${taskArgs.publicAddress}`);
          logger.info(`🔐 Private Address: ${taskArgs.privateAddress}`);
          logger.info('');
        }

        logger.info('📋 Next steps:');
        logger.info('⚠️  IMPORTANT: User created but requires approval before use');
        logger.info('1. Approve the user to activate all address pairs:');
        logger.info(`   npx hardhat approveUser --pn ${taskArgs.pn} --user-id ${taskArgs.userId}`);
        logger.info('2. After approval, user can participate in cross-chain transfers');
        logger.info('3. Use the public address for interactions on public chains');
        logger.info('4. Use the private address for interactions on the privacy node');

        return {
          success: true,
          userId: taskArgs.userId,
          publicAddress: taskArgs.publicAddress,
          privateAddress: taskArgs.privateAddress,
          isGenerated: generatedCredentials.isGenerated,
          ...(generatedCredentials.isGenerated && {
            generatedCredentials: {
              publicPrivateKey: generatedCredentials.publicWallet.privateKey,
              privatePrivateKey: generatedCredentials.privateWallet.privateKey
            }
          }),
          createUserTxHash: undefined, // Will be set if user was created
          addAddressPairTxHash: addAddressPairTx.hash
        };

      } else {
        throw new Error('AddAddressPair transaction failed');
      }

    } catch (error: any) {
      spinner.stop();
      logger.error('❌ Failed to create user or add address pair');
      logger.error(`Error: ${error.message}`);

      return { success: false, error: error.message };
    }
  });