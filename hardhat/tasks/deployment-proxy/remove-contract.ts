import '@nomicfoundation/hardhat-ethers';
import { task } from 'hardhat/config';

task('deployment-proxy:remove-contract', 'Removes a contract from the registry')
  .addParam('name', 'The name of the contract to remove')
  .addParam('node', 'The node to use')
  .setAction(async ({ name, node }, hre) => {

    const rpcUrl = process.env[`PRIVACY_NODE_${node}_RPC_URL`];
    const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
    const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);
    const signer = new hre.ethers.NonceManager(wallet.connect(provider));

    console.log('Removing contract...');
    console.log('Name:', name);

    const deploymentRegistryAddress = process.env[`PRIVACY_NODE_${node}_DEPLOYMENT_PROXY_REGISTRY`] as string;

    const deploymentProxyRegistry = await hre.ethers.getContractAt('DeploymentProxyRegistryV1', deploymentRegistryAddress, signer);
    
    const tx = await deploymentProxyRegistry.removeContract(name, { gasLimit: 5000000 });
    await tx.wait();
    
    console.log('Contract removed successfully');
    
    return tx;
  }); 