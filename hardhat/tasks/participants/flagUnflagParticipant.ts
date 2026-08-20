import { task } from 'hardhat/config';
import { getEnvVariableOrFlag } from '../../utils/getEnvOrFlag';

task('participants:flag-unflag', 'Flags or unflags a participant')
  .addParam('flagAction', 'The action to perform: "flag" or "unflag"') // Mandatory
  .addParam('reason', 'The reason for the action') // Mandatory
  .addParam('initiator', 'The initiator of the action') // Mandatory
  .addParam('entityType', 'Entity ( Participant/transaction )') // Mandatory
  .addParam('entityId', 'The entity ID to flag or unflag') // Mandatory
  .addParam('participantChainId', 'The Participant Chain ID to flag or unflag') // Optional
  .addOptionalParam('rpcUrlNodePnh', 'The URL of the JSON RPC API from the private hub') // Optional
  .addOptionalParam('contractAddress', 'The Deployment Registry contract address') // Optional
  .addOptionalParam('privateKeySystem', 'The private key to sign the transaction') // Optional
  .setAction(async (taskArgs, { ethers }) => {
    // Mandatory parameters
    const { flagAction, reason, initiator } = taskArgs;

    // Optional parameters with fallback
    const rpcUrl = getEnvVariableOrFlag('Private Hub RPC URL', `PNH_RPC_URL`, 'rpcUrlNodePnh', '--rpc-url', taskArgs);
    const deploymentRegistryAddress = getEnvVariableOrFlag('Deployment Registry Address', `PNH_DEPLOYMENT_PROXY_REGISTRY`, 'contractAddress', '--contract-address', taskArgs);
    const privateKey = getEnvVariableOrFlag('Private Key', `PRIVATE_KEY_SYSTEM`, 'privateKeySystem', '--private-key-system', taskArgs);
    const participantChainId = taskArgs.participantChainId;

    // ensure participantChainId
    if (!participantChainId) {
      throw new Error('Participant Chain ID is required.');
    }

    // Validate the mandatory `flagAction`
    const fevent = flagAction.toLowerCase() === 'flag' ? 0 : flagAction.toLowerCase() === 'unflag' ? 1 : null;
    if (fevent === null) {
      throw new Error('Invalid flag action. Use "flag" or "unflag".');
    }

    const provider = new ethers.JsonRpcProvider(rpcUrl);
    const wallet = new ethers.Wallet(privateKey);
    const signer = wallet.connect(provider);

    const deploymentRegistry = await ethers.getContractAt('DeploymentProxyRegistryV1', deploymentRegistryAddress!, signer);
    const participantStorageAddress = await deploymentRegistry.getContract('ParticipantStorage');
  
    const participantStorage = await ethers.getContractAt('ParticipantStorageV1', participantStorageAddress, signer);

    if (taskArgs.entityType !== 'Participant' && taskArgs.entityType !== 'Transaction') {
      throw new Error('Invalid entity type. Use "Participant" or "Transaction".');
    }

    const flagEventLog = {
      fevent,
      entityId: taskArgs.entityId,
      entityType: taskArgs.entityType,
      reason,
      initiator,
      timestamp: Math.floor(Date.now() / 1000) // Current timestamp
    };

  });
