// Migration generator — runs the static lint and the on-chain audit, then
// emits a single reviewable hardhat script with one
// `removeFunctionAllowedRoles` call per STALE entry the on-chain audit
// reported, bringing AccessManager state into sync with the current source.
//
// ──────────────────────────────────────────────────────────────────────
// This task is ALREADY a dry-run by design. It sends NO transactions.
// ──────────────────────────────────────────────────────────────────────
// Side-effects, exhaustive:
//   1. `fs.mkdirSync(audit/migrations/, { recursive: true })` — disk
//   2. `fs.writeFileSync(audit/migrations/<timestamp>-...ts, ...)` — disk
//   3. `eth_getLogs` / `eth_call` via `audit:<chain>:onchain-selectors` for
//      the audit's event replay — read-only RPC, no signed transactions.
//
// The `manager.removeFunctionAllowedRoles(...).wait();` strings in the
// generated file's source are TEXT being pushed into `lines[]` (look for
// `lines.push(...)` below); they are NOT calls this task executes. The
// actual transaction-sending step is a SEPARATE manual command run by
// the operator AFTER reviewing the generated file:
//     npx hardhat run audit/migrations/<timestamp>-...ts --network <name>
//
// So: no `--dry-run` flag exists, because the entire task is the dry-
// run. Adding such a flag would be actively misleading — it would imply
// a non-dry-run mode that doesn't exist (and shouldn't; the auto-execute
// path is deliberately not built, so the operator's diff-read is the
// gate against silent role changes).
//
// Scope (what this generator does NOT emit, and why)
// --------------------------------------------------
// Adds (`addFunctionAllowedRoles`) are valid AccessManager operations — the
// deploy tasks in `hardhat/tasks/deploy/*.ts` use them extensively. They
// just aren't auto-emitted *here*, because the audit's chain-vs-ABI diff
// can only ever detect *removals* automatically:
//
//   - The deploy script is the source of truth for which non-admin roles
//     should have access to which selectors. The audit can detect that an
//     on-chain mapping is dead (STALE) — but it can't synthesise a new
//     `(selector, roleId)` pair, because choosing a role for a function is
//     a design decision, not something derivable from ABI shape.
//   - Granting `ADMIN` to a function would be redundant. `ADMIN` (uint64 0)
//     is checked by `AccessManagerAuthLib.canCall` BEFORE the selector
//     map is consulted (see `AccessManagerAuthLib.sol:36-46`), so any
//     account with the `ADMIN` role can call every `restricted` function
//     regardless of `addFunctionAllowedRoles` entries. A migration that
//     "added ADMIN to function X" would change nothing on chain.
//   - Granting a non-admin role to a new function: do it by editing the
//     corresponding deploy task and re-running the deploy. The audit will
//     then see the new mapping as `OK` on its next run.
//
// See docs/access-manager-migration.md for the AccessManager access
// invariant and the operator workflow.
//
//   CLI: `npx hardhat audit:pnh:generate-migration`
//        `npx hardhat audit:pn:generate-migration --pn A`
//        `npx hardhat audit:pc:generate-migration --pn A`
//        (or pass --rpc + --registry explicitly to bypass env-var lookup)
//
// Output: `audit/migrations/<ISO-timestamp>-access-manager-drift.ts`
//   never executed automatically — the operator must inspect and run it via
//   `npx hardhat run <file> --network <name>`.
//
// Exit codes:
//   0 — wrote a migration (or had nothing to write, idempotent rerun)
//   1 — the static deploy-selector lint failed; deploy code references
//       functions that don't exist on the current ABI. Fix the source / the
//       deploy task strings before running the migration. No migration file
//       is emitted in this case, because the deploy code itself would
//       produce wrong selectors if re-run.

import { task } from 'hardhat/config';
import type { HardhatRuntimeEnvironment } from 'hardhat/types';
import * as fs from 'fs';
import * as path from 'path';
import type { DeployFinding } from './check-deploy-selectors';
import type { OnchainAuditResult } from './check-onchain-selectors';

const OUTPUT_DIR_REL = 'audit/migrations';

/**
 * Run the static lint + on-chain audit, write a migration file if STALE
 * mappings were found. All three sibling tasks (PNH, PN, PC) funnel through
 * here; the only delta per chain is which `audit:<chain>:onchain-selectors`
 * sub-task gets invoked.
 */
