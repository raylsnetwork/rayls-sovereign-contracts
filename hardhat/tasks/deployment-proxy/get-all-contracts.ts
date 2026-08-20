import '@nomicfoundation/hardhat-ethers';
import { task } from 'hardhat/config';

task('deployment-proxy:get-all-contracts', 'Gets all registered contracts')
  .addParam('node', 'The node to use')
  .setAction(async ({ node }, hre) => {
    console.log('Getting all registered contracts...');

    const rpcUrl = process.env[`PRIVACY_NODE_${node}_RPC_URL`];
    const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
    const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);
    const signer = new hre.ethers.NonceManager(wallet.connect(provider));

    let contractAddress = process.env[`PRIVACY_NODE_${node}_DEPLOYMENT_PROXY_REGISTRY`] as string;

    const deploymentProxyRegistry = await hre.ethers.getContractAt('DeploymentProxyRegistryV1', contractAddress, signer);
    
    const [names, addresses] = await deploymentProxyRegistry.getAllContracts();
    
    console.log('\nRegistered Contracts:');
    const contracts = names.map((name, i) => ({
      name,
      address: addresses[i]
    }));
    console.table(contracts);
    
    return { names, addresses };
  }); 