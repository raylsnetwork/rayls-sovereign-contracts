// Role audit: validates AccessManager role grants on each chain side.
//
// Three chain-keyed sibling tasks share one core:
//   audit:pnh:roles --privacy-nodes A,B,C    (PNH AccessManager, CSV of PNs)
//   audit:pn:roles  --pn A                   (PN A's own AccessManager)
//   audit:pc:roles  --pn A                   (PN A's PC AccessManager)
//
// Two audit modes, composable on the same task:
//
//   1. RELAYER audit (default): every CTS-advertised relayer address must
//      hold the RELAYER role on chain, and every on-chain RELAYER holder
//      must be CTS-advertised. Catches:
//        - MISSING: CTS lists an address that should hold RELAYER but the
//          on-chain grant is absent (partial authorization, manual revoke).
//        - UNEXPECTED: an address holds RELAYER on chain but isn't current
//          (rotated keys whose old grant wasn't revoked).
//      Skip with --skip-relayers (no CTS calls).
//
//   2. Own-roles audit (--include-own-roles): the static deploy-time role
//      grants described in `expected-roles/<chain>.ts` must exist on chain.
//      Reads the per-chain expected-roles module, resolves grantee names
//      via the DeploymentProxyRegistry, compares against `getRoleMembers`.
//      Catches drift between deploy code and chain state. Roles not in the
//      expected list (RELAYER, ADMIN, business roles) are surfaced as INFO.
//
//   `audit:all` opts both modes in automatically — it's the CI entrypoint.
//
// CTS list selection per task scope (internal mapping; not user-facing):
//   pn  → private_relayer.private_chain_addresses
//         ∪ public_relayer.private_chain_addresses
//   pc  → public_relayer.public_chain_addresses
//   pnh → private_relayer.private_hub_addresses
//         ∪ private_relayer.private_hub_dvp_operator_addresses
//
// External operators (Rayls users running audits against their own
// deployment) populate the env-var interface themselves — see the
// `audit:<chain>:roles` --help output for the env vars each task reads.
//
// Exit codes:
//   0 — both enabled audits clean (or --report-only suppressed exit-1).
//   1 — at least one MISSING or UNEXPECTED finding from either audit.

import { task } from 'hardhat/config';
import { ethers, JsonRpcProvider } from 'ethers';
import {
  ACCESS_MANAGER_CONTRACT_NAME,
  ChainType,
  fetchCtsAddresses,
  fetchInBatches,
  fetchLogsChunked,
  resolveRegistryAddress,
  resolveRpcUrlByChain,
  resolveStartingBlock
} from './utils';
import type { ExpectedRoleEntry } from './expected-roles/types';
import { EXPECTED_PNH_ROLES } from './expected-roles/pnh';
import { EXPECTED_PN_ROLES } from './expected-roles/pn';
import { EXPECTED_PC_ROLES } from './expected-roles/pc';

export type RelayerRoleFinding = {
  account: string; // lower-cased address
  status: 'OK' | 'MISSING' | 'UNEXPECTED';
  /** When set, the address is mapped against this CTS list label — e.g.
   *  'private_hub_addresses'. Helps operators trace where an expected
   *  address came from. */
  source?: string;
};

export type RelayerRolesAuditResult = {
  findings: RelayerRoleFinding[];
  managerAddress: string;
  roleId: bigint;
};

const REGISTRY_ABI = [
  'function getContract(string name) view returns (address)',
  'function getAllContracts() view returns (string[] names, address[] addresses)'
];

// Minimal manager ABI — just the lookups we use.
const MANAGER_ABI = [
  'function getRoleIdByName(string calldata name) external view returns (uint64)',
  'function hasRole(uint64 roleId, address account) external view returns (bool isMember, uint32 executionDelay)',
  'function getRegisteredRoleCount() external view returns (uint64)',
  'function getRoleMembers(uint64 roleId) external view returns (address[] memory)',
  'function getAllRoles() external view returns (tuple(uint64 roleId, string label, uint64 adminRole, uint64 guardianRole, uint32 grantDelay, uint256 memberCount)[] memory)'
];

/** Per-chain expected-roles lookup. Used by runOwnRolesAudit to pick the
 *  right specification module based on the audit's chain context. */
const EXPECTED_OWN_ROLES: Record<ChainType, ExpectedRoleEntry[]> = {
  pnh: EXPECTED_PNH_ROLES,
  pn: EXPECTED_PN_ROLES,
  pc: EXPECTED_PC_ROLES
};

