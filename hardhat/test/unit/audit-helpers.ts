// Unit tests for the pure helpers under hardhat/tasks/audit/.
//
// Scope: the helpers whose behaviour can be tested without a chain or
// fixture artifacts on disk:
//   - resolveRegistryAddress (utils.ts) — env-var dispatch per chain-side
//   - resolveRpcUrlByChain (utils.ts) — chain-keyed *_RPC_URL env-var lookup
//   - resolveConstBinding (check-deploy-selectors.ts) — const-binding
//     resolver, including TDZ-aware position checks for declaration-
//     before-use enforcement within the same block
//   - resolveMapArrowParam (check-deploy-selectors.ts) — .map(literal-
//     array, arrow) expansion with per-element source-line attribution
//
// Full task-level integration tests (event replay, fingerprint resolution,
// CTS round-trips) are deferred — they need a provider mock + fixture
// artifacts, which is enough scope to warrant a dedicated test harness.
//
// Run via `npm run test:unit` (picks up via `hardhat test ./hardhat/test/unit/*.ts`).

import { expect } from 'chai';
import * as ts from 'typescript';
import {
  DEFAULT_FETCH_BATCH_SIZE,
  fetchInBatches,
  resolveRegistryAddress,
  resolveRpcUrlByChain
} from '../../tasks/audit/utils';
import {
  resolveConstBinding,
  resolveMapArrowParam
} from '../../tasks/audit/check-deploy-selectors';
import { EXPECTED_PNH_ROLES } from '../../tasks/audit/expected-roles/pnh';
import { EXPECTED_PN_ROLES } from '../../tasks/audit/expected-roles/pn';
import { EXPECTED_PC_ROLES } from '../../tasks/audit/expected-roles/pc';

/**
 * Parse TS source and return the first Identifier matching `name` in
 * source order. Used to give the resolvers a real `ts.Identifier` node to
 * walk up from.
 */
function findFirstIdentifier(src: string, name: string): ts.Identifier {
  const sf = ts.createSourceFile('test.ts', src, ts.ScriptTarget.ES2020, true);
  let found: ts.Identifier | undefined;
  function visit(node: ts.Node) {
    if (found) return;
    if (
      ts.isIdentifier(node) &&
      node.text === name &&
      node.parent &&
      !ts.isVariableDeclaration(node.parent)
    ) {
      // Skip identifiers in declaration position — we want use-site refs.
      found = node;
      return;
    }
    ts.forEachChild(node, visit);
  }
  visit(sf);
  if (!found) throw new Error(`identifier '${name}' not found in source`);
  return found;
}

