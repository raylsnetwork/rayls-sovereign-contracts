import { task } from 'hardhat/config';
import { getDeploymentProxyRegistryAddress } from '../utils/deploymentProxyHelper';

task('participants:update-storage-replica', 'Request participants from the Private Hub to be synced into this PN')
  .addParam('node', 'PN A, B, C, D')
  .setAction(async (taskArgs, { ethers }) => {
    const pnRpcUrl = process.env[`PRIVACY_NODE_${taskArgs.node}_RPC_URL`] as string;
    const privateKey = process.env['PRIVATE_KEY_SYSTEM'] as string;
    const pnSigner = new ethers.Wallet(privateKey, new ethers.JsonRpcProvider(pnRpcUrl));
    const deploymentRegistryAddress = process.env[`PRIVACY_NODE_${taskArgs.node}_DEPLOYMENT_PROXY_REGISTRY`] as string;
    const contracts = await getDeploymentProxyRegistryAddress(['ParticipantStorageReplica'], deploymentRegistryAddress, pnSigner, ethers);
    const replica = await ethers.getContractAt('ParticipantStorageReplicaV1', contracts[0], pnSigner);

    const before = await replica.getAllParticipants();
    console.log(`Before sync: ${before.length} participants.`);

    const tx = await replica.requestAllParticipantsDataFromPrivateHub();
    console.log(`Request transaction sent: ${tx.hash}`);
    await tx.wait();
    console.log('Request confirmed. Waiting 60 seconds for sync...');

    await new Promise((resolve) => setTimeout(resolve, 60000));

    const after = await replica.getAllParticipants();
    console.log(`After sync: ${after.length} participants.`);

    if (after.length > before.length) {
      console.log(`✔ Sync successful! ${after.length - before.length} new participants added.`);
    } else if (after.length === before.length) {
      console.warn('⚠ No new participants detected. Data may already have been synced or is still in transit.');
    } else {
      console.error('❌ Unexpected issue: participant count decreased.');
    }
  });