const ROLE_EVENT_ABI = [
  'event RoleGranted(uint64 indexed roleId, address indexed account, uint32 executionDelay, uint48 activeSince, address indexed grantor)',
  'event RoleRevoked(uint64 indexed roleId, address indexed account, address indexed revoker)'
];

const EVENT_LOG_CHUNK = 5000n;

/**
 * Parse the user-facing `--privacy-nodes` CSV into an ordered, de-duplicated
 * list. Throws if the result is empty (caller wants ≥1 PN always) or contains
 * a blank token (operator typo we'd otherwise treat as "PN named ''").
 */
export function parsePrivacyNodes(csv: string, taskName: string): string[] {
  const tokens = csv.split(',').map((t) => t.trim());
  if (tokens.some((t) => t.length === 0)) {
    throw new Error(`${taskName}: --privacy-nodes contains an empty entry: '${csv}'`);
  }
  const out: string[] = [];
  for (const t of tokens) {
    if (!out.includes(t)) out.push(t);
  }
  if (out.length === 0) {
    throw new Error(`${taskName}: --privacy-nodes must list at least one PN`);
  }
  return out;
}

/**
 * Resolve the expected RELAYER-role holders from CTS across one or more PNs,
 * unioning their lists. The `chain` discriminator (helper-internal, *not*
 * user-facing) selects which CTS lists to merge per PN. Each address is
 * tagged with its source label so the audit can attribute findings ("CTS
 * expects this address per `private_hub_addresses` from PN B").
 */
async function expectedRelayerAddresses(
  pns: string[],
  chain: ChainType,
  includePublicRelayer = true
): Promise<Map<string, string>> {
  const out = new Map<string, string>(); // addr-lower → source label
  const add = (addrs: string[] | undefined, label: string) => {
    for (const a of addrs ?? []) {
      if (!ethers.isAddress(a)) continue;
      const lower = a.toLowerCase();
      // First source wins — multi-source addresses keep the more specific
      // label rather than getting overwritten by a later, more generic one.
      if (!out.has(lower)) out.set(lower, label);
    }
  };

  for (const pn of pns) {
    if (chain === 'pn') {
      const priv = await fetchCtsAddresses(pn, 'private_relayer');
      add(priv.private_chain_addresses, `PN ${pn} private_relayer.private_chain_addresses`);
      // Skip the public relayer when the public chain is disabled
      // (start_dev.sh --no-public-chain): the deployer doesn't grant RELAYER
      // to its PN-side addresses (add-authorized-relayers --with-public-relayer
      // false), so they must not be in the expected set either.
      if (includePublicRelayer) {
        const pub = await fetchCtsAddresses(pn, 'public_relayer');
        add(pub.private_chain_addresses, `PN ${pn} public_relayer.private_chain_addresses`);
      }
    } else if (chain === 'pnh') {
      const priv = await fetchCtsAddresses(pn, 'private_relayer');
      add(priv.private_hub_addresses, `PN ${pn} private_relayer.private_hub_addresses`);
      add(
        priv.private_hub_dvp_operator_addresses,
        `PN ${pn} private_relayer.private_hub_dvp_operator_addresses`
      );
    } else if (chain === 'pc') {
      const pub = await fetchCtsAddresses(pn, 'public_relayer');
      add(pub.public_chain_addresses, `PN ${pn} public_relayer.public_chain_addresses`);
    }
  }
  return out;
}

/**
 * Sentinel `roleId` used in an OwnRoleFinding when the expected-roles
 * module references a role that isn't registered on the on-chain
 * AccessManager. -1n is impossible as a real role id (uint64) so it can't
 * collide with a legitimate value. The renderer maps it to "not-registered"
 * in operator-facing output so the raw sentinel never leaks.
 */
const UNREGISTERED_ROLE_SENTINEL = -1n;

/** Format an OwnRoleFinding role id for display. Hides the
 *  UNREGISTERED_ROLE_SENTINEL behind a human-readable label. */
function formatRoleId(roleId: bigint): string {
  return roleId === UNREGISTERED_ROLE_SENTINEL ? 'not-registered' : `#${roleId}`;
}

/** Per-role finding for the own-roles audit. */
export type OwnRoleFinding = {
  roleName: string;
  /** Real uint64 role id from AccessManager, OR `UNREGISTERED_ROLE_SENTINEL`
   *  (-1n) when the expected-roles module references a role not registered
   *  on chain. Don't render this raw — use formatRoleId(). */
  roleId: bigint;
  account: string;
  status: 'OK' | 'MISSING' | 'UNEXPECTED' | 'INFO';
  source?: string;
};