describe('audit helpers — resolveRegistryAddress', () => {
  // Each test patches process.env directly and restores in `afterEach`.
  // Avoid running with --parallel without isolation; mocha-default sequential
  // is fine.
  const ENV_KEYS = [
    'PNH_DEPLOYMENT_PROXY_REGISTRY',
    'PRIVACY_NODE_A_DEPLOYMENT_PROXY_REGISTRY',
    'PRIVACY_NODE_A_PUBLIC_CHAIN_DEPLOYMENT_PROXY_REGISTRY',
    'PRIVACY_NODE_B_DEPLOYMENT_PROXY_REGISTRY'
  ];
  const saved: Record<string, string | undefined> = {};

  beforeEach(() => {
    for (const k of ENV_KEYS) {
      saved[k] = process.env[k];
      delete process.env[k];
    }
  });
  afterEach(() => {
    for (const k of ENV_KEYS) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
  });

  it('returns explicit registry verbatim when provided', () => {
    process.env.PNH_DEPLOYMENT_PROXY_REGISTRY = '0xenv';
    const got = resolveRegistryAddress('0xexplicit', { chain: 'pnh', taskName: 't' });
    expect(got).to.equal('0xexplicit');
  });

  it('falls back to PNH_DEPLOYMENT_PROXY_REGISTRY for chain=pnh', () => {
    process.env.PNH_DEPLOYMENT_PROXY_REGISTRY = '0xpnh';
    const got = resolveRegistryAddress('', { chain: 'pnh', taskName: 't' });
    expect(got).to.equal('0xpnh');
  });

  it('falls back to PRIVACY_NODE_<PN>_DEPLOYMENT_PROXY_REGISTRY for chain=pn', () => {
    process.env.PRIVACY_NODE_A_DEPLOYMENT_PROXY_REGISTRY = '0xpnA';
    const got = resolveRegistryAddress('', { pn: 'A', chain: 'pn', taskName: 't' });
    expect(got).to.equal('0xpnA');
  });

  it('falls back to PRIVACY_NODE_<PN>_PUBLIC_CHAIN_DEPLOYMENT_PROXY_REGISTRY for chain=pc', () => {
    process.env.PRIVACY_NODE_A_PUBLIC_CHAIN_DEPLOYMENT_PROXY_REGISTRY = '0xpcA';
    const got = resolveRegistryAddress('', { pn: 'A', chain: 'pc', taskName: 't' });
    expect(got).to.equal('0xpcA');
  });

  it('throws with actionable message when chain=pn omitted --pn', () => {
    expect(() => resolveRegistryAddress('', { chain: 'pn', taskName: 'audit:x' })).to.throw(
      /audit:x.*--registry omitted and chain='pn' needs --pn/
    );
  });

  it('throws with actionable message when chain=pc omitted --pn', () => {
    expect(() => resolveRegistryAddress('', { chain: 'pc', taskName: 'audit:x' })).to.throw(
      /audit:x.*--registry omitted and chain='pc' needs --pn/
    );
  });

  it('throws listing the env var it tried when nothing resolves', () => {
    expect(() => resolveRegistryAddress('', { chain: 'pnh', taskName: 'audit:x' })).to.throw(
      /PNH_DEPLOYMENT_PROXY_REGISTRY/
    );
  });

  it('uses the correct env var name per --pn (B not A)', () => {
    process.env.PRIVACY_NODE_A_DEPLOYMENT_PROXY_REGISTRY = '0xpnA';
    process.env.PRIVACY_NODE_B_DEPLOYMENT_PROXY_REGISTRY = '0xpnB';
    const gotA = resolveRegistryAddress('', { pn: 'A', chain: 'pn', taskName: 't' });
    const gotB = resolveRegistryAddress('', { pn: 'B', chain: 'pn', taskName: 't' });
    expect(gotA).to.equal('0xpnA');
    expect(gotB).to.equal('0xpnB');
  });

  it('explicit registry wins over env var', () => {
    process.env.PNH_DEPLOYMENT_PROXY_REGISTRY = '0xenv';
    const got = resolveRegistryAddress('0xexplicit', { chain: 'pnh', taskName: 't' });
    expect(got).to.equal('0xexplicit');
  });

  it('treats empty-string explicit as "not provided"', () => {
    process.env.PNH_DEPLOYMENT_PROXY_REGISTRY = '0xfromenv';
    const got = resolveRegistryAddress('', { chain: 'pnh', taskName: 't' });
    expect(got).to.equal('0xfromenv');
  });
});

