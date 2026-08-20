import { task } from 'hardhat/config';
import { getEnvVariableOrFlag } from '../../../utils/getEnvOrFlag';
import { ethers as ethersLib } from 'ethers';

task('list-authorized-relayers', 'List all authorized relay addresses from the RelayAuthorizationRegistry')
  .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D)')
  .addOptionalParam('registryAddress', 'The RelayAuthorizationRegistry contract address (defaults to parametrized env vars)')
  .addOptionalParam('rpcUrl', 'The URL of the JSON-RPC API')
  .addOptionalParam('checkAddress', 'Check if a specific address is authorized (optional)')
  .addOptionalParam('registryType', 'Registry type: private or public (defaults to private)', 'private')
  .setAction(async (taskArgs, { ethers }) => {
    console.log('📋 Listing authorized relay addresses from RelayAuthorizationRegistry...');
    console.log('============================================================');

    // Load environment or CLI parameters
    const pn = taskArgs.pn;
    if (!pn) {
      throw new Error('The --pn parameter must be provided');
    }
    
    const registryType = taskArgs.registryType || 'private';
    const rpcUrl = getEnvVariableOrFlag('RPC URL', registryType === 'private' ? `PRIVACY_NODE_${pn}_RPC_URL` : 'PUBLIC_CHAIN_RPC_URL', 'rpcUrl', '--rpc-url', taskArgs);
    const checkAddress = taskArgs.checkAddress?.trim();

    // Get deployment registry address based on type
    const deploymentRegistryEnvVar = registryType === 'private'
      ? `PRIVACY_NODE_${pn}_DEPLOYMENT_PROXY_REGISTRY`
      : `PRIVACY_NODE_${pn}_PUBLIC_CHAIN_DEPLOYMENT_PROXY_REGISTRY`;
    const deploymentRegistryAddress = getEnvVariableOrFlag('Deployment Registry Address', deploymentRegistryEnvVar, 'deploymentRegistryAddress', '--deployment-registry-address', taskArgs);

    // Setup provider
    const provider = new ethers.JsonRpcProvider(rpcUrl);

    // Fetch RelayAuthorizationRegistry address from deployment registry
    console.log('🔍 Fetching RelayAuthorizationRegistry address from deployment registry...');
    const deploymentRegistry = await ethers.getContractAt('DeploymentProxyRegistryV1', deploymentRegistryAddress, provider);
    const registryAddress = await deploymentRegistry.getContract('RelayAuthorizationRegistry');

    // Validate registry address
    if (!ethersLib.isAddress(registryAddress)) {
      throw new Error(`Invalid registry address: ${registryAddress}`);
    }

    // Validate check address if provided
    if (checkAddress && !ethersLib.isAddress(checkAddress)) {
      throw new Error(`Invalid check address: ${checkAddress}`);
    }

    console.log(`📋 Registry Type: ${registryType.toUpperCase()}`);
    console.log(`📋 Registry Address: ${registryAddress}`);
    console.log(`📋 Privacy Node: ${pn}`);
    if (checkAddress) {
      console.log(`🔍 Checking specific address: ${checkAddress}`);
    }
    console.log('============================================================');

    try {
      // Load the RelayAuthorizationRegistry contract (read-only)
      const registry = await ethers.getContractAt('RelayAuthorizationRegistry', registryAddress, provider);

      // Get all authorized relay addresses
      console.log('📊 Fetching authorized relay addresses...');
      const authorizedRelayers = await registry.getAuthorizedRelayAddresses();
      const relayerCount = await registry.getAuthorizedRelayCount();

      console.log(`Total authorized relayers: ${relayerCount.toString()}`);
      console.log('============================================================');

      if (authorizedRelayers.length === 0) {
        console.log('ℹ️  No authorized relayers found');
      } else {
        console.log('📋 Authorized Relay Addresses:');
        authorizedRelayers.forEach((address: string, index: number) => {
          console.log(`   ${index + 1}. ${address}`);
        });
      }

      // Check specific address if provided
      if (checkAddress) {
        console.log('============================================================');
        console.log('🔍 Address Authorization Check:');
        
        const isAuthorized = await registry.isAuthorizedRelayer(checkAddress);
        const status = isAuthorized ? '✅ AUTHORIZED' : '❌ NOT AUTHORIZED';
        
        console.log(`Address: ${checkAddress}`);
        console.log(`Status: ${status}`);
        
        if (isAuthorized) {
          // Find the index in the list
          const index = authorizedRelayers.findIndex((addr: string) => 
            addr.toLowerCase() === checkAddress.toLowerCase()
          );
          if (index !== -1) {
            console.log(`Position in list: ${index + 1}`);
          }
        }
      }

      console.log('============================================================');
      console.log('✅ Relay authorization listing completed successfully!');

    } catch (error: any) {
      console.error('❌ Error listing authorized relay addresses:');
      console.error(error.message);
      
      if (error.reason) {
        console.error('Reason:', error.reason);
      }
      
      if (error.code) {
        console.error('Error Code:', error.code);
      }
      
      throw error;
    }
  });