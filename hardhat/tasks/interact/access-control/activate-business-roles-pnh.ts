import { task } from 'hardhat/config';
import { getEnvVariableOrFlag } from '../../../utils/getEnvOrFlag';

task('activate-business-roles-pnh', 'Register and configure business roles (PRIVATE_NETWORK_OPERATOR, NETWORK_AUDITOR, COMPLIANCE_OFFICER, TOKEN_MANAGER) on Private Network Hub')
  .addOptionalParam('rpcUrl', 'The URL of the JSON-RPC API')
  .addOptionalParam('privateKey', 'The private key used for signing transactions')
  .addOptionalParam('registryAddress', 'DeploymentProxyRegistry address')
  .setAction(async (taskArgs, { ethers }) => {
    console.log('🚀 Activating business roles on Private Network Hub...');
    console.log('============================================================');

    const rpcUrl = getEnvVariableOrFlag('RPC URL', 'PNH_RPC_URL', 'rpcUrl', '--rpc-url', taskArgs);
    const privateKey = getEnvVariableOrFlag('Private Key', 'PRIVATE_KEY_SYSTEM', 'privateKey', '--private-key', taskArgs);
    const registryAddress = getEnvVariableOrFlag('Registry Address', 'PNH_DEPLOYMENT_PROXY_REGISTRY', 'registryAddress', '--registry-address', taskArgs);

    const provider = new ethers.JsonRpcProvider(rpcUrl);
    const wallet = new ethers.Wallet(privateKey);
    const signer = wallet.connect(provider);

    console.log(`📍 Signer: ${signer.address}`);

    // Resolve AccessManager from deployment registry
    const registry = await ethers.getContractAt('DeploymentProxyRegistryV1', registryAddress, signer);
    const managerAddress = await registry.getContract('RaylsAccessManager');
    console.log(`📍 RaylsAccessManagerV1: ${managerAddress}`);

    const manager = await ethers.getContractAt('RaylsAccessManagerV1', managerAddress, signer);

    // Resolve target contract addresses
    const tokenRegistryAddress = await registry.getContract('TokenRegistry');
    const teleportAddress = await registry.getContract('Teleport');
    const participantStorageAddress = await registry.getContract('ParticipantStorage');
    const templateRegistryAddress = await registry.getContract('TemplateRegistry');

    console.log(`📍 TokenRegistryV1: ${tokenRegistryAddress}`);
    console.log(`📍 TeleportV1: ${teleportAddress}`);
    console.log(`📍 ParticipantStorageV1: ${participantStorageAddress}`);
    console.log(`📍 TemplateRegistryV1: ${templateRegistryAddress}`);

    // ─── Step 1: Register roles ───
    console.log('\n📝 Step 1: Registering business roles...');

    const rolesToRegister = ['PRIVATE_NETWORK_OPERATOR', 'NETWORK_AUDITOR', 'COMPLIANCE_OFFICER', 'TOKEN_MANAGER'];
    let nonce = await signer.getNonce('pending');

    // Check which roles already exist
    const existingRoles: Record<string, bigint> = {};
    const newRoles: string[] = [];

    for (const roleName of rolesToRegister) {
      try {
        const roleId = await manager.getRoleIdByName(roleName);
        if (roleId > 0n) {
          existingRoles[roleName] = roleId;
          console.log(`   ✅ ${roleName} already registered (id=${roleId})`);
        } else {
          newRoles.push(roleName);
        }
      } catch {
        newRoles.push(roleName);
      }
    }

    if (newRoles.length > 0) {
      const registerTxs = newRoles.map(roleName =>
        manager['registerRole(string)'](roleName, { nonce: nonce++ })
      );
      const registerResponses = await Promise.all(registerTxs);
      const registerReceipts = await Promise.all(registerResponses.map((tx: any) => tx.wait()));

      for (let i = 0; i < newRoles.length; i++) {
        if (registerReceipts[i].status !== 1) {
          throw new Error(`Failed to register role ${newRoles[i]}`);
        }
        console.log(`   ✅ Registered: ${newRoles[i]} (tx: ${registerReceipts[i].hash})`);
      }
    }

    // Get all role IDs
    const PRIVATE_NETWORK_OPERATOR = await manager.getRoleIdByName('PRIVATE_NETWORK_OPERATOR');
    const NETWORK_AUDITOR = await manager.getRoleIdByName('NETWORK_AUDITOR');
    const COMPLIANCE_OFFICER = await manager.getRoleIdByName('COMPLIANCE_OFFICER');
    const TOKEN_MANAGER = await manager.getRoleIdByName('TOKEN_MANAGER');

    console.log(`\n   Role IDs:`);
    console.log(`   PRIVATE_NETWORK_OPERATOR: ${PRIVATE_NETWORK_OPERATOR}`);
    console.log(`   NETWORK_AUDITOR: ${NETWORK_AUDITOR}`);
    console.log(`   COMPLIANCE_OFFICER: ${COMPLIANCE_OFFICER}`);
    console.log(`   TOKEN_MANAGER: ${TOKEN_MANAGER}`);

    // ─── Step 2: Map functions to roles ───
    console.log('\n📝 Step 2: Mapping functions to roles...');

    const tokenRegistryFactory = await ethers.getContractFactory('TokenRegistryV1');
    const trIface = tokenRegistryFactory.interface;

    const teleportFactory = await ethers.getContractFactory('TeleportV1');
    const tpIface = teleportFactory.interface;


    const templateRegistryFactory = await ethers.getContractFactory('TemplateRegistryV1');
    const tplIface = templateRegistryFactory.interface;

  // Don't re-query nonce via `eth_getTransactionCount(addr, 'pending')` —
    // Don't re-query nonce via `eth_getTransactionCount(addr, 'pending')` —
    // the pending count can return a stale value immediately after a parallel
    // batch's tx.wait() resolves (observed on Besu, which is what the PNH
    // currently runs; if PNH later moves to Axyl the same defensive logic
    // still applies). The local `nonce` variable is already at the correct
    // next value from Step 1's increments.


    const participantStorageFactory = await ethers.getContractFactory('ParticipantStorageV1');
    const psIface = participantStorageFactory.interface;

    const mappingTxs = [
      // PRIVATE_NETWORK_OPERATOR: updateStatus on TokenRegistry
      manager.addFunctionAllowedRoles(
        tokenRegistryAddress,
        [trIface.getFunction('updateStatus')!.selector],
        [PRIVATE_NETWORK_OPERATOR],
        { nonce: nonce++ }
      ),
      // PRIVATE_NETWORK_OPERATOR: participant management
      manager.addFunctionAllowedRoles(
        participantStorageAddress,
        [
          psIface.getFunction('updateStatus')!.selector,
          psIface.getFunction('addParticipants')!.selector,
          psIface.getFunction('updateRole')!.selector,
        ],
        [PRIVATE_NETWORK_OPERATOR],
        { nonce: nonce++ }
      ),
      // COMPLIANCE_OFFICER: freezeToken, unfreezeToken on TokenRegistry
      manager.addFunctionAllowedRoles(
        tokenRegistryAddress,
        [
          trIface.getFunction('freezeToken')!.selector,
          trIface.getFunction('unfreezeToken')!.selector,
        ],
        [COMPLIANCE_OFFICER],
        { nonce: nonce++ }
      ),
      // PRIVATE_NETWORK_OPERATOR: seedStandardTemplate, approve, revoke on TemplateRegistry.
      // `propose` is intentionally left open (no entry here) so any address can submit.
      manager.addFunctionAllowedRoles(
        templateRegistryAddress,
        [
          tplIface.getFunction('seedStandardTemplate')!.selector,
          tplIface.getFunction('approve')!.selector,
          tplIface.getFunction('revoke')!.selector,
        ],
        [PRIVATE_NETWORK_OPERATOR],
        { nonce: nonce++ }
      ),
      // TOKEN_MANAGER: updateStatus on TokenRegistry (shared with PRIVATE_NETWORK_OPERATOR via separate mapping)
      // NOTE: OZ AccessManager maps ONE role per (target, selector).
      // updateStatus is already mapped to PRIVATE_NETWORK_OPERATOR above.
      // TOKEN_MANAGER holders should be granted PRIVATE_NETWORK_OPERATOR for updateStatus,
      // or a composite role should be used. For now, TOKEN_MANAGER maps to addToken-related selectors only.
    ];

    const mappingResponses = await Promise.all(mappingTxs);
    const mappingReceipts = await Promise.all(mappingResponses.map((tx: any) => tx.wait()));

    for (const receipt of mappingReceipts) {
      if (receipt.status !== 1) {
        throw new Error(`Function mapping TX failed: ${receipt.hash}`);
      }
    }
    console.log(`   ✅ Mapped ${mappingReceipts.length} function→role configurations`);

    // ─── Step 3: Set role hierarchy ───
    console.log('\n📝 Step 3: Setting role hierarchy...');

    // Don't re-query nonce — same reason as Step 2/Step 4. The local `nonce`
    // is already at the correct next value from Step 2's increments.

    const hierarchyTxs = [
      // PRIVATE_NETWORK_OPERATOR is admin of NETWORK_AUDITOR, COMPLIANCE_OFFICER, TOKEN_MANAGER
      manager.setRoleAdmin(NETWORK_AUDITOR, PRIVATE_NETWORK_OPERATOR, { nonce: nonce++ }),
      manager.setRoleAdmin(COMPLIANCE_OFFICER, PRIVATE_NETWORK_OPERATOR, { nonce: nonce++ }),
      manager.setRoleAdmin(TOKEN_MANAGER, PRIVATE_NETWORK_OPERATOR, { nonce: nonce++ }),
      // ADMIN_ROLE (0) is guardian of PRIVATE_NETWORK_OPERATOR
      manager.setRoleGuardian(PRIVATE_NETWORK_OPERATOR, 0, { nonce: nonce++ }),
      // PRIVATE_NETWORK_OPERATOR is guardian of COMPLIANCE_OFFICER
      manager.setRoleGuardian(COMPLIANCE_OFFICER, PRIVATE_NETWORK_OPERATOR, { nonce: nonce++ }),
    ];

    const hierarchyResponses = await Promise.all(hierarchyTxs);
    const hierarchyReceipts = await Promise.all(hierarchyResponses.map((tx: any) => tx.wait()));

    for (const receipt of hierarchyReceipts) {
      if (receipt.status !== 1) {
        throw new Error(`Hierarchy TX failed: ${receipt.hash}`);
      }
    }
    console.log('   ✅ Role hierarchy configured');

    // ─── Step 4: Label roles ───
    console.log('\n📝 Step 4: Labeling roles...');

    // Don't re-query nonce — some nodes have a delay updating the pending count
    // after receipts are confirmed. The `nonce` variable is already at the correct
    // next value from Step 3's increments.

    const labelTxs = [
      manager.labelRole(PRIVATE_NETWORK_OPERATOR, 'Private Network Operator', { nonce: nonce++ }),
      manager.labelRole(NETWORK_AUDITOR, 'Network Auditor', { nonce: nonce++ }),
      manager.labelRole(COMPLIANCE_OFFICER, 'Compliance Officer', { nonce: nonce++ }),
      manager.labelRole(TOKEN_MANAGER, 'Token Manager', { nonce: nonce++ }),
    ];

    const labelResponses = await Promise.all(labelTxs);
    await Promise.all(labelResponses.map((tx: any) => tx.wait()));
    console.log('   ✅ Roles labeled');

    // ─── Summary ───
    console.log('\n============================================================');
    console.log('✅ PNH business roles activated successfully!');
    console.log('');
    console.log('Role Hierarchy:');
    console.log(`  ADMIN_ROLE (0)`);
    console.log(`  └── PRIVATE_NETWORK_OPERATOR (${PRIVATE_NETWORK_OPERATOR}) ← guardian: ADMIN_ROLE`);
    console.log(`      ├── NETWORK_AUDITOR (${NETWORK_AUDITOR})`);
    console.log(`      ├── COMPLIANCE_OFFICER (${COMPLIANCE_OFFICER}) ← guardian: PRIVATE_NETWORK_OPERATOR`);
    console.log(`      └── TOKEN_MANAGER (${TOKEN_MANAGER})`);
    console.log('');
    console.log('Function Mappings:');
    console.log('  TokenRegistryV1.updateStatus()                  → PRIVATE_NETWORK_OPERATOR');
    console.log('  TokenRegistryV1.freezeToken()                   → COMPLIANCE_OFFICER');
    console.log('  TokenRegistryV1.unfreezeToken()                 → COMPLIANCE_OFFICER');
    console.log('  TeleportV1.setLockTime()                        → PRIVATE_NETWORK_OPERATOR');
    console.log('  ParticipantStorageV1.updateStatus()             → PRIVATE_NETWORK_OPERATOR');
    console.log('  ParticipantStorageV1.addParticipants()          → PRIVATE_NETWORK_OPERATOR');
    console.log('  ParticipantStorageV1.updateRole()               → PRIVATE_NETWORK_OPERATOR');
    console.log('  TemplateRegistryV1.seedStandardTemplate()       → PRIVATE_NETWORK_OPERATOR');
    console.log('  TemplateRegistryV1.approve()                    → PRIVATE_NETWORK_OPERATOR');
    console.log('  TemplateRegistryV1.revoke()                     → PRIVATE_NETWORK_OPERATOR');
    console.log('  TemplateRegistryV1.propose()                    → (open to all)');
    console.log('  TokenRegistryV1.updateStatus()          → PRIVATE_NETWORK_OPERATOR');
    console.log('  TokenRegistryV1.freezeToken()           → COMPLIANCE_OFFICER');
    console.log('  TokenRegistryV1.unfreezeToken()         → COMPLIANCE_OFFICER');
    console.log('  ParticipantStorageV1.updateStatus()     → PRIVATE_NETWORK_OPERATOR');
    console.log('  ParticipantStorageV1.addParticipants()  → PRIVATE_NETWORK_OPERATOR');
    console.log('  ParticipantStorageV1.updateRole()       → PRIVATE_NETWORK_OPERATOR');
    console.log('');
    console.log('Next steps:');
    console.log('  1. Grant PRIVATE_NETWORK_OPERATOR to an address:');
    console.log(`     npx hardhat grant-business-role --role PRIVATE_NETWORK_OPERATOR --account <address> --chain pnh`);
    console.log('  2. The PRIVATE_NETWORK_OPERATOR can then grant sub-roles (AUDITOR, COMPLIANCE, TOKEN_MANAGER)');
  });