describe('audit helpers — resolveRpcUrlByChain', () => {
  // Chain-keyed RPC URL resolution. Each chain has its own env var the deploy
  // script writes; the audit task reads it. --rpc <url> remains a manual override.
  const ENV_KEYS = [
    'PNH_RPC_URL',
    'PUBLIC_CHAIN_RPC_URL',
    'PRIVACY_NODE_A_RPC_URL',
    'PRIVACY_NODE_B_RPC_URL'
  ];
  const saved: Record<string, string | undefined> = {};
  beforeEach(() => {
    for (const k of ENV_KEYS) {
      saved[k] = process.env[k];
      delete process.env[k];
    }
  });
  afterEach(() => {
    for (const k of ENV_KEYS) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
  });

  it('returns explicit --rpc verbatim when provided', () => {
    process.env.PNH_RPC_URL = 'http://from-env';
    const got = resolveRpcUrlByChain({
      chain: 'pnh',
      explicitRpc: 'http://explicit',
      taskName: 't'
    });
    expect(got).to.equal('http://explicit');
  });

  it('reads PNH_RPC_URL for chain=pnh', () => {
    process.env.PNH_RPC_URL = 'http://private-hub:3445';
    const got = resolveRpcUrlByChain({ chain: 'pnh', taskName: 't' });
    expect(got).to.equal('http://private-hub:3445');
  });

  it('reads PUBLIC_CHAIN_RPC_URL for chain=pc', () => {
    process.env.PUBLIC_CHAIN_RPC_URL = 'http://pc:8545';
    const got = resolveRpcUrlByChain({ chain: 'pc', pn: 'A', taskName: 't' });
    expect(got).to.equal('http://pc:8545');
  });

  it('reads PRIVACY_NODE_<X>_RPC_URL for chain=pn', () => {
    process.env.PRIVACY_NODE_A_RPC_URL = 'http://pn-a:8545';
    const got = resolveRpcUrlByChain({ chain: 'pn', pn: 'A', taskName: 't' });
    expect(got).to.equal('http://pn-a:8545');
  });

  it('uses the correct env var name per --pn (B not A)', () => {
    process.env.PRIVACY_NODE_A_RPC_URL = 'http://pn-a:8545';
    process.env.PRIVACY_NODE_B_RPC_URL = 'http://pn-b:8545';
    const gotA = resolveRpcUrlByChain({ chain: 'pn', pn: 'A', taskName: 't' });
    const gotB = resolveRpcUrlByChain({ chain: 'pn', pn: 'B', taskName: 't' });
    expect(gotA).to.equal('http://pn-a:8545');
    expect(gotB).to.equal('http://pn-b:8545');
  });

  it('throws with the missing env-var name when nothing resolves', () => {
    expect(() => resolveRpcUrlByChain({ chain: 'pnh', taskName: 'audit:x' })).to.throw(
      /audit:x.*no RPC URL resolved.*PNH_RPC_URL/
    );
  });

  it('throws when chain=pn but --pn is omitted', () => {
    expect(() => resolveRpcUrlByChain({ chain: 'pn', taskName: 'audit:x' })).to.throw(
      /audit:x.*chain='pn' requires --pn/
    );
  });

  it('explicit --rpc wins even when env var is set', () => {
    process.env.PNH_RPC_URL = 'http://from-env';
    const got = resolveRpcUrlByChain({
      chain: 'pnh',
      explicitRpc: 'http://from-flag',
      taskName: 't'
    });
    expect(got).to.equal('http://from-flag');
  });
});

describe('audit helpers — resolveConstBinding (TDZ rules)', () => {
  it('resolves a const declared BEFORE the use in the same block', () => {
    const id = findFirstIdentifier(`const fn = 'doSomething'; iface.getFunction(fn);`, 'fn');
    expect(resolveConstBinding(id)).to.equal('doSomething');
  });

  it('does NOT resolve a const declared AFTER the use in the same block (TDZ)', () => {
    // At runtime this would throw `ReferenceError: cannot access 'fn'
    // before initialization`. The lint must not report OK for this.
    const id = findFirstIdentifier(`iface.getFunction(fn); const fn = 'doSomething';`, 'fn');
    expect(resolveConstBinding(id)).to.be.null;
  });

  it('resolves a const declared in an outer scope BEFORE the inner reference', () => {
    const src = `
      const fn = 'X';
      function inner() { return iface.getFunction(fn); }
    `;
    const id = findFirstIdentifier(src, 'fn');
    expect(resolveConstBinding(id)).to.equal('X');
  });

  it('does NOT resolve an outer-scope const declared AFTER the inner function (conservative)', () => {
    // Runtime-wise this CAN work if `inner` is called after `const fn`
    // initializes — but the static lint can't know when `inner` runs, so
    // it falls back to the conservative position rule (declaration must
    // precede the inner function's containing statement at the outer
    // scope's level).
    const src = `
      function inner() { return iface.getFunction(fn); }
      const fn = 'X';
    `;
    const id = findFirstIdentifier(src, 'fn');
    expect(resolveConstBinding(id)).to.be.null;
  });

  it('inner-scope const shadows outer-scope const (innermost wins)', () => {
    const src = `
      const fn = 'OUTER';
      {
        const fn = 'INNER';
        iface.getFunction(fn);
      }
    `;
    const id = findFirstIdentifier(src, 'fn');
    // Walking up from the use, the inner block's `const fn = 'INNER'` is
    // found first and wins (correct lexical scoping).
    expect(resolveConstBinding(id)).to.equal('INNER');
  });

  it('returns null when the const initializer is not a string literal', () => {
    // The lint won't false-positive on env-var fallbacks, function calls,
    // template strings, etc. — they bail to UNCHECKED, not a wrong OK.
    const id = findFirstIdentifier(
      `const fn = process.env.X ?? 'fallback'; iface.getFunction(fn);`,
      'fn'
    );
    expect(resolveConstBinding(id)).to.be.null;
  });

  it('ignores `let` and `var` declarations (only const counts)', () => {
    // `let` allows reassignment — we can't be sure the value at the call
    // site matches the initializer, so the resolver bails.
    const letId = findFirstIdentifier(`let fn = 'X'; iface.getFunction(fn);`, 'fn');
    expect(resolveConstBinding(letId)).to.be.null;
    const varId = findFirstIdentifier(`var fn = 'X'; iface.getFunction(fn);`, 'fn');
    expect(resolveConstBinding(varId)).to.be.null;
  });

  it('returns null when no binding exists in any enclosing scope', () => {
    const id = findFirstIdentifier(`iface.getFunction(fn);`, 'fn');
    expect(resolveConstBinding(id)).to.be.null;
  });
});

