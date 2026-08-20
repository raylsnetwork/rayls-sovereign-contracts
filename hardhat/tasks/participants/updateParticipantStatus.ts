import { task } from 'hardhat/config';

task('participants:update-status', 'Update participant on the Private Network Hub')
  .addParam('chainid', 'ChainID of the participant')
  .addParam('status', 'New status of the participant')
  .setAction(async (taskArgs, { ethers }) => {
    const rpcUrl = process.env['PNH_RPC_URL'] as string;
    const deploymentRegistryAddress = process.env[`PNH_DEPLOYMENT_PROXY_REGISTRY`] as string;
    const privateKey = process.env['PRIVATE_KEY_SYSTEM'] as string;

    const newParticipantChainId = taskArgs.chainid;
    const newParticipantStatus = taskArgs.status;

    const provider = new ethers.JsonRpcProvider(rpcUrl);
    const venOperatorWallet = new ethers.Wallet(privateKey);
    const signer = venOperatorWallet.connect(provider);

    const deploymentRegistry = await ethers.getContractAt('DeploymentProxyRegistryV1', deploymentRegistryAddress!, signer);
    const participantStorageAddress = await deploymentRegistry.getContract('ParticipantStorage');
    const participantStorage = await ethers.getContractAt('ParticipantStorageV1', participantStorageAddress, signer);

    let tx = await participantStorage.updateStatus(newParticipantChainId, newParticipantStatus);

    console.log(`Participant ${newParticipantChainId} status updated to ${newParticipantStatus}`);
  });
