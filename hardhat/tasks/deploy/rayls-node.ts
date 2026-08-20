import '@nomicfoundation/hardhat-ethers';
import { task } from 'hardhat/config';
import { HardhatRuntimeEnvironment } from 'hardhat/types';

task('deploy:rayls-node', 'Deploys RaylsNode governance contracts')
  .setAction(async (taskArgs, hre) => {
  const privateKeySystem = process.env.PRIVATE_KEY_SYSTEM!;

  if (!privateKeySystem) {
    throw new Error('PRIVATE_KEY_SYSTEM environment variable is required');
  }

  // Create wallet from private key
  const deployer = new hre.ethers.Wallet(privateKeySystem, hre.ethers.provider);
  const deployerAddress = deployer.address;

  console.log('Deploying RaylsNode governance contracts...');
  console.log('Deployer address:', deployerAddress);

  // Deploy RNUserGovernance
  const userGovernanceAddress = await deployRNUserGovernance(deployerAddress, hre);

  console.log('');
  console.log('✅ Finished deployment of RaylsNode governance contracts');
  console.log('');
  console.log('===========================================');
  console.log('👉 Deployed Contract Addresses 👈');
  console.log('-------------------------------------------');
  console.log('RNUserGovernanceV1:', userGovernanceAddress);
  console.log('===========================================');

  return {
    userGovernanceAddress
  };
});

async function deployRNUserGovernance(initialOwner: string, hre: HardhatRuntimeEnvironment): Promise<string> {
  console.log('Deploying RNUserGovernanceV1...');

  // Deploy implementation
  const userGovernanceFactory = await hre.ethers.getContractFactory('RNUserGovernanceV1');
  const implementation = await userGovernanceFactory.deploy();
  await implementation.waitForDeployment();
  const implAddress = await implementation.getAddress();
  console.log('  Implementation deployed at:', implAddress);

  // Deploy proxy
  const proxyFactory = await hre.ethers.getContractFactory('RaylsERC1967Proxy');
  const initData = userGovernanceFactory.interface.encodeFunctionData('initialize', []);
  const proxy = await proxyFactory.deploy(implAddress, initData);
  await proxy.waitForDeployment();

  const userGovernanceAddress = await proxy.getAddress();
  console.log('RNUserGovernanceV1 deployed at:', userGovernanceAddress);

  return userGovernanceAddress;
}