export type OwnRolesAuditResult = {
  findings: OwnRoleFinding[];
  managerAddress: string;
  /** Roles registered on-chain that have no entry in the expected-roles
   *  module — listed informationally so the operator can decide whether
   *  to add an entry or accept the dynamic-grant pattern. */
  unaudited: { roleId: bigint; roleName: string; members: string[] }[];
};

/**
 * Audit the static "own-roles" grants on an AccessManager — the deploy-
 * time role assignments described in the chain's `expected-roles/<chain>.ts`
 * module. Compares the on-chain holder set of each expected role against
 * the addresses resolved from DeploymentProxyRegistry by name.
 *
 * Roles registered on-chain but absent from the expected list (e.g.,
 * RELAYER, AUTHORIZED_SENDER) are surfaced as `unaudited` so the operator
 * sees them without classification — the caller handles RELAYER via the
 * separate CTS-driven path.
 */
async function runOwnRolesAudit(opts: {
  taskName: string;
  rpcUrl: string;
  registryAddress: string;
  chain: ChainType;
  reportOnly: boolean;
  headerLines: string[];
}): Promise<OwnRolesAuditResult> {
  const provider = new JsonRpcProvider(opts.rpcUrl);
  const registry = new ethers.Contract(opts.registryAddress, REGISTRY_ABI, provider);
  const managerAddr: string = await registry.getContract(ACCESS_MANAGER_CONTRACT_NAME);
  if (!managerAddr || managerAddr === ethers.ZeroAddress) {
    throw new Error(`${opts.taskName}: registry has no ${ACCESS_MANAGER_CONTRACT_NAME} entry`);
  }
  const manager = new ethers.Contract(managerAddr, MANAGER_ABI, provider);

  // Resolve all registry entries once for grantee name → address lookups.
  const [regNames, regAddrs] = (await registry.getAllContracts()) as [string[], string[]];
  const nameToAddr = new Map<string, string>();
  for (let i = 0; i < regNames.length; i++) {
    nameToAddr.set(regNames[i]!, regAddrs[i]!.toLowerCase());
  }

  // Enumerate all on-chain roles so we can classify each one as either
  // "in expected list" (do the diff) or "unaudited" (INFO listing).
  const allRoles = (await manager.getAllRoles()) as Array<{
    roleId: bigint;
    label: string;
    adminRole: bigint;
    guardianRole: bigint;
    grantDelay: bigint;
    memberCount: bigint;
  }>;
  // Bounded-concurrency getRoleMembers — fans out across the registered
  // roles (~15-19 on PNH) without bombarding the RPC node. Defaults to 4
  // concurrent in-flight calls (see DEFAULT_FETCH_BATCH_SIZE), which is
  // a meaningful speedup over fully sequential without a thundering herd.
  const membersPerRole = await fetchInBatches(
    allRoles,
    (r) => manager.getRoleMembers(r.roleId) as Promise<string[]>
  );
  const onChainRoleByName = new Map<string, { id: bigint; members: Set<string> }>();
  for (let i = 0; i < allRoles.length; i++) {
    const r = allRoles[i]!;
    onChainRoleByName.set(r.label, {
      id: r.roleId,
      members: new Set(membersPerRole[i]!.map((a) => a.toLowerCase()))
    });
  }

  const expected = EXPECTED_OWN_ROLES[opts.chain];
  const expectedRoleNames = new Set(expected.map((e) => e.roleName));
  const findings: OwnRoleFinding[] = [];

  for (const entry of expected) {
    const onChain = onChainRoleByName.get(entry.roleName);
    if (!onChain) {
      // The expected-roles module references a role the AccessManager
      // doesn't have. That's a deploy-vs-spec drift worth a MISSING per
      // expected grantee.
      for (const grantee of entry.expectedGrantees) {
        const addr = nameToAddr.get(grantee);
        findings.push({
          roleName: entry.roleName,
          roleId: UNREGISTERED_ROLE_SENTINEL,
          account: addr ?? `<${grantee}: not in registry>`,
          status: 'MISSING',
          source: `expected role '${entry.roleName}' not registered on AccessManager`
        });
      }
      continue;
    }

    // Resolve expected grantees via the registry.
    const expectedAddrs = new Map<string, string>(); // lower-cased addr → grantee label
    for (const grantee of entry.expectedGrantees) {
      const addr = nameToAddr.get(grantee);
      if (!addr) {
        // The grantee name isn't in the registry. Surface as a finding so
        // operators see the drift between the expected-roles module and
        // their deployment's registry contents.
        findings.push({
          roleName: entry.roleName,
          roleId: onChain.id,
          account: `<${grantee}: not in registry>`,
          status: 'MISSING',
          source: 'registry has no entry for this expected grantee'
        });
        continue;
      }
      expectedAddrs.set(addr, grantee);
    }

    for (const [addr, label] of expectedAddrs) {
      findings.push({
        roleName: entry.roleName,
        roleId: onChain.id,
        account: addr,
        status: onChain.members.has(addr) ? 'OK' : 'MISSING',
        source: label
      });
    }

    // UNEXPECTED holders — on-chain members that aren't in the expected set.
    // Skip when the entry opted out (dynamic-grant roles).
    if (!entry.allowUnexpected) {
      for (const member of onChain.members) {
        if (!expectedAddrs.has(member)) {
          findings.push({
            roleName: entry.roleName,
            roleId: onChain.id,
            account: member,
            status: 'UNEXPECTED'
          });
        }
      }
    }
  }

  // Build the unaudited list: every registered role NOT covered by the
  // expected-roles module. Caller decides how to handle (RELAYER → CTS,
  // others → INFO-only).
  const unaudited: { roleId: bigint; roleName: string; members: string[] }[] = [];
  for (const [roleName, info] of onChainRoleByName) {
    if (expectedRoleNames.has(roleName)) continue;
    unaudited.push({
      roleId: info.id,
      roleName,
      members: [...info.members]
    });
  }

  // Render the own-roles report.
  const missing = findings.filter((f) => f.status === 'MISSING');
  const unexpected = findings.filter((f) => f.status === 'UNEXPECTED');
  const ok = findings.filter((f) => f.status === 'OK');

  console.log(`\nOwn-roles audit:`);
  for (const line of opts.headerLines) console.log(`  ${line}`);
  console.log(`  AccessManager:        ${managerAddr}`);
  console.log(`  Expected role count:  ${expected.length}`);
  console.log(`  On-chain role count:  ${allRoles.length}`);
  console.log(
    `  OK / MISSING / UNEXPECTED: ${ok.length} / ${missing.length} / ${unexpected.length}`
  );
  console.log('');

  if (missing.length > 0) {
    console.log('  MISSING — expected grantee absent on chain:');
    for (const f of missing) {
      console.log(`    [${f.roleName}${formatRoleId(f.roleId)}] ${f.account}  (${f.source ?? ''})`);
    }
    console.log('');
  }
  if (unexpected.length > 0) {
    console.log('  UNEXPECTED — on-chain holder of a fixed-membership role not in expected list:');
    for (const f of unexpected) {
      console.log(`    [${f.roleName}${formatRoleId(f.roleId)}] ${f.account}`);
    }
    console.log('');
  }
  if (unaudited.length > 0) {
    console.log(
      `  INFO — ${unaudited.length} role${unaudited.length !== 1 ? 's' : ''} not covered by expected-roles module:`
    );
    for (const r of unaudited) {
      console.log(
        `    [${r.roleName}${formatRoleId(r.roleId)}] ${r.members.length} holder${r.members.length !== 1 ? 's' : ''}`
      );
    }
    console.log('');
  }

  const blockers: string[] = [];
  if (missing.length > 0)
    blockers.push(`${missing.length} MISSING grant${missing.length !== 1 ? 's' : ''}`);
  if (unexpected.length > 0)
    blockers.push(`${unexpected.length} UNEXPECTED holder${unexpected.length !== 1 ? 's' : ''}`);

  if (blockers.length === 0) {
    console.log(`  ✅ OWN-ROLES AUDIT PASSED — every expected grant is on chain.\n`);
  } else if (opts.reportOnly) {
    console.log(
      `  ℹ️  REPORT-ONLY — ${blockers.join(', ')} (would have failed without --report-only).\n`
    );
  } else {
    console.log(`  ❌ OWN-ROLES AUDIT FAILED — ${blockers.join(', ')}.\n`);
    process.exitCode = 1;
  }

  return { findings, managerAddress: managerAddr, unaudited };
}

