// Shared type for per-chain expected-roles modules.
//
// These describe the deploy-time role grants the audit expects to find on
// each chain's RaylsAccessManager. The audit uses them as the "what
// should be granted" specification; on-chain `getRoleMembers(roleId)`
// gives "what is granted". The diff produces OK / MISSING / UNEXPECTED
// findings.
//
// External operators run the audit against their own deployment; the
// expected-roles modules are the contract between deploy code and audit
// code. When the deploy code changes, the matching expected-roles entry
// must be updated — the audit's job is to fail loudly when it isn't.

/**
 * One expected role assignment on an AccessManager.
 *
 * - `expectedGrantees` references DeploymentProxyRegistry names. The audit
 *   resolves each name to an address via `registry.getContract(name)` at
 *   audit time, then compares the resolved set against on-chain holders.
 * - `allowUnexpected` opts out of UNEXPECTED classification for this role.
 *   Use it for roles dynamically extended at runtime (e.g., ENDPOINT_SENDER
 *   gets new grantees as tokens deploy; RELAYER gets new wallets when CTS
 *   rotates). Without this, the audit would flag every dynamic grantee.
 */
export interface ExpectedRoleEntry {
  roleName: string;
  expectedGrantees: string[];
  allowUnexpected?: boolean;
  note?: string;
}
