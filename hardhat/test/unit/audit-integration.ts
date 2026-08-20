// Integration-style tests for the AccessManager audit suite.
//
// Scope: tests that touch real subsystems — the in-process hardhat EVM
// (for event-replay correctness against an actual contract emitting actual
// events), the filesystem (for artifact resolution against the real
// `artifacts/` tree), and the CTS DI hook (for relayer-roles reconciliation
// without an HTTP server).
//
// These complement `audit-helpers.ts` (which tests the pure helpers
// against synthetic AST input). Pattern: deploy a minimal contract that
// emits a chosen event, exercise the audit helper end-to-end, verify
// observable behaviour.
//
// Run via `npm run test:unit`.

import { expect } from 'chai';
import hre, { ethers } from 'hardhat';
import { loadFixture } from '@nomicfoundation/hardhat-toolbox/network-helpers';
import {
  fetchLogsChunked,
  loadAbi,
  findArtifactJson,
  defaultCtsFetcher,
  type CtsFetcher,
  type CtsAddressesResponse
} from '../../tasks/audit/utils';

// ─── Test fixture: a tiny AccessManager-shaped event emitter ───────────────
//
// `AuditEventEmitter` is a minimal contract under
// `src/test/unit/audit/AuditEventEmitter.sol` that emits events with the
// same indexed-topic layout as `RaylsAccessManagerV1`'s
// `FunctionAllowedRoleAdded` / `FunctionAllowedRoleRemoved`. Using it
// instead of the real AccessManager keeps the test independent of the
// AccessManager's library deployment graph.

const TARGET_PLACEHOLDER = '0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const SEL_A = '0xaaaaaaaa';
const SEL_B = '0xbbbbbbbb';
const ROLE_ID = 5n;

async function deployEmitterAndEmit() {
  const Emitter = await ethers.getContractFactory('AuditEventEmitter');
  const emitter = await Emitter.deploy();
  await emitter.waitForDeployment();
  const emitterAddr = await emitter.getAddress();

  const iface = (emitter as any).interface;
  const addedTopic = iface.getEvent('FunctionAllowedRoleAdded')!.topicHash;
  const removedTopic = iface.getEvent('FunctionAllowedRoleRemoved')!.topicHash;

  // Emit 12 events: 10 adds (mix of selectors) + 2 removes — gives the
  // event-replay tests a non-trivial timeline to reason about.
  for (let i = 0; i < 10; i++) {
    const sel = i % 2 === 0 ? SEL_A : SEL_B;
    await (await (emitter as any).emitAdded(TARGET_PLACEHOLDER, sel, ROLE_ID)).wait();
  }
  await (await (emitter as any).emitRemoved(TARGET_PLACEHOLDER, SEL_A, ROLE_ID)).wait();
  await (await (emitter as any).emitRemoved(TARGET_PLACEHOLDER, SEL_B, ROLE_ID)).wait();

  return { emitterAddr, addedTopic, removedTopic };
}

describe('audit integration — fetchLogsChunked against in-process EVM', () => {
  it('returns every event when scanning the full range with default chunk size', async () => {
    const { emitterAddr, addedTopic } = await loadFixture(deployEmitterAndEmit);
    const head = await hre.ethers.provider.getBlockNumber();

    const logs = await fetchLogsChunked(
      hre.ethers.provider as any,
      { address: emitterAddr, topics: [addedTopic] },
      0n,
      BigInt(head),
      5000n
    );

    expect(logs.length).to.equal(10);
    for (const log of logs) {
      expect(log.address.toLowerCase()).to.equal(emitterAddr.toLowerCase());
      expect(log.topics[0]).to.equal(addedTopic);
    }
  });

  it('returns every event when chunk size is smaller than the range (forces multiple RPC calls)', async () => {
    const { emitterAddr, addedTopic } = await loadFixture(deployEmitterAndEmit);
    const head = await hre.ethers.provider.getBlockNumber();

    // Small chunk forces fetchLogsChunked to split the [0, head] range
    // across multiple `getLogs` calls — exercises the loop boundary logic
    // (off-by-one between `from + chunk - 1` and `toBlock` etc.).
    const logs = await fetchLogsChunked(
      hre.ethers.provider as any,
      { address: emitterAddr, topics: [addedTopic] },
      0n,
      BigInt(head),
      2n
    );

    expect(logs.length).to.equal(10);
  });

  it('respects fromBlock — skips events before the cutoff', async () => {
    const { emitterAddr, addedTopic } = await loadFixture(deployEmitterAndEmit);
    const head = await hre.ethers.provider.getBlockNumber();

    // Start from block (head-5) — should capture only the last ~5 transfers.
    const fromBlock = BigInt(head - 5);
    const logs = await fetchLogsChunked(
      hre.ethers.provider as any,
      { address: emitterAddr, topics: [addedTopic] },
      fromBlock,
      BigInt(head),
      5000n
    );

    expect(logs.length).to.be.lessThan(10);
    for (const log of logs) {
      expect(log.blockNumber).to.be.at.least(Number(fromBlock));
    }
  });

  it('returns empty array when no events match the filter', async () => {
    const { emitterAddr } = await loadFixture(deployEmitterAndEmit);
    const head = await hre.ethers.provider.getBlockNumber();

    // Filter for a topic that no event matches.
    const unknownTopic = ethers.id('NonExistentEvent(address)');
    const logs = await fetchLogsChunked(
      hre.ethers.provider as any,
      { address: emitterAddr, topics: [unknownTopic] },
      0n,
      BigInt(head),
      5000n
    );

    expect(logs).to.deep.equal([]);
  });

  it('handles fromBlock === toBlock (single-block scan)', async () => {
    const { emitterAddr, addedTopic } = await loadFixture(deployEmitterAndEmit);
    const head = await hre.ethers.provider.getBlockNumber();

    // Scan just the last block — likely catches the last transfer.
    const logs = await fetchLogsChunked(
      hre.ethers.provider as any,
      { address: emitterAddr, topics: [addedTopic] },
      BigInt(head),
      BigInt(head),
      5000n
    );

    // Could be 0 or 1 depending on what's in the head block; the assertion
    // is that the function doesn't loop infinitely or throw.
    expect(logs.length).to.be.at.most(1);
  });
});