describe('audit helpers — resolveMapArrowParam', () => {
  it('expands a .map(literal-array, arrow) over a string-literal array', () => {
    const src = `['a', 'b', 'c'].map(fn => iface.getFunction(fn));`;
    const id = findFirstIdentifier(src, 'fn');
    const got = resolveMapArrowParam(id);
    expect(got).to.not.be.null;
    expect(got!.values).to.deep.equal(['a', 'b', 'c']);
    expect(got!.lines).to.have.lengthOf(3);
  });

  it('returns null when the .map receiver is not an array literal', () => {
    // `someArr.map(...)` — receiver is an Identifier, not ArrayLiteral.
    const src = `someArr.map(fn => iface.getFunction(fn));`;
    const id = findFirstIdentifier(src, 'fn');
    expect(resolveMapArrowParam(id)).to.be.null;
  });

  it('returns null when any array element is not a string literal', () => {
    const src = `['a', someVar, 'c'].map(fn => iface.getFunction(fn));`;
    const id = findFirstIdentifier(src, 'fn');
    expect(resolveMapArrowParam(id)).to.be.null;
  });

  it('returns null when identifier is not the .map arrow parameter', () => {
    // `other` isn't the arrow's param — it's a free variable.
    const src = `['a', 'b'].map(fn => iface.getFunction(other));`;
    const id = findFirstIdentifier(src, 'other');
    expect(resolveMapArrowParam(id)).to.be.null;
  });

  it('attributes each expanded entry to the source line of its array element', () => {
    // Elements split across two lines — the returned `lines` should
    // reflect that split, not the single .map call line.
    const src = `['a',\n'b']\n.map(fn => iface.getFunction(fn));`;
    const id = findFirstIdentifier(src, 'fn');
    const got = resolveMapArrowParam(id)!;
    expect(got.values).to.deep.equal(['a', 'b']);
    expect(got.lines[0]).to.equal(1); // 'a' is on line 1
    expect(got.lines[1]).to.equal(2); // 'b' is on line 2
  });

  it('resolves a const-bound array used as the .map receiver', () => {
    // The receiver of `.map` is `NAMES` (an identifier), not an inline
    // ArrayLiteral — but the const binding resolves to a literal array of
    // strings, so the lint can still validate.
    const src = `const NAMES = ['a', 'b', 'c']; NAMES.map(fn => iface.getFunction(fn));`;
    const id = findFirstIdentifier(src, 'fn');
    const got = resolveMapArrowParam(id);
    expect(got).to.not.be.null;
    expect(got!.values).to.deep.equal(['a', 'b', 'c']);
    expect(got!.lines).to.have.lengthOf(3);
  });

  it('does NOT resolve a const-bound array used BEFORE its declaration (TDZ)', () => {
    // The `.map` runs at module-load time, before `const NAMES` initializes
    // → TDZ at runtime. The audit must report UNCHECKED, not OK.
    const src = `NAMES.map(fn => iface.getFunction(fn)); const NAMES = ['a', 'b'];`;
    const id = findFirstIdentifier(src, 'fn');
    expect(resolveMapArrowParam(id)).to.be.null;
  });

  it('does NOT resolve a let-bound array used as the .map receiver', () => {
    // Only `const` is reliably a compile-time constant.
    const src = `let NAMES = ['a', 'b']; NAMES.map(fn => iface.getFunction(fn));`;
    const id = findFirstIdentifier(src, 'fn');
    expect(resolveMapArrowParam(id)).to.be.null;
  });

  it('does NOT resolve a const that points to a non-array (function call, etc.)', () => {
    const src = `const NAMES = getSomeNames(); NAMES.map(fn => iface.getFunction(fn));`;
    const id = findFirstIdentifier(src, 'fn');
    expect(resolveMapArrowParam(id)).to.be.null;
  });
});