/**
 * Shared audit core. Resolves the manager via the registry, scans
 * RoleGranted / RoleRevoked events, diffs against `expected`, renders the
 * report, and sets `process.exitCode` on drift unless `reportOnly`.
 *
 * `headerLines` are printed verbatim under "Relayer-role audit (<role>):" so
 * each wrapper task can describe its concrete scope (PN id, PC scope, PNH
 * with the full PN list) without the helper having to know about chain types.
 */
async function runRelayerRolesAudit(opts: {
  taskName: string;
  expected: Map<string, string>;
  rpcUrl: string;
  registryAddress: string;
  roleName: string;
  /** Raw `--from-block` string from CLI (`''` triggers fallback; `'0'` is an explicit operator choice meaning "scan from genesis"). */
  fromBlockArg: string;
  /** Chain context for the fromBlock env-var fallback ladder. */
  chain: ChainType;
  /** PN id for env-var fallback when chain is 'pn' or 'pc'. */
  pn?: string;
  reportOnly: boolean;
  headerLines: string[];
}): Promise<RelayerRolesAuditResult> {
  const provider = new JsonRpcProvider(opts.rpcUrl);

  // 1. Resolve AccessManager from the DeploymentProxyRegistry.
  const registry = new ethers.Contract(opts.registryAddress, REGISTRY_ABI, provider);
  const managerAddr: string = await registry.getContract(ACCESS_MANAGER_CONTRACT_NAME);
  if (!managerAddr || managerAddr === ethers.ZeroAddress) {
    throw new Error(`${opts.taskName}: registry has no ${ACCESS_MANAGER_CONTRACT_NAME} entry`);
  }
  const manager = new ethers.Contract(managerAddr, MANAGER_ABI, provider);

  // 1b. Resolve --from-block via the four-tier ladder: explicit flag → env
  //     var per chain side → auto-detect via eth_getCode → default 0 with
  //     a warning. See utils.resolveStartingBlock.
  const startingBlockResolution = await resolveStartingBlock(opts.fromBlockArg, {
    pn: opts.pn,
    chain: opts.chain,
    managerAddress: managerAddr,
    provider: {
      getCode: (addr: string, blockTag: number | 'latest') =>
        provider.getCode(addr, blockTag as any),
      getBlockNumber: () => provider.getBlockNumber()
    },
    taskName: opts.taskName
  });
  const fromBlock = startingBlockResolution.fromBlock;

  // 2. Resolve roleId by name. Guard: `getRoleIdByName` returns 0 for any
  //    unknown role label, and 0 is the ADMIN id. Without this check the
  //    audit would silently compare CTS-expected RELAYER addresses against
  //    every ADMIN holder, reporting every admin as UNEXPECTED — a
  //    misleading report rather than a clear configuration error. Auditing
  //    the admin role itself isn't supported by this task (CTS doesn't
  //    advertise admin wallets); operators querying admin grants should use
  //    a direct on-chain query instead.
  const roleId: bigint = await manager.getRoleIdByName(opts.roleName);
  if (roleId === 0n) {
    throw new Error(
      `${opts.taskName}: role '${opts.roleName}' not found on AccessManager — ` +
        `getRoleIdByName returned 0 (ADMIN id). Pass --role-name <NAME> ` +
        `with a role that's actually registered on this AccessManager.`
    );
  }

  // 3. Replay RoleGranted / RoleRevoked events filtered to roleId, derive
  //    the live set of holders. Topic encoding: roleId is uint64 indexed,
  //    padded to 32 bytes.
  const roleIface = new ethers.Interface(ROLE_EVENT_ABI);
  const grantedTopic = roleIface.getEvent('RoleGranted')!.topicHash;
  const revokedTopic = roleIface.getEvent('RoleRevoked')!.topicHash;
  const roleIdTopic = ethers.zeroPadValue(ethers.toBeHex(roleId), 32);

  const latest = BigInt(await provider.getBlockNumber());
  if (fromBlock > latest) {
    throw new Error(
      `${opts.taskName}: --from-block ${fromBlock} is past the chain head (${latest})`
    );
  }

  const [grantedLogs, revokedLogs] = await Promise.all([
    fetchLogsChunked(
      provider,
      { address: managerAddr, topics: [grantedTopic, roleIdTopic] },
      fromBlock,
      latest,
      EVENT_LOG_CHUNK
    ),
    fetchLogsChunked(
      provider,
      { address: managerAddr, topics: [revokedTopic, roleIdTopic] },
      fromBlock,
      latest,
      EVENT_LOG_CHUNK
    )
  ]);

  // Replay events in (block, logIndex) order — last write wins per account.
  type Ev = { kind: 'grant' | 'revoke'; account: string; blockNumber: number; index: number };
  const events: Ev[] = [];
  let skipped = 0;
  for (const log of grantedLogs) {
    try {
      const parsed = roleIface.parseLog(log);
      if (!parsed) {
        skipped++;
        continue;
      }
      events.push({
        kind: 'grant',
        account: (parsed.args.account as string).toLowerCase(),
        blockNumber: log.blockNumber,
        index: log.index
      });
    } catch {
      skipped++;
    }
  }
  for (const log of revokedLogs) {
    try {
      const parsed = roleIface.parseLog(log);
      if (!parsed) {
        skipped++;
        continue;
      }
      events.push({
        kind: 'revoke',
        account: (parsed.args.account as string).toLowerCase(),
        blockNumber: log.blockNumber,
        index: log.index
      });
    } catch {
      skipped++;
    }
  }
  events.sort((a, b) => a.blockNumber - b.blockNumber || a.index - b.index);

  const liveHolders = new Set<string>();
  for (const ev of events) {
    if (ev.kind === 'grant') liveHolders.add(ev.account);
    else liveHolders.delete(ev.account);
  }

  // 4. Classify.
  const findings: RelayerRoleFinding[] = [];
  for (const [addr, source] of opts.expected) {
    if (liveHolders.has(addr)) findings.push({ account: addr, status: 'OK', source });
    else findings.push({ account: addr, status: 'MISSING', source });
  }
  for (const addr of liveHolders) {
    if (!opts.expected.has(addr)) findings.push({ account: addr, status: 'UNEXPECTED' });
  }

  // 5. Render.
  const missing = findings.filter((f) => f.status === 'MISSING');
  const unexpected = findings.filter((f) => f.status === 'UNEXPECTED');
  const ok = findings.filter((f) => f.status === 'OK');

  console.log(`\nRelayer-role audit (${opts.roleName}):`);
  for (const line of opts.headerLines) console.log(`  ${line}`);
  console.log(`  AccessManager:        ${managerAddr}`);
  console.log(
    `  Block range scanned:  ${fromBlock} → ${latest}  (source: ${startingBlockResolution.source}${startingBlockResolution.detail ? `, ${startingBlockResolution.detail}` : ''})`
  );
  console.log(`  Role ID:              ${roleId}`);
  console.log(`  Expected (CTS):       ${opts.expected.size}`);
  console.log(`  On-chain holders:     ${liveHolders.size}`);
  console.log(
    `  OK / MISSING / UNEXPECTED: ${ok.length} / ${missing.length} / ${unexpected.length}`
  );
  if (skipped > 0) console.log(`  ⚠️  Skipped (undecodable) role logs: ${skipped}`);
  console.log('');

  if (missing.length > 0) {
    console.log('  MISSING — CTS expects RELAYER but on-chain grant absent:');
    for (const f of missing) {
      console.log(`    ${f.account}  (source: ${f.source})`);
    }
    console.log('');
  }
  if (unexpected.length > 0) {
    console.log(
      '  UNEXPECTED — on-chain holder not advertised by CTS (likely rotated key or stray grant):'
    );
    for (const f of unexpected) {
      console.log(`    ${f.account}`);
    }
    console.log('');
  }

  const blockers: string[] = [];
  if (missing.length > 0)
    blockers.push(`${missing.length} MISSING grant${missing.length !== 1 ? 's' : ''}`);
  if (unexpected.length > 0)
    blockers.push(`${unexpected.length} UNEXPECTED holder${unexpected.length !== 1 ? 's' : ''}`);

  if (blockers.length === 0) {
    console.log(
      `  ✅ AUDIT PASSED — every CTS-expected wallet holds ${opts.roleName} and no extras.\n`
    );
  } else if (opts.reportOnly) {
    console.log(
      `  ℹ️  REPORT-ONLY — ${blockers.join(', ')} (would have failed without --report-only).\n`
    );
  } else {
    console.log(`  ❌ AUDIT FAILED — ${blockers.join(', ')}.\n`);
    process.exitCode = 1;
  }

  return { findings, managerAddress: managerAddr, roleId };
}

