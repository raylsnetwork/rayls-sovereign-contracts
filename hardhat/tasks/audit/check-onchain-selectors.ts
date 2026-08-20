// On-chain audit: every (target, selector, role) currently mapped by the
// AccessManager must correspond to a function that actually exists in the
// target contract's current ABI. The audit reports two outcomes per
// mapping:
//   - OK    — selector resolves against the current ABI; the explicit
//             non-admin role mapping is well-formed.
//   - STALE — selector doesn't resolve; the mapping points at a function
//             that no longer exists (typically because the function was
//             renamed or its parameter shape changed since deploy). The
//             on-chain mapping is dead weight; `removeFunctionAllowedRoles`
//             should clean it up.
//
// The audit deliberately does NOT enumerate `restricted` functions in
// source that lack an explicit non-admin role mapping. The AccessManager's
// invariant is that `ADMIN` (uint64 constant 0) can call every function
// unconditionally — explicit `addFunctionAllowedRoles` mappings exist to
// *open* a function to additional roles, not to grant admin access. So a
// `restricted` function with no mapping is the *correct default* for
// admin-only setters; listing them as audit findings would just be noise.
//
// Three chain-keyed sibling tasks share a single implementation:
//   audit:pnh:onchain-selectors                 (PNH AccessManager)
//   audit:pn:onchain-selectors  --pn X          (PN X's own AccessManager)
//   audit:pc:onchain-selectors  --pn X          (PN X's PC AccessManager)
//
// Programmatic: `await hre.run('audit:<chain>:onchain-selectors', { rpc, registry, pn, fromBlock, contracts })`
//   returns OnchainAuditResult ({ findings, managerAddress, registryAddress })
//   for the migration generator. The managerAddress is exported alongside
//   findings so the generator doesn't need to instantiate a second provider
//   just to re-resolve it.
//
// RPC + registry plumbing:
//   RPC URL:  explicit `--rpc <url>` wins; otherwise resolved from the
//             chain-keyed env var (PNH_RPC_URL / PUBLIC_CHAIN_RPC_URL /
//             PRIVACY_NODE_<X>_RPC_URL) per `resolveRpcUrlByChain`.
//   Registry: explicit `--registry <addr>` wins; otherwise resolved from
//             the chain-keyed env var via `resolveRegistryAddress`.

import { task } from 'hardhat/config';
import { ethers, JsonRpcProvider } from 'ethers';
import * as fs from 'fs';
import * as path from 'path';
import * as ts from 'typescript';
import {
  ACCESS_MANAGER_CONTRACT_NAME,
  ChainType,
  fetchLogsChunked,
  loadAbi,
  resolveRegistryAddress,
  resolveRpcUrlByChain,
  resolveStartingBlock
} from './utils';

export type OnchainFinding = {
  target: string; // logical name (registry name, deploy-task name, or fingerprint match)
  targetAddress: string;
  selector: string; // '0x…'
  signature?: string; // resolved from current ABI when status === 'OK'
  roleId: bigint;
  roleName?: string; // resolved when available
  status: 'OK' | 'STALE';
  /** When set, the address wasn't registered in the DeploymentProxyRegistry
   *  but the audit identified its contract type by selector fingerprinting
   *  against the artifact set. */
  unregistered?: boolean;
  /** When set, the registry's logical name differs from the contract's
   *  artifact name (e.g. 'FungibleAssetGroup' is registered but the actual
   *  contract is 'AssetGroup'). Tells the operator where to look. */
  artifactName?: string;
};

export type OnchainAuditResult = {
  findings: OnchainFinding[];
  /** The AccessManager address resolved from the registry. Exported so the
   *  migration generator can reuse it without re-querying the chain. */
  managerAddress: string;
  /** The DeploymentProxyRegistry address actually used (post env-fallback
   *  resolution). Exported so the migration generator's banner reports the
   *  effective value even when the operator omitted --registry. */
  registryAddress: string;
};

const EVENT_LOG_CHUNK = 5000n;

const REGISTRY_ABI = [
  'function getAllContracts() view returns (string[] names, address[] addresses)',
  'function getContract(string name) view returns (address)'
];

