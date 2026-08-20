import { task } from 'hardhat/config';
import * as path from 'node:path';
import { Spinner } from '../../../utils/spinner';
import { getEnvVariableFromFile, upsertEnvVariable } from '../../../utils/envFile';
import { getEnvVariableOrFlag } from '../../../utils/getEnvOrFlag';
import { assertValidAddress } from '../../../utils/tokenStandards';
import { getDeploymentProxyRegistryAddress } from '../../utils/deploymentProxyHelper';

export const genRanHex = (size: number) => [...Array(size)].map(() => Math.floor(Math.random() * 16).toString(16)).join('');

/**
 * Builds the deploy action, parameterized by the concrete ERC721 contract to instantiate.
 * Production uses `ProductionErc721Token` (canonical handler surface, matches the factory-seeded
 * template); the `_test` task uses `RaylsErc721Example` (test-only public `awardItem` mint).
 */
function makeErc721DeployAction(contractName: string) {
  return async (taskArgs: any, hre: any) => {
    const spinner: Spinner = new Spinner();
    const pn = String(taskArgs.pn).toUpperCase();

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
    console.log(`Deploying token on ${pn}...`);
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
      taskArgs.uri,
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

    console.log(`Token Deployed At Address ${tokenAddress}`);
    console.log(`Stored ${envKey}=${tokenAddress} in ${envFilePath}`);
    console.log('Token Deployer Address: ', wallet.address);
    console.log('Token uri: ', taskArgs.uri);
    console.log('Token name: ', taskArgs.name);
    console.log('Token symbol: ', taskArgs.symbol);

    console.log('Next step — register the token:');
    console.log(`npx hardhat tokens:register --pn ${pn} --token-address ${tokenAddress}`);
    return tokenPN;
  };
}

task('tokens:erc721:deploy', 'Deploys ERC721 (ProductionErc721Token) on the PN')
  .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D)')
  .addParam('symbol', 'The ERC 721 symbol')
  .addParam('name', 'The name of the ERC 721 contract')
  .addParam('uri', 'The ERC 721 URI')
  .addOptionalParam('privateKey', 'private key of token deployer')
  .addOptionalParam('rpcUrl', 'The URL of the JSON-RPC API')
  .addOptionalParam('registryAddress', 'DeploymentProxyRegistry address')
  .setAction(makeErc721DeployAction('ProductionErc721Token'));

task('tokens:erc721:deploy_test', 'Deploys the test ERC721 (RaylsErc721Example) on the PN')
  .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D)')
  .addParam('symbol', 'The ERC 721 symbol')
  .addParam('name', 'The name of the ERC 721 contract')
  .addParam('uri', 'The ERC 721 URI')
  .addOptionalParam('privateKey', 'private key of token deployer')
  .addOptionalParam('rpcUrl', 'The URL of the JSON-RPC API')
  .addOptionalParam('registryAddress', 'DeploymentProxyRegistry address')
  .setAction(makeErc721DeployAction('RaylsErc721Example'));
