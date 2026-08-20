import { task } from 'hardhat/config';
import { getEnvVariableOrFlag } from '../../../utils/getEnvOrFlag';

task('activate-business-roles-pn', 'Register and configure business roles (PRIVACY_NODE_OPERATOR, BANK_EMPLOYEE, AUDITOR, COMPLIANCE_OFFICER) on a Privacy Node')
  .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D)')
  .addOptionalParam('rpcUrl', 'The URL of the JSON-RPC API')
  .addOptionalParam('privateKey', 'The private key used for signing transactions')
  .addOptionalParam('registryAddress', 'DeploymentProxyRegistry address')
  .setAction(async (taskArgs, hre) => {
    const { ethers } = hre;
    const pn = taskArgs.pn;
    if (!pn) {
      throw new Error('The --pn parameter must be provided');
    }

    console.log(`🚀 Activating business roles on Privacy Node ${pn}...`);
    console.log('============================================================');

    const rpcUrl = getEnvVariableOrFlag('RPC URL', `PRIVACY_NODE_${pn}_RPC_URL`, 'rpcUrl', '--rpc-url', taskArgs);
    const privateKey = getEnvVariableOrFlag('Private Key', 'PRIVATE_KEY_SYSTEM', 'privateKey', '--private-key', taskArgs);
    const registryAddress = getEnvVariableOrFlag('Registry Address', `PRIVACY_NODE_${pn}_DEPLOYMENT_PROXY_REGISTRY`, 'registryAddress', '--registry-address', taskArgs);

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
    let tokenGovAddress: string;
    let userGovAddress: string;

    try {
      tokenGovAddress = await registry.getContract('TokenRegistry');
      console.log(`📍 TokenRegistryV1: ${tokenGovAddress}`);
    } catch {
      console.log('⚠️  TokenRegistry not found in registry. Skipping token registry mappings.');
      tokenGovAddress = ethers.ZeroAddress;
    }

    try {
      userGovAddress = await registry.getContract('RNUserGovernance');
      console.log(`📍 RNUserGovernanceV1: ${userGovAddress}`);
    } catch {
      console.log('⚠️  RNUserGovernance not found in registry. Skipping user governance mappings.');
      userGovAddress = ethers.ZeroAddress;
    }

    // ─── Step 1: Register roles ───
    console.log('\n📝 Step 1: Registering business roles...');

    const rolesToRegister = ['PRIVACY_NODE_OPERATOR', 'BANK_EMPLOYEE', 'AUDITOR', 'COMPLIANCE_OFFICER'];
    let nonce = await signer.getNonce('pending');

    const newRoles: string[] = [];

    for (const roleName of rolesToRegister) {
      try {
        const roleId = await manager.getRoleIdByName(roleName);
        if (roleId > 0n) {
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
    const PRIVACY_NODE_OPERATOR = await manager.getRoleIdByName('PRIVACY_NODE_OPERATOR');
    const BANK_EMPLOYEE = await manager.getRoleIdByName('BANK_EMPLOYEE');
    const AUDITOR = await manager.getRoleIdByName('AUDITOR');
    const COMPLIANCE_OFFICER = await manager.getRoleIdByName('COMPLIANCE_OFFICER');

    console.log(`\n   Role IDs:`);
    console.log(`   PRIVACY_NODE_OPERATOR: ${PRIVACY_NODE_OPERATOR}`);
    console.log(`   BANK_EMPLOYEE: ${BANK_EMPLOYEE}`);
    console.log(`   AUDITOR: ${AUDITOR}`);
    console.log(`   COMPLIANCE_OFFICER: ${COMPLIANCE_OFFICER}`);

    // ─── Step 2: Map functions to roles ───
    console.log('\n📝 Step 2: Mapping functions to roles...');

    // Don't re-query nonce via `eth_getTransactionCount(addr, 'pending')` —
    // the pending count can return a stale value immediately after a parallel
    // batch's tx.wait() resolves (originally observed on Besu; PNs now run
    // Axyl but the same race is plausible on any node that updates pending
    // state asynchronously, and the defensive approach is free). The local
    // `nonce` variable is already at the correct next value from Step 1's
    // increments.
    const mappingTxs: Promise<any>[] = [];

    if (tokenGovAddress !== ethers.ZeroAddress) {
      const tgIface = (await ethers.getContractFactory('PNTokenRegistryV1')).interface;

      // PRIVACY_NODE_OPERATOR: token registry (approval/status + layer submission).
      mappingTxs.push(
        manager.addFunctionAllowedRoles(
          tokenGovAddress,
          [
            tgIface.getFunction('updatePrivacyNodeStatus')!.selector,
            tgIface.getFunction('submitToHub')!.selector,
            tgIface.getFunction('submitToPublicChain')!.selector,
            tgIface.getFunction('freezeOnPrivacyNode')!.selector,
            tgIface.getFunction('unfreezeOnPrivacyNode')!.selector,
            tgIface.getFunction('freezeOnPublicChain')!.selector,
            tgIface.getFunction('unfreezeOnPublicChain')!.selector,
          ],
          [PRIVACY_NODE_OPERATOR],
          { nonce: nonce++ }
        )
      );

      // BANK_EMPLOYEE: tokenization flow (registering tokens)
      mappingTxs.push(
        manager.addFunctionAllowedRoles(
          tokenGovAddress,
          [tgIface.getFunction('registerToken')!.selector],
          [BANK_EMPLOYEE],
          { nonce: nonce++ }
        )
      );
    }

    if (userGovAddress !== ethers.ZeroAddress) {
      const userGovFactory = await ethers.getContractFactory('RNUserGovernanceV1');
      const ugIface = userGovFactory.interface;

      // PRIVACY_NODE_OPERATOR: user governance (approval/rejection/removal/status)
      mappingTxs.push(
        manager.addFunctionAllowedRoles(
          userGovAddress,
          [
            ugIface.getFunction('createUser')!.selector,
            ugIface.getFunction('approveUser')!.selector,
            ugIface.getFunction('rejectUser')!.selector,
            ugIface.getFunction('removeUser')!.selector,
            ugIface.getFunction('setAddressPairApprovalStatus')!.selector,
          ],
          [PRIVACY_NODE_OPERATOR],
          { nonce: nonce++ }
        )
      );

      // BANK_EMPLOYEE: day-to-day user operations
      mappingTxs.push(
        manager.addFunctionAllowedRoles(
          userGovAddress,
          [
            ugIface.getFunction('addAddressPair')!.selector,
            ugIface.getFunction('removeAddressPair')!.selector,
          ],
          [BANK_EMPLOYEE],
          { nonce: nonce++ }
        )
      );
    }

    if (mappingTxs.length > 0) {
      const mappingResponses = await Promise.all(mappingTxs);
      const mappingReceipts = await Promise.all(mappingResponses.map((tx: any) => tx.wait()));

      for (const receipt of mappingReceipts) {
        if (receipt.status !== 1) {
          throw new Error(`Function mapping TX failed: ${receipt.hash}`);
        }
      }
      console.log(`   ✅ Mapped ${mappingReceipts.length} function→role configurations`);
    } else {
      console.log('   ⚠️  No target contracts found — skipping function mappings');
    }

    // ─── Step 3: Set role hierarchy ───
    console.log('\n📝 Step 3: Setting role hierarchy...');

    // Don't re-query nonce — same reason as Step 2/Step 4. The local `nonce`
    // is already at the correct next value from Step 2's increments.

    const hierarchyTxs = [
      // PRIVACY_NODE_OPERATOR is admin of BANK_EMPLOYEE, AUDITOR, COMPLIANCE_OFFICER
      manager.setRoleAdmin(BANK_EMPLOYEE, PRIVACY_NODE_OPERATOR, { nonce: nonce++ }),
      manager.setRoleAdmin(AUDITOR, PRIVACY_NODE_OPERATOR, { nonce: nonce++ }),
      manager.setRoleAdmin(COMPLIANCE_OFFICER, PRIVACY_NODE_OPERATOR, { nonce: nonce++ }),
      // ADMIN_ROLE (0) is guardian of PRIVACY_NODE_OPERATOR
      manager.setRoleGuardian(PRIVACY_NODE_OPERATOR, 0, { nonce: nonce++ }),
      // PRIVACY_NODE_OPERATOR is guardian of COMPLIANCE_OFFICER
      manager.setRoleGuardian(COMPLIANCE_OFFICER, PRIVACY_NODE_OPERATOR, { nonce: nonce++ }),
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
    // after receipts are confirmed. The `nonce` variable is already correct from Step 3.

    const labelTxs = [
      manager.labelRole(PRIVACY_NODE_OPERATOR, 'Privacy Node Operator', { nonce: nonce++ }),
      manager.labelRole(BANK_EMPLOYEE, 'Bank Employee', { nonce: nonce++ }),
      manager.labelRole(AUDITOR, 'Auditor', { nonce: nonce++ }),
      manager.labelRole(COMPLIANCE_OFFICER, 'Compliance Officer', { nonce: nonce++ }),
    ];

    const labelResponses = await Promise.all(labelTxs);
    await Promise.all(labelResponses.map((tx: any) => tx.wait()));
    console.log('   ✅ Roles labeled');

    // ─── Summary ───
    console.log('\n============================================================');
    console.log(`✅ PN-${pn} business roles activated successfully!`);
    console.log('');
    console.log('Role Hierarchy:');
    console.log(`  ADMIN_ROLE (0)`);
    console.log(`  └── PRIVACY_NODE_OPERATOR (${PRIVACY_NODE_OPERATOR}) ← guardian: ADMIN_ROLE`);
    console.log(`      ├── BANK_EMPLOYEE (${BANK_EMPLOYEE})`);
    console.log(`      ├── AUDITOR (${AUDITOR})`);
    console.log(`      └── COMPLIANCE_OFFICER (${COMPLIANCE_OFFICER}) ← guardian: PRIVACY_NODE_OPERATOR`);
    console.log('');
    console.log('Function Mappings:');
    if (tokenGovAddress !== ethers.ZeroAddress) {
      console.log('  TokenRegistryV1.updatePrivacyNodeStatus()  → PRIVACY_NODE_OPERATOR');
      console.log('  TokenRegistryV1.registerToken()            → BANK_EMPLOYEE');
    }
    if (userGovAddress !== ethers.ZeroAddress) {
      console.log('  RNUserGovernanceV1.createUser()            → PRIVACY_NODE_OPERATOR');
      console.log('  RNUserGovernanceV1.approveUser()           → PRIVACY_NODE_OPERATOR');
      console.log('  RNUserGovernanceV1.rejectUser()            → PRIVACY_NODE_OPERATOR');
      console.log('  RNUserGovernanceV1.removeUser()            → PRIVACY_NODE_OPERATOR');
      console.log('  RNUserGovernanceV1.setAddressPairApproval  → PRIVACY_NODE_OPERATOR');
      console.log('  RNUserGovernanceV1.addAddressPair()        → BANK_EMPLOYEE');
      console.log('  RNUserGovernanceV1.removeAddressPair()     → BANK_EMPLOYEE');
    }
    console.log('');
    console.log('Next steps:');
    console.log(`  1. Grant PRIVACY_NODE_OPERATOR to "Marcos": npx hardhat grant-business-role --pn ${pn} --role PRIVACY_NODE_OPERATOR --account <address>`);
    console.log('  2. The PRIVACY_NODE_OPERATOR can then grant BANK_EMPLOYEE, AUDITOR, COMPLIANCE_OFFICER');
  });