const MANAGER_EVENT_ABI = [
  'event FunctionAllowedRoleAdded(address indexed managedContract, bytes4 indexed selector, uint64 indexed roleId)',
  'event FunctionAllowedRoleRemoved(address indexed managedContract, bytes4 indexed selector, uint64 indexed roleId)',
  'event RoleRegistered(uint64 indexed roleId, string name)'
];

/**
 * Parse the deploy task TS files for `{ name: 'X', contractName: 'Y', … }`
 * literals — the deploy system's own source of truth for "registry label →
 * artifact name". `FungibleAssetGroup` is registered under that name but the
 * artifact on disk is `AssetGroup`; the V1/V2/Replica alias fallback can't
 * recover that, but this parse can.
 */
function buildRegistryNameToArtifactName(rootDir: string): Map<string, string> {
  const out = new Map<string, string>();
  const deployDir = path.join(rootDir, 'hardhat/tasks/deploy');
  if (!fs.existsSync(deployDir)) return out;

  function walkObjectLiteral(node: ts.ObjectLiteralExpression): void {
    let name: string | undefined;
    let contractName: string | undefined;
    for (const prop of node.properties) {
      if (!ts.isPropertyAssignment(prop)) continue;
      if (!ts.isIdentifier(prop.name)) continue;
      const key = prop.name.text;
      if (key !== 'name' && key !== 'contractName') continue;
      if (!ts.isStringLiteral(prop.initializer)) continue;
      if (key === 'name') name = prop.initializer.text;
      else contractName = prop.initializer.text;
    }
    if (name && contractName && name !== contractName) out.set(name, contractName);
  }

  function visit(node: ts.Node): void {
    if (ts.isObjectLiteralExpression(node)) walkObjectLiteral(node);
    ts.forEachChild(node, visit);
  }

  function walkDir(d: string) {
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(d, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const full = path.join(d, entry.name);
      if (entry.isDirectory()) walkDir(full);
      else if (entry.name.endsWith('.ts')) {
        const src = fs.readFileSync(full, 'utf8');
        const sf = ts.createSourceFile(full, src, ts.ScriptTarget.ES2020, true);
        visit(sf);
      }
    }
  }
  walkDir(deployDir);
  return out;
}

/**
 * Index every artifact ABI under `artifacts/` by function selector. Used
 * to fingerprint an address that isn't in the registry (or whose registry
 * label can't be resolved to an artifact) by looking up what contract type
 * its actual selectors match. Lazy-built and memoised.
 */
function buildSelectorIndex(rootDir: string): {
  artifactByName: Map<string, any[]>;
  bySelector: Map<string, Set<string>>;
  // Whether the artifact has non-empty deployable bytecode. Interfaces and
  // abstract contracts have empty bytecode; concrete contracts don't. Used to
  // tie-break the selector fingerprint so we don't pick the interface when
  // the implementation is also a match.
  hasBytecode: Map<string, boolean>;
} {
  const artifactByName = new Map<string, any[]>();
  const bySelector = new Map<string, Set<string>>();
  const hasBytecode = new Map<string, boolean>();
  const artifactsDir = path.join(rootDir, 'artifacts');
  function walk(d: string) {
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(d, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const full = path.join(d, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.name.endsWith('.json') && !entry.name.includes('.dbg.')) {
        try {
          const raw = JSON.parse(fs.readFileSync(full, 'utf8'));
          if (!raw.abi || !Array.isArray(raw.abi) || raw.abi.length === 0) continue;
          const name = entry.name.replace(/\.json$/, '');
          if (artifactByName.has(name)) continue; // first occurrence wins; build-info copies are equivalent
          artifactByName.set(name, raw.abi);
          // Hardhat artifacts: `bytecode` is "0x" for interfaces / abstract.
          // Forge artifacts: `bytecode.object` is "0x".
          const bc = raw.bytecode;
          const bcStr =
            typeof bc === 'string' ? bc : bc && typeof bc.object === 'string' ? bc.object : '';
          hasBytecode.set(name, bcStr.length > 4); // more than just "0x"
          const iface = new ethers.Interface(raw.abi);
          iface.forEachFunction((fn) => {
            let set = bySelector.get(fn.selector);
            if (!set) {
              set = new Set();
              bySelector.set(fn.selector, set);
            }
            set.add(name);
          });
        } catch {}
      }
    }
  }
  walk(artifactsDir);
  return { artifactByName, bySelector, hasBytecode };
}

