import { task } from 'hardhat/config';
import { Spinner } from '../../utils/spinner';
import { getEnvVariableOrFlag } from '../../utils/getEnvOrFlag';

const ZERO_RESOURCE_ID =
  '0x0000000000000000000000000000000000000000000000000000000000000000';

task(
  'tokens:check-resource-id',
  'Look up a token on the Private Network Hub by symbol and print its resourceId',
)
  .addParam('symbol', 'The token symbol (ex: MYTOKEN)')
  .addOptionalParam('rpcUrl', 'The url of the json rpc api from the private hub')
  .addOptionalParam('contractAddress', 'The Deployment Registry contract address')
  .setAction(async (taskArgs, { ethers }) => {
    const spinner: Spinner = new Spinner();
    const rpcUrl = getEnvVariableOrFlag(
      'Private Hub RPC Url',
      'PNH_RPC_URL',
      'rpcUrl',
      '--rpc-url',
      taskArgs,
    );
    const deploymentRegistryAddress = getEnvVariableOrFlag(
      'Deployment Registry Address',
      'PNH_DEPLOYMENT_PROXY_REGISTRY',
      'contractAddress',
      '--contract-address',
      taskArgs,
    );

    console.log('Checking token information on the Private Hub...');
    spinner.start();

    const provider = new ethers.JsonRpcProvider(rpcUrl);
    const venOperatorWallet = new ethers.Wallet(
      process.env['PRIVATE_KEY_SYSTEM'] as string,
    );
    const signer = venOperatorWallet.connect(provider);

    const deploymentRegistry = await ethers.getContractAt(
      'DeploymentProxyRegistryV1',
      deploymentRegistryAddress,
      signer,
    );
    const tokenRegistryAddress =
      await deploymentRegistry.getContract('TokenRegistry');

    const tokenRegistry = await ethers.getContractAt(
      'TokenRegistryV1',
      tokenRegistryAddress,
      signer,
    );

    const tokens = await tokenRegistry.getAllTokens({ gasLimit: 5000000 });
    const normalizedSymbol = String(taskArgs.symbol).toUpperCase();
    const token = tokens.find(
      (t: any) => String(t.symbol).toUpperCase() === normalizedSymbol,
    );

    spinner.stop();

    if (!token) {
      console.log(
        `No token with symbol "${taskArgs.symbol}" is registered on the Private Hub yet.`,
      );
      console.log(
        `👉 Make sure \`submitTokenToHub\` was called and the relayer is running, then retry.`,
      );
      return;
    }

    if (token.resourceId === ZERO_RESOURCE_ID) {
      console.log(
        `Token "${token.symbol}" found on the hub but has no resourceId yet. Check that the relayer is working properly.`,
      );
      return;
    }

    const approved = token.status == BigInt(1);
    console.log(
      `The token got successfully registered with the resourceId ${token.resourceId}`,
    );
    console.log(
      `Name: "${token.name}" | Symbol: "${token.symbol}" | Status: ${approved ? 'Approved' : 'Not Approved'}`,
    );
    console.log(``);
    console.log(
      `👉 Add the variable below in .env to interact with this token. Always mention by symbol with flag --token ${token.symbol}`,
    );
    console.log(`TOKEN_${normalizedSymbol}_RESOURCE_ID=${token.resourceId}`);

    if (!approved) {
      console.log(``);
      console.log(
        `Token is not approved yet. Approve it on the hub with: npx hardhat tokens:approve-hub --symbol ${token.symbol}`,
      );
    }
  });