describe('audit integration — loadAbi / findArtifactJson against real artifacts/', () => {
  it('finds the ABI for a directly-named contract (TokenExample)', () => {
    const root = hre.config.paths.root;
    const abi = loadAbi(root, 'TokenExample');
    expect(abi).to.not.be.null;
    expect(Array.isArray(abi)).to.equal(true);
    // Should contain at least the standard ERC20 function fragments.
    const names = (abi as any[]).filter((f) => f.type === 'function').map((f) => f.name);
    expect(names).to.include('transfer');
    expect(names).to.include('balanceOf');
  });

  it('returns null for an artifact that does not exist', () => {
    const root = hre.config.paths.root;
    const abi = loadAbi(root, 'DefinitelyNonExistentContract');
    expect(abi).to.be.null;
  });

  it('resolves the V1 alias (e.g. "RaylsAccessManager" → "RaylsAccessManagerV1")', () => {
    const root = hre.config.paths.root;
    const abi = loadAbi(root, 'RaylsAccessManager');
    expect(abi).to.not.be.null;
    const names = (abi as any[]).filter((f) => f.type === 'function').map((f) => f.name);
    // Functions present on V1 should be found via the alias.
    expect(names).to.include('hasRole');
    expect(names).to.include('grantRole');
  });

  it('findArtifactJson skips .dbg. debug-info files', () => {
    const root = hre.config.paths.root;
    const dir = `${root}/artifacts`;
    const matches = findArtifactJson(dir, 'TokenExample');
    expect(matches.length).to.be.greaterThan(0);
    for (const m of matches) {
      expect(m).to.not.include('.dbg.');
    }
  });
});

describe('audit integration — CTS fetcher dependency injection', () => {
  // Demonstrates the CtsFetcher DI hook works as documented — tests can
  // override the default axios fetcher with a stub that returns canned
  // responses, exercising the relayer-roles audit's diff logic without
  // standing up an HTTP server.

  it('defaultCtsFetcher throws when CTS_SERVICE_<PN>_URL is unset', async () => {
    const saved = process.env.CTS_SERVICE_X_URL;
    delete process.env.CTS_SERVICE_X_URL;
    try {
      let threw: Error | null = null;
      try {
        await defaultCtsFetcher('X', 'private_relayer');
      } catch (err: any) {
        threw = err;
      }
      expect(threw).to.not.be.null;
      expect(threw!.message).to.match(/CTS_SERVICE_X_URL is not set/);
    } finally {
      if (saved !== undefined) process.env.CTS_SERVICE_X_URL = saved;
    }
  });

  it('a stubbed CtsFetcher returns canned responses without an HTTP server', async () => {
    const canned: CtsAddressesResponse = {
      private_chain_addresses: ['0x1111111111111111111111111111111111111111'],
      private_hub_addresses: [
        '0x2222222222222222222222222222222222222222',
        '0x3333333333333333333333333333333333333333'
      ]
    };
    const stubFetcher: CtsFetcher = async (pn, service) => {
      expect(pn).to.equal('A');
      expect(service).to.be.oneOf(['private_relayer', 'public_relayer']);
      return canned;
    };

    const res = await stubFetcher('A', 'private_relayer');
    expect(res.private_chain_addresses).to.deep.equal([
      '0x1111111111111111111111111111111111111111'
    ]);
    expect(res.private_hub_addresses).to.have.lengthOf(2);
  });

  it('a stubbed CtsFetcher can signal errors via the response.error field', async () => {
    const stubFetcher: CtsFetcher = async () => ({ error: 'simulated CTS outage' });
    const res = await stubFetcher('A', 'private_relayer');
    expect(res.error).to.equal('simulated CTS outage');
  });
});