/**
 * Given a set of selectors observed at one address, find the artifact whose
 * ABI contains ALL of them. Used as a fallback when neither the registry
 * name nor its deploy-task `contractName` mapping resolves to an artifact
 * that decodes the address's selectors — typically for unregistered
 * addresses (e.g. per-message `MessageExecutor` instances) or for registry
 * labels that diverge from artifact names.
 *
 * Returns null when no artifact has every selector — that's a genuine
 * "STALE selector on an orphan address" situation.
 *
 * Tie-breaking rationale (when multiple artifacts cover all selectors):
 *
 *   1. **Deployable wins over interfaces/abstract.**
 *      Solidity interfaces and abstract base contracts have the same
 *      function selectors as their concrete implementations, but their
 *      compiled bytecode is `"0x"`. The address actually deployed on chain
 *      is a concrete contract, so an interface/abstract match is a false
 *      positive that we want sorted last. We classify "deployable" as
 *      "compiled artifact has non-trivial bytecode" — see
 *      `buildSelectorIndex` for the bytecode detection.
 *
 *   2. **Fewest functions wins as the most specific match.**
 *      A child contract `Foo extends Bar` shares Bar's selectors plus its
 *      own. If both `Foo` and `Bar` cover all observed selectors, then
 *      the observed surface area is entirely in Bar — picking the parent
 *      (fewer functions) is the more specific identification. Picking the
 *      child would imply the address has additional methods we just
 *      haven't observed events for, which is a strictly weaker claim.
 *      Conversely, when the observed selectors include Foo-specific ones,
 *      Bar's ABI won't cover them all and Bar drops out of `candidates`
 *      before this sort runs.
 *
 *   3. **Lexicographic artifact name as final tie-break (explicit).**
 *      When two artifacts are indistinguishable on the above (e.g. two
 *      empty-bytecode interfaces with the same function count covering the
 *      same selector set), pick the lexicographically smaller artifact name.
 *      Earlier versions relied on JS stable sort + Set-insertion order, but
 *      Set order is `buildSelectorIndex`'s `fs.readdirSync` order, which is
 *      filesystem-dependent (ext4 vs. APFS vs. NTFS produce different
 *      orderings). Explicit name comparison gives the same result on every
 *      OS / CI runner / local dev machine.
 */
function fingerprintByAllSelectors(
  selectors: string[],
  index: ReturnType<typeof buildSelectorIndex>
): string | null {
  if (selectors.length === 0) return null;
  const first = index.bySelector.get(selectors[0]!);
  if (!first) return null;
  const candidates: string[] = [];
  for (const name of first) {
    if (selectors.every((s) => index.bySelector.get(s)?.has(name))) candidates.push(name);
  }
  if (candidates.length === 0) return null;

  candidates.sort((a, b) => {
    // Rule 1: deployable (concrete contract w/ bytecode) before
    // non-deployable (interface / abstract).
    const aDeployable = index.hasBytecode.get(a) ? 0 : 1;
    const bDeployable = index.hasBytecode.get(b) ? 0 : 1;
    if (aDeployable !== bDeployable) return aDeployable - bDeployable;
    // Rule 2: fewer functions = more specific match (parent over child
    // when the parent already covers all observed selectors).
    const fa = (index.artifactByName.get(a) ?? []).filter((f: any) => f.type === 'function').length;
    const fb = (index.artifactByName.get(b) ?? []).filter((f: any) => f.type === 'function').length;
    if (fa !== fb) return fa - fb;
    // Rule 3: lexicographic artifact name — cross-platform deterministic
    // tiebreak. Without this we'd depend on `fs.readdirSync` order, which
    // varies by filesystem (ext4 vs APFS vs NTFS).
    return a.localeCompare(b);
  });
  return candidates[0]!;
}

