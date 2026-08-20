# AccessManager Audit Suite

Hardhat tasks that verify on-chain AccessManager state, deploy-script integrity, and role grants against current source / ABIs / CTS, on each Rayls chain side.

This README is the **entry point**. The detailed task reference (CLI flags, status tables, env-var conventions, AccessManager access invariant) lives in [`docs/access-manager-migration.md`](../../../docs/access-manager-migration.md). The operator playbook (pre-flight, per-finding triage, CI/CD wiring, CTS-down recovery) lives at [docs.rayls.io](https://docs.rayls.io/deploy/privacy-node/access-manager-audit/).

## Tasks at a glance

| Task                                                                | What it checks                                                                                                                          | Default exit-1 on                                    |
| ------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------- |
| **`audit:deploy-selectors`** ([src](./check-deploy-selectors.ts))   | Every `iface.getFunction('NAME')` in `hardhat/tasks/deploy/*.ts` resolves to a function on the current ABI                              | `MISSING` (or `UNCHECKED` with `--strict-unchecked`) |
| **`audit:all`** ([src](./parents.ts))                               | Full CI entrypoint: deploy-selectors --strict-unchecked + audit:pnh + per-PN audit:pn + per-PN audit:pc, all with `--include-own-roles` | any child finding                                    |
| **PNH**                                                             |                                                                                                                                         |                                                      |
| `audit:pnh` ([src](./parents.ts))                                   | Parent — runs `:pnh:onchain-selectors` then `:pnh:roles`                                                                                | any child finding                                    |
| `audit:pnh:onchain-selectors` ([src](./check-onchain-selectors.ts)) | On-chain `(target, selector, role)` mappings decode against current ABIs                                                                | `STALE`                                              |
| `audit:pnh:roles` ([src](./check-roles.ts))                         | CTS-advertised relayer wallets hold RELAYER on PNH (+ own-roles audit with `--include-own-roles`)                                       | `MISSING` or `UNEXPECTED`                            |
| `audit:pnh:generate-migration` ([src](./generate-migration.ts))     | Combines static lint + on-chain audit; writes a reviewable `removeFunctionAllowedRoles` script under `audit/migrations/`                | static-lint MISSING                                  |
| **PN** (requires `--pn A[,B,…]`)                                    |                                                                                                                                         |                                                      |
| `audit:pn` ([src](./parents.ts))                                    | Parent — iterates per PN, runs `:pn:onchain-selectors` then `:pn:roles`                                                                 | any child finding                                    |
| `audit:pn:onchain-selectors` ([src](./check-onchain-selectors.ts))  | Selector audit on the PN's own AccessManager                                                                                            | `STALE`                                              |
| `audit:pn:roles` ([src](./check-roles.ts))                          | RELAYER (+ own-roles with `--include-own-roles`) on the PN's own chain                                                                  | `MISSING` or `UNEXPECTED`                            |
| `audit:pn:generate-migration` ([src](./generate-migration.ts))      | Migration emitter scoped to the PN's own chain                                                                                          | static-lint MISSING                                  |
| **PC** (requires `--pn A[,B,…]`)                                    |                                                                                                                                         |                                                      |
| `audit:pc` ([src](./parents.ts))                                    | Parent — iterates per PN, runs `:pc:onchain-selectors` then `:pc:roles` against the per-PN AccessManager on the public chain            | any child finding                                    |
| `audit:pc:onchain-selectors` ([src](./check-onchain-selectors.ts))  | Selector audit on the per-PN PC AccessManager                                                                                           | `STALE`                                              |
| `audit:pc:roles` ([src](./check-roles.ts))                          | RELAYER (+ own-roles) on the per-PN PC AccessManager                                                                                    | `MISSING` or `UNEXPECTED`                            |
| `audit:pc:generate-migration` ([src](./generate-migration.ts))      | Migration emitter scoped to the per-PN PC AccessManager                                                                                 | static-lint MISSING                                  |

`generate-migration` tasks are **dry-run by design** — they emit a reviewable TypeScript file under `audit/migrations/` and never send a transaction.

## How they fit together

```
                           hardhat compile
                                 │
                                 ▼
                  ┌──────────────────────────────┐
                  │   audit:deploy-selectors     │
                  │   (static AST lint, no chain)│
                  └──────────────┬───────────────┘
                                 │ exit 0
                                 ▼
                  ┌──────────────────────────────┐
                  │  deploy each chain           │
                  │  (PNH, each PN, each PC)     │
                  └──────────────┬───────────────┘
                                 │
                  ┌──────────────┴───────────────┐
                  ▼              ▼               ▼
              audit:pnh      audit:pn       audit:pc
              (per chain)    (per PN)       (per PN)
                 │                │              │
                 ├─ :onchain-selectors  (event replay vs current ABIs)
                 └─ :roles              (CTS + expected-roles vs on-chain grants)

  Drift detected → exit 1 → CI fails → deploy never promotes.
```

Each parent task chains its children via `hre.run()`. Children set `process.exitCode = 1` on findings without throwing, so a single audit run reports all findings together rather than halting on the first one. RPC unreachable or CTS down throws and halts immediately.

## Shared helpers ([`utils.ts`](./utils.ts))

| Helper                                                                | Purpose                                                                                                                                                                                            |
| --------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `loadAbi(rootDir, name)` / `findArtifactJson(dir, name)`              | Resolve a contract's ABI from `artifacts/` with the V1/V2/Replica alias chain.                                                                                                                     |
| `resolveRpcUrlByChain(opts)`                                          | `--rpc` → chain-keyed env var (`PNH_RPC_URL` / `PUBLIC_CHAIN_RPC_URL` / `PRIVACY_NODE_<X>_RPC_URL`) → error.                                                                                       |
| `resolveRegistryAddress(explicit, opts)`                              | `--registry` → chain-keyed env var (`PNH_DEPLOYMENT_PROXY_REGISTRY` / `PRIVACY_NODE_<X>_[PUBLIC_CHAIN_]DEPLOYMENT_PROXY_REGISTRY`) → error.                                                        |
| `resolveStartingBlock(explicit, opts)`                                | `--from-block <N>` → `*_STARTING_BLOCK` env var → `eth_getCode` binary-search auto-detect → 0 with loud warning. Any explicit value (including `0`) is taken verbatim.                             |
| `fetchLogsChunked(provider, filter, from, to, chunk)`                 | Chunked `eth_getLogs` for ranges that exceed provider limits.                                                                                                                                      |
| `fetchInBatches(items, fetcher, batchSize?)`                          | Bounded-concurrency wrapper around `Promise.all`. Default batch size of `DEFAULT_FETCH_BATCH_SIZE` (4) — used for fan-out RPC calls (e.g. per-role `getRoleMembers`) without thundering-herd risk. |
| `fetchCtsAddresses(pn, service)` / `CtsFetcher` / `defaultCtsFetcher` | CTS HTTP fetch with DI hook for testability.                                                                                                                                                       |

## Style recommendation for deploy authors

Prefer **static string literals** for `iface.getFunction()` arguments in `hardhat/tasks/deploy/*.ts` so `audit:deploy-selectors` can statically validate them against current ABIs. The lint's three resolution passes cover literal arguments, `.map([...literals], (fn) => iface.getFunction(fn))` patterns, and `const`-bound string literals; anything outside those (template strings, ternaries, dynamic property access) is marked `UNCHECKED`. See [`docs/access-manager-migration.md`](../../../docs/access-manager-migration.md#style-recommendation-for-deploy-authors) for examples.

## Expected-roles modules ([`expected-roles/`](./expected-roles/))

Per-chain specifications of static deploy-time role grants. The own-roles audit (run with `--include-own-roles`) compares each module against on-chain `getRoleMembers(roleId)`.

| Module                                                 | Mirrors                                                                                          |
| ------------------------------------------------------ | ------------------------------------------------------------------------------------------------ |
| [`expected-roles/pnh.ts`](./expected-roles/pnh.ts)     | `grantRole` calls in [`hardhat/tasks/deploy/private-hub.ts:278-372`](../deploy/private-hub.ts)   |
| [`expected-roles/pn.ts`](./expected-roles/pn.ts)       | `grantRole` calls in [`hardhat/tasks/deploy/privacy-node.ts:209-267`](../deploy/privacy-node.ts) |
| [`expected-roles/pc.ts`](./expected-roles/pc.ts)       | `grantRole` calls in [`hardhat/tasks/deploy/public-chain.ts:225-259`](../deploy/public-chain.ts) |
| [`expected-roles/types.ts`](./expected-roles/types.ts) | Shared `ExpectedRoleEntry` type                                                                  |

The modules are hand-authored. When deploy code changes a grant, the matching expected-roles entry must update too — the audit's job is to fail loudly when they diverge.

## npm scripts ([`package.json`](../../../package.json))

| Script                     | Equivalent                                               | Use case                              |
| -------------------------- | -------------------------------------------------------- | ------------------------------------- |
| `npm run audit:deploy`     | `hardhat audit:deploy-selectors`                         | Static lint only — dev fast-feedback  |
| `npm run audit:all`        | `hardhat audit:all`                                      | Full coverage across every chain (CI) |
| `npm run audit:pnh:strict` | `audit:deploy-selectors --strict-unchecked && audit:pnh` | Strict PNH check (CI variant)         |
| `npm run audit:pn:strict`  | `audit:deploy-selectors --strict-unchecked && audit:pn`  | Strict PN check (requires `--pn`)     |
| `npm run audit:pc:strict`  | `audit:deploy-selectors --strict-unchecked && audit:pc`  | Strict PC check (requires `--pn`)     |

## Tests

Pure-helper unit tests + helper integration tests live in
[`hardhat/test/unit/audit-helpers.ts`](../../test/unit/audit-helpers.ts) and
[`hardhat/test/unit/audit-integration.ts`](../../test/unit/audit-integration.ts).
Run with `npx hardhat test hardhat/test/unit/audit-helpers.ts hardhat/test/unit/audit-integration.ts`.

## File map

```
hardhat/tasks/audit/
├── README.md                        ← you are here
├── utils.ts                         ← shared helpers (RPC / registry / starting-block / CTS / log fetch)
├── check-deploy-selectors.ts        ← audit:deploy-selectors
├── check-onchain-selectors.ts       ← audit:{pnh,pn,pc}:onchain-selectors
├── check-roles.ts                   ← audit:{pnh,pn,pc}:roles (RELAYER + own-roles)
├── generate-migration.ts            ← audit:{pnh,pn,pc}:generate-migration
├── parents.ts                       ← audit:{pnh,pn,pc} parent tasks + audit:all
└── expected-roles/
    ├── types.ts                     ← ExpectedRoleEntry type
    ├── pnh.ts                       ← PNH static grants
    ├── pn.ts                        ← PN static grants
    └── pc.ts                        ← PC static grants
```

## See also

- [`docs/access-manager-migration.md`](../../../docs/access-manager-migration.md) — full task reference, env-var conventions, worked migration example, CI integration.
- [`audit/migrations/README.md`](../../../audit/migrations/README.md) — the migration output directory.
- [AccessManager Audit guide](https://docs.rayls.io/deploy/privacy-node/access-manager-audit/) — operator playbook.
