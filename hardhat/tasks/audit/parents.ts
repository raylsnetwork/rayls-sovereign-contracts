// Parent audit tasks. Each parent invokes its chain's children in sequence
// via `hre.run()`. Children set `process.exitCode` on findings; the parent
// doesn't reset, so the final exit reflects the worst child's verdict.
// Hard errors (RPC unreachable, CTS down) throw out of the child and halt
// the parent — that's the right behavior.
//
//   audit:pnh                              full PNH suite
//   audit:pn  --pn A[,B,…]                 PN suite, iterated per PN
//   audit:pc  --pn A[,B,…]                 PC suite, iterated per PN
//   audit:all                              everything: deploy-selectors → pnh →
//                                          per-PN pn → per-PN pc.
//                                          Reads PARTICIPANT_LIST for the PN set.
//
// `audit:pnh:generate-migration`, `audit:pn:generate-migration`, and
// `audit:pc:generate-migration` are NEVER auto-run by parents — generating a
// migration is a deliberate remediation step, not part of "is everything
// clean?".
//
// External operators: each child task reads chain-keyed env vars (PNH_RPC_URL,
// PRIVACY_NODE_<X>_RPC_URL, PUBLIC_CHAIN_RPC_URL, plus the matching
// *_DEPLOYMENT_PROXY_REGISTRY entries) and CTS endpoints (CTS_SERVICE_<X>_URL).
// Set those in your .env (or pass --rpc / --registry / --pn flags) and the
// parent tasks run end-to-end without `docker/dev/deploy_contracts.sh` having
// touched your environment.

import { task } from 'hardhat/config';
import type { HardhatRuntimeEnvironment } from 'hardhat/types';

function parsePnList(csv: string, taskName: string): string[] {
  const tokens = csv.split(',').map((t) => t.trim());
  if (tokens.some((t) => t.length === 0)) {
    throw new Error(`${taskName}: --pn contains an empty entry: '${csv}'`);
  }
  const out: string[] = [];
  for (const t of tokens) if (!out.includes(t)) out.push(t);
  if (out.length === 0) {
    throw new Error(`${taskName}: --pn must list at least one PN`);
  }
  return out;
}

/** Re-throws if `hre.run` itself rejected; otherwise returns whatever the
 *  child set as exit code so the caller can aggregate. */
async function runChild(
  hre: HardhatRuntimeEnvironment,
  taskName: string,
  args: Record<string, unknown>
): Promise<void> {
  await hre.run(taskName, args);
}

task('audit:pnh', 'Run the full PNH audit suite (onchain-selectors + roles)')
  .addOptionalParam(
    'privacyNodes',
    'PN list forwarded to audit:pnh:roles (default: PARTICIPANT_LIST env var)',
    ''
  )
  .addOptionalParam('rpc', 'JSON-RPC URL override (default: PNH_RPC_URL)', '')
  .addOptionalParam('registry', 'DeploymentProxyRegistry address override', '')
  .addOptionalParam('fromBlock', 'Start block override (forwarded to both children)', '')
  .addFlag('reportOnly', 'roles child prints findings but exits 0 even on drift')
  .addFlag(
    'includeOwnRoles',
    'roles child also runs the static deploy-time own-roles audit against expected-roles/<chain>.ts'
  )
  .addFlag(
    'skipRelayers',
    'roles child skips the CTS-driven RELAYER audit (use with --include-own-roles)'
  )
  .setAction(
    async (
      args: {
        privacyNodes: string;
        rpc: string;
        registry: string;
        fromBlock: string;
        reportOnly: boolean;
        includeOwnRoles: boolean;
        skipRelayers: boolean;
      },
      hre
    ): Promise<void> => {
      const taskName = 'audit:pnh';
      console.log(`\n══════ ${taskName} ══════════════════════════════════════════════════`);
      console.log('[1/2] audit:pnh:onchain-selectors');
      await runChild(hre, 'audit:pnh:onchain-selectors', {
        rpc: args.rpc,
        registry: args.registry,
        fromBlock: args.fromBlock,
        contracts: ''
      });

      console.log('\n[2/2] audit:pnh:roles');
      await runChild(hre, 'audit:pnh:roles', {
        privacyNodes: args.privacyNodes,
        rpc: args.rpc,
        registry: args.registry,
        fromBlock: args.fromBlock,
        roleName: 'RELAYER',
        reportOnly: args.reportOnly,
        includeOwnRoles: args.includeOwnRoles,
        skipRelayers: args.skipRelayers
      });

      const verdict =
        process.exitCode === 0 || process.exitCode === undefined ? '✅ PASSED' : '❌ FAILED';
      console.log(`\n══════ ${taskName} ${verdict} ══════\n`);
    }
  );