/**
 * Run the on-chain selector audit. All three sibling tasks (PNH, PN, PC)
 * funnel through here after their setAction resolves the chain-keyed RPC
 * URL and registry address — keeping the core event-replay + ABI-decode
 * logic single-source.
 */
async function runOnchainSelectorsAudit(opts: {
  taskName: string;
  rpcUrl: string;
  registryAddress: string;
  chain: ChainType;
  pn?: string;
  fromBlockArg: string;
  contractsArg: string;
  root: string;
}): Promise<OnchainAuditResult> {
  const contractFilter = opts.contractsArg
    .split(',')
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
  const filterSet = contractFilter.length > 0 ? new Set(contractFilter) : null;
  const root = opts.root;
  const registryAddress = opts.registryAddress;

  const provider = new JsonRpcProvider(opts.rpcUrl);
  const registry = new ethers.Contract(registryAddress, REGISTRY_ABI, provider);

  // 1. Enumerate managed contracts. When `--contracts` is set, narrow the
  //    visible registry to the requested subset; unknown names are warned
  //    once and the audit proceeds with the remainder. The downstream
  //    pipeline (event replay) keys off `addrToName` and
  //    `liveSelectorsByTarget`, so filtering here is sufficient — we don't
  //    need to short-circuit each downstream stage.
  const [names, addresses] = (await registry.getAllContracts()) as [string[], string[]];
  const addrToName = new Map<string, string>();
  const fullNameSet = new Set(names);
  for (let i = 0; i < names.length; i++) {
    const name = names[i]!;
    if (filterSet && !filterSet.has(name)) continue;
    addrToName.set(addresses[i]!.toLowerCase(), name);
  }
  if (filterSet) {
    const unknown = [...filterSet].filter((n) => !fullNameSet.has(n));
    if (unknown.length > 0) {
      console.warn(
        `  [warn] --contracts: unknown registry name${unknown.length !== 1 ? 's' : ''} ignored: ${unknown.join(', ')}`
      );
    }
    if (addrToName.size === 0) {
      throw new Error('--contracts filter matched zero registry entries; nothing to audit');
    }
  }
  const filterTargetAddrs = filterSet ? new Set(addrToName.keys()) : null;

  // 2. Resolve AccessManager from the registry itself.
  const managerAddr: string = await registry.getContract(ACCESS_MANAGER_CONTRACT_NAME);
  if (!managerAddr || managerAddr === ethers.ZeroAddress) {
    throw new Error(`registry has no ${ACCESS_MANAGER_CONTRACT_NAME} entry`);
  }

  const managerIface = new ethers.Interface(MANAGER_EVENT_ABI);
  const addedTopic = managerIface.getEvent('FunctionAllowedRoleAdded')!.topicHash;
  const removedTopic = managerIface.getEvent('FunctionAllowedRoleRemoved')!.topicHash;
  const roleRegisteredTopic = managerIface.getEvent('RoleRegistered')!.topicHash;

  const latest = BigInt(await provider.getBlockNumber());

  // 2b. Resolve --from-block via the four-tier ladder: explicit flag →
  //     env var per chain side → auto-detect via eth_getCode binary
  //     search → default 0 with a warning. See utils.resolveStartingBlock.
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

  // 3. Pull all role-config events.
  if (fromBlock > latest) {
    throw new Error(`--from-block ${fromBlock} is past the chain head (${latest})`);
  }
  const [addedLogs, removedLogs, roleLogs] = await Promise.all([
    fetchLogsChunked(
      provider,
      { address: managerAddr, topics: [addedTopic] },
      fromBlock,
      latest,
      EVENT_LOG_CHUNK
    ),
    fetchLogsChunked(
      provider,
      { address: managerAddr, topics: [removedTopic] },
      fromBlock,
      latest,
      EVENT_LOG_CHUNK
    ),
    fetchLogsChunked(
      provider,
      { address: managerAddr, topics: [roleRegisteredTopic] },
      fromBlock,
      latest,
      EVENT_LOG_CHUNK
    )
  ]);

  // Diagnostic counters — surfaced in the verdict footer so a silently
  // skipped malformed log doesn't become an invisible source of incorrect
  // live-state reconstruction. A non-zero value here means the manager
  // emitted a log with the expected topic but a payload that doesn't
  // decode against MANAGER_EVENT_ABI; typically an ABI mismatch worth
  // investigating.
  let skippedRoleLogs = 0;
  let skippedReplayLogs = 0;

  // 4. Role name lookup (best-effort).
  const roleNames = new Map<bigint, string>();
  for (const log of roleLogs) {
    try {
      const parsed = managerIface.parseLog(log);
      if (parsed) roleNames.set(parsed.args.roleId as bigint, parsed.args.name as string);
      else skippedRoleLogs++;
    } catch {
      skippedRoleLogs++;
    }
  }

  // 5. Replay events in (block, logIndex) order to derive the live set.
  type Key = string; // `${addrLower}|${selector}|${roleId}`
  const liveByKey = new Map<
    Key,
    { target: string; targetAddress: string; selector: string; roleId: bigint }
  >();
  const allEvents = [
    ...addedLogs.map((l) => ({ ...l, kind: 'add' as const })),
    ...removedLogs.map((l) => ({ ...l, kind: 'remove' as const }))
  ].sort((a, b) => a.blockNumber - b.blockNumber || a.index - b.index);

  for (const ev of allEvents) {
    let parsed;
    try {
      parsed = managerIface.parseLog(ev);
    } catch {
      skippedReplayLogs++;
      continue;
    }
    if (!parsed) {
      skippedReplayLogs++;
      continue;
    }
    const targetAddr = (parsed.args.managedContract as string).toLowerCase();
    // When `--contracts` narrows the audit, skip events for any address
    // not in the filtered registry subset. Filtering here keeps the
    // downstream STALE / hygiene pipeline scoped without
    // touching its internals.
    if (filterTargetAddrs && !filterTargetAddrs.has(targetAddr)) continue;
    const selector = parsed.args.selector as string;
    const roleId = parsed.args.roleId as bigint;
    const key = `${targetAddr}|${selector}|${roleId.toString()}`;
    if (ev.kind === 'add') {
      liveByKey.set(key, {
        target: addrToName.get(targetAddr) ?? `Unknown(${targetAddr.slice(0, 10)}…)`,
        targetAddress: targetAddr,
        selector,
        roleId
      });
    } else {
      liveByKey.delete(key);
    }
  }

  // 6. Build helpers for contract-type identification.
  //    A. Registry-name → artifact-name from deploy task source-of-truth.
  //    B. Selector-fingerprint index across all artifacts.
  const nameToArtifact = buildRegistryNameToArtifactName(root);
  const selectorIndex = buildSelectorIndex(root);
  const abiCache = new Map<string, any[] | null>();
  function getAbiByArtifactName(artifactName: string) {
    if (!abiCache.has(artifactName)) abiCache.set(artifactName, loadAbi(root, artifactName));
    return abiCache.get(artifactName) ?? null;
  }

  // Group event-derived selectors by address — used by the STALE check
  // (which artifact decodes them all?) and by fingerprint resolution for
  // addresses missing from the registry.
  const liveSelectorsByTarget = new Map<string, Set<string>>();
  for (const entry of liveByKey.values()) {
    let set = liveSelectorsByTarget.get(entry.targetAddress);
    if (!set) {
      set = new Set();
      liveSelectorsByTarget.set(entry.targetAddress, set);
    }
    set.add(entry.selector);
  }

  // For each address, resolve the actual artifact name once. Order of
  // preference:
  //   1. Registry name → artifact-name from deploy parse (when different)
  //   2. Registry name itself (with V1/V2/Replica aliases inside loadAbi)
  //   3. Selector fingerprint — any artifact whose ABI decodes ALL the
  //      address's observed selectors. Marks the entry as `unregistered`
  //      or with a divergent `artifactName` so the operator can audit the
  //      registry hygiene separately from selector drift.
  // Hoisted out of the per-address loop — the closure is identical for
  // every address; only the `sels` argument varies.
  function abiCoversAll(name: string, sels: string[]): boolean {
    const abi = getAbiByArtifactName(name);
    if (!abi) return false;
    const iface = new ethers.Interface(abi);
    return sels.every((s) => {
      try {
        return !!iface.getFunction(s);
      } catch {
        return false;
      }
    });
  }

  const resolvedByAddress = new Map<
    string,
    { artifactName: string | null; unregistered: boolean; divergent: boolean }
  >();
  for (const [addrLower, selectors] of liveSelectorsByTarget) {
    const registryName = addrToName.get(addrLower);
    const sels = [...selectors];
    let artifactName: string | null = null;
    let unregistered = false;
    let divergent = false;

    if (registryName) {
      // Step 1: deploy-task mapping (registry-name → artifact-name)
      const mapped = nameToArtifact.get(registryName);
      if (mapped && getAbiByArtifactName(mapped)) {
        artifactName = mapped;
        divergent = true;
      }
      // Step 2: registry name itself
      if (!artifactName && getAbiByArtifactName(registryName)) {
        artifactName = registryName;
      }
    } else {
      unregistered = true;
    }

    // Step 3: fingerprint by selectors. Only resort to this when the
    // direct lookups didn't find an artifact whose ABI decodes the
    // address's selectors. Confirms decoding when 1/2 found an artifact
    // but it doesn't cover the selectors (the original "STALE" false-
    // positive case).
    if (artifactName && !abiCoversAll(artifactName, sels)) {
      // Direct lookup found an artifact but it doesn't decode the
      // selectors — fall through to fingerprint.
      artifactName = null;
    }
    if (!artifactName) {
      const fp = fingerprintByAllSelectors(sels, selectorIndex);
      if (fp) {
        artifactName = fp;
        if (registryName && fp !== registryName) divergent = true;
      }
    }

    resolvedByAddress.set(addrLower, { artifactName, unregistered, divergent });
  }

  // 7. STALE / OK classification per live entry.
  const findings: OnchainFinding[] = [];
  for (const entry of liveByKey.values()) {
    const resolution = resolvedByAddress.get(entry.targetAddress);
    const artifactName = resolution?.artifactName ?? null;
    const target = artifactName
      ? (addrToName.get(entry.targetAddress) ?? artifactName)
      : (addrToName.get(entry.targetAddress) ?? `Unknown(${entry.targetAddress.slice(0, 10)}…)`);

    let status: 'OK' | 'STALE' = 'STALE';
    let signature: string | undefined;
    if (artifactName) {
      const abi = getAbiByArtifactName(artifactName);
      if (abi) {
        try {
          const fn = new ethers.Interface(abi).getFunction(entry.selector);
          if (fn) {
            status = 'OK';
            signature = fn.format('minimal').replace('function ', '');
          }
        } catch {}
      }
    }
    findings.push({
      target,
      targetAddress: entry.targetAddress,
      selector: entry.selector,
      signature,
      roleId: entry.roleId,
      roleName: roleNames.get(entry.roleId),
      status,
      unregistered: resolution?.unregistered || undefined,
      artifactName: resolution?.divergent && artifactName ? artifactName : undefined
    });
  }

  // 8. Registry-hygiene warnings — surface (a) unregistered addresses that
  //    have on-chain mappings and (b) divergent registry-name vs artifact-
  //    name pairs. Neither is "STALE selector drift"; both are deploy-time
  //    hygiene issues worth knowing about.
  type Hygiene =
    | { kind: 'unregistered'; addr: string; artifactName: string | null; selectors: string[] }
    | { kind: 'divergent'; addr: string; registryName: string; artifactName: string };
  const hygiene: Hygiene[] = [];
  const seenAddrs = new Set<string>();
  for (const entry of liveByKey.values()) {
    if (seenAddrs.has(entry.targetAddress)) continue;
    seenAddrs.add(entry.targetAddress);
    const resolution = resolvedByAddress.get(entry.targetAddress);
    if (!resolution) continue;
    if (resolution.unregistered) {
      hygiene.push({
        kind: 'unregistered',
        addr: entry.targetAddress,
        artifactName: resolution.artifactName,
        selectors: [...(liveSelectorsByTarget.get(entry.targetAddress) ?? [])]
      });
    } else if (resolution.divergent && resolution.artifactName) {
      hygiene.push({
        kind: 'divergent',
        addr: entry.targetAddress,
        registryName: addrToName.get(entry.targetAddress)!,
        artifactName: resolution.artifactName
      });
    }
  }

  // 9. Render — header → optional detail sections → verdict line.
  const stale = findings.filter((f) => f.status === 'STALE');
  const ok = findings.filter((f) => f.status === 'OK');
  const unreg = hygiene.filter((h) => h.kind === 'unregistered').length;
  const div = hygiene.filter((h) => h.kind === 'divergent').length;
  console.log(`\nOn-chain selector audit:`);
  console.log(`  AccessManager:        ${managerAddr}`);
  console.log(
    `  Block range scanned:  ${fromBlock} → ${latest}  (source: ${startingBlockResolution.source}${startingBlockResolution.detail ? `, ${startingBlockResolution.detail}` : ''})`
  );
  if (filterSet) {
    console.log(
      `  Contract filter:      ${[...filterSet].join(', ')} (${addrToName.size}/${fullNameSet.size} registry entries in scope)`
    );
  }
  console.log(`  Managed contracts:    ${addrToName.size}`);
  console.log(`  Live mappings:        ${liveByKey.size}`);
  console.log(`  OK / STALE:           ${ok.length} / ${stale.length}`);
  if (hygiene.length > 0) {
    console.log(
      `  Registry hygiene:     ${unreg} unregistered address${unreg !== 1 ? 'es' : ''}, ${div} name divergence${div !== 1 ? 's' : ''} (informational)`
    );
  }
  if (skippedRoleLogs > 0 || skippedReplayLogs > 0) {
    // Surface silently skipped logs so the operator can investigate
    // suspected ABI/topic drift rather than getting a confidently wrong
    // live-state reconstruction.
    console.log(
      `  ⚠️  Skipped (undecodable) logs: ${skippedReplayLogs} role-config, ${skippedRoleLogs} role-name`
    );
  }
  console.log('');

  if (stale.length > 0) {
    console.log('  STALE — on-chain selector with no matching function in current ABI:');
    for (const f of stale) {
      const role = f.roleName ? `${f.roleName}(#${f.roleId})` : `#${f.roleId}`;
      const suffix = f.artifactName ? `  [artifact=${f.artifactName}]` : '';
      console.log(
        `    ${f.target} @ ${f.targetAddress}  selector=${f.selector}  role=${role}${suffix}`
      );
    }
    console.log('');
  }
  if (hygiene.length > 0) {
    console.log('  REGISTRY HYGIENE — informational, not drift:');
    for (const h of hygiene) {
      if (h.kind === 'unregistered') {
        const ident = h.artifactName ? `identified as ${h.artifactName}` : 'unidentified contract';
        console.log(
          `    UNREGISTERED  ${h.addr}  (${ident})  has on-chain role mappings but no entry in DeploymentProxyRegistry`
        );
      } else {
        console.log(
          `    NAME DIVERGES ${h.addr}  registry='${h.registryName}'  artifact='${h.artifactName}'`
        );
      }
    }
    console.log('');
  }
  // Verdict — single-glance summary so the operator doesn't have to read
  // the table to know if anything's wrong.
  if (stale.length === 0) {
    console.log(`  ✅ AUDIT PASSED — no selector drift; on-chain state matches current ABIs.\n`);
  } else {
    console.log(
      `  ❌ AUDIT FAILED — ${stale.length} STALE mapping${stale.length !== 1 ? 's' : ''}.\n`
    );
    process.exitCode = 1;
  }

  return { findings, managerAddress: managerAddr, registryAddress };
}

