import { task } from 'hardhat/config';
import { Spinner } from '../../utils/spinner';
import { Logger, LogLevel } from '../../test/unit/utils/moca-logger';
import { getEnvVariableOrFlag } from '../../utils/getEnvOrFlag';
import { assertValidAddress, detectTokenStandardName } from '../../utils/tokenStandards';

const TOKEN_METADATA_ABI = [
  'function name() view returns (string)',
  'function symbol() view returns (string)',
];

const logger = new Logger();
const logLevel = Number(process.env['TEST_LOGGING_LEVEL'] || LogLevel.INFO);
logger.setLogLevel(logLevel);

task('tokens:register', 'Register a token on the PN TokenRegistry')
  .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D)')
  .addParam('tokenAddress', 'The deployed token address')
  .addOptionalParam('isCustom', 'Whether token uses a custom implementation', 'false')
  .addOptionalParam('privateKey', 'Private key used to sign the registration transaction')
  .addOptionalParam('rpcUrl', 'The URL of the JSON-RPC API')
  .addOptionalParam('registryAddress', 'DeploymentProxyRegistry address')
  .setAction(async (taskArgs, hre) => {
    const { ethers, run } = hre;
    await run('compile');

    const tokenAddress = assertValidAddress(taskArgs.tokenAddress, 'token address', ethers);

    const normalizedIsCustom = String(taskArgs.isCustom).toLowerCase();
    if (!['true', 'false'].includes(normalizedIsCustom)) {
      throw new Error(`Invalid isCustom value "${taskArgs.isCustom}". Use true or false.`);
    }
    const isCustom = normalizedIsCustom === 'true';

    const spinner: Spinner = new Spinner();
    const pn = String(taskArgs.pn).toUpperCase();
    const rpcUrl = getEnvVariableOrFlag('RPC URL', `PRIVACY_NODE_${pn}_RPC_URL`, 'rpcUrl', '--rpc-url', taskArgs);
    const deploymentRegistryAddress = assertValidAddress(getEnvVariableOrFlag(
      'Registry Address',
      `PRIVACY_NODE_${pn}_DEPLOYMENT_PROXY_REGISTRY`,
      'registryAddress',
      '--registry-address',
      taskArgs,
    ), 'deployment registry address', ethers);
    const privateKey = getEnvVariableOrFlag('Private Key', 'PRIVATE_KEY_SYSTEM', 'privateKey', '--private-key', taskArgs);

    logger.debug(`Registering token ${tokenAddress} on TokenRegistry for PN ${pn}...`);
    spinner.start();

    const provider = new ethers.JsonRpcProvider(rpcUrl);
    const wallet = new ethers.Wallet(privateKey);
    const signer = new ethers.NonceManager(wallet.connect(provider));

    const deploymentRegistry = await ethers.getContractAt('DeploymentProxyRegistryV1', deploymentRegistryAddress, signer);
    const tokenRegistryAddress = assertValidAddress(
      await deploymentRegistry.getContract('TokenRegistry'),
      'TokenRegistry address',
      ethers,
    );
    const tokenRegistry = await hre.ethers.getContractAt('PNTokenRegistryV1', tokenRegistryAddress, signer);

    // Skip re-registration if the token is already known to the registry.
    if (await tokenRegistry.tokenExists(tokenAddress)) {
      spinner.stop();
      logger.info(`Token already exists with private address: ${tokenAddress}`);
      return;
    }

    // Read metadata best-effort for logging only; the registry reads it on-chain during registration.
    const detectedStandard = await detectTokenStandardName(tokenAddress, signer, ethers);
    let tokenName = 'N/A';
    let tokenSymbol = 'N/A';
    try {
      const tokenContract = new ethers.Contract(tokenAddress, TOKEN_METADATA_ABI, signer);
      tokenName = await tokenContract.name();
      tokenSymbol = await tokenContract.symbol();
    } catch {
      // Token does not expose name()/symbol() (e.g. ERC1155); keep the 'N/A' fallback.
    }

    // Metadata (name/symbol/uri/standard) is now read on-chain from the token by the registry.
    const tx = await tokenRegistry.registerToken(tokenAddress, {
      gasLimit: 5_000_000,
    });
    const receipt = await tx.wait();
    spinner.stop();

    if (!receipt || receipt.status !== 1) {
      throw new Error(`Failed to register token ${tokenAddress} on TokenRegistry`);
    }

    let tokenExists = false;
    try {
      tokenExists = await tokenRegistry.tokenExists(tokenAddress);
    } catch {
      logger.debug('Could not verify token existence after successful registration');
    }

    const tokenStandard = detectedStandard
      ? `${detectedStandard.standardName} (${detectedStandard.standardValue})`
      : 'N/A';

    logger.info('✅ Token successfully registered on TokenRegistry!');
    logger.info(`📄 Transaction Hash: ${receipt.hash}`);
    logger.info(`🏪 Private Address: ${tokenAddress}`);
    logger.info(`📛 Token Name: ${tokenName}`);
    logger.info(`🔤 Token Symbol: ${tokenSymbol || 'N/A'}`);
    logger.info(`📊 Token Standard: ${tokenStandard}`);
    logger.info(`✅ Token Exists: ${tokenExists}`);
    logger.debug(`PN: ${pn}`);
    logger.debug(`TokenRegistryV1: ${tokenRegistryAddress}`);
    logger.debug(`isCustom: ${isCustom}`);
    logger.debug('Next step:');
    logger.debug(`Authorize the token on the PN (privacyNodeStatus = AUTHORIZED): \n npx hardhat tokens:approve-pn --pn ${pn} --token-address ${tokenAddress}`);
});