describe('audit helpers — resolveStartingBlock', () => {
  // Helpers for the env-var dispatch tests. Tests that exercise auto-detect
  // construct an inline provider mock so we never need a live RPC.
  const ENV_KEYS = [
    'PNH_STARTING_BLOCK',
    'PNH_CHAIN_STARTING_BLOCK',
    'PRIVACY_NODE_A_STARTING_BLOCK',
    'PRIVACY_NODE_A_PUBLIC_CHAIN_STARTING_BLOCK'
  ];
  const saved: Record<string, string | undefined> = {};
  beforeEach(() => {
    for (const k of ENV_KEYS) {
      saved[k] = process.env[k];
      delete process.env[k];
    }
  });
  afterEach(() => {
    for (const k of ENV_KEYS) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
  });

  // Defer import until inside describe so the test file remains importable
  // without hardhat being initialized.
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const { resolveStartingBlock } = require('../../tasks/audit/utils');

  it('returns explicit --from-block verbatim when provided (non-zero)', async () => {
    const res = await resolveStartingBlock('1234', { chain: 'pnh', taskName: 't' });
    expect(res.fromBlock).to.equal(1234n);
    expect(res.source).to.equal('flag');
  });

  it('treats explicit "0" as an operator-chosen scan-from-genesis (skips fallback ladder)', async () => {
    // "0" is a legitimate deliberate choice — short-circuit the resolution
    // ladder even when an env var or auto-detect would otherwise return a
    // higher block. Only the empty string (omitted flag) triggers fallback.
    process.env.PNH_STARTING_BLOCK = '5000';
    const res = await resolveStartingBlock('0', { chain: 'pnh', taskName: 't' });
    expect(res.fromBlock).to.equal(0n);
    expect(res.source).to.equal('flag');
  });

  it('treats empty --from-block as not-provided (triggers fallback)', async () => {
    // Without env-var or provider, '' falls through to default-zero with a warning.
    const res = await resolveStartingBlock('', { chain: 'pnh', taskName: 't' });
    expect(res.fromBlock).to.equal(0n);
    expect(res.source).to.equal('default-zero');
  });

  it('falls back to PNH_STARTING_BLOCK env var for chain=pnh', async () => {
    process.env.PNH_STARTING_BLOCK = '5000';
    const res = await resolveStartingBlock('', { chain: 'pnh', taskName: 't' });
    expect(res.fromBlock).to.equal(5000n);
    expect(res.source).to.equal('env');
    expect(res.detail).to.equal('PNH_STARTING_BLOCK');
  });

  it('falls back to PNH_CHAIN_STARTING_BLOCK if PNH_STARTING_BLOCK missing', async () => {
    process.env.PNH_CHAIN_STARTING_BLOCK = '7777';
    const res = await resolveStartingBlock('', { chain: 'pnh', taskName: 't' });
    expect(res.fromBlock).to.equal(7777n);
    expect(res.detail).to.equal('PNH_CHAIN_STARTING_BLOCK');
  });

  it('falls back to PRIVACY_NODE_<PN>_STARTING_BLOCK for chain=pn', async () => {
    process.env.PRIVACY_NODE_A_STARTING_BLOCK = '99';
    const res = await resolveStartingBlock('', { chain: 'pn', pn: 'A', taskName: 't' });
    expect(res.fromBlock).to.equal(99n);
    expect(res.detail).to.equal('PRIVACY_NODE_A_STARTING_BLOCK');
  });

  it('falls back to PRIVACY_NODE_<PN>_PUBLIC_CHAIN_STARTING_BLOCK for chain=pc', async () => {
    process.env.PRIVACY_NODE_A_PUBLIC_CHAIN_STARTING_BLOCK = '42';
    const res = await resolveStartingBlock('', { chain: 'pc', pn: 'A', taskName: 't' });
    expect(res.fromBlock).to.equal(42n);
    expect(res.detail).to.equal('PRIVACY_NODE_A_PUBLIC_CHAIN_STARTING_BLOCK');
  });

  it('auto-detects deploy block via eth_getCode binary search when env var absent', async () => {
    // Mock provider where the contract appears at block 1000.
    const head = 2000;
    const deployBlock = 1000;
    const provider = {
      getBlockNumber: async () => head,
      getCode: async (_addr: string, blockTag: number | 'latest') => {
        const b = blockTag === 'latest' ? head : blockTag;
        return b >= deployBlock ? '0xabcd' : '0x';
      }
    };
    const res = await resolveStartingBlock('', {
      chain: 'pnh',
      managerAddress: '0xMockAddr',
      provider,
      taskName: 't'
    });
    expect(res.source).to.equal('auto-detect');
    expect(res.fromBlock).to.equal(BigInt(deployBlock));
  });

  it('defaults to 0 with a warning when nothing resolves', async () => {
    const res = await resolveStartingBlock('', { chain: 'pnh', taskName: 't' });
    expect(res.fromBlock).to.equal(0n);
    expect(res.source).to.equal('default-zero');
  });

  it('returns null-equivalent (default-zero) when auto-detect provider says no code at head', async () => {
    // Contract doesn't exist on chain → auto-detect returns null → default 0.
    const provider = {
      getBlockNumber: async () => 100,
      getCode: async () => '0x'
    };
    const res = await resolveStartingBlock('', {
      chain: 'pnh',
      managerAddress: '0xMockAddr',
      provider,
      taskName: 't'
    });
    expect(res.fromBlock).to.equal(0n);
    expect(res.source).to.equal('default-zero');
  });
});