// ─── Sibling tasks: one per chain side ─────────────────────────────────────

const RPC_DESC = 'JSON-RPC URL override (default: chain-keyed *_RPC_URL env var)';
const REGISTRY_DESC = 'DeploymentProxyRegistry address (default: chain-keyed env var)';
const ROLE_NAME_DESC = 'Role name to audit';
const FROM_BLOCK_DESC =
  'Start block for event scan (default: chain-keyed *_STARTING_BLOCK env var, then auto-detect, then 0). Pass any value (including "0") to override.';

// ─── audit:pn:roles ─── PN side (per-PN chain) ─────────────────────────────

const INCLUDE_OWN_ROLES_DESC =
  'Also audit the static deploy-time role grants (own-roles audit) against the chain-specific expected-roles module.';
const SKIP_RELAYERS_DESC =
  'Skip the CTS-driven RELAYER audit. Combine with --include-own-roles to run own-roles only (no CTS calls).';

task('audit:pn:roles', "Audit role grants on a Privacy Node's own chain")
  .addParam('pn', 'Privacy node identifier (e.g. A)')
  .addOptionalParam('registry', REGISTRY_DESC, '')
  .addOptionalParam('rpc', RPC_DESC, '')
  .addOptionalParam('roleName', ROLE_NAME_DESC, 'RELAYER')
  .addOptionalParam('fromBlock', FROM_BLOCK_DESC, '')
  .addOptionalParam(
    'withPublicRelayer',
    'Include public-relayer private_chain_addresses in the expected RELAYER set ' +
      '(default true; pass false under --no-public-chain, where they are never granted)',
    'true'
  )
  .addFlag('reportOnly', 'Print findings but exit 0 even on drift')
  .addFlag('includeOwnRoles', INCLUDE_OWN_ROLES_DESC)
  .addFlag('skipRelayers', SKIP_RELAYERS_DESC)
  .setAction(
    async (args: {
      pn: string;
      registry: string;
      rpc: string;
      roleName: string;
      fromBlock: string;
      withPublicRelayer: string;
      reportOnly: boolean;
      includeOwnRoles: boolean;
      skipRelayers: boolean;
    }): Promise<RelayerRolesAuditResult | null> => {
      const taskName = 'audit:pn:roles';
      if (!args.pn) throw new Error(`${taskName}: --pn is required`);
      if (args.skipRelayers && !args.includeOwnRoles) {
        throw new Error(
          `${taskName}: --skip-relayers with --include-own-roles omitted leaves nothing to audit. ` +
            `Add --include-own-roles to run the own-roles audit only, or drop --skip-relayers to run the RELAYER audit.`
        );
      }
      const rpcUrl = resolveRpcUrlByChain({
        chain: 'pn',
        pn: args.pn,
        explicitRpc: args.rpc,
        taskName
      });
      const registryAddress = resolveRegistryAddress(args.registry, {
        chain: 'pn',
        pn: args.pn,
        taskName
      });
      if (args.includeOwnRoles) {
        await runOwnRolesAudit({
          taskName,
          rpcUrl,
          registryAddress,
          chain: 'pn',
          reportOnly: args.reportOnly,
          headerLines: [`Scope:                PN (own chain)`, `Privacy node:         ${args.pn}`]
        });
      }
      if (args.skipRelayers) return null;
      // Default to include; only an explicit "false" (from --no-public-chain)
      // drops the public relayer, keeping the expected set aligned with what
      // add-authorized-relayers actually granted.
      const includePublicRelayer = args.withPublicRelayer.toLowerCase() !== 'false';
      const expected = await expectedRelayerAddresses([args.pn], 'pn', includePublicRelayer);
      return runRelayerRolesAudit({
        taskName,
        expected,
        rpcUrl,
        registryAddress,
        roleName: args.roleName,
        fromBlockArg: args.fromBlock,
        chain: 'pn',
        pn: args.pn,
        reportOnly: args.reportOnly,
        headerLines: [`Scope:                PN (own chain)`, `Privacy node:         ${args.pn}`]
      });
    }
  );