// ─── Sibling tasks: one per chain side ─────────────────────────────────────
//
// Each task pre-resolves rpcUrl + registryAddress via the chain-keyed env-var
// helpers, then delegates to runOnchainSelectorsAudit.

const FROM_BLOCK_DESC =
  'Start block for event scan (default: chain-keyed *_STARTING_BLOCK env var, then auto-detect, then 0). Pass any value (including "0") to override the fallback ladder.';
const CONTRACTS_DESC = 'Comma-separated registry names to restrict the audit to (default: all)';
const RPC_DESC = 'JSON-RPC URL override (default: chain-keyed *_RPC_URL env var)';
const REGISTRY_DESC = 'DeploymentProxyRegistry address (default: chain-keyed env var)';

task(
  'audit:pnh:onchain-selectors',
  'Audit on-chain AccessManager selector mappings on the Private Network Hub'
)
  .addOptionalParam('rpc', RPC_DESC, '')
  .addOptionalParam('registry', REGISTRY_DESC, '')
  .addOptionalParam('fromBlock', FROM_BLOCK_DESC, '')
  .addOptionalParam('contracts', CONTRACTS_DESC, '')
  .setAction(
    async (
      args: { rpc: string; registry: string; fromBlock: string; contracts: string },
      hre
    ): Promise<OnchainAuditResult> => {
      const taskName = 'audit:pnh:onchain-selectors';
      const rpcUrl = resolveRpcUrlByChain({ chain: 'pnh', explicitRpc: args.rpc, taskName });
      const registryAddress = resolveRegistryAddress(args.registry, { chain: 'pnh', taskName });
      return runOnchainSelectorsAudit({
        taskName,
        rpcUrl,
        registryAddress,
        chain: 'pnh',
        fromBlockArg: args.fromBlock,
        contractsArg: args.contracts,
        root: hre.config.paths.root
      });
    }
  );

