import '@nomicfoundation/hardhat-ethers';
import { task } from 'hardhat/config';

task('deployment-proxy:register-contracts', 'Registers multiple contracts')
  .addParam('names', 'Comma-separated list of contract names')
  .addParam('addresses', 'Comma-separated list of contract addresses')
  .addParam('node', 'The node to use')
  .setAction(async ({ names, addresses, node }, hre) => {

    const rpcUrl = process.env[`PRIVACY_NODE_${node}_RPC_URL`];
    const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
    const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);
    const signer = new hre.ethers.NonceManager(wallet.connect(provider));

    const nameArray = names.split(',').map((n: string) => n.trim());
    const addressArray = addresses.split(',').map((a: string) => a.trim());

    if (nameArray.length !== addressArray.length) {
      throw new Error('Number of names must match number of addresses');
    }

    console.log('Registering contracts...');
    console.log('Names:', nameArray);
    console.log('Addresses:', addressArray);

    const deploymentRegistryAddress = process.env[`PRIVACY_NODE_${node}_DEPLOYMENT_PROXY_REGISTRY`] as string;

    const deploymentProxyRegistry = await hre.ethers.getContractAt('DeploymentProxyRegistryV1', deploymentRegistryAddress, signer);
    
    const tx = await deploymentProxyRegistry.registerContracts(nameArray, addressArray, { gasLimit: 5000000 });
    await tx.wait();
    
    console.log('Contracts registered successfully');
    
    return tx;
  }); 