task('audit:pn', "Run the full audit suite on one or more Privacy Nodes' own chains")
  .addParam('pn', 'Privacy node id(s) — single or comma-separated (e.g. A or A,B,C)')
  .addOptionalParam('rpc', 'JSON-RPC URL override (default: PRIVACY_NODE_<X>_RPC_URL per PN)', '')
  .addOptionalParam('registry', 'DeploymentProxyRegistry address override', '')
  .addOptionalParam('fromBlock', 'Start block override (forwarded to both children)', '')
  .addFlag('reportOnly', 'roles child prints findings but exits 0 even on drift')
  .addFlag(
    'includeOwnRoles',
    'roles child also runs the static deploy-time own-roles audit against expected-roles/<chain>.ts'
  )
  .addFlag(
    'skipRelayers',
    'roles child skips the CTS-driven RELAYER audit (use with --include-own-roles)'
  )
  .setAction(
    async (
      args: {
        pn: string;
        rpc: string;
        registry: string;
        fromBlock: string;
        reportOnly: boolean;
        includeOwnRoles: boolean;
        skipRelayers: boolean;
      },
      hre
    ): Promise<void> => {
      const taskName = 'audit:pn';
      const pns = parsePnList(args.pn, taskName);
      for (const pn of pns) {
        console.log(`\n══════ ${taskName} --pn ${pn} ═════════════════════════════════════`);
        console.log(`[1/2] audit:pn:onchain-selectors --pn ${pn}`);
        await runChild(hre, 'audit:pn:onchain-selectors', {
          pn,
          rpc: args.rpc,
          registry: args.registry,
          fromBlock: args.fromBlock,
          contracts: ''
        });

        console.log(`\n[2/2] audit:pn:roles --pn ${pn}`);
        await runChild(hre, 'audit:pn:roles', {
          pn,
          rpc: args.rpc,
          registry: args.registry,
          fromBlock: args.fromBlock,
          roleName: 'RELAYER',
          reportOnly: args.reportOnly,
          includeOwnRoles: args.includeOwnRoles,
          skipRelayers: args.skipRelayers
        });
      }

      const verdict =
        process.exitCode === 0 || process.exitCode === undefined ? '✅ PASSED' : '❌ FAILED';
      console.log(
        `\n══════ ${taskName} (${pns.length} PN${pns.length !== 1 ? 's' : ''}) ${verdict} ══════\n`
      );
    }
  );

