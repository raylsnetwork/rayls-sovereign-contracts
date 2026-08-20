import { task } from 'hardhat/config';
import { getEnvVariableOrFlag } from '../../utils/getEnvOrFlag';

task('participants:add', 'Add participant on the VEN')
  .addOptionalParam('rpcUrlNodePnh', 'The URL of the JSON-RPC API from the private hub')  
  .addOptionalParam('privateKeySystem', 'The private key used for signing transactions')
  .addOptionalParam('participantChainId', 'The participant chain ID')
  .addOptionalParam('participantName', 'The participant name')
  .addOptionalParam('participantOwnerAddress', 'The participant owner address')
  .addOptionalParam('participantRole', 'The participant role (0 for Participant, 1 for Issuer)')
  .setAction(async (taskArgs, { ethers }) => {
    // Load environment or CLI parameters
    const rpcUrl = getEnvVariableOrFlag('Private Hub RPC Url', 'PNH_RPC_URL', 'rpcUrlNodePnh', '--rpc-url', taskArgs);
    const deploymentRegistryAddress = process.env[`PRIVACY_NODE_${taskArgs.pn}_DEPLOYMENT_PROXY_REGISTRY`] as string;
    const privateKey = getEnvVariableOrFlag('Private Key', 'PRIVATE_KEY_SYSTEM', 'privateKeySystem', '--private-key-system', taskArgs);
    const participantChainId = getEnvVariableOrFlag('Participant ChainId', 'PARTICIPANT_CHAIN_ID', 'participantChainId', '--participant-chain-id', taskArgs);
    const participantName = getEnvVariableOrFlag('Participant Name', 'PARTICIPANT_NAME', 'participantName', '--participant-name', taskArgs);
    const participantRole = getEnvVariableOrFlag('Participant Role', 'PARTICIPANT_ROLE', 'participantRole', '--participant-role', taskArgs);
    const participantOwnerAddress = getEnvVariableOrFlag('Participant OwnerAddress', 'PARTICIPANT_OWNER_ADDRESS', 'participantOwnerAddress', '--participant-owner-address', taskArgs);

    // Setup provider and signer
    const provider = new ethers.JsonRpcProvider(rpcUrl);
    const wallet = new ethers.Wallet(privateKey);
    const signer = wallet.connect(provider);

    // Load contracts    
    const registry = await ethers.getContractAt('DeploymentProxyRegistryV1', deploymentRegistryAddress, signer);
    const { names, addresses } = await registry.getAllContracts();
    
    const deploymentMap = names.reduce((acc, name, index) => {
      acc[name] = addresses[index];
      return acc;
    }, {} as Record<string, string>);

    const participantStorage = await ethers.getContractAt('ParticipantStorageV1', deploymentMap['ParticipantStorage'], signer);

    // Add participant
    let tx = await participantStorage.addParticipant({
      chainId: participantChainId,
      role: participantRole,
      ownerId: participantOwnerAddress,
      name: participantName,
      allowedToBroadcast: true,
    });
    let receipt = await tx.wait(2);
    if (receipt?.status === 0) {
      throw new Error(`Failed to add participant "${participantChainId}"`);
    }

    // Set participant status to ACTIVE
    tx = await participantStorage.updateStatus(participantChainId, 1);
    receipt = await tx.wait(2);
    if (receipt?.status === 0) {
      throw new Error(`Failed to activate participant "${participantChainId}"`);
    }

    console.log('✅ Participant successfully added and activated.');

    // Grant broadcast permission
    const broadcastTx = await participantStorage.updateBroadcastMessagesPermission(participantChainId, true);
    const broadcastReceipt = await broadcastTx.wait(2);
    if (broadcastReceipt?.status === 0) {
      throw new Error(`Failed to grant broadcast permission for participant "${participantChainId}"`);
    }

    console.log('✅ Broadcast permission successfully granted.');
  });
