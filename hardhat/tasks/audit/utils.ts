// Shared helpers for the AccessManager audit suite.
//
// Kept deliberately small — only the helpers reused across more than one
// audit task live here. Per-task concerns (event replay, source parsing,
// migration emission) stay in their respective files.
//
// Convention — chain-keyed env vars
// ---------------------------------
// Audit task names carry their chain side (`audit:pnh:*`, `audit:pn:*`,
// `audit:pc:*`). All chain-dependent state — RPC URL, registry address,
// starting block — is read from chain-keyed env vars that the deploy
// script writes to `.env`. Hardhat auto-loads dotenv, so `process.env`
// carries everything by the time any task runs.
//
//   npx hardhat audit:pnh                  # reads PNH_RPC_URL, PNH_DEPLOYMENT_PROXY_REGISTRY
//   npx hardhat audit:pn --pn A            # reads PRIVACY_NODE_A_RPC_URL, PRIVACY_NODE_A_DEPLOYMENT_PROXY_REGISTRY
//   npx hardhat audit:pc --pn A            # reads PUBLIC_CHAIN_RPC_URL, PRIVACY_NODE_A_PUBLIC_CHAIN_DEPLOYMENT_PROXY_REGISTRY
//
// Operators can override with `--rpc <url>` and/or `--registry <addr>` —
// these wins over env-var lookups for one-off audits.

import * as fs from 'fs';
import * as path from 'path';
import type { JsonRpcProvider, Log } from 'ethers';

// The registry label under which the AccessManager is recorded. Shared
// between the on-chain audit (which resolves the manager from the registry)
// and the migration generator (which does the same to write the address into
// the emitted script).
export const ACCESS_MANAGER_CONTRACT_NAME = 'RaylsAccessManager';

/**
 * Recursively find every `<name>.json` artifact under `dir`, skipping the
 * `.dbg.` debug copies hardhat emits alongside.
 */
export function findArtifactJson(dir: string, name: string): string[] {
  const target = `${name}.json`;
  const out: string[] = [];
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
      else if (entry.name === target && !full.includes('.dbg.')) out.push(full);
    }
  }
  walk(dir);
  return out;
}

/**
 * Load a contract's ABI from `artifacts/`. Mirrors the auth-ops V1/V2/Replica
 * alias chain so the registry's logical name finds the artifact even when the
 * on-disk contract is a versioned variant (e.g. registry `Teleport` →
 * artifact `TeleportV1`, registry `EndpointReplica` → artifact `EndpointV1`).
 *
 * Returns the first ABI whose JSON parses and contains a non-empty `abi`
 * array. Returns null when nothing matched.
 */
export function loadAbi(rootDir: string, name: string): any[] | null {
  const candidates = Array.from(
    new Set([
      name,
      `${name}V1`,
      `${name}V2`,
      name.replace('Replica', 'V1'),
      name.replace('RN', 'RaylsNode')
    ])
  );
  for (const candidate of candidates) {
    const matches = findArtifactJson(path.join(rootDir, 'artifacts'), candidate);
    for (const m of matches) {
      try {
        const raw = JSON.parse(fs.readFileSync(m, 'utf8'));
        if (raw.abi && Array.isArray(raw.abi) && raw.abi.length > 0) return raw.abi;
      } catch {
        // try next candidate / match
      }
    }
  }
  return null;
}

/**
 * Chain side an audit task targets. Carried into every chain-keyed helper
 * (registry address, RPC URL, starting block) so the helper can pick the
 * right env-var family.
 */
export type ChainType = 'pn' | 'pnh' | 'pc';

// ─── RPC URL resolution ────────────────────────────────────────────────────
//
// Audit tasks identify their chain by task name (`audit:pnh:*`, `audit:pn:*`,
// `audit:pc:*`). The RPC URL for each chain comes from a chain-keyed env var
// the deploy script writes to `.env` after each chain comes up:
//
//   pnh             → `PNH_RPC_URL`
//   pc              → `PUBLIC_CHAIN_RPC_URL`
//   pn  + --pn X    → `PRIVACY_NODE_<X>_RPC_URL`
//
// Hardhat's `--network <name>` is intentionally NOT a source — audit tasks
// would otherwise carry two overlapping signals for the same thing. An
// explicit `--rpc <url>` remains as a manual override (one-off audits
// against an arbitrary RPC).

