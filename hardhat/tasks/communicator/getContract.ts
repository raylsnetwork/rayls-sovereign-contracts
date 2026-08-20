import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { PNCommunicatorV1 } from '../../../typechain-types';
import { getDeploymentProxyRegistryAddress } from '../utils/deploymentProxyHelper';

export async function getCommunicatorPN(hre: HardhatRuntimeEnvironment, pn: string): Promise<PNCommunicatorV1> {
  const rpcUrl = process.env[`PRIVACY_NODE_${pn}_RPC_URL`];
  const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
  const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);

  const signer = wallet.connect(provider);

  const deploymentRegistryAddress = process.env[`PRIVACY_NODE_${pn}_DEPLOYMENT_PROXY_REGISTRY`] as string;
  const contracts = await getDeploymentProxyRegistryAddress(['PNCommunicator'], deploymentRegistryAddress, signer, hre.ethers);

  const pnCommunicator = await hre.ethers.getContractAt('PNCommunicatorV1', contracts[0], signer);

  return pnCommunicator;
}
