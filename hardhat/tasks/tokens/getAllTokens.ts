import { task } from 'hardhat/config';
import { getEnvVariableOrFlag } from '../../utils/getEnvOrFlag';

task('getAllTokens', 'List all registered tokens from the TokenRegistry contract')
  .addOptionalParam('rpcUrlNodePnh', 'The url of the json rpc api from the private hub')
  .addOptionalParam('contractAddress', 'The Deployment Registry contract address')
  .setAction(async (taskArgs, { ethers }) => {
    const rpcUrl = getEnvVariableOrFlag('Private Hub RPC Url', `PNH_RPC_URL`, 'rpcUrlNodePnh', '--rpc-url', taskArgs);
    const deploymentRegistryAddress = getEnvVariableOrFlag('Deployment Registry Address', `PNH_DEPLOYMENT_PROXY_REGISTRY`, 'contractAddress', '--contract-address', taskArgs);

    const provider = new ethers.JsonRpcProvider(rpcUrl);
    const venOperatorWallet = new ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);
    const signer = venOperatorWallet.connect(provider);

    // Load the Deployment Registry contract
    const deploymentRegistry = await ethers.getContractAt('DeploymentProxyRegistryV1', deploymentRegistryAddress!, signer);
    const tokenRegistryAddress = await deploymentRegistry.getContract('TokenRegistry');

    // Load the TokenRegistry contract
    const TokenRegistry = await ethers.getContractAt('TokenRegistryV1', tokenRegistryAddress, signer);
    // Call getAllTokens function
    const tokens = await TokenRegistry.getAllTokens({ gasLimit: 5000000 });
    for (var token of tokens) {
      console.log(`ResourceId: ${token.resourceId} | Name: "${token.name}" | Symbol: "${token.symbol}" | Status: ${token.status == BigInt(1) ? 'Approved' : 'Not Approved'}`);
    }
  });
