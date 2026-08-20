import { task } from 'hardhat/config';

task('participants:update-broadcast-permission', 'Updates the broadcast messages permission of a participant')
  .addParam('chainid', 'The chainId of the participant')
  .addParam('allow', 'A boolean indicating if this participant will be allowed to broadcast')
  .setAction(async (taskArgs, hre) => {
    const { chainid, allow } = taskArgs;
    const rpcUrl = process.env[`PNH_RPC_URL`] as string;  
    const deploymentRegistryAddress = process.env[`PNH_DEPLOYMENT_PROXY_REGISTRY`] as string;

    const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
    const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);
    const signer = wallet.connect(provider);

    const deploymentRegistry = await hre.ethers.getContractAt('DeploymentProxyRegistryV1', deploymentRegistryAddress!, signer);
    const participantStorageAddress = await deploymentRegistry.getContract('ParticipantStorage');
    const ps = await hre.ethers.getContractAt('ParticipantStorageV1', participantStorageAddress, signer);

    const allowParticipant = allow === 'true';

    const tx = await ps.updateBroadcastMessagesPermission(Number(chainid), allowParticipant);
    const receipt = await tx.wait();
    if (receipt?.status === 1) {
      console.log(`Participant with chainId ${chainid} updated successfully!`);
    }
  });
