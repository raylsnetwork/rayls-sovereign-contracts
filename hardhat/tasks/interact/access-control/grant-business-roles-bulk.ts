import { task } from 'hardhat/config';
import { getEnvVariableOrFlag } from '../../../utils/getEnvOrFlag';
import { ethers as ethersLib } from 'ethers';

// grant-business-roles-bulk grants a set of roles to a set of accounts in ONE process:
// a single Hardhat cold-start, one signer, sequential nonces. Used by the RayUp bind flow
// (start_dev.sh:rebind_ops_stack), which grants the chain creator + the admin the roles
// login/deploy require. Every (account, role) pair that is already held is skipped (no tx),
// so re-binding a chain is cheap and idempotent.
//
// --accounts and --roles are comma-separated. Roles must already be REGISTERED on the
// AccessManager (activate-business-roles-pn does that); this task only grants them.
task('grant-business-roles-bulk', 'Grant multiple business roles to multiple accounts in one call')
  .addParam('accounts', 'Comma-separated addresses to grant the roles to')
  .addParam('roles', 'Comma-separated role names (e.g. FACTORY_DEPLOYER,PRIVACY_NODE_OPERATOR)')
  .addOptionalParam('pn', 'Privacy Node identification (ex: A, B, C, D). Omit for PNH.')
  .addOptionalParam('chain', 'Chain type: "pnh" or "pn" (default: auto-detect from --pn)')
  .addOptionalParam('delay', 'Execution delay in seconds (default: 0 = immediate)', '0')
  .addOptionalParam('rpcUrl', 'The URL of the JSON-RPC API')
  .addOptionalParam('privateKey', 'The private key used for signing transactions')
  .addOptionalParam('registryAddress', 'DeploymentProxyRegistry address')
  .setAction(async (taskArgs, { ethers }) => {
    const accounts: string[] = String(taskArgs.accounts)
      .split(',')
      .map((a) => a.trim())
      .filter(Boolean);
    const roleNames: string[] = String(taskArgs.roles)
      .split(',')
      .map((r) => r.trim())
      .filter(Boolean);
    const executionDelay = parseInt(taskArgs.delay);

    if (accounts.length === 0) throw new Error('--accounts must contain at least one address');
    if (roleNames.length === 0) throw new Error('--roles must contain at least one role name');
    for (const account of accounts) {
      if (!ethersLib.isAddress(account)) throw new Error(`Invalid address: ${account}`);
    }

    const isPNH = taskArgs.chain === 'pnh' || (!taskArgs.pn && !taskArgs.chain);
    const chainLabel = isPNH ? 'PNH' : `PN-${taskArgs.pn}`;

    console.log(`🚀 Bulk-granting [${roleNames.join(', ')}] to ${accounts.length} account(s) on ${chainLabel}...`);
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

    // Resolve role IDs once (shared across all accounts).
    const roleIds = new Map<string, bigint>();
    for (const roleName of roleNames) {
      let roleId: bigint;
      try {
        roleId = await manager.getRoleIdByName(roleName);
      } catch {
        throw new Error(`Role "${roleName}" is not registered. Run activate-business-roles-pn first.`);
      }
      if (roleId === 0n) {
        throw new Error(`Role "${roleName}" is not registered (returned id=0 = ADMIN_ROLE). Run the activation task first.`);
      }
      roleIds.set(roleName, roleId);
      console.log(`📍 Role: ${roleName} (id=${roleId})`);
    }

    // Grant sequentially, managing the nonce ourselves so we never wait a full block between
    // txs. Skip pairs already held (no tx). A single failure aborts (thrown), matching the
    // single-role task's contract; the caller treats the whole step as best-effort.
    let nonce = await signer.getNonce('pending');
    let granted = 0;
    let skipped = 0;

    for (const account of accounts) {
      for (const roleName of roleNames) {
        const roleId = roleIds.get(roleName)!;
        const [alreadyHasRole] = await manager.hasRole(roleId, account);
        if (alreadyHasRole) {
          console.log(`  ⏭️  ${account} already has ${roleName} — skipping.`);
          skipped++;
          continue;
        }
        const tx = await manager.grantRole(roleId, account, executionDelay, { nonce: nonce++ });
        const receipt = await tx.wait();
        if (receipt.status !== 1) {
          throw new Error(`grantRole(${roleName} → ${account}) failed: ${receipt.hash}`);
        }
        console.log(`  ✅ Granted ${roleName} to ${account} (tx ${receipt.hash})`);
        granted++;
      }
    }

    console.log(`\n✅ Done: ${granted} granted, ${skipped} already held.`);
  });