/**
 * Resolve the JSON-RPC URL the audit should connect to.
 *
 * Precedence:
 *   1. Explicit `--rpc <url>` (operator override; always wins).
 *   2. Chain-keyed env var:
 *        pnh             → `PNH_RPC_URL`
 *        pc              → `PUBLIC_CHAIN_RPC_URL`
 *        pn  (requires pn) → `PRIVACY_NODE_<X>_RPC_URL`
 *   3. Throws with the env-var name the operator could set.
 */
export function resolveRpcUrlByChain(opts: {
  chain: ChainType;
  pn?: string;
  explicitRpc?: string;
  taskName: string;
}): string {
  if (opts.explicitRpc && opts.explicitRpc.length > 0) return opts.explicitRpc;

  let envName: string;
  if (opts.chain === 'pnh') {
    envName = 'PNH_RPC_URL';
  } else if (opts.chain === 'pc') {
    envName = 'PUBLIC_CHAIN_RPC_URL';
  } else {
    if (!opts.pn) {
      throw new Error(`${opts.taskName}: chain='pn' requires --pn to derive the RPC env-var name.`);
    }
    envName = `PRIVACY_NODE_${opts.pn}_RPC_URL`;
  }

  const url = process.env[envName];
  if (url && url.length > 0) return url;

  throw new Error(
    `${opts.taskName}: no RPC URL resolved. Pass --rpc <url> or set ${envName} in .env.`
  );
}

/**
 * Fetch logs in `[fromBlock, toBlock]` from `provider.getLogs`, sliced into
 * `chunk`-block windows. Most RPC providers reject single calls covering
 * very large ranges; chunking is the universal workaround.
 *
 * `fromBlock` defaults to 0, so this function works fine on fresh chains;
 * for long-lived chains, callers should pass a starting block past the
 * AccessManager's deploy block to skip the dead range.
 *
 * Block params are passed as `Number(...)` — safe up to ~9e15, far beyond
 * any current EVM chain head. If that ceiling becomes relevant, switch to
 * hex-string BigNumberish.
 */
export async function fetchLogsChunked(
  provider: JsonRpcProvider,
  filter: { address: string; topics: (string | string[] | null)[] },
  fromBlock: bigint,
  toBlock: bigint,
  chunk: bigint
): Promise<Log[]> {
  const out: Log[] = [];
  for (let from = fromBlock; from <= toBlock; from += chunk) {
    const to = from + chunk - 1n > toBlock ? toBlock : from + chunk - 1n;
    const logs = await provider.getLogs({
      ...filter,
      fromBlock: Number(from),
      toBlock: Number(to)
    });
    out.push(...logs);
  }
  return out;
}

/** Default concurrency for `fetchInBatches`. Picked low enough that a
 *  hardhat audit never bombards an RPC node — even at full fan-out
 *  (e.g. PNH with ~19 roles), this caps at 4 concurrent `eth_call`s.
 *  Sequential audit:all over 6 PNs × (PN + PC) sums to ≤24 concurrent
 *  calls only at the moment of switching audits, not all at once. */
export const DEFAULT_FETCH_BATCH_SIZE = 4;

/**
 * Run `fetcher` across `items` with bounded concurrency. Each batch of
 * up to `batchSize` items is dispatched with `Promise.all`; the next
 * batch only starts after the previous one resolves. Order of returned
 * results matches input order.
 *
 * Used for fanning out N read-only RPC calls (e.g., per-role
 * `getRoleMembers`) without thundering-herd risk on the connected node.
 * For unbounded `Promise.all`, prefer this helper.
 *
 * @param items     work items
 * @param fetcher   async function called per item
 * @param batchSize max concurrent in-flight (default 4)
 */