// ─── audit:pc:roles ─── Public Chain (per-PN AccessManager) ────────────────

task(
  'audit:pc:roles',
  "Audit role grants on a Privacy Node's per-PN AccessManager on the public chain"
)
  .addParam('pn', 'Privacy node identifier (e.g. A)')
  .addOptionalParam('registry', REGISTRY_DESC, '')
  .addOptionalParam('rpc', RPC_DESC, '')
  .addOptionalParam('roleName', ROLE_NAME_DESC, 'RELAYER')
  .addOptionalParam('fromBlock', FROM_BLOCK_DESC, '')
  .addFlag('reportOnly', 'Print findings but exit 0 even on drift')
  .addFlag('includeOwnRoles', INCLUDE_OWN_ROLES_DESC)
  .addFlag('skipRelayers', SKIP_RELAYERS_DESC)
  .setAction(
    async (args: {
      pn: string;
      registry: string;
      rpc: string;
      roleName: string;
      fromBlock: string;
      reportOnly: boolean;
      includeOwnRoles: boolean;
      skipRelayers: boolean;
    }): Promise<RelayerRolesAuditResult | null> => {
      const taskName = 'audit:pc:roles';
      if (!args.pn) throw new Error(`${taskName}: --pn is required`);
      if (args.skipRelayers && !args.includeOwnRoles) {
        throw new Error(
          `${taskName}: --skip-relayers with --include-own-roles omitted leaves nothing to audit. ` +
            `Add --include-own-roles to run the own-roles audit only, or drop --skip-relayers to run the RELAYER audit.`
        );
      }
      const rpcUrl = resolveRpcUrlByChain({
        chain: 'pc',
        pn: args.pn,
        explicitRpc: args.rpc,
        taskName
      });
      const registryAddress = resolveRegistryAddress(args.registry, {
        chain: 'pc',
        pn: args.pn,
        taskName
      });
      if (args.includeOwnRoles) {
        await runOwnRolesAudit({
          taskName,
          rpcUrl,
          registryAddress,
          chain: 'pc',
          reportOnly: args.reportOnly,
          headerLines: [
            `Scope:                Public Chain (per-PN AccessManager)`,
            `Privacy node:         ${args.pn}`
          ]
        });
      }
      if (args.skipRelayers) return null;
      const expected = await expectedRelayerAddresses([args.pn], 'pc');
      return runRelayerRolesAudit({
        taskName,
        expected,
        rpcUrl,
        registryAddress,
        roleName: args.roleName,
        fromBlockArg: args.fromBlock,
        chain: 'pc',
        pn: args.pn,
        reportOnly: args.reportOnly,
        headerLines: [
          `Scope:                Public Chain (per-PN AccessManager)`,
          `Privacy node:         ${args.pn}`
        ]
      });
    }
  );