task(
  'audit:pn:onchain-selectors',
  "Audit on-chain AccessManager selector mappings on a Privacy Node's own chain"
)
  .addParam('pn', 'Privacy node identifier (e.g. A)')
  .addOptionalParam('rpc', RPC_DESC, '')
  .addOptionalParam('registry', REGISTRY_DESC, '')
  .addOptionalParam('fromBlock', FROM_BLOCK_DESC, '')
  .addOptionalParam('contracts', CONTRACTS_DESC, '')
  .setAction(
    async (
      args: {
        pn: string;
        rpc: string;
        registry: string;
        fromBlock: string;
        contracts: string;
      },
      hre
    ): Promise<OnchainAuditResult> => {
      const taskName = 'audit:pn:onchain-selectors';
      if (!args.pn) throw new Error(`${taskName}: --pn is required`);
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
      return runOnchainSelectorsAudit({
        taskName,
        rpcUrl,
        registryAddress,
        chain: 'pn',
        pn: args.pn,
        fromBlockArg: args.fromBlock,
        contractsArg: args.contracts,
        root: hre.config.paths.root
      });
    }
  );

task(
  'audit:pc:onchain-selectors',
  "Audit on-chain AccessManager selector mappings on a Privacy Node's public-chain AccessManager"
)
  .addParam('pn', 'Privacy node identifier (e.g. A)')
  .addOptionalParam('rpc', RPC_DESC, '')
  .addOptionalParam('registry', REGISTRY_DESC, '')
  .addOptionalParam('fromBlock', FROM_BLOCK_DESC, '')
  .addOptionalParam('contracts', CONTRACTS_DESC, '')
  .setAction(
    async (
      args: {
        pn: string;
        rpc: string;
        registry: string;
        fromBlock: string;
        contracts: string;
      },
      hre
    ): Promise<OnchainAuditResult> => {
      const taskName = 'audit:pc:onchain-selectors';
      if (!args.pn) throw new Error(`${taskName}: --pn is required`);
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
      return runOnchainSelectorsAudit({
        taskName,
        rpcUrl,
        registryAddress,
        chain: 'pc',
        pn: args.pn,
        fromBlockArg: args.fromBlock,
        contractsArg: args.contracts,
        root: hre.config.paths.root
      });
    }
  );
