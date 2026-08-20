import { task } from 'hardhat/config';
import { Spinner } from '../../utils/spinner';
import { getDeploymentProxyRegistryAddress } from '../utils/deploymentProxyHelper';

export const genRanHex = (size: number) => [...Array(size)].map(() => Math.floor(Math.random() * 16).toString(16)).join('');

task('batch-transfer:arbitrary-messages', 'Batch transfer arbitrary messages')
  .addVariadicPositionalParam('messages', 'The messages to send [message1, message2, ...]')
  .setAction(async (taskArgs, hre) => {
    const spinner: Spinner = new Spinner();

    const messages: string[] = taskArgs.messages;

    const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);

    const rpcUrlPnA = process.env[`PRIVACY_NODE_A_RPC_URL`];
    const providerPnA = new hre.ethers.JsonRpcProvider(rpcUrlPnA);
    const signerPnA = new hre.ethers.NonceManager(wallet.connect(providerPnA));

    const rpcUrlPnB = process.env[`PRIVACY_NODE_B_RPC_URL`];
    const providerPnB = new hre.ethers.JsonRpcProvider(rpcUrlPnB);
    const signerPnB = new hre.ethers.NonceManager(wallet.connect(providerPnB));

    const deploymentRegistryAddressA = process.env['PRIVACY_NODE_A_DEPLOYMENT_PROXY_REGISTRY'] as string;
    const deploymentRegistryAddressB = process.env['PRIVACY_NODE_B_DEPLOYMENT_PROXY_REGISTRY'] as string;


    const contractsA = await getDeploymentProxyRegistryAddress(['Endpoint', 'ArbitraryMessagesBatchTeleport'], deploymentRegistryAddressA, signerPnA, hre.ethers);
    const contractsB = await getDeploymentProxyRegistryAddress(['Endpoint', 'ArbitraryMessagesBatchTeleport'], deploymentRegistryAddressB, signerPnB, hre.ethers);    

    const resourceIdPnA = `0x${genRanHex(64)}`;
    const resourceIdPnB = `0x${genRanHex(64)}`;

    const chainIdPnA = process.env[`PRIVACY_NODE_A_CHAIN_ID`] as string;
    const chainIdPnB = process.env[`PRIVACY_NODE_B_CHAIN_ID`] as string;

    console.log('Deploying contract on PN-A');

    spinner.start();

    const arbitraryMessagesContractPnA = await hre.ethers.getContractFactory('ArbitraryMessagesBatchTeleport', signerPnA);
    const arbitraryMessagesPnA = await arbitraryMessagesContractPnA.deploy(resourceIdPnA, contractsA[0]);
    await arbitraryMessagesPnA.waitForDeployment();

    spinner.stop();

    console.log('Contract Address on PN-A');
    console.log(await arbitraryMessagesPnA.getAddress());
    console.log('');

    console.log('Deploying contract on PN-B');

    spinner.start();

    const arbitraryMessagesContractPnB = await hre.ethers.getContractFactory('ArbitraryMessagesBatchTeleport', signerPnB);
    const arbitraryMessagesPnB = await arbitraryMessagesContractPnB.deploy(resourceIdPnB, contractsB[0]);
    await arbitraryMessagesPnB.waitForDeployment();

    spinner.stop();

    console.log('Contract Address on PN-B');
    console.log(await arbitraryMessagesPnB.getAddress());
    console.log('');

    console.log('Messages to be sent');
    console.log(messages);
    console.log('');

    console.log('Messages on PN-A');
    console.log(await arbitraryMessagesPnA.getMessages());
    console.log('');

    console.log('Messages on PN-B');
    console.log(await arbitraryMessagesPnB.getMessages());
    console.log('');

    console.log('Sending messages from PN-A to PN-B...');

    spinner.start();

    const batchTeleportPayloadRequests = messages.map((message) => ({
      resourceId: resourceIdPnB,
      message: message,
      chainId: chainIdPnB
    }));

    await arbitraryMessagesPnA.connect(signerPnA).batchTeleport(batchTeleportPayloadRequests);

    const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));
    await sleep(15000);

    spinner.stop();

    console.log('Messages sent successfully!');
    console.log('');

    console.log('Messages on PN-B');
    console.log(` - Messages: ${await arbitraryMessagesPnB.getMessages()}`);
    console.log(` - Count: ${await arbitraryMessagesPnB.getMessagesCount()}`);
  });
