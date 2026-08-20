/**
 * @deprecated Decommissioning Teleport (vanilla, atomic).
 */
import { task } from 'hardhat/config';
import { Spinner } from '../../utils/spinner';
import { Logger, LogLevel } from '../../test/unit/utils/moca-logger';

const logger = new Logger();
const logLevel = Number(process.env['TEST_LOGGING_LEVEL'] || LogLevel.INFO);
logger.setLogLevel(logLevel);

task('checkPublicChainBalance', 'Check balance of a token on public chain after bridging from privacy node')
  .addParam('privateTokenAddress', 'The private token address on the privacy node')
  .addParam('userAddress', 'The user address to check balance for')
  .addParam('destinationChainId', 'The destination public chain ID')
  .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D)')
  .addOptionalParam('tokenId', 'Token ID for ERC1155 tokens (required for ERC1155, ignored for ERC20/ERC721)')
  .addOptionalParam('publicRpcUrl', 'Custom RPC URL for the public chain (overrides environment variable)')
  .addOptionalParam('privateRpcUrl', 'Custom RPC URL for the privacy node (overrides environment variable)')
  .addOptionalParam('privateKey', 'Custom private key (overrides environment variable)')
  .setAction(async (taskArgs, hre) => {
    await hre.run('compile');
    
    const spinner: Spinner = new Spinner();
    
    try {
      // Validate input parameters
      if (!hre.ethers.isAddress(taskArgs.privateTokenAddress)) {
        throw new Error('Invalid private token address format');
      }
      
      if (!hre.ethers.isAddress(taskArgs.userAddress)) {
        throw new Error('Invalid user address format');
      }

      // Load environment variables or use provided parameters
      const privateRpcUrl = taskArgs.privateRpcUrl || process.env[`PRIVACY_NODE_${taskArgs.pn}_RPC_URL`];
      const privateKey = taskArgs.privateKey || process.env['PRIVATE_KEY_SYSTEM'];
      const tokenRegistryAddress = process.env[`PRIVACY_NODE_${taskArgs.pn}_TOKEN_REGISTRY_ADDRESS`];

      if (!privateRpcUrl) {
        throw new Error(`Private RPC URL not found. Set PRIVACY_NODE_${taskArgs.pn}_RPC_URL environment variable or use --private-rpc-url parameter`);
      }
      if (!privateKey) {
        throw new Error('Private key not found. Set PRIVATE_KEY_SYSTEM environment variable or use --private-key parameter');
      }
      if (!tokenRegistryAddress) {
        throw new Error(`Token registry address not found. Set PRIVACY_NODE_${taskArgs.pn}_TOKEN_REGISTRY_ADDRESS environment variable`);
      }

      logger.debug(`Checking public chain balance...`);
      logger.debug(`Private Token Address: ${taskArgs.privateTokenAddress}`);
      logger.debug(`User Address: ${taskArgs.userAddress}`);
      logger.debug(`Destination Chain ID: ${taskArgs.destinationChainId}`);
      logger.debug(`Privacy Node: ${taskArgs.pn}`);
      
      spinner.start();

      // Step 1: Connect to Privacy Node and get TokenRegistry contract
      const privateProvider = new hre.ethers.JsonRpcProvider(privateRpcUrl);
      const privateWallet = new hre.ethers.Wallet(privateKey);
      const privateSigner = privateWallet.connect(privateProvider);

      const tokenRegistry = await hre.ethers.getContractAt('PNTokenRegistryV1', tokenRegistryAddress, privateSigner);

      // Step 2: Check if token exists and get public token address
      const tokenExists = await tokenRegistry.tokenExists(taskArgs.privateTokenAddress);
      if (!tokenExists) {
        throw new Error(`Token with private address ${taskArgs.privateTokenAddress} does not exist in TokenRegistry`);
      }

      // Step 3: Get token info (includes the public token address) to display additional details
      const tokenInfo = await tokenRegistry.getTokenByAddress(taskArgs.privateTokenAddress);

      const publicTokenAddress = tokenInfo.publicTokenAddress;
      if (publicTokenAddress === hre.ethers.ZeroAddress) {
        throw new Error('Public token address is not set. Token may not have been deployed on the public chain yet');
      }
      
      logger.debug(`Found public token address: ${publicTokenAddress}`);
      
      // Step 4: Connect to Public Chain
      let publicRpcUrl = taskArgs.publicRpcUrl;
      if (!publicRpcUrl) {
        // Try to find RPC URL based on chain ID in environment variables
        const chainId = taskArgs.destinationChainId;
        publicRpcUrl = process.env["PUBLIC_CHAIN_RPC_URL"];
        
        if (!publicRpcUrl) {
          throw new Error(`Public chain RPC URL not found for chain ID ${chainId}. Set PUBLIC_CHAIN_${chainId}_RPC_URL environment variable or use --public-rpc-url parameter`);
        }
      }

      const publicProvider = new hre.ethers.JsonRpcProvider(publicRpcUrl);
      
      // Step 5: Get token contract on public chain and check balance
      let publicTokenContract;
      let userBalance;
      
      try {
        // Try as ERC20 first (most common)
        publicTokenContract = await hre.ethers.getContractAt("PublicChainERC20", publicTokenAddress, publicProvider);
        userBalance = await publicTokenContract.balanceOf(taskArgs.userAddress);
        
        // Get token decimals for proper display
        let decimals = 18; // Default
        try {
          decimals = await publicTokenContract.decimals();
        } catch (e) {
          logger.debug('Could not get token decimals, using default 18');
        }
        
        spinner.stop();

        logger.info('✅ Public chain token balance retrieved successfully!');
        logger.info(`📄 Privacy Node: ${taskArgs.pn}`);
        logger.info(`🏦 Private Token Address: ${taskArgs.privateTokenAddress}`);
        logger.info(`🌐 Public Token Address: ${publicTokenAddress}`);
        logger.info(`🪙 Token Name: ${tokenInfo.name}`);
        logger.info(`🎫 Token Symbol: ${tokenInfo.symbol}`);
        logger.info(`🎫 Token Standard: ${tokenInfo.ercStandard} => ERC20`);
        logger.info(`👤 User Address: ${taskArgs.userAddress}`);
        logger.info(`⛓️  Chain ID: ${taskArgs.destinationChainId}`);
        logger.info(`💰 Balance: ${hre.ethers.formatUnits(userBalance, decimals)} ${tokenInfo.symbol}`);
        logger.info(`🔢 Raw Balance: ${userBalance.toString()}`);
        
        return {
          success: true,
          privateTokenAddress: taskArgs.privateTokenAddress,
          publicTokenAddress: publicTokenAddress,
          userAddress: taskArgs.userAddress,
          chainId: taskArgs.destinationChainId,
          tokenName: tokenInfo.name,
          tokenSymbol: tokenInfo.symbol,
          balance: userBalance.toString(),
          formattedBalance: hre.ethers.formatUnits(userBalance, decimals)
        };

      } catch (contractError: any) {
        // If ERC20 fails, try ERC721
        if (tokenInfo.ercStandard === 2n) { // 2 = ERC721 (SharedObjects.ErcStandard)
          try {
            publicTokenContract = await hre.ethers.getContractAt("PublicChainERC721", publicTokenAddress, publicProvider);
            userBalance = await publicTokenContract.balanceOf(taskArgs.userAddress);
            
            spinner.stop();
            
            logger.info('✅ Public chain NFT balance retrieved successfully!');
            logger.info(`📄 Privacy Node: ${taskArgs.pn}`);
            logger.info(`🏦 Private Token Address: ${taskArgs.privateTokenAddress}`);
            logger.info(`🌐 Public Token Address: ${publicTokenAddress}`);
            logger.info(`🪙 Token Name: ${tokenInfo.name}`);
            logger.info(`🎫 Token Symbol: ${tokenInfo.symbol}`);
            logger.info(`📊 Token Standard: ERC721`);
            logger.info(`👤 User Address: ${taskArgs.userAddress}`);
            logger.info(`⛓️  Chain ID: ${taskArgs.destinationChainId}`);
            logger.info(`💰 NFT Balance: ${userBalance.toString()} NFTs`);
            
            return {
              success: true,
              privateTokenAddress: taskArgs.privateTokenAddress,
              publicTokenAddress: publicTokenAddress,
              userAddress: taskArgs.userAddress,
              chainId: taskArgs.destinationChainId,
              tokenName: tokenInfo.name,
              tokenSymbol: tokenInfo.symbol,
              balance: userBalance.toString(),
              tokenStandard: 'ERC721'
            };
            
          } catch (erc721Error) {
            throw new Error(`Failed to interact with PublicChainERC721 contract: ${erc721Error}`);
          }
        } else if (tokenInfo.ercStandard === 3n) { // 3 = ERC1155 (SharedObjects.ErcStandard)
          try {
            if (!taskArgs.tokenId) {
              throw new Error('ERC1155 token requires --token-id parameter for balance checking');
            }
            
            publicTokenContract = await hre.ethers.getContractAt("PublicChainERC1155", publicTokenAddress, publicProvider);
            userBalance = await publicTokenContract.balanceOf(taskArgs.userAddress, taskArgs.tokenId);
            
            spinner.stop();
            
            logger.info('✅ Public chain ERC1155 balance retrieved successfully!');
            logger.info(`📄 Privacy Node: ${taskArgs.pn}`);
            logger.info(`🏦 Private Token Address: ${taskArgs.privateTokenAddress}`);
            logger.info(`🌐 Public Token Address: ${publicTokenAddress}`);
            logger.info(`🪙 Token Name: ${tokenInfo.name}`);
            logger.info(`🎫 Token Symbol: ${tokenInfo.symbol}`);
            logger.info(`📊 Token Standard: ERC1155`);
            logger.info(`👤 User Address: ${taskArgs.userAddress}`);
            logger.info(`⛓️  Chain ID: ${taskArgs.destinationChainId}`);
            logger.info(`🆔 Token ID: ${taskArgs.tokenId}`);
            logger.info(`💰 Balance: ${userBalance.toString()} tokens`);
            
            return {
              success: true,
              privateTokenAddress: taskArgs.privateTokenAddress,
              publicTokenAddress: publicTokenAddress,
              userAddress: taskArgs.userAddress,
              chainId: taskArgs.destinationChainId,
              tokenName: tokenInfo.name,
              tokenSymbol: tokenInfo.symbol,
              tokenId: taskArgs.tokenId,
              balance: userBalance.toString(),
              tokenStandard: 'ERC1155'
            };
            
          } catch (erc1155Error) {
            throw new Error(`Failed to interact with PublicChainERC1155 contract: ${erc1155Error}`);
          }
        } else {
          throw new Error(`Failed to interact with PublicChainERC20 contract: ${contractError.message}`);
        }
      }

    } catch (error: any) {
      spinner.stop();
      logger.error('❌ Failed to check public chain token balance');
      logger.error(`Error: ${error.message}`);

      return { success: false, error: error.message };
    }
  });