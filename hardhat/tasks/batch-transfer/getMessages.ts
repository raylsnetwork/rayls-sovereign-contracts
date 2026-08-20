import { task } from 'hardhat/config';
import { getDeploymentProxyRegistryAddress } from '../utils/deploymentProxyHelper';

export const genRanHex = (size: number) => [...Array(size)].map(() => Math.floor(Math.random() * 16).toString(16)).join('');

task('batch-transfer:get-messages', 'Get arbitrary messages')
  .addParam("pn", "The privacy node identification e.g. A, B, ...")
  .setAction(async (taskArgs, hre) => {
    const pn: string = taskArgs.pn;

    const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);

    const rpcUrl = process.env[`PRIVACY_NODE_${pn}_RPC_URL`];
    const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
    const signer = new hre.ethers.NonceManager(wallet.connect(provider));

    const deploymentRegistryAddress = process.env[`PRIVACY_NODE_${pn}_DEPLOYMENT_PROXY_REGISTRY`] as string;
    const contracts = await getDeploymentProxyRegistryAddress(['ArbitraryMessagesBatchTeleport'], deploymentRegistryAddress, signer, hre.ethers);
    
    const arbitraryMessages = await hre.ethers.getContractAt('ArbitraryMessagesBatchTeleport', contracts[0], signer);

    console.log(`Messages on PN${pn}`);
    console.log(` - Messages: ${await arbitraryMessages.getMessages()}`);
    console.log(` - Count: ${await arbitraryMessages.getMessagesCount()}`);
  });
