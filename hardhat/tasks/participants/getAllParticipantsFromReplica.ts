import { task } from 'hardhat/config';
import { getDeploymentProxyRegistryAddress } from '../utils/deploymentProxyHelper';

task('participants:get-all-from-replica', 'Get all participants on the PN')
  .addParam('node', 'PN A, B, C, D')
  .setAction(async (taskArgs, { ethers }) => {
    const rpcUrl = process.env[`PRIVACY_NODE_${taskArgs.node}_RPC_URL`] as string;
    const privateKey = process.env['PRIVATE_KEY_SYSTEM'] as string;
    
    const provider = new ethers.JsonRpcProvider(rpcUrl);
    const venOperatorWallet = new ethers.Wallet(privateKey);
    const signer = venOperatorWallet.connect(provider);

    const deploymentRegistryAddress = process.env[`PRIVACY_NODE_${taskArgs.node}_DEPLOYMENT_PROXY_REGISTRY`] as string;
    const contracts = await getDeploymentProxyRegistryAddress(['ParticipantStorageReplica'], deploymentRegistryAddress, signer, ethers);

    const storageReplicaAddress = contracts[0];

    const participantStorageReplica = await ethers.getContractAt('ParticipantStorageReplicaV1', storageReplicaAddress, signer);

    let participants = await participantStorageReplica.getAllParticipants();

    const statusEnum = ['NEW', 'ACTIVE', 'INACTIVE', 'FROZEN'];
    const roleEnum = ['PARTICIPANT', 'ISSUER', 'AUDITOR'];

    for (const participant of participants) {
      const statusName = statusEnum[Number(participant.status)];
      const roleName = roleEnum[Number(participant.role)];

      console.log(`---`);
      console.log(`ChainID: ${participant.chainId}`);
      console.log(`Role: ${roleName}`);
      console.log(`Status: ${statusName}`);
      console.log(`Owner ID: ${participant.ownerId}`);
      console.log(`Name: ${participant.name}`);
      console.log(`Created At: ${new Date(Number(participant.createdAt) * 1000).toISOString()}`);
      console.log(`Updated At: ${new Date(Number(participant.updatedAt) * 1000).toISOString()}`);
      console.log(`Allowed to Broadcast: ${participant.allowedToBroadcast}`);
    }

    console.log(`\nTotal participants: ${participants.length}`);
  });
