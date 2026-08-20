import { task } from 'hardhat/config';
import * as path from 'node:path';
import { Spinner } from '../../../utils/spinner';
import { Logger, LogLevel } from '../../../test/unit/utils/moca-logger';
import { getEnvVariableFromFile, upsertEnvVariable } from '../../../utils/envFile';
import { getEnvVariableOrFlag } from '../../../utils/getEnvOrFlag';
import { assertValidAddress } from '../../../utils/tokenStandards';
import { getDeploymentProxyRegistryAddress } from '../../utils/deploymentProxyHelper';
export const genRanHex = (size: number) => [...Array(size)].map(() => Math.floor(Math.random() * 16).toString(16)).join('');
const logger = new Logger();
const logLevel = Number(process.env['TEST_LOGGING_LEVEL'] || LogLevel.INFO);
logger.setLogLevel(logLevel);

/**
 * Builds the deploy action, parameterized by the concrete ERC20 contract to instantiate.
 * Production uses `ProductionErc20Token` (canonical handler surface, matches the factory-seeded
 * template); the `_test` task uses `TokenExample` (test-only hooks like `fakeMint`).
 */
function makeErc20DeployAction(contractName: string) {
  return async (taskArgs: any, hre: any) => {
    const spinner: Spinner = new Spinner();
    const pn = String(taskArgs.pn).toUpperCase();
    const randString = genRanHex(6);
    taskArgs.name = taskArgs.name || `Token ${randString}`;
    taskArgs.symbol = taskArgs.symbol || `T_${randString}`;
    const envKey = `TOKEN_${String(taskArgs.symbol).toUpperCase()}_ADDRESS`;
    const envFilePath = path.resolve(process.cwd(), '.env');
    const existingTokenAddress = getEnvVariableFromFile(envFilePath, envKey);

    if (existingTokenAddress) {
      throw new Error(
        `Token symbol "${taskArgs.symbol}" is already configured in ${envFilePath}: ` +
        `${envKey}=${existingTokenAddress}. Refusing to overwrite existing token address.`,
      );
    }

    await hre.run('compile');
    logger.debug(`Deploying ${contractName} token on ${pn}...`);
    spinner.start();
    const rpcUrl = getEnvVariableOrFlag('RPC URL', `PRIVACY_NODE_${pn}_RPC_URL`, 'rpcUrl', '--rpc-url', taskArgs);
    const provider = new hre.ethers.JsonRpcProvider(rpcUrl);

    taskArgs.privateKey = getEnvVariableOrFlag('Private Key', 'PRIVATE_KEY_SYSTEM', 'privateKey', '--private-key', taskArgs);

    const wallet = new hre.ethers.Wallet(taskArgs.privateKey as string);
    const signer = new hre.ethers.NonceManager(wallet.connect(provider));

    const token = await hre.ethers.getContractFactory(contractName, signer);

    const deploymentRegistryAddress = assertValidAddress(
      getEnvVariableOrFlag(
        'Registry Address',
        `PRIVACY_NODE_${pn}_DEPLOYMENT_PROXY_REGISTRY`,
        'registryAddress',
        '--registry-address',
        taskArgs,
      ),
      'deployment registry address',
      hre.ethers,
    );
    const [endpointAddress] = await getDeploymentProxyRegistryAddress(['Endpoint'], deploymentRegistryAddress, signer, hre.ethers);
    const [rnEndpointAddress] = await getDeploymentProxyRegistryAddress(['RNEndpoint'], deploymentRegistryAddress, signer, hre.ethers);
    const [userGovernanceAddress] = await getDeploymentProxyRegistryAddress(['RNUserGovernance'], deploymentRegistryAddress, signer, hre.ethers);

    const resolvedEndpointAddress = assertValidAddress(endpointAddress, `Endpoint address for PN ${pn}`, hre.ethers);
    const resolvedRnEndpointAddress = assertValidAddress(rnEndpointAddress, `RNEndpoint address for PN ${pn}`, hre.ethers);
    const resolvedUserGovernanceAddress = assertValidAddress(
      userGovernanceAddress,
      `RNUserGovernance address for PN ${pn}`,
      hre.ethers,
    );

    const tokenPN = await token.connect(signer).deploy(
      taskArgs.name,
      taskArgs.symbol,
      resolvedEndpointAddress,
      resolvedRnEndpointAddress,
      resolvedUserGovernanceAddress,
      { gasLimit: 5000000 },
    );

    await tokenPN.waitForDeployment();
    const tokenAddress = await tokenPN.getAddress();
    upsertEnvVariable(envFilePath, envKey, tokenAddress);
    process.env[envKey] = tokenAddress;
    spinner.stop();

    logger.info(`Token Deployed At Address ${tokenAddress}`);
    logger.info(`Stored ${envKey}=${tokenAddress} in ${envFilePath}`);
    logger.debug(`Token Deployer Address: ${wallet.address}`);
    logger.debug(`Token Name: ${taskArgs.name}`);
    logger.debug(`Token Symbol: ${taskArgs.symbol}`);

    logger.info('Next step — register the token:');
    logger.info(`npx hardhat tokens:register --pn ${pn} --token-address ${tokenAddress}`);
    return tokenPN;
  };
}

task('tokens:erc20:deploy', 'Deploys token (ProductionErc20Token) on the PN')
  .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D)')
  .addOptionalParam('name', 'Token Name')
  .addOptionalParam('symbol', 'symbol')
  .addOptionalParam('privateKey', 'private key of token deployer')
  .addOptionalParam('rpcUrl', 'The URL of the JSON-RPC API')
  .addOptionalParam('registryAddress', 'DeploymentProxyRegistry address')
  .setAction(makeErc20DeployAction('ProductionErc20Token'));

task('tokens:erc20:deploy_test', 'Deploys the test token (TokenExample) on the PN')
  .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D)')
  .addOptionalParam('name', 'Token Name')
  .addOptionalParam('symbol', 'symbol')
  .addOptionalParam('privateKey', 'private key of token deployer')
  .addOptionalParam('rpcUrl', 'The URL of the JSON-RPC API')
  .addOptionalParam('registryAddress', 'DeploymentProxyRegistry address')
  .setAction(makeErc20DeployAction('TokenExample'));