export async function fetchInBatches<T, R>(
  items: T[],
  fetcher: (item: T) => Promise<R>,
  batchSize: number = DEFAULT_FETCH_BATCH_SIZE
): Promise<R[]> {
  if (batchSize < 1) {
    throw new Error(`fetchInBatches: batchSize must be >= 1, got ${batchSize}`);
  }
  const out: R[] = [];
  for (let i = 0; i < items.length; i += batchSize) {
    const batch = items.slice(i, i + batchSize);
    const settled = await Promise.all(batch.map(fetcher));
    out.push(...settled);
  }
  return out;
}

// ─── Registry address resolution ───────────────────────────────────────────
//
// The audits read the AccessManager address from a DeploymentProxyRegistry.
// Each chain side has its own env var the deploy script writes:
//   pnh             → `PNH_DEPLOYMENT_PROXY_REGISTRY`
//   pn  + --pn X    → `PRIVACY_NODE_<X>_DEPLOYMENT_PROXY_REGISTRY`
//   pc  + --pn X    → `PRIVACY_NODE_<X>_PUBLIC_CHAIN_DEPLOYMENT_PROXY_REGISTRY`

/**
 * Resolve the DeploymentProxyRegistry address for the chain being audited.
 *
 * Resolution order:
 *   1. Explicit `--registry <addr>` (always wins).
 *   2. Chain-keyed env var (see header).
 *   3. Throws with the env-var name the operator could set.
 */
export function resolveRegistryAddress(
  explicit: string | undefined,
  opts: { chain: ChainType; pn?: string; taskName: string }
): string {
  if (explicit && explicit.length > 0) return explicit;

  let envName: string;
  if (opts.chain === 'pnh') {
    envName = 'PNH_DEPLOYMENT_PROXY_REGISTRY';
  } else if (opts.chain === 'pn') {
    if (!opts.pn) {
      throw new Error(
        `${opts.taskName}: --registry omitted and chain='pn' needs --pn to derive the env-var name.`
      );
    }
    envName = `PRIVACY_NODE_${opts.pn}_DEPLOYMENT_PROXY_REGISTRY`;
  } else {
    if (!opts.pn) {
      throw new Error(
        `${opts.taskName}: --registry omitted and chain='pc' needs --pn to derive the env-var name.`
      );
    }
    envName = `PRIVACY_NODE_${opts.pn}_PUBLIC_CHAIN_DEPLOYMENT_PROXY_REGISTRY`;
  }

  const addr = process.env[envName];
  if (addr && addr.length > 0) return addr;

  throw new Error(
    `${opts.taskName}: could not resolve a DeploymentProxyRegistry address. ` +
      `Pass --registry <addr> or set ${envName} in .env.`
  );
}

// ─── CTS (Cryptographic Trust Suite) address fetch ─────────────────────────
//
// Mirrors the contract of `add-authorized-relayers*` so the audit's notion
// of "expected role holders" matches what the authorization task grants.
// Source URL: `CTS_SERVICE_<PN>_URL/public/addresses?service=<service>`.

/** Subset of the CTS response shape used across services. Optional fields
 *  reflect that not every service populates every list. */
export interface CtsAddressesResponse {
  private_chain_addresses?: string[];
  public_chain_addresses?: string[];
  private_hub_addresses?: string[];
  private_hub_dvp_operator_addresses?: string[];
  error?: string;
}

/**
 * Pull the CTS address response for one (PN, service) pair. Caller passes
 * `service='private_relayer'` or `service='public_relayer'`; mirrors
 * `add-authorized-relayers*` so the audit reads the same source the
 * authorization task wrote against.
 */
export async function fetchCtsAddresses(
  pn: string,
  service: 'private_relayer' | 'public_relayer'
): Promise<CtsAddressesResponse> {
  return defaultCtsFetcher(pn, service);
}

/**
 * Pluggable CTS fetcher type — lets tests inject canned responses without
 * spinning up a real HTTP server. Default is `defaultCtsFetcher` (axios
 * against the env-var-derived URL).
 */
export type CtsFetcher = (
  pn: string,
  service: 'private_relayer' | 'public_relayer'
) => Promise<CtsAddressesResponse>;