describe('audit helpers — expected-roles modules', () => {
  // Shape-stability tests. Each chain's expected-roles module is the
  // contract between deploy code and the own-roles audit. These tests
  // pin the structure (so a typo in a new entry breaks the build) and
  // catch accidental empties (an empty module would silently pass the
  // audit). They do NOT validate the semantic content — that's the
  // audit's runtime job.

  it('PNH expected-roles is a non-empty array of well-formed entries', () => {
    expect(EXPECTED_PNH_ROLES).to.be.an('array');
    expect(EXPECTED_PNH_ROLES.length).to.be.greaterThan(0);
    for (const entry of EXPECTED_PNH_ROLES) {
      expect(entry.roleName).to.be.a('string').and.not.empty;
      expect(entry.expectedGrantees).to.be.an('array');
    }
  });

  it('PN expected-roles is a non-empty array of well-formed entries', () => {
    expect(EXPECTED_PN_ROLES).to.be.an('array');
    expect(EXPECTED_PN_ROLES.length).to.be.greaterThan(0);
    for (const entry of EXPECTED_PN_ROLES) {
      expect(entry.roleName).to.be.a('string').and.not.empty;
      expect(entry.expectedGrantees).to.be.an('array');
    }
  });

  it('PC expected-roles is a non-empty array of well-formed entries', () => {
    expect(EXPECTED_PC_ROLES).to.be.an('array');
    expect(EXPECTED_PC_ROLES.length).to.be.greaterThan(0);
    for (const entry of EXPECTED_PC_ROLES) {
      expect(entry.roleName).to.be.a('string').and.not.empty;
      expect(entry.expectedGrantees).to.be.an('array');
    }
  });

  it('no expected-roles entry has duplicate grantees', () => {
    for (const [chain, entries] of [
      ['pnh', EXPECTED_PNH_ROLES],
      ['pn', EXPECTED_PN_ROLES],
      ['pc', EXPECTED_PC_ROLES]
    ] as const) {
      for (const entry of entries) {
        const unique = new Set(entry.expectedGrantees);
        expect(unique.size, `${chain}/${entry.roleName}: duplicate grantee`).to.equal(
          entry.expectedGrantees.length
        );
      }
    }
  });

  it('no roleName appears twice within a single chain module', () => {
    for (const [chain, entries] of [
      ['pnh', EXPECTED_PNH_ROLES],
      ['pn', EXPECTED_PN_ROLES],
      ['pc', EXPECTED_PC_ROLES]
    ] as const) {
      const seen = new Set<string>();
      for (const entry of entries) {
        expect(seen.has(entry.roleName), `${chain}: duplicate role ${entry.roleName}`).to.be.false;
        seen.add(entry.roleName);
      }
    }
  });
});

