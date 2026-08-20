import { task } from 'hardhat/config';
import { getEnvVariableOrFlag } from '../../../utils/getEnvOrFlag';
import { ethers as ethersLib } from 'ethers';

task('remove-authorized-relayer', 'Remove an authorized relay address from the RelayAuthorizationRegistry')
  .addParam('relayerAddress', 'The Ethereum address to remove from authorized relayers')
  .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D)')
  .addOptionalParam('registryAddress', 'The RelayAuthorizationRegistry contract address (defaults to parametrized env vars)')
  .addOptionalParam('rpcUrl', 'The URL of the JSON-RPC API')
  .addOptionalParam('privateKey', 'The private key used for signing transactions')
  .addOptionalParam('registryType', 'Registry type: private or public (defaults to private)', 'private')
  .setAction(async (taskArgs, { ethers }) => {
    console.log('🚀 Removing authorized relay address from RelayAuthorizationRegistry...');
    console.log('============================================================');

    // Load environment or CLI parameters
    const pn = taskArgs.pn;
    if (!pn) {
      throw new Error('The --pn parameter must be provided');
    }
    
    const registryType = taskArgs.registryType || 'private';
    const rpcUrl = getEnvVariableOrFlag('RPC URL', registryType === 'private' ? `PRIVACY_NODE_${pn}_RPC_URL` : 'PUBLIC_CHAIN_RPC_URL', 'rpcUrl', '--rpc-url', taskArgs);
    const privateKey = getEnvVariableOrFlag('Private Key', 'PRIVATE_KEY_SYSTEM', 'privateKey', '--private-key', taskArgs);
    const relayerAddress = taskArgs.relayerAddress.trim();

    // Get deployment registry address based on type
    const deploymentRegistryEnvVar = registryType === 'private'
      ? `PRIVACY_NODE_${pn}_DEPLOYMENT_PROXY_REGISTRY`
      : `PRIVACY_NODE_${pn}_PUBLIC_CHAIN_DEPLOYMENT_PROXY_REGISTRY`;
    const deploymentRegistryAddress = getEnvVariableOrFlag('Deployment Registry Address', deploymentRegistryEnvVar, 'deploymentRegistryAddress', '--deployment-registry-address', taskArgs);

    // Setup provider and signer
    const provider = new ethers.JsonRpcProvider(rpcUrl);
    const wallet = new ethers.Wallet(privateKey);
    const signer = wallet.connect(provider);

    // Fetch RelayAuthorizationRegistry address from deployment registry
    console.log('🔍 Fetching RelayAuthorizationRegistry address from deployment registry...');
    const deploymentRegistry = await ethers.getContractAt('DeploymentProxyRegistryV1', deploymentRegistryAddress, signer);
    const registryAddress = await deploymentRegistry.getContract('RelayAuthorizationRegistry');

    // Validate addresses
    if (!ethersLib.isAddress(registryAddress)) {
      throw new Error(`Invalid registry address: ${registryAddress}`);
    }

    if (!ethersLib.isAddress(relayerAddress)) {
      throw new Error(`Invalid relay address: ${relayerAddress}`);
    }

    console.log(`📋 Registry Type: ${registryType.toUpperCase()}`);
    console.log(`📋 Registry Address: ${registryAddress}`);
    console.log(`📋 Privacy Node: ${pn}`);
    console.log(`📝 Relay Address to remove: ${relayerAddress}`);

    console.log(`👤 Signer Address: ${signer.address}`);
    console.log('============================================================');

    try {
      // Load the RelayAuthorizationRegistry contract
      const registry = await ethers.getContractAt('RelayAuthorizationRegistry', registryAddress, signer);

      // Check if the address is currently authorized
      console.log('🔍 Checking current authorization status...');
      const isCurrentlyAuthorized = await registry.isAuthorizedRelayer(relayerAddress);
      
      if (!isCurrentlyAuthorized) {
        console.log('⚠️  Address is not currently authorized as a relayer');
        return;
      }

      console.log('✓ Address is currently authorized');
      
      // Get current count
      const currentRelayers = await registry.getAuthorizedRelayAddresses();
      console.log(`Current authorized relayers: ${currentRelayers.length}`);

      // Call removeAuthorizedRelayAddress
      console.log('⏳ Sending transaction to remove relay address...');
      const tx = await registry.removeAuthorizedRelayAddress(relayerAddress);
      
      console.log(`📤 Transaction hash: ${tx.hash}`);
      console.log('⏳ Waiting for confirmation...');
      
      const receipt = await tx.wait(2);
      
      if (receipt?.status === 0) {
        throw new Error('Transaction failed');
      }

      console.log('✅ Transaction confirmed!');
      console.log(`⛽ Gas used: ${receipt.gasUsed.toString()}`);
      console.log(`🧱 Block number: ${receipt.blockNumber}`);

      // Verify removal
      console.log('🔍 Verifying removal...');
      const isStillAuthorized = await registry.isAuthorizedRelayer(relayerAddress);
      const updatedRelayers = await registry.getAuthorizedRelayAddresses();
      
      console.log(`Updated authorized relayers: ${updatedRelayers.length}`);
      console.log(`Address still authorized: ${isStillAuthorized ? 'YES' : 'NO'}`);

      // Parse events to confirm removal
      const events = receipt.logs?.filter(log => {
        try {
          const parsedLog = registry.interface.parseLog({
            topics: log.topics as string[],
            data: log.data
          });
          return parsedLog?.name === 'RelayAddressRemoved';
        } catch {
          return false;
        }
      });

      if (events && events.length > 0) {
        console.log('🎉 Successfully removed relay address:');
        events.forEach(event => {
          const parsedLog = registry.interface.parseLog({
            topics: event.topics as string[],
            data: event.data
          });
          if (parsedLog) {
            console.log(`   ✓ ${parsedLog.args.relayer}`);
          }
        });
      }

      console.log('============================================================');
      console.log('✅ Relay authorization removal completed successfully!');

    } catch (error: any) {
      console.error('❌ Error removing authorized relay address:');
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