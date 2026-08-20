import { task } from 'hardhat/config';
import { getEnvVariableOrFlag } from '../../../utils/getEnvOrFlag';
import { ethers as ethersLib } from 'ethers';

task('grant-business-role', 'Grant a business role to an address via RaylsAccessManagerV1')
  .addParam('role', 'Role name (e.g., PRIVACY_NODE_OPERATOR, BANK_EMPLOYEE, COMPLIANCE_OFFICER)')
  .addParam('account', 'Address to grant the role to')
  .addOptionalParam('pn', 'Privacy Node identification (ex: A, B, C, D). Omit for PNH.')
  .addOptionalParam('chain', 'Chain type: "pnh" or "pn" (default: auto-detect from --pn)')
  .addOptionalParam('delay', 'Execution delay in seconds (default: 0 = immediate)', '0')
  .addOptionalParam('rpcUrl', 'The URL of the JSON-RPC API')
  .addOptionalParam('privateKey', 'The private key used for signing transactions')
  .addOptionalParam('registryAddress', 'DeploymentProxyRegistry address')
  .setAction(async (taskArgs, { ethers }) => {
    const roleName: string = taskArgs.role;
    const account: string = taskArgs.account;
    const executionDelay = parseInt(taskArgs.delay);

    if (!ethersLib.isAddress(account)) {
      throw new Error(`Invalid address: ${account}`);
    }

    const isPNH = taskArgs.chain === 'pnh' || (!taskArgs.pn && !taskArgs.chain);
    const chainLabel = isPNH ? 'PNH' : `PN-${taskArgs.pn}`;

    console.log(`🚀 Granting ${roleName} to ${account} on ${chainLabel}...`);
    console.log('============================================================');

    // Resolve environment variables based on chain type
    let rpcUrl: string;
    let registryAddr: string;

    if (isPNH) {
      rpcUrl = getEnvVariableOrFlag('RPC URL', 'PNH_RPC_URL', 'rpcUrl', '--rpc-url', taskArgs);
      registryAddr = getEnvVariableOrFlag('Registry', 'PNH_DEPLOYMENT_PROXY_REGISTRY', 'registryAddress', '--registry-address', taskArgs);
    } else {
      const pn = taskArgs.pn;
      if (!pn) throw new Error('--pn parameter required for Privacy Node operations');
      rpcUrl = getEnvVariableOrFlag('RPC URL', `PRIVACY_NODE_${pn}_RPC_URL`, 'rpcUrl', '--rpc-url', taskArgs);
      registryAddr = getEnvVariableOrFlag('Registry', `PRIVACY_NODE_${pn}_DEPLOYMENT_PROXY_REGISTRY`, 'registryAddress', '--registry-address', taskArgs);
    }

    const privateKey = getEnvVariableOrFlag('Private Key', 'PRIVATE_KEY_SYSTEM', 'privateKey', '--private-key', taskArgs);
    const provider = new ethers.JsonRpcProvider(rpcUrl);
    const wallet = new ethers.Wallet(privateKey);
    const signer = wallet.connect(provider);

    console.log(`📍 Signer: ${signer.address}`);

    // Resolve AccessManager
    const registry = await ethers.getContractAt('DeploymentProxyRegistryV1', registryAddr, signer);
    const managerAddress = await registry.getContract('RaylsAccessManager');
    const manager = await ethers.getContractAt('RaylsAccessManagerV1', managerAddress, signer);

    console.log(`📍 RaylsAccessManagerV1: ${managerAddress}`);

    // Get role ID
    let roleId: bigint;
    try {
      roleId = await manager.getRoleIdByName(roleName);
    } catch {
      throw new Error(`Role "${roleName}" is not registered. Run activate-business-roles-pnh or activate-business-roles-pn first.`);
    }

    if (roleId === 0n) {
      throw new Error(`Role "${roleName}" is not registered (returned id=0, which is ADMIN_ROLE). Run the activation task first.`);
    }

    console.log(`📍 Role: ${roleName} (id=${roleId})`);
    console.log(`📍 Execution delay: ${executionDelay}s`);

    // Check if already granted
    const [alreadyHasRole] = await manager.hasRole(roleId, account);
    if (alreadyHasRole) {
      console.log(`\n⚠️  ${account} already has ${roleName}. No action needed.`);
      return;
    }

    // Grant role
    const tx = await manager.grantRole(roleId, account, executionDelay);
    const receipt = await tx.wait();

    if (receipt.status !== 1) {
      throw new Error(`Transaction failed: ${receipt.hash}`);
    }

    console.log(`\n✅ Granted ${roleName} to ${account}`);
    console.log(`   TX: ${receipt.hash}`);

    if (executionDelay > 0) {
      console.log(`   ⏱️  Execution delay: ${executionDelay}s — operations by this account will require schedule() + execute()`);
    }

    // Verify
    const [hasRoleNow, delay] = await manager.hasRole(roleId, account);
    console.log(`   Verified: hasRole=${hasRoleNow}, executionDelay=${delay}s`);
  });
