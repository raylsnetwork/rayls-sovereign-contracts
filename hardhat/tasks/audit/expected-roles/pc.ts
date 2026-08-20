// Expected role grants on a Privacy Node's public-chain AccessManager.
//
// Mirrors the grantRole calls executed by `task('deploy:public-chain')`
// (see hardhat/tasks/deploy/public-chain.ts). Each PN has its own per-PN
// AccessManager on the shared public chain; the audit resolves names via
// that PN's per-PN DeploymentProxyRegistry
// (PRIVACY_NODE_<X>_PUBLIC_CHAIN_DEPLOYMENT_PROXY_REGISTRY).
//
// The PC AccessManager has only three roles registered at deploy time:
// RELAYER, AUTHORIZED_SENDER, MESSAGE_EXECUTOR. Of those, only
// MESSAGE_EXECUTOR receives a deploy-time grantRole; the other two are
// granted dynamically (RELAYER via CTS, AUTHORIZED_SENDER via token
// deploys with role-admin delegated to RELAYER).
//
// MAINTENANCE: hand-authored mirror — when deploy code adds, removes, or
// renames a grantRole call, update this file in the same PR. See
// docs/access-manager-migration.md, section "Maintaining the
// expected-roles modules", for the full update protocol.

import type { ExpectedRoleEntry } from './types';

export const EXPECTED_PC_ROLES: ExpectedRoleEntry[] = [
  {
    roleName: 'MESSAGE_EXECUTOR',
    expectedGrantees: ['RNMessageExecutor'],
    note: 'RN MessageExecutor delivers public-chain messages to restricted receive functions'
  },
  {
    roleName: 'AUTHORIZED_SENDER',
    expectedGrantees: [],
    allowUnexpected: true,
    note: 'No deploy-time grant. Granted at runtime to deployed token contracts (role-admin is RELAYER).'
  }
  // Roles deliberately omitted:
  //   ADMIN (0)        — deployer signer; reported as INFO
  //   RELAYER (dynamic) — audited via the CTS-driven path (--pn X)
];
