import { task } from 'hardhat/config';

task('freeze-token', 'Freezes a token for a list of participants')
  .addParam('participants', 'The participants to freeze the token for (comma separated)')
  .addParam('resourceId', 'The resourceId of the token to freeze')
  .setAction(async (taskArgs, hre) => {
    const { participants, resourceId } = taskArgs;
    const rpcUrl = process.env['PNH_RPC_URL'];
    const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
    const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);
    const signer = wallet.connect(provider);
    
    const deploymentRegistry = await hre.ethers.getContractAt('DeploymentProxyRegistryV1', process.env['PNH_DEPLOYMENT_PROXY_REGISTRY']!, signer);    
    const tokenRegistryAddress = await deploymentRegistry.getContract('TokenRegistry');

    const TokenRegistry = await hre.ethers.getContractAt('TokenRegistryV1', tokenRegistryAddress, signer);
    const tx = await TokenRegistry.freezeToken(resourceId, participants.split(',').map(Number));
    const receipt = await tx.wait();
    if (receipt?.status === 1) {
      console.log(`Token ${resourceId} frozen successfully for participants ${participants}`);
    }
  });
