import '@nomicfoundation/hardhat-ethers';
import { task } from 'hardhat/config';

task('deployment-proxy:get-contract', 'Gets a contract address by name')
  .addParam('name', 'The name of the contract to query')
  .addParam('node', 'The node to use')
  .setAction(async ({ name, node }, hre) => {
    console.log('Getting contract address for:', name);

    const rpcUrl = process.env[`PRIVACY_NODE_${node}_RPC_URL`];
    const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
    const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);
    const signer = new hre.ethers.NonceManager(wallet.connect(provider));

    const deploymentRegistryAddress = process.env[`PRIVACY_NODE_${node}_DEPLOYMENT_PROXY_REGISTRY`] as string;

    const deploymentProxyRegistry = await hre.ethers.getContractAt('DeploymentProxyRegistryV1', deploymentRegistryAddress, signer);
    
    const address = await deploymentProxyRegistry.getContract(name);
    
    console.log(`Contract "${name}" address:`, address);
    
    return address;
  }); 