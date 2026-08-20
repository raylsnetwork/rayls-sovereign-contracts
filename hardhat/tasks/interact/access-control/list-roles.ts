import { task } from 'hardhat/config';
import { getEnvVariableOrFlag } from '../../../utils/getEnvOrFlag';

task('list-roles', 'List all registered roles and optionally check membership for an address')
  .addOptionalParam('pn', 'Privacy Node identification (ex: A, B, C, D). Omit for PNH.')
  .addOptionalParam('chain', 'Chain type: "pnh" or "pn"')
  .addOptionalParam('account', 'Check role membership for this address')
  .addOptionalParam('rpcUrl', 'The URL of the JSON-RPC API')
  .addOptionalParam('registryAddress', 'DeploymentProxyRegistry address')
  .setAction(async (taskArgs, { ethers }) => {
    const isPNH = taskArgs.chain === 'pnh' || (!taskArgs.pn && !taskArgs.chain);
    const chainLabel = isPNH ? 'PNH' : `PN-${taskArgs.pn}`;

    console.log(`📋 Listing roles on ${chainLabel}...`);
    console.log('============================================================');

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

    const provider = new ethers.JsonRpcProvider(rpcUrl);

    const registry = await ethers.getContractAt('DeploymentProxyRegistryV1', registryAddr, provider);
    const managerAddress = await registry.getContract('RaylsAccessManager');
    const manager = await ethers.getContractAt('RaylsAccessManagerV1', managerAddress, provider);

    console.log(`📍 RaylsAccessManagerV1: ${managerAddress}\n`);

    // Known role names to check (infrastructure + business)
    const knownRoleNames = [
      // Infrastructure roles
      'ENDPOINT_SENDER',
      'ENYGMA_CREATOR',
      'FACTORY_ADMIN',
      'ENYGMA_V1',
      'COIN_VAULT',
      'DVP_CONTRACT',
      'RELAYER',
      'TOKEN_CREATOR',
      'AUTHORIZED_SENDER',
      // Business roles
      'PRIVATE_NETWORK_OPERATOR',
      'NETWORK_AUDITOR',
      'PRIVACY_NODE_OPERATOR',
      'BANK_EMPLOYEE',
      'AUDITOR',
      'COMPLIANCE_OFFICER',
      'TOKEN_MANAGER',
      // Integration roles
      'COMPLIANCE_TOOL',
      'CUSTODY_MANAGER',
      'TOKENIZER',
      'DVP_SETTLEMENT',
      'AUDITOR_TOOL',
    ];

    console.log('Registered Roles:');
    console.log('─────────────────────────────────────────────────');

    const checkAccount = taskArgs.account;
    let foundRoles = 0;

    for (const roleName of knownRoleNames) {
      try {
        const roleId = await manager.getRoleIdByName(roleName);
        if (roleId > 0n) {
          foundRoles++;
          const adminRoleId = await manager.getRoleAdmin(roleId);
          let membershipInfo = '';

          if (checkAccount) {
            const [hasMembership, delay] = await manager.hasRole(roleId, checkAccount);
            membershipInfo = hasMembership
              ? ` │ ✅ ${checkAccount.slice(0, 10)}... HAS role (delay=${delay}s)`
              : ` │ ❌ ${checkAccount.slice(0, 10)}... does NOT have role`;
          }

          console.log(`  ${roleName.padEnd(25)} │ id=${String(roleId).padEnd(4)} │ admin=${String(adminRoleId).padEnd(4)}${membershipInfo}`);
        }
      } catch {
        // Role not registered — skip silently
      }
    }

    // Always show ADMIN_ROLE (0), PUBLIC_ROLE (1), TOKEN_OWNER_ROLE (2)
    console.log('─────────────────────────────────────────────────');
    console.log(`  ${'ADMIN_ROLE (built-in)'.padEnd(25)} │ id=0    │ admin=0   (self-administered)`);
    console.log(`  ${'PUBLIC_ROLE (built-in)'.padEnd(25)} │ id=1    │ everyone has this role`);
    console.log(`  ${'TOKEN_OWNER_ROLE (built-in)'.padEnd(25)} │ id=2    │ contract-scoped token ownership`);

    if (checkAccount) {
      const [isAdmin] = await manager.hasRole(0, checkAccount);
      console.log(`\n  ADMIN_ROLE membership for ${checkAccount}: ${isAdmin ? '✅ YES' : '❌ NO'}`);
    }

    console.log(`\n  Total registered roles: ${foundRoles} (+ 3 built-in)`);
  });
