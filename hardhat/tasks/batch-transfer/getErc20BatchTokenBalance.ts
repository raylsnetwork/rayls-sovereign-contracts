import { task } from 'hardhat/config';
import { Spinner } from '../../utils/spinner';
import { getDeploymentProxyRegistryAddress } from '../utils/deploymentProxyHelper';

task('batch-transfer:erc20-get-balance', 'Retrieves the token balance')
  .addParam('pn', 'The Privacy Node to check the balance in e.g.: A, B, ...')
  .addParam('address', 'The address to check the balance')
  .addParam('resourceId', 'The resourceId of the token')
  .setAction(async (taskArgs, hre) => {
    const spinner: Spinner = new Spinner();
    spinner.start();

    const rpcUrl = process.env[`PRIVACY_NODE_${taskArgs.pn}_RPC_URL`];
    const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
    const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);
    const signer = wallet.connect(provider);
    
    const deploymentRegistryAddress = process.env[`PRIVACY_NODE_${taskArgs.pn}_DEPLOYMENT_PROXY_REGISTRY`] as string;
    const contracts = await getDeploymentProxyRegistryAddress(['Endpoint'], deploymentRegistryAddress, signer, hre.ethers);
    const endpointAddress = contracts[0];
    const endpoint = await hre.ethers.getContractAt('EndpointV1', endpointAddress, signer);
    const tokenAddress = await endpoint.connect(signer).getAddressByResourceId(taskArgs.resourceId);
    
    spinner.stop();
    
    if (tokenAddress == '0x0000000000000000000000000000000000000000') {
      console.log(`Token not implemented on PN ${taskArgs.pn}`);
      return;
    }

    const token = await hre.ethers.getContractAt('Erc20BatchTeleport', tokenAddress, signer);

    console.log(`Found Implemented on PN ${taskArgs.pn} at address ${tokenAddress}`);
    console.log('');
    console.log('Token Data:');
    console.log(`- Symbol: ${await token.symbol()}`);
    console.log(`- Name: ${await token.name()}`);
    console.log(`- Balance of ${taskArgs.address}: ${await token.balanceOf(taskArgs.address)}`);
  });