export const defaultCtsFetcher: CtsFetcher = async (pn, service) => {
  const ctsUrlEnvVar = `CTS_SERVICE_${pn}_URL`;
  const ctsUrl = process.env[ctsUrlEnvVar];
  if (!ctsUrl) {
    throw new Error(`Environment variable ${ctsUrlEnvVar} is not set`);
  }
  const endpoint = `${ctsUrl}/public/addresses?service=${service}`;
  // Lazy require — keeps `audit:deploy-selectors` (which doesn't need axios)
  // from paying the import cost on every hardhat invocation.
  const axios = (await import('axios')).default;
  let response;
  try {
    response = await axios.get<CtsAddressesResponse>(endpoint, {
      timeout: 10000,
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' }
    });
  } catch (err: any) {
    if (err.response)
      throw new Error(
        `HTTP error ${err.response.status}: ${err.response.statusText} at ${endpoint}`
      );
    if (err.request) throw new Error(`Network error: could not reach CTS endpoint at ${endpoint}`);
    throw err;
  }
  if (response.data.error) throw new Error(`CTS API error: ${response.data.error}`);
  return response.data;
};

// ─── Starting-block resolution ─────────────────────────────────────────────
//
// `audit:<chain>:onchain-selectors` and `audit:<chain>:roles` replay events
// from the AccessManager. Starting at block 0 is correct but slow on long-
// lived chains — `eth_getLogs` for ranges past chain head is fast, but
// ranges covering millions of empty blocks make a lot of RPC round-trips.
//
// Resolution order:
//   1. Explicit `--from-block <N>` (operator override).
//   2. Env-var fallback — same shape as resolveRegistryAddress:
//        pnh                → `PNH_STARTING_BLOCK` (or `PNH_CHAIN_STARTING_BLOCK`)
//        pn  (requires pn)  → `PRIVACY_NODE_<PN>_STARTING_BLOCK`
//        pc  (requires pn)  → `PRIVACY_NODE_<PN>_PUBLIC_CHAIN_STARTING_BLOCK`
//      The deploy scripts emit these; `deploy_contracts.sh` propagates the
//      values into the contracts `.env`.
//   3. Auto-detect via binary search on `eth_getCode(<manager-addr>)` — the
//      AccessManager's deployment block is the first one where the contract
//      has non-empty code. O(log chainHead) RPC calls.
//   4. Default to 0 with a printed warning (worst case; loud).
//
// The auto-detect path is the safety net for chains where the deploy script
// didn't write a starting-block env var (e.g. operator imported an existing
// chain into the audit harness without re-running the deploy).

export interface StartingBlockResolution {
  /** The block number to start the event scan from. */
  fromBlock: bigint;
  /** Where the value came from, for verdict-line reporting. */
  source: 'flag' | 'env' | 'auto-detect' | 'default-zero';
  /** Set when source === 'env' or 'auto-detect'; useful for log/triage. */
  detail?: string;
}

interface StartingBlockProvider {
  getCode(address: string, blockTag: number | 'latest'): Promise<string>;
  getBlockNumber(): Promise<number>;
}

/**
 * Resolve the starting block for an event-replay audit.
 *
 * `explicit` is the operator's `--from-block` flag value (string from CLI).
 * **Only an empty string** (`''` — the operator didn't pass the flag)
 * triggers fallback to env vars / auto-detect / default-zero. Any
 * non-empty value (including `'0'`) is honored verbatim — `--from-block 0`
 * is a legitimate operator choice meaning "scan from the genesis block,
 * skip the fallback ladder".
 *
 * Hardhat task params with `addOptionalParam('fromBlock', desc, '')` default
 * to the empty string when the flag isn't passed, which makes the
 * "fallback vs. explicit-zero" distinction work cleanly.
 *
 * Pass `managerAddress` to enable the auto-detect pass; omit (or pass
 * undefined) to skip it.
 */