async function runGenerateMigration(opts: {
  taskName: string;
  hre: HardhatRuntimeEnvironment;
  onchainTaskName:
    | 'audit:pnh:onchain-selectors'
    | 'audit:pn:onchain-selectors'
    | 'audit:pc:onchain-selectors';
  pn?: string;
  rpc: string;
  registry: string;
  fromBlock: string;
  contracts: string;
}): Promise<string | null> {
  const root = opts.hre.config.paths.root;
  const outDir = path.join(root, OUTPUT_DIR_REL);
  fs.mkdirSync(outDir, { recursive: true });

  console.log('\n[1/2] Static deploy-selector lint…\n');
  const deployFindings = (await opts.hre.run('audit:deploy-selectors')) as DeployFinding[];
  const deployMissing = deployFindings.filter((f) => f.status === 'MISSING');
  if (deployMissing.length > 0) {
    console.error(
      '\n❌ Static lint reported broken getFunction(...) references. Fix the deploy code\n' +
        '   before generating a migration — re-running the deploy with broken strings\n' +
        '   would just recreate the same drift. No migration file was written.\n'
    );
    process.exitCode = 1;
    return null;
  }

  console.log('\n[2/2] On-chain audit…\n');
  const subtaskArgs: Record<string, string> = {
    rpc: opts.rpc,
    registry: opts.registry,
    fromBlock: opts.fromBlock,
    contracts: opts.contracts
  };
  if (opts.pn) subtaskArgs.pn = opts.pn;
  const onchainResult = (await opts.hre.run(
    opts.onchainTaskName,
    subtaskArgs
  )) as OnchainAuditResult;
  const {
    findings: onchainFindings,
    managerAddress: managerAddr,
    registryAddress: effectiveRegistry
  } = onchainResult;

  const stale = onchainFindings.filter((f) => f.status === 'STALE');

  if (stale.length === 0) {
    console.log(
      '\n✅ Nothing to migrate — on-chain state matches current ABIs. No migration file emitted.\n'
    );
    process.exitCode = 0;
    return null;
  }

  const now = new Date();
  const stamp = now.toISOString().replace(/[:.]/g, '-');
  const outPath = path.join(outDir, `${stamp}-access-manager-drift.ts`);

  const lines: string[] = [];
  lines.push(`// AUTO-GENERATED by \`npx hardhat ${opts.taskName}\``);
  lines.push(`// Generated at: ${now.toISOString()}`);
  lines.push(`// Registry:     ${effectiveRegistry}`);
  lines.push(`// AccessManager: ${managerAddr}`);
  lines.push(`// Findings: ${stale.length} STALE removal${stale.length !== 1 ? 's' : ''}`);
  lines.push('//');
  lines.push('// REVIEW THIS FILE BEFORE RUNNING. To apply:');
  lines.push(`//   npx hardhat run ${OUTPUT_DIR_REL}/${path.basename(outPath)} --network <name>`);
  lines.push('//');
  lines.push('// The `--network` you pass must point at the same chain the audit ran against;');
  lines.push('// hardhat networks config is the source of truth for keys/signer at run time.');
  lines.push('');
  lines.push(`import { ethers } from 'hardhat';`);
  lines.push('');
  lines.push('async function main() {');
  lines.push(
    `  const manager = await ethers.getContractAt('RaylsAccessManagerV1', '${managerAddr}');`
  );
  lines.push('');

  lines.push('  // ─── STALE removals ─────────────────────────────────────────────');
  lines.push('  // On-chain mappings whose selector no longer matches any current');
  lines.push('  // function on the target contract — call `removeFunctionAllowedRoles`');
  lines.push('  // to clear them.');
  for (const f of stale) {
    const roleTag = f.roleName ? `${f.roleName}(#${f.roleId})` : `#${f.roleId}`;
    lines.push(`  // ${f.target} @ ${f.targetAddress}  selector=${f.selector}  role=${roleTag}`);
    lines.push(
      `  await (await manager.removeFunctionAllowedRoles(` +
        `'${f.targetAddress}', ['${f.selector}'], [${f.roleId}n])).wait();`
    );
  }
  lines.push('');

  lines.push('  console.log("AccessManager migration applied.");');
  lines.push('}');
  lines.push('');
  lines.push('main().catch((e) => { console.error(e); process.exit(1); });');
  lines.push('');

  fs.writeFileSync(outPath, lines.join('\n'));

  console.log(`\n📄 Wrote migration: ${path.relative(root, outPath)}`);
  console.log(`     STALE removals:   ${stale.length} (active)`);
  console.log(`\n  ⚠️  Migration GENERATED but NOT applied. Review the file, then run:`);
  console.log(`     npx hardhat run ${path.relative(root, outPath)} --network <name>\n`);

  // The migration was generated successfully — don't propagate the STALE
  // exit code the on-chain audit set, because the operator is about to fix
  // it. They'll re-run the audit afterwards to confirm.
  process.exitCode = 0;
  return outPath;
}