describe('audit helpers — fetchInBatches', () => {
  // Bounded-concurrency wrapper around Promise.all. The audit suite uses
  // it to fan out per-role getRoleMembers RPC calls without slamming the
  // node with N concurrent eth_calls.

  it('returns results in input order', async () => {
    const items = [1, 2, 3, 4, 5, 6, 7];
    const out = await fetchInBatches(items, async (i) => i * 10);
    expect(out).to.deep.equal([10, 20, 30, 40, 50, 60, 70]);
  });

  it('handles an empty input list', async () => {
    const out = await fetchInBatches<number, number>([], async (i) => i);
    expect(out).to.deep.equal([]);
  });

  it('handles a single-item list', async () => {
    const out = await fetchInBatches([42], async (i) => i + 1);
    expect(out).to.deep.equal([43]);
  });

  it('throws on batchSize < 1', async () => {
    try {
      await fetchInBatches([1, 2, 3], async (i) => i, 0);
      expect.fail('expected fetchInBatches to throw on batchSize=0');
    } catch (err: any) {
      expect(err.message).to.match(/batchSize must be >= 1/);
    }
  });

  it('caps concurrency at batchSize — never more than N in flight', async () => {
    // Track concurrent execution via a counter that each task bumps on
    // entry and decrements on exit. The high-water mark must never exceed
    // batchSize. Tasks include a microtask-yield to give the scheduler a
    // chance to run others.
    let inFlight = 0;
    let maxInFlight = 0;
    const work = Array.from({ length: 20 }, (_, i) => i);
    await fetchInBatches(
      work,
      async (i) => {
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        await new Promise((r) => setTimeout(r, 5));
        inFlight--;
        return i;
      },
      4
    );
    expect(maxInFlight).to.be.at.most(4);
    expect(maxInFlight).to.be.at.least(2); // batchSize > 1 actually parallelizes
  });

  it('default batchSize is the documented constant (DEFAULT_FETCH_BATCH_SIZE)', async () => {
    let maxInFlight = 0;
    let inFlight = 0;
    const work = Array.from({ length: DEFAULT_FETCH_BATCH_SIZE * 3 }, (_, i) => i);
    await fetchInBatches(work, async (i) => {
      inFlight++;
      if (inFlight > maxInFlight) maxInFlight = inFlight;
      await new Promise((r) => setTimeout(r, 1));
      inFlight--;
      return i;
    });
    expect(maxInFlight).to.be.at.most(DEFAULT_FETCH_BATCH_SIZE);
  });

  it('processes batches sequentially (next batch only starts after previous resolves)', async () => {
    // With batchSize=2 over 4 items, the third item must not start until
    // both items of batch 1 have resolved. Recorded start/end timestamps
    // make the ordering observable.
    const events: Array<{ kind: 'start' | 'end'; id: number; t: number }> = [];
    let now = 0;
    await fetchInBatches(
      [1, 2, 3, 4],
      async (i) => {
        const t = now++;
        events.push({ kind: 'start', id: i, t });
        await new Promise((r) => setTimeout(r, 5));
        events.push({ kind: 'end', id: i, t: now++ });
        return i;
      },
      2
    );
    // The earliest start of any batch-2 item must come AFTER both batch-1
    // items have ended. Items 1 and 2 are batch-1; items 3 and 4 are
    // batch-2. Find the latest 'end' among {1,2} and earliest 'start'
    // among {3,4}.
    const batchOneLastEnd = Math.max(
      ...events.filter((e) => e.kind === 'end' && (e.id === 1 || e.id === 2)).map((e) => e.t)
    );
    const batchTwoFirstStart = Math.min(
      ...events.filter((e) => e.kind === 'start' && (e.id === 3 || e.id === 4)).map((e) => e.t)
    );
    expect(batchTwoFirstStart).to.be.greaterThan(batchOneLastEnd);
  });

  it('propagates errors from the fetcher (Promise.all-style)', async () => {
    try {
      await fetchInBatches([1, 2, 3], async (i) => {
        if (i === 2) throw new Error('boom on 2');
        return i;
      });
      expect.fail('expected fetchInBatches to throw');
    } catch (err: any) {
      expect(err.message).to.equal('boom on 2');
    }
  });
});