export async function resolveStartingBlock(
  explicit: string | undefined,
  opts: {
    chain: ChainType;
    pn?: string;
    managerAddress?: string;
    provider?: StartingBlockProvider;
    taskName: string;
  }
): Promise<StartingBlockResolution> {
  // Pass 1: explicit flag wins. Any non-empty value — including the
  // string '0' — is taken as the operator's deliberate choice.
  if (explicit !== undefined && explicit !== '') {
    const n = BigInt(explicit);
    if (n < 0n) throw new Error(`${opts.taskName}: --from-block must be >= 0, got ${explicit}`);
    return { fromBlock: n, source: 'flag' };
  }

  // Pass 2: env-var fallback.
  let envName: string | null = null;
  let altEnvName: string | null = null;
  if (opts.chain === 'pnh') {
    envName = 'PNH_STARTING_BLOCK';
    altEnvName = 'PNH_CHAIN_STARTING_BLOCK';
  } else if (opts.chain === 'pn' && opts.pn) {
    envName = `PRIVACY_NODE_${opts.pn}_STARTING_BLOCK`;
  } else if (opts.chain === 'pc' && opts.pn) {
    envName = `PRIVACY_NODE_${opts.pn}_PUBLIC_CHAIN_STARTING_BLOCK`;
  }
  for (const name of [envName, altEnvName]) {
    if (!name) continue;
    const v = process.env[name];
    if (v && v.length > 0) {
      const n = BigInt(v);
      if (n < 0n) continue;
      return { fromBlock: n, source: 'env', detail: name };
    }
  }

  // Pass 3: auto-detect via binary search on `eth_getCode`.
  if (opts.managerAddress && opts.provider) {
    try {
      const block = await binarySearchDeployBlock(opts.provider, opts.managerAddress);
      if (block !== null) {
        return { fromBlock: BigInt(block), source: 'auto-detect', detail: `block ${block}` };
      }
    } catch (err: any) {
      // Auto-detect is best-effort — RPC may not support historical eth_getCode
      // (some providers don't), in which case we fall through to the default.
      console.warn(
        `  [warn] ${opts.taskName}: auto-detect of AccessManager deploy block failed (${err?.message ?? err}). Falling back to 0.`
      );
    }
  }

  // Pass 4: default to 0 with a loud warning.
  console.warn(
    `  ⚠️  ${opts.taskName}: --from-block not specified, no env-var fallback found, and auto-detect did not run or failed. Scanning the chain from block 0 — this may be slow on long-lived chains. Set --from-block <N> or one of: ${[envName, altEnvName].filter(Boolean).join(' / ') || '(none applicable)'} to skip the dead range.`
  );
  return { fromBlock: 0n, source: 'default-zero' };
}

/**
 * Binary-search the chain for the lowest block where `eth_getCode(addr)`
 * returns non-empty (i.e. the address has deployed contract code). Returns
 * null if the address has no code even at chain head.
 *
 * Returns the deploy block (1-indexed equivalent — the block in which the
 * contract was created and code became visible). Worst case ~ceil(log2(N))
 * RPC calls for a chain at block N.
 */
export async function binarySearchDeployBlock(
  provider: StartingBlockProvider,
  address: string
): Promise<number | null> {
  const head = await provider.getBlockNumber();
  if (head < 0) return null;
  // Check head first — if no code there, the address isn't a contract on
  // this chain (or it self-destructed); we can't help.
  const codeAtHead = await provider.getCode(address, head);
  if (codeAtHead === '0x' || codeAtHead.length <= 2) return null;

  // Invariant during search: getCode at `lo` is '0x' (no code), getCode at
  // `hi` is non-empty. Block 0 of a fresh chain has no contracts, so lo=0
  // is a safe initial bound unless the chain's genesis includes pre-
  // deployed code at this address (rare). For Rayls dev chains, ADM is
  // deployed normally so the invariant holds.
  let lo = 0;
  let hi = head;
  // Special case: if hi = 0, the contract is at genesis.
  if (hi === 0) return 0;

  // Sanity: verify lo really has no code (catches genesis-deployed contracts).
  const codeAtZero = await provider.getCode(address, 0);
  if (codeAtZero !== '0x' && codeAtZero.length > 2) return 0;

  while (lo + 1 < hi) {
    const mid = Math.floor((lo + hi) / 2);
    const code = await provider.getCode(address, mid);
    if (code === '0x' || code.length <= 2) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return hi;
}