// ─── audit:pnh:roles ─── Private Network Hub (shared across PNs) ──────────

task(
  'audit:pnh:roles',
  "Audit role grants on the Private Network Hub's shared AccessManager across one or more Privacy Nodes"
)
  .addOptionalParam(
    'privacyNodes',
    "Privacy node ids to audit, comma-separated (e.g. A,B,C). PNH is shared, so the union of all listed PNs' CTS hub addresses defines the expected RELAYER set. Defaults to PARTICIPANT_LIST env var. Not required when --skip-relayers is set.",
    ''
  )
  .addOptionalParam('registry', REGISTRY_DESC, '')
  .addOptionalParam('rpc', RPC_DESC, '')
  .addOptionalParam('roleName', ROLE_NAME_DESC, 'RELAYER')
  .addOptionalParam('fromBlock', FROM_BLOCK_DESC, '')
  .addFlag('reportOnly', 'Print findings but exit 0 even on drift')
  .addFlag('includeOwnRoles', INCLUDE_OWN_ROLES_DESC)
  .addFlag('skipRelayers', SKIP_RELAYERS_DESC)
  .setAction(
    async (args: {
      privacyNodes: string;
      registry: string;
      rpc: string;
      roleName: string;
      fromBlock: string;
      reportOnly: boolean;
      includeOwnRoles: boolean;
      skipRelayers: boolean;
    }): Promise<RelayerRolesAuditResult | null> => {
      const taskName = 'audit:pnh:roles';
      if (args.skipRelayers && !args.includeOwnRoles) {
        throw new Error(
          `${taskName}: --skip-relayers with --include-own-roles omitted leaves nothing to audit. ` +
            `Add --include-own-roles to run the own-roles audit only, or drop --skip-relayers to run the RELAYER audit.`
        );
      }
      const rpcUrl = resolveRpcUrlByChain({ chain: 'pnh', explicitRpc: args.rpc, taskName });
      const registryAddress = resolveRegistryAddress(args.registry, { chain: 'pnh', taskName });
      if (args.includeOwnRoles) {
        await runOwnRolesAudit({
          taskName,
          rpcUrl,
          registryAddress,
          chain: 'pnh',
          reportOnly: args.reportOnly,
          headerLines: [`Scope:                Private Network Hub (shared)`]
        });
      }
      if (args.skipRelayers) return null;
      const pnsArg = args.privacyNodes || process.env.PARTICIPANT_LIST || '';
      if (!pnsArg) {
        throw new Error(
          `${taskName}: --privacy-nodes omitted and PARTICIPANT_LIST env var is unset. ` +
            `Pass --privacy-nodes A[,B,C] or export PARTICIPANT_LIST. ` +
            `(Use --skip-relayers with --include-own-roles to audit own-roles only.)`
        );
      }
      const pns = parsePrivacyNodes(pnsArg, taskName);
      const expected = await expectedRelayerAddresses(pns, 'pnh');
      return runRelayerRolesAudit({
        taskName,
        expected,
        rpcUrl,
        registryAddress,
        roleName: args.roleName,
        fromBlockArg: args.fromBlock,
        chain: 'pnh',
        reportOnly: args.reportOnly,
        headerLines: [
          `Scope:                Private Network Hub (shared)`,
          `Privacy nodes:        ${pns.join(',')}`
        ]
      });
    }
  );