task(
  'audit:pc',
  "Run the full audit suite on one or more Privacy Nodes' public-chain AccessManagers"
)
  .addParam('pn', 'Privacy node id(s) — single or comma-separated (e.g. A or A,B,C)')
  .addOptionalParam('rpc', 'JSON-RPC URL override (default: PUBLIC_CHAIN_RPC_URL)', '')
  .addOptionalParam('registry', 'DeploymentProxyRegistry address override', '')
  .addOptionalParam('fromBlock', 'Start block override (forwarded to both children)', '')
  .addFlag('reportOnly', 'roles child prints findings but exits 0 even on drift')
  .addFlag(
    'includeOwnRoles',
    'roles child also runs the static deploy-time own-roles audit against expected-roles/<chain>.ts'
  )
  .addFlag(
    'skipRelayers',
    'roles child skips the CTS-driven RELAYER audit (use with --include-own-roles)'
  )
  .setAction(
    async (
      args: {
        pn: string;
        rpc: string;
        registry: string;
        fromBlock: string;
        reportOnly: boolean;
        includeOwnRoles: boolean;
        skipRelayers: boolean;
      },
      hre
    ): Promise<void> => {
      const taskName = 'audit:pc';
      const pns = parsePnList(args.pn, taskName);
      for (const pn of pns) {
        console.log(`\n══════ ${taskName} --pn ${pn} ═════════════════════════════════════`);
        console.log(`[1/2] audit:pc:onchain-selectors --pn ${pn}`);
        await runChild(hre, 'audit:pc:onchain-selectors', {
          pn,
          rpc: args.rpc,
          registry: args.registry,
          fromBlock: args.fromBlock,
          contracts: ''
        });

        console.log(`\n[2/2] audit:pc:roles --pn ${pn}`);
        await runChild(hre, 'audit:pc:roles', {
          pn,
          rpc: args.rpc,
          registry: args.registry,
          fromBlock: args.fromBlock,
          roleName: 'RELAYER',
          reportOnly: args.reportOnly,
          includeOwnRoles: args.includeOwnRoles,
          skipRelayers: args.skipRelayers
        });
      }

      const verdict =
        process.exitCode === 0 || process.exitCode === undefined ? '✅ PASSED' : '❌ FAILED';
      console.log(
        `\n══════ ${taskName} (${pns.length} PN${pns.length !== 1 ? 's' : ''}) ${verdict} ══════\n`
      );
    }
  );

task('audit:all', 'Run every audit across every chain — full CI entrypoint')
  .addOptionalParam(
    'pn',
    'Override the PN list (default: PARTICIPANT_LIST env var; comma-separated, e.g. A,B,C)',
    ''
  )
  .addFlag('reportOnly', 'roles children print findings but exit 0 even on drift')
  .setAction(async (args: { pn: string; reportOnly: boolean }, hre): Promise<void> => {
    const taskName = 'audit:all';
    const pnsArg = args.pn || process.env.PARTICIPANT_LIST || '';
    if (!pnsArg) {
      throw new Error(
        `${taskName}: --pn omitted and PARTICIPANT_LIST env var is unset. ` +
          `Pass --pn A[,B,C] or export PARTICIPANT_LIST.`
      );
    }
    const pns = parsePnList(pnsArg, taskName);

    console.log(`\n══════ ${taskName} (PNs: ${pns.join(',')}) ════════════════════════\n`);

    // audit:all is the CI entrypoint — strict by definition. UNCHECKED
    // findings (deploy-selectors can't resolve the getFunction argument
    // to a literal) escalate to fatal. Operators who want lenient
    // behaviour run `audit:deploy-selectors` directly without
    // --strict-unchecked, or use the individual child tasks.
    console.log('[1/4] audit:deploy-selectors --strict-unchecked');
    await runChild(hre, 'audit:deploy-selectors', {
      strictUnchecked: true
    });

    // audit:all always opts into own-roles for full coverage — the CI
    // entrypoint should detect drift between deploy code and the
    // expected-roles modules. Operators can run the children directly
    // (without --include-own-roles) for the lighter relayer-only check.
    console.log('\n[2/4] audit:pnh (includes own-roles)');
    await runChild(hre, 'audit:pnh', {
      privacyNodes: pns.join(','),
      rpc: '',
      registry: '',
      fromBlock: '',
      reportOnly: args.reportOnly,
      includeOwnRoles: true,
      skipRelayers: false
    });

    console.log(`\n[3/4] audit:pn --pn ${pns.join(',')} (includes own-roles)`);
    await runChild(hre, 'audit:pn', {
      pn: pns.join(','),
      rpc: '',
      registry: '',
      fromBlock: '',
      reportOnly: args.reportOnly,
      includeOwnRoles: true,
      skipRelayers: false
    });

    console.log(`\n[4/4] audit:pc --pn ${pns.join(',')} (includes own-roles)`);
    await runChild(hre, 'audit:pc', {
      pn: pns.join(','),
      rpc: '',
      registry: '',
      fromBlock: '',
      reportOnly: args.reportOnly,
      includeOwnRoles: true,
      skipRelayers: false
    });

    const verdict =
      process.exitCode === 0 || process.exitCode === undefined ? '✅ PASSED' : '❌ FAILED';
    console.log(`\n══════ ${taskName} ${verdict} ══════\n`);
  });
