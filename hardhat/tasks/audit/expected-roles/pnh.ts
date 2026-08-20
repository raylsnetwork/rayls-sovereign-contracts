// Expected role grants on the PNH (Private Network Hub) AccessManager.
//
// Mirrors the grantRole calls executed by `task('deploy:private-hub')`
// (see hardhat/tasks/deploy/private-hub.ts). Each entry references a
// contract by its DeploymentProxyRegistry name; the audit resolves the
// name to the live address via `getContract(name)` at audit time.
//
// MAINTENANCE: hand-authored mirror — when deploy code adds, removes, or
// renames a grantRole call, update this file in the same PR. CI runs
// `audit:all` against a fresh deploy and fails loudly if the modules drift
// from the deploy code, but catching drift in the same PR is cheaper than
// catching it in CI. See docs/access-manager-migration.md, section
// "Maintaining the expected-roles modules", for the full update protocol.
//
// Roles NOT covered here:
//   - ADMIN (id 0): granted to the deployer signer at AccessManager init.
//     The audit reports on-chain ADMIN holders as INFO (no expected list
//     comparison) since the deployer wallet identity is operator-specific.
//   - RELAYER: granted dynamically by `add-authorized-relayers-pnh` from
//     CTS-advertised hub addresses. Audited separately by the existing
//     CTS-driven flow when `--privacy-nodes A,B,C` is given.

import type { ExpectedRoleEntry } from './types';

export const EXPECTED_PNH_ROLES: ExpectedRoleEntry[] = [
  {
    roleName: 'ENYGMA_CREATOR',
    expectedGrantees: ['EnygmaTokenManager'],
    note: 'EnygmaTokenManager calls EnygmaFactory.initiateEnygmaCreation'
  },
  {
    roleName: 'DVP_FACTORY_CALLER',
    expectedGrantees: ['TokenCore'],
    note: 'TokenCore calls DvpErc721Factory/DvpErc1155Factory.createDvp*'
  },
  {
    roleName: 'REGISTRY_CALLER',
    expectedGrantees: ['EnygmaFactory'],
    note: 'EnygmaFactory calls EnygmaRegistry.register*'
  },
  {
    roleName: 'ENDPOINT_SENDER',
    expectedGrantees: ['TokenCore', 'TokenFreezeManager', 'ParticipantCore'],
    allowUnexpected: true,
    note: 'Granted to additional contracts dynamically at runtime (factories grant to deployed tokens)'
  },
  {
    roleName: 'FACTORY_ADMIN',
    expectedGrantees: ['EnygmaFactory', 'Dvp', 'DvpErc721Factory', 'DvpErc1155Factory'],
    note: 'Factories grant ENYGMA_V1/COIN_VAULT/DVP_CONTRACT at runtime via this role'
  },
  {
    roleName: 'DVP_CONTRACT',
    expectedGrantees: ['Dvp'],
    note: 'Dvp emits commitments/nullifiers/swap-* on DvpTeleport'
  },
  {
    roleName: 'RESOURCE_REGISTRAR',
    expectedGrantees: ['Endpoint', 'EnygmaTokenManager', 'TokenCore'],
    note: 'Resource ID registration is restricted; these three contracts need it'
  },
  {
    roleName: 'MESSAGE_RECEIVER',
    expectedGrantees: ['MessageReceiver'],
    note: 'MessageReceiver calls MessageExecutor.executeMessage* (restricted)'
  }
  // Roles that are dynamically managed by FACTORY_ADMIN at runtime (no
  // deploy-time grants — admin is FACTORY_ADMIN via setRoleAdmin):
  //   ENYGMA_V1, COIN_VAULT, DVP_CONTRACT (grants come from factory.deploy())
  //
  // Roles deliberately omitted:
  //   ADMIN (0)        — deployer signer; reported as INFO
  //   RELAYER (dynamic) — audited via the CTS-driven path (--privacy-nodes)
  //   MESSAGE_EXECUTOR — granted to MessageExecutor address which isn't
  //                      currently registered in DeploymentProxyRegistry
  //                      (registry-hygiene finding, separate from roles).
  //                      Re-add once MessageExecutor is registered.
];
