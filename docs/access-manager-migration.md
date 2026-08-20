# AccessManager audit & migration guide

`RaylsAccessManagerV1` governs access to every managed contract on each Rayls chain. The audit suite under `hardhat/tasks/audit/` checks that on-chain AccessManager state matches the deploy code's intent — selector mappings, role grants, and CTS-derived relayer authorizations — and produces a reviewable migration script when drift is found.

This document is the **task reference** for the audit suite under `hardhat/tasks/audit/` (pre-flight checks against existing chains, per-finding triage, CI/CD wiring, CTS-down recovery).

## AccessManager access invariant

> Every `restricted` function in any managed contract is **always callable by any account holding the `ADMIN` role** (`uint64 constant ADMIN = 0`). This bypass is **not granted via** `addFunctionAllowedRoles` **and cannot be revoked** through the role-mapping system. Source of truth: [`AccessManagerAuthLib.sol:36-46`](../src/privateHub/AccessControl/libraries/AccessManagerAuthLib.sol#L36-L46) — the ADMIN-bypass returns `allowed=true` _before_ the selector map is consulted (inline comment: `unmapped = ADMIN only`).
>
> Explicit `addFunctionAllowedRoles` mappings exist to **open** a function to additional non-admin roles, never to grant or revoke admin access. A `restricted` function with no explicit mapping is the correct default: callable by every ADMIN-role holder, by no one else.
>
> Caveats:
>
> - **Emergency pause** (`emergencyPaused`) blocks every call including ADMIN — checked at the top of `canCall` before the ADMIN bypass.
> - **Execution delay** — an ADMIN grant can carry a non-zero `executionDelay`, requiring `schedule()` + `execute()`. Still authorised, just time-gated.
>
> The audit's job is to detect drift — STALE selector mappings, missing or unexpected role grants — not to enumerate admin-callable functions, since by this invariant _every_ `restricted` function is admin-callable.

## Task hierarchy

```
audit:deploy-selectors             chain-agnostic static lint over hardhat/tasks/deploy/*.ts

audit:all                          CI entrypoint — runs everything below
                                   Reads PARTICIPANT_LIST env var for the PN set
                                   Opts into --include-own-roles automatically

audit:pnh                          parent: PNH suite
  audit:pnh:onchain-selectors      selector mappings on the PNH AccessManager
  audit:pnh:roles                  RELAYER (+ own-roles with --include-own-roles)
  audit:pnh:generate-migration     emits a reviewable STALE-removal script

audit:pn --pn A[,B,…]              parent: PN suite, iterated per PN
  audit:pn:onchain-selectors  --pn A
  audit:pn:roles              --pn A
  audit:pn:generate-migration --pn A

audit:pc --pn A[,B,…]              parent: PC suite, iterated per PN
  audit:pc:onchain-selectors  --pn A
  audit:pc:roles              --pn A
  audit:pc:generate-migration --pn A
```

Parent tasks chain their children via `hre.run()`. Children that find drift set `process.exitCode = 1` but don't throw; the parent keeps running so the operator sees all findings at once. `generate-migration` is never auto-run by parents — emitting a migration is a deliberate remediation step.

## Quick workflows

```sh
# Local dev fast check — relayer-only, per chain
npx hardhat audit:pnh
npx hardhat audit:pn  --pn A
npx hardhat audit:pc  --pn A

# Full check (own-roles + relayer audits)
npx hardhat audit:pnh --include-own-roles
npx hardhat audit:pn  --pn A,B,C --include-own-roles
npx hardhat audit:pc  --pn A,B,C --include-own-roles

# Own-roles only (no CTS calls)
npx hardhat audit:pnh:roles --include-own-roles --skip-relayers

# CI entrypoint — strict static lint + every chain
npx hardhat audit:all                  # PARTICIPANT_LIST from .env
npx hardhat audit:all --pn A,B,C       # explicit PN list
npm run audit:all                      # npm script wrapper

# Targeted child audit
npx hardhat audit:pn:onchain-selectors --pn A
npx hardhat audit:pn:roles             --pn A

# Manual remediation — writes audit/migrations/<timestamp>-...ts
npx hardhat audit:pnh:generate-migration
npx hardhat audit:pn:generate-migration --pn A
# Review the file, then apply:
npx hardhat run audit/migrations/<timestamp>-...ts --network <name>
```

No `--chain` or `--network` flag exists on any audit task — chain identity is in the task name (`:pnh` / `:pn` / `:pc`), and RPC URLs come from chain-keyed env vars.

## Environment variables

All audit tasks read RPC URLs and registry addresses from `.env`. The deploy script writes these automatically; external operators populate them by hand. Both can be overridden by `--rpc <url>` and `--registry <addr>` flags on any task.

| Variable                                                  | Purpose                                                             | Read by                                                                             |
| --------------------------------------------------------- | ------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| `PNH_RPC_URL`                                             | PNH JSON-RPC URL                                                    | `audit:pnh:*`                                                                       |
| `PUBLIC_CHAIN_RPC_URL`                                    | Public chain JSON-RPC URL                                           | `audit:pc:*`                                                                        |
| `PRIVACY_NODE_<X>_RPC_URL`                                | PN X's own-chain JSON-RPC URL                                       | `audit:pn:*`                                                                        |
| `PNH_DEPLOYMENT_PROXY_REGISTRY`                           | PNH DeploymentProxyRegistry address                                 | `audit:pnh:*`                                                                       |
| `PRIVACY_NODE_<X>_DEPLOYMENT_PROXY_REGISTRY`              | PN X's own-chain DeploymentProxyRegistry address                    | `audit:pn:*`                                                                        |
| `PRIVACY_NODE_<X>_PUBLIC_CHAIN_DEPLOYMENT_PROXY_REGISTRY` | PN X's public-chain DeploymentProxyRegistry address                 | `audit:pc:*`                                                                        |
| `PNH_STARTING_BLOCK`                                      | First block the PNH event scan should start from                    | `audit:pnh:*` (skip `eth_getCode` binary search)                                    |
| `PRIVACY_NODE_<X>_STARTING_BLOCK`                         | First block PN X's event scan should start from                     | `audit:pn:*`                                                                        |
| `PRIVACY_NODE_<X>_PUBLIC_CHAIN_STARTING_BLOCK`            | First block PN X's PC event scan should start from                  | `audit:pc:*`                                                                        |
| `CTS_SERVICE_<X>_URL`                                     | CTS endpoint for PN X (used by relayer-roles audit)                 | `audit:pnh:roles`, `audit:pn:roles`, `audit:pc:roles` (skip with `--skip-relayers`) |
| `PARTICIPANT_LIST`                                        | Comma-separated PN ids the deployment supports (e.g. `A,B,C,D,E,F`) | `audit:all`, `audit:pnh:roles` default for `--privacy-nodes`                        |

## Per-task reference

### `audit:deploy-selectors` — static lint

Walks every `iface.getFunction(...)` call in `hardhat/tasks/deploy/*.ts` (auto-discovered) and classifies each:

| Status        | Meaning                                                                                                     | Default exit                       |
| ------------- | ----------------------------------------------------------------------------------------------------------- | ---------------------------------- |
| **OK**        | First argument resolves to a string literal and the literal exists in the matching factory's current ABI    | —                                  |
| **MISSING**   | First argument resolves to a string literal but the literal does NOT exist in the current ABI               | 1                                  |
| **UNCHECKED** | First argument cannot be resolved to a string literal by the lint's three resolution passes (informational) | 0 (use `--strict-unchecked` for 1) |

Three resolution passes per call site (in order, with TDZ-aware position checks):

1. **Direct string literal**: `iface.getFunction('foo')` → resolves to `'foo'`.
2. **`.map(literal-array, arrow)`**: `['a','b'].map(s => iface.getFunction(s))` → expands per element with source-line attribution.
3. **`const`-binding**: `const fn = 'foo'; iface.getFunction(fn)` → walks scope chains, respects declaration-before-use within a block.

Failures cannot be auto-fixed — they indicate a deploy script bug. Fix the source string or restore the missing function before re-running the deploy.

##### Style recommendation for deploy authors

Prefer **static string literals** for the first argument to `iface.getFunction()` in `hardhat/tasks/deploy/*.ts`. The lint then resolves the call and validates the literal against the matching factory's current ABI — drift is caught at lint time, before any deploy fires.

```ts
// PREFERRED — lint reduces to a literal, validates against the ABI.
iface.getFunction('transfer');

// PREFERRED — .map(literal-array, arrow) is also resolved by the lint.
['addBatchHeaders', 'tryAddHeader'].map((fn) => iface.getFunction(fn));

// PREFERRED — const-bound string literal is also resolved.
const FN = 'receivePayload';
iface.getFunction(FN);

// AVOID — template strings, ternaries, dynamic property access can't
// be statically resolved. The lint marks them UNCHECKED (informational
// by default; fatal under --strict-unchecked).
iface.getFunction(`${prefix}Transfer`);
iface.getFunction(useV2 ? 'transferV2' : 'transfer');
iface.getFunction(config.methodName);
```

When a dynamic argument is genuinely necessary, leave an inline `// audit:unchecked` comment explaining why and use `--strict-unchecked` in CI so any _new_ UNCHECKED finding forces a documented decision.

**Example output** (clean run against the local dev environment):

```text
$ npx hardhat audit:deploy-selectors
Deploy-selector lint: 102 references checked (102 OK, 0 MISSING, 0 UNCHECKED).

  ✅ LINT PASSED — all 102 getFunction(...) references resolve against the current ABIs.
```

### `audit:<chain>:onchain-selectors` — selector-mapping audit

Replays `FunctionAllowedRoleAdded` / `FunctionAllowedRoleRemoved` events from the chain's AccessManager. For each surviving `(target, selector, role)` tuple:

| Status    | Meaning                                                                           | Default exit |
| --------- | --------------------------------------------------------------------------------- | ------------ |
| **OK**    | Selector decodes against the target's current ABI                                 | —            |
| **STALE** | Selector doesn't decode — the function was renamed or its parameter shape changed | 1            |

Also surfaces registry-hygiene findings (informational):

- **UNREGISTERED**: an on-chain address has role mappings but isn't in `DeploymentProxyRegistry.getAllContracts()`.
- **NAME DIVERGENCE**: registry name (`Endpoint`) doesn't match the artifact name (`EndpointV1`).

#### Flags

| Flag                | Purpose                                                                                                                                                                                                                                   |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--pn <X>`          | Required for `:pn` and `:pc` variants; PN identifier.                                                                                                                                                                                     |
| `--rpc <url>`       | Manual RPC URL override.                                                                                                                                                                                                                  |
| `--registry <addr>` | Manual DeploymentProxyRegistry override.                                                                                                                                                                                                  |
| `--from-block <N>`  | Start block for event scan. When omitted, walks a fallback ladder: chain-keyed `*_STARTING_BLOCK` env var → `eth_getCode` binary-search auto-detect → 0 with a loud warning. Passing any value (including `0`) short-circuits the ladder. |
| `--contracts X,Y`   | Restrict the audit to the listed registry names; useful for targeted checks against a subsystem.                                                                                                                                          |

**Example output** (PNH clean):

```text
$ npx hardhat audit:pnh:onchain-selectors

On-chain selector audit:
  AccessManager:        0xF99E319deB5bc8b108E5b87fA2cf1EEB5cbFA4D5
  Block range scanned:  24 → 27392  (source: auto-detect, block 24)
  Managed contracts:    29
  Live mappings:        84
  OK / STALE:           84 / 0
  Registry hygiene:     1 unregistered address, 6 name divergences (informational)

  REGISTRY HYGIENE — informational, not drift:
    NAME DIVERGES 0xe602…  registry='FungibleAssetGroup'    artifact='AssetGroup'
    NAME DIVERGES 0xd0b6…  registry='Endpoint'              artifact='EndpointV1'
    UNREGISTERED  0x0810…  (identified as RaylsMessageExecutorV1)  has on-chain role mappings but no entry in DeploymentProxyRegistry
    ...

  ✅ AUDIT PASSED — no selector drift; on-chain state matches current ABIs.
```

`PC` side is the smallest:

```text
$ npx hardhat audit:pc:onchain-selectors --pn A

On-chain selector audit:
  Managed contracts:    4
  Live mappings:        3
  OK / STALE:           3 / 0
  ✅ AUDIT PASSED — no selector drift; on-chain state matches current ABIs.
```

### `audit:<chain>:roles` — role-grant audit

Two composable audit modes on the same task:

#### Mode 1: RELAYER audit (default)

For each PN listed (singular `--pn` for `:pn` / `:pc`; CSV `--privacy-nodes` for `:pnh`, defaulting to `PARTICIPANT_LIST`), fetch CTS-advertised relayer addresses, replay `RoleGranted` / `RoleRevoked` events on chain, and diff:

| Status         | Meaning                                                                                                                             | Default exit |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------- | ------------ |
| **OK**         | CTS-expected wallet holds RELAYER on chain                                                                                          | —            |
| **MISSING**    | CTS lists the wallet but the on-chain grant is absent (partial authorization, manual revoke)                                        | 1            |
| **UNEXPECTED** | An address holds RELAYER on chain but isn't current in CTS (rotated key whose old grant lingers because no one called `revokeRole`) | 1            |

CTS list selection (internal mapping):

- `:pn` → `private_relayer.private_chain_addresses` ∪ `public_relayer.private_chain_addresses`
- `:pc` → `public_relayer.public_chain_addresses`
- `:pnh` → `private_relayer.private_hub_addresses` ∪ `private_relayer.private_hub_dvp_operator_addresses`

Skip with `--skip-relayers`.

#### Mode 2: own-roles audit (`--include-own-roles`)

For each role in [`hardhat/tasks/audit/expected-roles/<chain>.ts`](../hardhat/tasks/audit/expected-roles/) — the hand-authored mirror of the chain's deploy-time `grantRole` calls — resolve each `expectedGrantees` registry name to an address via `DeploymentProxyRegistry.getContract()` and diff against `getRoleMembers(roleId)`. Classifications: OK / MISSING / UNEXPECTED.

Roles registered on chain but absent from the expected-roles module are surfaced as **INFO** (no classification) — used for RELAYER (audited separately in mode 1), ADMIN (operator-specific deployer wallet), and business roles granted later via the `grant-business-role` task family.

Entries can set `allowUnexpected: true` to opt out of UNEXPECTED classification for roles dynamically extended at runtime (ENDPOINT_SENDER gets new grantees as tokens deploy; AUTHORIZED_SENDER is granted at runtime by token deploys).

##### Maintaining the expected-roles modules

The expected-roles modules are **hand-authored mirrors** of the deploy code's `grantRole` calls. They live in [`hardhat/tasks/audit/expected-roles/`](../hardhat/tasks/audit/expected-roles/) and are referenced by registry name, not by address. Adding or removing a `grantRole` in a deploy task without updating the matching expected-roles entry causes the next own-roles audit to fail — that's the intended drift-detection mechanism, but it requires authoring discipline.

**Update protocol** when changing a deploy task:

1. The deploy-task PR also updates the matching `expected-roles/<chain>.ts` entry. Examples:
   - Added a new `grantRole(roleId, addresses.foo, 0)` → add `{ roleName: 'X', expectedGrantees: ['Foo'] }` or extend the existing role's `expectedGrantees` array.
   - Removed a `grantRole` → remove the corresponding entry.
   - The grantee's registry name changes (e.g., `TokenRegistry` → `TokenRegistryV2`) → update the `expectedGrantees` string.
2. Run `npx hardhat audit:all` against a fresh local deploy (`docker/dev/up.sh && deploy_contracts.sh`) before requesting review. A clean audit confirms the deploy code and the expected-roles module are in sync.
3. If the role is granted dynamically at runtime (factories granting downstream roles, etc.), set `allowUnexpected: true` on the entry instead of trying to enumerate every possible grantee.

Drift between deploy code and the expected-roles module **will** be caught by `audit:all` in CI — the failure is loud, with the exact (roleName, expected grantee) tuple in the MISSING / UNEXPECTED report. But catching drift in CI is later than catching it in the same PR; the update protocol above keeps the modules accurate.

**Future improvement (not implemented).** A static AST analysis pass over `hardhat/tasks/deploy/*.ts` could auto-extract `grantRole` calls into the expected-roles modules, eliminating the manual sync step. The pattern is analogous to [`check-deploy-selectors.ts`](../hardhat/tasks/audit/check-deploy-selectors.ts) (which already walks the deploy code for `iface.getFunction(...)` arguments). Tracking as a follow-up since it touches:

- Resolving variable bindings: `await manager.getRoleIdByName('ENYGMA_CREATOR')` → role `ENYGMA_CREATOR`.
- Resolving registry names: `addresses.enygmaTokenManagerAddress` → registry entry `EnygmaTokenManager`. This needs a `registerAllContracts()` mapping pass, which the existing static lint already performs in part.
- Expanding spread patterns: `...contractsToGrant.map((addr, i) => ({ method: 'grantRole', args: [..., addr, 0] }))` — same shape `check-deploy-selectors` resolves for `.map(literal-array, arrow)`.

Until then, the modules stay hand-authored.

#### Combining the modes

| Invocation                                                | Behavior                                                 |
| --------------------------------------------------------- | -------------------------------------------------------- |
| `audit:<chain>:roles`                                     | RELAYER audit only                                       |
| `audit:<chain>:roles --include-own-roles`                 | Own-roles audit + RELAYER audit                          |
| `audit:<chain>:roles --skip-relayers`                     | Errors out — no audit would run                          |
| `audit:<chain>:roles --include-own-roles --skip-relayers` | Own-roles only, zero CTS calls                           |
| `audit:all`                                               | Always sets `--include-own-roles` (full coverage for CI) |

The `--skip-relayers` guard exits 1 with:

```text
Error: audit:pn:roles: --skip-relayers with --include-own-roles omitted leaves nothing to audit.
Add --include-own-roles to run the own-roles audit only, or drop --skip-relayers to run the RELAYER audit.
```

This catches the common mistake of skipping CTS without enabling any other audit mode — a silent pass would otherwise look like a clean audit when nothing was actually checked.

**Example output — RELAYER mode, clean** (`audit:pn:roles --pn A`):

```text
Relayer-role audit (RELAYER):
  Scope:                PN (own chain)
  Privacy node:         A
  AccessManager:        0xF99E319deB5bc8b108E5b87fA2cf1EEB5cbFA4D5
  Block range scanned:  92 → 29229  (source: auto-detect, block 92)
  Role ID:              5
  Expected (CTS):       10
  On-chain holders:     10
  OK / MISSING / UNEXPECTED: 10 / 0 / 0

  ✅ AUDIT PASSED — every CTS-expected wallet holds RELAYER and no extras.
```

**Example output — own-roles mode** (`audit:pnh:roles --include-own-roles --skip-relayers`):

```text
Own-roles audit:
  Scope:                Private Network Hub (shared)
  AccessManager:        0xF99E319deB5bc8b108E5b87fA2cf1EEB5cbFA4D5
  Expected role count:  8
  On-chain role count:  19
  OK / MISSING / UNEXPECTED: 15 / 0 / 0

  INFO — 11 roles not covered by expected-roles module:
    [#0] 1 holder                  ← ADMIN, deployer signer
    [PUBLIC#1] 0 holders
    [TOKEN_OWNER#2] 0 holders
    [ENYGMA_V1#8] 0 holders        ← dynamically granted by FACTORY_ADMIN
    [COIN_VAULT#9] 0 holders       ← dynamically granted by FACTORY_ADMIN
    [RELAYER#11] 36 holders        ← audited via the CTS path with --privacy-nodes
    [MESSAGE_EXECUTOR#12] 1 holder ← unregistered grantee; awaiting registry hygiene fix
    [Private Network Operator#15] 0 holders
    ...

  ✅ OWN-ROLES AUDIT PASSED — every expected grant is on chain.
```

**Example output — what drift looks like.** Passing only a partial PN list to `audit:pnh:roles` makes the other PNs' relayers look UNEXPECTED:

```text
$ npx hardhat audit:pnh:roles --privacy-nodes A,B

Relayer-role audit (RELAYER):
  Privacy nodes:        A,B
  Expected (CTS):       12
  On-chain holders:     36
  OK / MISSING / UNEXPECTED: 12 / 0 / 24

  UNEXPECTED — on-chain holder not advertised by CTS (likely rotated key or stray grant):
    0xab95…
    0xae6d…
    ...

  ❌ AUDIT FAILED — 24 UNEXPECTED holders.
```

Fix: pass the full `PARTICIPANT_LIST` (or set it in `.env`). On the live local environment, `--privacy-nodes A,B,C,D,E,F` produces `36 OK / 0 MISSING / 0 UNEXPECTED`.

`--report-only` suppresses the exit code but keeps the findings:

```text
  ℹ️  REPORT-ONLY — 24 UNEXPECTED holders (would have failed without --report-only).
```

### `audit:<chain>:generate-migration` — STALE-removal script emitter

Runs `audit:deploy-selectors` (static lint must pass) then `audit:<chain>:onchain-selectors`. When STALE entries are found, writes a reviewable script to `audit/migrations/<timestamp>-access-manager-drift.ts` with one `removeFunctionAllowedRoles` call per STALE entry. The file is **not auto-executed** — operator must review then `npx hardhat run <file> --network <name>` to apply.

The task is dry-run by design. It only writes a file; it never sends a transaction.

Add-side changes (granting new `(selector, role)` pairs) are intentionally NOT emitted. Granting a role is a design decision tied to the deploy code; the audit cannot synthesize one from ABI shape alone. To grant a new mapping: update the corresponding deploy task and redeploy.

**Example output — clean state**: no migration file is emitted when there's no STALE drift to fix.

```text
$ npx hardhat audit:pnh:generate-migration

[1/2] Static deploy-selector lint…
Deploy-selector lint: 102 references checked (102 OK, 0 MISSING, 0 UNCHECKED).

[2/2] On-chain audit…
On-chain selector audit:
  AccessManager:        0xF99E319deB5bc8b108E5b87fA2cf1EEB5cbFA4D5
  OK / STALE:           84 / 0
  ✅ AUDIT PASSED — no selector drift; on-chain state matches current ABIs.

✅ Nothing to migrate — on-chain state matches current ABIs. No migration file emitted.
```

When STALE entries are found, the task writes `audit/migrations/<timestamp>-access-manager-drift.ts` and prints:

```text
📄 Wrote migration: audit/migrations/2026-05-19T04-12-00-access-manager-drift.ts
   STALE removals:   3 (active)

  ⚠️  Migration GENERATED but NOT applied. Review the file, then run:
     npx hardhat run audit/migrations/2026-05-19T04-12-00-access-manager-drift.ts --network <name>
```

## Parent tasks and `audit:all`

Parent tasks orchestrate per-chain children via `hre.run()` and print a 2-line verdict per phase.

**Example: `audit:pnh`** (selector audit + RELAYER audit):

```text
══════ audit:pnh ══════════════════════════════════════════════════
[1/2] audit:pnh:onchain-selectors
  ✅ AUDIT PASSED — no selector drift; on-chain state matches current ABIs.

[2/2] audit:pnh:roles
  ✅ AUDIT PASSED — every CTS-expected wallet holds RELAYER and no extras.

══════ audit:pnh ✅ PASSED ══════
```

**Example: `audit:pn --pn A,B,C`** (iterates per PN):

```text
══════ audit:pn --pn A ═════════════════════════════════════
[1/2] audit:pn:onchain-selectors --pn A
[2/2] audit:pn:roles --pn A

══════ audit:pn --pn B ═════════════════════════════════════
[1/2] audit:pn:onchain-selectors --pn B
[2/2] audit:pn:roles --pn B

══════ audit:pn --pn C ═════════════════════════════════════
[1/2] audit:pn:onchain-selectors --pn C
[2/2] audit:pn:roles --pn C

══════ audit:pn (3 PNs) ✅ PASSED ══════
```

**Example: `audit:all`** (full CI entrypoint, all 4 phases, all PNs):

```text
══════ audit:all (PNs: A,B,C,D,E,F) ════════════════════════
[1/4] audit:deploy-selectors --strict-unchecked
  ✅ LINT PASSED — all 102 getFunction(...) references resolve against the current ABIs.

[2/4] audit:pnh (includes own-roles)
  ✅ AUDIT PASSED — no selector drift; on-chain state matches current ABIs.
  ✅ OWN-ROLES AUDIT PASSED — every expected grant is on chain.
  ✅ AUDIT PASSED — every CTS-expected wallet holds RELAYER and no extras.
  ══════ audit:pnh ✅ PASSED ══════

[3/4] audit:pn --pn A,B,C,D,E,F (includes own-roles)
  ... (six per-PN passes) ...
  ══════ audit:pn (6 PNs) ✅ PASSED ══════

[4/4] audit:pc --pn A,B,C,D,E,F (includes own-roles)
  ... (six per-PN passes) ...
  ══════ audit:pc (6 PNs) ✅ PASSED ══════

══════ audit:all ✅ PASSED ══════
```

Parents do NOT halt on the first failed child — every child runs and `process.exitCode` aggregates the worst result. RPC-unreachable or CTS-down errors throw and halt immediately.

## Worked example — adding a struct field to `Proofs.tryAddHeader`

The `Header` struct in `src/privateHub/Proofs/Proofs.sol` grows from 15 fields to 21. Selectors of `addBatchHeaders` and `tryAddHeader` rotate.

1. **Static lint catches the old strings**:

   ```sh
   npx hardhat audit:deploy-selectors
   # MISSING — deploy code references the old selector that no longer exists.
   ```

   Fix: update `private-hub.ts` to use the new signatures.

2. **Redeploy** to a fresh chain. The new role mappings register against the new selectors.

3. **Run the on-chain audit on an EXISTING chain** (one where the old `addBatchHeaders` mapping was previously registered):

   ```sh
   npx hardhat audit:pnh:onchain-selectors
   # STALE — old (target, selector, role) tuple no longer decodes
   ```

4. **Generate the migration**:

   ```sh
   npx hardhat audit:pnh:generate-migration
   ```

5. **Review** `audit/migrations/<timestamp>-access-manager-drift.ts`. Each line is a `removeFunctionAllowedRoles(...)` call. Confirm the targets and selectors match the renamed functions you expect to remove.

6. **Apply**:

   ```sh
   npx hardhat run audit/migrations/<timestamp>-access-manager-drift.ts --network localPNH
   ```

7. **Re-audit** to confirm clean:
   ```sh
   npx hardhat audit:pnh
   ```

## CI integration

`audit:all` is the recommended CI entrypoint. It runs:

1. `audit:deploy-selectors --strict-unchecked` (UNCHECKED becomes fatal)
2. `audit:pnh` with `--include-own-roles` (selector + own-roles + RELAYER)
3. `audit:pn --pn <every PN in PARTICIPANT_LIST>` with `--include-own-roles`
4. `audit:pc --pn <every PN>` with `--include-own-roles`

Each child sets `process.exitCode` on findings without throwing, so all four phases run and a single failed phase causes the CI step to exit 1. RPC unreachable / CTS down throws and halts immediately — that's the right behavior; investigate infra before re-running.

For lighter checks (skipping the relayer audit and its CTS dependency):

```sh
npx hardhat audit:deploy-selectors --strict-unchecked
npx hardhat audit:pnh:onchain-selectors
npx hardhat audit:pnh:roles --include-own-roles --skip-relayers
# ...similar for pn / pc
```

## External operators (Rayls users without docker/dev/deploy_contracts.sh)

The audit task suite needs only this repo + a populated `.env`. To audit your own deployment:

1. Clone the contracts repo and run `npx hardhat compile` (so `artifacts/` exists).
2. Populate `.env` with the env-vars listed above for the chain(s) you're auditing — RPC URL + DeploymentProxyRegistry address per chain. RELAYER audits additionally need `CTS_SERVICE_<X>_URL`.
3. Run any task: `npx hardhat audit:pnh`, `npx hardhat audit:pn --pn A`, etc.

You can also pass `--rpc <url>` and `--registry <addr>` directly to bypass env-var lookup entirely (one-off audits against arbitrary chains).