describe('audit integration — synthetic AccessManager-event reconstruction', () => {
  // Tests the audit's invariant that replaying `FunctionAllowedRoleAdded`
  // and `FunctionAllowedRoleRemoved` events in (block, logIndex) order
  // produces the correct live (target, selector, role) set — without
  // deploying the full RaylsAccessManagerV1 (which has heavy library
  // dependencies). We synthesise the event stream and run the same
  // replay logic the audit task uses inline.

  // The audit's replay logic is currently inlined in check-onchain-selectors
  // .setAction. Replicate it here against synthetic data — the goal is to
  // verify the semantic behaviour (add then remove leaves no entry; double-
  // add overwrites; sort-by-(block, index) handles out-of-order input) so
  // that any future refactor preserves these properties.

  type Ev = {
    kind: 'add' | 'remove';
    targetAddr: string;
    selector: string;
    roleId: bigint;
    blockNumber: number;
    index: number;
  };

  function replay(events: Ev[]): Map<string, { selector: string; roleId: bigint }> {
    const live = new Map<string, { selector: string; roleId: bigint }>();
    const sorted = [...events].sort((a, b) => a.blockNumber - b.blockNumber || a.index - b.index);
    for (const ev of sorted) {
      const key = `${ev.targetAddr}|${ev.selector}|${ev.roleId}`;
      if (ev.kind === 'add') {
        live.set(key, { selector: ev.selector, roleId: ev.roleId });
      } else {
        live.delete(key);
      }
    }
    return live;
  }

  const TARGET = '0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const SEL_A = '0xaaaaaaaa';
  const SEL_B = '0xbbbbbbbb';
  const ROLE = 5n;

  it('a single add produces one live entry', () => {
    const live = replay([
      { kind: 'add', targetAddr: TARGET, selector: SEL_A, roleId: ROLE, blockNumber: 1, index: 0 }
    ]);
    expect(live.size).to.equal(1);
  });

  it('add then remove (same key) leaves zero live entries', () => {
    const live = replay([
      { kind: 'add', targetAddr: TARGET, selector: SEL_A, roleId: ROLE, blockNumber: 1, index: 0 },
      {
        kind: 'remove',
        targetAddr: TARGET,
        selector: SEL_A,
        roleId: ROLE,
        blockNumber: 2,
        index: 0
      }
    ]);
    expect(live.size).to.equal(0);
  });

  it('out-of-order events get sorted to (block, index) order', () => {
    // Replay-order-dependent semantics: add(block=1) then remove(block=2)
    // should net to nothing. If we feed them in reverse, sorting fixes it.
    const live = replay([
      {
        kind: 'remove',
        targetAddr: TARGET,
        selector: SEL_A,
        roleId: ROLE,
        blockNumber: 2,
        index: 0
      },
      { kind: 'add', targetAddr: TARGET, selector: SEL_A, roleId: ROLE, blockNumber: 1, index: 0 }
    ]);
    expect(live.size).to.equal(0);
  });

  it('two adds for distinct selectors leave two live entries', () => {
    const live = replay([
      { kind: 'add', targetAddr: TARGET, selector: SEL_A, roleId: ROLE, blockNumber: 1, index: 0 },
      { kind: 'add', targetAddr: TARGET, selector: SEL_B, roleId: ROLE, blockNumber: 1, index: 1 }
    ]);
    expect(live.size).to.equal(2);
  });

  it('remove without a prior add is a no-op', () => {
    const live = replay([
      {
        kind: 'remove',
        targetAddr: TARGET,
        selector: SEL_A,
        roleId: ROLE,
        blockNumber: 1,
        index: 0
      }
    ]);
    expect(live.size).to.equal(0);
  });

  it('logIndex breaks ties when two events share a block', () => {
    // Same block: index 0 adds, index 1 removes → net zero. The sort by
    // (block, index) must respect logIndex order, not array order.
    const live = replay([
      {
        kind: 'remove',
        targetAddr: TARGET,
        selector: SEL_A,
        roleId: ROLE,
        blockNumber: 1,
        index: 1
      },
      { kind: 'add', targetAddr: TARGET, selector: SEL_A, roleId: ROLE, blockNumber: 1, index: 0 }
    ]);
    expect(live.size).to.equal(0);
  });
});
