import '@nomicfoundation/hardhat-ethers';
import { task } from 'hardhat/config';

task('deployment-proxy:register-contract', 'Registers a new contract')
  .addParam('name', 'The name of the contract')
  .addParam('address', 'The address of the contract')
  .addParam('node', 'The node to use')
  .setAction(async ({ name, address, node }, hre) => {
    console.log('Registering contract...');
    console.log('Name:', name);
    console.log('Address:', address);

    const rpcUrl = process.env[`PRIVACY_NODE_${node}_RPC_URL`];
    const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
    const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);
    const signer = new hre.ethers.NonceManager(wallet.connect(provider));

    const deploymentRegistryAddress = process.env[`PRIVACY_NODE_${node}_DEPLOYMENT_PROXY_REGISTRY`] as string;

    const deploymentProxyRegistry = await hre.ethers.getContractAt('DeploymentProxyRegistryV1', deploymentRegistryAddress, signer);
    
    const tx = await deploymentProxyRegistry.registerContracts([name], [address], { gasLimit: 5000000 });
    await tx.wait();
    
    console.log('Contract registered successfully');
    
    return tx;
  }); 