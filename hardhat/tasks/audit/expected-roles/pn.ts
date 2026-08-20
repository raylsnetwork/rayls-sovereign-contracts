// Expected role grants on a Privacy Node's own AccessManager.
//
// Mirrors the grantRole calls executed by `task('deploy:privacy-node')`
// (see hardhat/tasks/deploy/privacy-node.ts). Each entry references a
// contract by its DeploymentProxyRegistry name for that PN; the audit
// resolves names to addresses via the PN-side DeploymentProxyRegistry at
// audit time.
//
// MAINTENANCE: hand-authored mirror — when deploy code adds, removes, or
// renames a grantRole call, update this file in the same PR. See
// docs/access-manager-migration.md, section "Maintaining the
// expected-roles modules", for the full update protocol.

import type { ExpectedRoleEntry } from './types';

export const EXPECTED_PN_ROLES: ExpectedRoleEntry[] = [
  {
    roleName: 'FACTORY_ADMIN',
    expectedGrantees: ['ContractFactory', 'TokenRegistryReplica'],
    note: 'Factories grant ENDPOINT_SENDER at runtime via this role'
  },
  {
    roleName: 'FACTORY_DEPLOYER',
    expectedGrantees: ['RNEndpoint', 'ResourceManager'],
    note: 'These contracts call factory.deploy() but do not grant downstream roles'
  },
  {
    roleName: 'ENDPOINT_SENDER',
    expectedGrantees: ['ParticipantStorage', 'TokenRegistryReplica'],
    allowUnexpected: true,
    note: 'Granted to additional contracts dynamically at runtime (factories grant to deployed tokens)'
  },
  {
    roleName: 'TOKEN_CREATOR',
    expectedGrantees: ['TokenRegistryReplica'],
    note: 'TokenRegistryReplica calls EnygmaPNEvents.* for token creation events'
  },
  {
    roleName: 'MESSAGE_EXECUTOR',
    expectedGrantees: ['MessageExecutor', 'RNMessageExecutor'],
    note: 'Both executors deliver cross-chain messages to restricted targets'
  },
  {
    roleName: 'MESSAGE_RECEIVER',
    expectedGrantees: ['MessageReceiver'],
    note: 'MessageReceiver calls MessageExecutor.executeMessage* (restricted)'
  },
  {
    roleName: 'RESOURCE_REGISTRAR',
    expectedGrantees: ['Endpoint', 'TokenRegistryReplica'],
    note: 'Resource ID registration is restricted; these two need it'
  }
  // Roles deliberately omitted:
  //   ADMIN (0)        — deployer signer; reported as INFO
  //   RELAYER (dynamic) — audited via the CTS-driven path (--pn X)
];