// ─── Sibling tasks: one per chain side ─────────────────────────────────────

const RPC_DESC = 'JSON-RPC URL override (default: chain-keyed *_RPC_URL env var)';
const REGISTRY_DESC = 'DeploymentProxyRegistry address (default: chain-keyed env var)';
const FROM_BLOCK_DESC =
  'Start block for event scan (default: chain-keyed *_STARTING_BLOCK env var, then auto-detect, then 0). Pass any value (including "0") to override.';
const CONTRACTS_DESC = 'Comma-separated registry names to restrict the audit to (default: all)';

task(
  'audit:pnh:generate-migration',
  'Run both audits for the PNH and emit a reviewable migration script'
)
  .addOptionalParam('rpc', RPC_DESC, '')
  .addOptionalParam('registry', REGISTRY_DESC, '')
  .addOptionalParam('fromBlock', FROM_BLOCK_DESC, '')
  .addOptionalParam('contracts', CONTRACTS_DESC, '')
  .setAction(
    async (
      args: { rpc: string; registry: string; fromBlock: string; contracts: string },
      hre
    ): Promise<string | null> => {
      return runGenerateMigration({
        taskName: 'audit:pnh:generate-migration',
        hre,
        onchainTaskName: 'audit:pnh:onchain-selectors',
        rpc: args.rpc,
        registry: args.registry,
        fromBlock: args.fromBlock,
        contracts: args.contracts
      });
    }
  );

task(
  'audit:pn:generate-migration',
  "Run both audits for a Privacy Node's own chain and emit a reviewable migration script"
)
  .addParam('pn', 'Privacy node identifier (e.g. A)')
  .addOptionalParam('rpc', RPC_DESC, '')
  .addOptionalParam('registry', REGISTRY_DESC, '')
  .addOptionalParam('fromBlock', FROM_BLOCK_DESC, '')
  .addOptionalParam('contracts', CONTRACTS_DESC, '')
  .setAction(
    async (
      args: { pn: string; rpc: string; registry: string; fromBlock: string; contracts: string },
      hre
    ): Promise<string | null> => {
      if (!args.pn) throw new Error('audit:pn:generate-migration: --pn is required');
      return runGenerateMigration({
        taskName: 'audit:pn:generate-migration',
        hre,
        onchainTaskName: 'audit:pn:onchain-selectors',
        pn: args.pn,
        rpc: args.rpc,
        registry: args.registry,
        fromBlock: args.fromBlock,
        contracts: args.contracts
      });
    }
  );

task(
  'audit:pc:generate-migration',
  "Run both audits for a Privacy Node's public-chain AccessManager and emit a reviewable migration script"
)
  .addParam('pn', 'Privacy node identifier (e.g. A)')
  .addOptionalParam('rpc', RPC_DESC, '')
  .addOptionalParam('registry', REGISTRY_DESC, '')
  .addOptionalParam('fromBlock', FROM_BLOCK_DESC, '')
  .addOptionalParam('contracts', CONTRACTS_DESC, '')
  .setAction(
    async (
      args: { pn: string; rpc: string; registry: string; fromBlock: string; contracts: string },
      hre
    ): Promise<string | null> => {
      if (!args.pn) throw new Error('audit:pc:generate-migration: --pn is required');
      return runGenerateMigration({
        taskName: 'audit:pc:generate-migration',
        hre,
        onchainTaskName: 'audit:pc:onchain-selectors',
        pn: args.pn,
        rpc: args.rpc,
        registry: args.registry,
        fromBlock: args.fromBlock,
        contracts: args.contracts
      });
    }
  );
