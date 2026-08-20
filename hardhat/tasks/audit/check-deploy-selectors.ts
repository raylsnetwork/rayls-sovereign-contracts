// Static lint: every `iface.getFunction(arg)` reference in the role-mapping
// deploy code must resolve against the matching contract's current ABI.
//
// Catches the developer-error category where a managed contract function is
// renamed (or its overload signature changes) but the deploy task's
// `getFunction('OLD_NAME')` string isn't updated. Without this check the
// deploy would throw at runtime, which is loud but only useful AT deploy
// time — this task surfaces it in CI before a PR is merged.
//
// CLI: `npx hardhat audit:deploy-selectors`
//   exits 1 if any reference is MISSING from the current ABI.
//
// Programmatic: `await hre.run('audit:deploy-selectors')` returns
//   DeployFinding[] for the generator to consume.

import { task } from 'hardhat/config';
import { ethers } from 'ethers';
import * as fs from 'fs';
import * as path from 'path';
import * as ts from 'typescript';
import { loadAbi } from './utils';

export type DeployFinding = {
  file: string;
  line: number;
  factoryVar: string;
  contractName: string;
  arg: string;
  /**
   * - OK        — literal arg resolves against the current ABI
   * - MISSING   — literal arg does NOT resolve (deploy bug; blocks the lint)
   * - UNCHECKED — non-literal arg (variable / template / ternary / etc).
   *               The lint can't statically determine the runtime value, so
   *               the call is reported as an audit blind spot. Not fatal by
   *               default; emit a CI warning + counter so the limitation is
   *               visible. See collectGetFunctionCalls for the docblock.
   */
  status: 'OK' | 'MISSING' | 'UNCHECKED';
  reason?: string;
};

// Directory the lint auto-discovers `.ts` deploy tasks under. Auto-scanning
// rather than pinning a static list keeps this in lockstep with the on-chain
// audit's `buildRegistryNameToArtifactName`, which already walks the same
// tree — a new deploy file would otherwise be picked up there but silently
// missed here, creating a blind spot.
const DEPLOY_TASK_DIR = 'hardhat/tasks/deploy';

function discoverDeployTaskFiles(rootDir: string): string[] {
  const absRoot = path.join(rootDir, DEPLOY_TASK_DIR);
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
      else if (entry.name.endsWith('.ts')) out.push(full);
    }
  }
  walk(absRoot);
  // Stable order so the lint output is deterministic across OS/FS traversal.
  out.sort();
  return out;
}

/**
 * Walk a TS source file, collecting:
 *   - factoryVarName → contractName  from `ethers.getContractFactory('Name')`
 *   - aliasVarName   → factoryVarName from `const x = y.interface`
 *
 * Both single declarations and Promise.all-with-destructuring forms are
 * handled, since the deploy code uses the destructured form
 * (`private-hub.ts:230-249`).
 */
function collectBindings(sourceFile: ts.SourceFile): {
  factories: Map<string, string>;
  aliases: Map<string, string>;
} {
  const factories = new Map<string, string>();
  const aliases = new Map<string, string>();

  function getFactoryNameArg(call: ts.CallExpression): string | null {
    // Match (...)getContractFactory('Name', ...) — accept any property access
    // chain ending in `getContractFactory` (hre.ethers.getContractFactory,
    // ethers.getContractFactory, etc.).
    let expr = call.expression;
    // Unwrap an awaited call: AwaitExpression is on the outer node, not here.
    if (ts.isPropertyAccessExpression(expr) && expr.name.text === 'getContractFactory') {
      const arg0 = call.arguments[0];
      if (arg0 && ts.isStringLiteral(arg0)) return arg0.text;
    }
    return null;
  }

  function isAwaitedGetContractFactory(expr: ts.Expression): string | null {
    let inner = expr;
    if (ts.isAwaitExpression(inner)) inner = inner.expression;
    if (ts.isCallExpression(inner)) return getFactoryNameArg(inner);
    return null;
  }

  function visit(node: ts.Node) {
    if (ts.isVariableStatement(node)) {
      for (const decl of node.declarationList.declarations) {
        if (!decl.initializer) continue;

        // const x = await ethers.getContractFactory('Name');
        const name = isAwaitedGetContractFactory(decl.initializer);
        if (name && ts.isIdentifier(decl.name)) {
          factories.set(decl.name.text, name);
        }

        // const [x, y] = await Promise.all([
        //   ethers.getContractFactory('A'),
        //   ethers.getContractFactory('B'),
        // ]);
        if (
          ts.isArrayBindingPattern(decl.name) &&
          ts.isAwaitExpression(decl.initializer) &&
          ts.isCallExpression(decl.initializer.expression)
        ) {
          const call = decl.initializer.expression;
          // Expect Promise.all(<arrayLiteral>)
          if (
            ts.isPropertyAccessExpression(call.expression) &&
            call.expression.name.text === 'all' &&
            call.arguments[0] &&
            ts.isArrayLiteralExpression(call.arguments[0])
          ) {
            const arr = call.arguments[0];
            decl.name.elements.forEach((bindingEl, i) => {
              if (ts.isOmittedExpression(bindingEl)) return;
              if (!ts.isBindingElement(bindingEl)) return;
              if (!ts.isIdentifier(bindingEl.name)) return;
              const item = arr.elements[i];
              if (!item) return;
              const factoryName = isAwaitedGetContractFactory(item);
              if (factoryName) factories.set(bindingEl.name.text, factoryName);
            });
          }
        }

        // const epIface = endpointV1Factory.interface;
        if (
          ts.isIdentifier(decl.name) &&
          ts.isPropertyAccessExpression(decl.initializer) &&
          decl.initializer.name.text === 'interface' &&
          ts.isIdentifier(decl.initializer.expression)
        ) {
          aliases.set(decl.name.text, decl.initializer.expression.text);
        }
      }
    }
    ts.forEachChild(node, visit);
  }
  visit(sourceFile);
  return { factories, aliases };
}

/**
 * For every `<expr>.getFunction(<arg>)` call where `<expr>` resolves to a
 * known factory (directly via `.interface` or via an alias), record the call
 * site and the arg literal.
 *
 * Argument resolution — three passes
 * ----------------------------------
 * The static lint can validate calls whose first argument is either a
 * string literal *or* something that statically reduces to a string literal.
 * Three resolution passes, tried in order:
 *
 *   1. **String literal** — `iface.getFunction('foo')`. The trivial case;
 *      record `'foo'` as the literal arg.
 *
 *   2. **`.map(<literal-array>)` arrow parameter** — patterns like
 *      `['a', 'b'].map(fn => iface.getFunction(fn))`. When the arg is an
 *      identifier bound as the parameter of an enclosing `.map(...)` arrow,
 *      and the receiver of `.map` is an ArrayLiteralExpression of
 *      StringLiterals, expand to N validated calls (one per array element,
 *      each pointing at the element's own line for better triage).
 *
 *   3. **Lexically-scoped `const` binding to a string literal** — patterns
 *      like `const fnName = 'doSomething'; iface.getFunction(fnName)`.
 *      Walks up enclosing scopes (Block / SourceFile) looking for a
 *      `const <id> = '<literal>'` declaration; inner-scope bindings shadow
 *      outer ones via the walk order. A `const` declared with anything
 *      other than a string-literal initializer is treated as unresolvable
 *      (we don't recurse through `process.env`-style fallbacks because that
 *      would mean blessing runtime values as compile-time constants).
 *
 * Anything that doesn't reduce via 1–3 becomes an `UNCHECKED` finding:
 * template strings, ternaries, property access on a dynamic object,
 * `.map` over a non-literal receiver (e.g. an identifier that itself binds
 * to a string array via const — chain depth > 1, deliberately not
 * pursued), etc. UNCHECKED is informational by default; CI can escalate
 * via `--strict-unchecked`.
 *
 * Why these three passes specifically
 * -----------------------------------
 * They cover every pattern present in `hardhat/tasks/deploy/` today
 * without introducing flow-sensitive analysis. Adding more (e.g.
 * resolving an array identifier through its const binding before the
 * `.map` expansion) is doable but increases the surface area where the
 * lint can be subtly wrong via stale state — better to leave them as
 * `UNCHECKED` and force an explicit decision (refactor or accept the
 * blind spot) than to validate them with a confidence the analysis
 * doesn't actually have.
 */
export function resolveMapArrowParam(
  id: ts.Identifier
): { values: string[]; lines: number[] } | null {
  // Walk up looking for an enclosing arrow function whose parameter shadows
  // the identifier. Stop at the first match — inner-scope binding wins.
  let scope: ts.Node | undefined = id.parent;
  while (scope) {
    if (ts.isArrowFunction(scope)) {
      const paramNames = scope.parameters
        .map((p) => (ts.isIdentifier(p.name) ? p.name.text : null))
        .filter((n): n is string => n !== null);
      if (paramNames.includes(id.text)) {
        // This arrow binds the identifier. Now check it's the callback of
        // a `<receiver>.map(<arrow>)` call where the receiver reduces to
        // an array of string literals.
        if (!scope.parent || !ts.isCallExpression(scope.parent)) return null;
        const call = scope.parent;
        if (!ts.isPropertyAccessExpression(call.expression)) return null;
        if (call.expression.name.text !== 'map') return null;
        const recv = call.expression.expression;
        return resolveLiteralArrayReceiver(recv);
      }
      // Identifier isn't bound by this arrow — keep walking up (could be
      // bound by an outer arrow / function / scope).
    }
    scope = scope.parent;
  }
  return null;
}

/**
 * Reduce an arbitrary expression to `{ values, lines }` when it's either:
 *   (a) an inline `ArrayLiteralExpression` of `StringLiteral`s, or
 *   (b) an `Identifier` whose lexically-resolvable `const` binding is itself
 *       an `ArrayLiteralExpression` of `StringLiteral`s.
 *
 * Returns null when neither path applies. The const-binding lookup uses the
 * same scope-walk semantics as `resolveConstBinding` (TDZ-aware, inner-
 * scope wins).
 */
function resolveLiteralArrayReceiver(recv: ts.Node): { values: string[]; lines: number[] } | null {
  // Case (a): inline array literal.
  if (ts.isArrayLiteralExpression(recv)) {
    return extractStringArrayElements(recv);
  }
  // Case (b): identifier → resolve via const binding to ArrayLiteralExpression.
  if (ts.isIdentifier(recv)) {
    const arr = resolveConstArrayBinding(recv);
    if (arr) return extractStringArrayElements(arr);
  }
  return null;
}

function extractStringArrayElements(
  arr: ts.ArrayLiteralExpression
): { values: string[]; lines: number[] } | null {
  const values: string[] = [];
  const lines: number[] = [];
  const sf = arr.getSourceFile();
  for (const el of arr.elements) {
    if (!ts.isStringLiteral(el)) return null;
    values.push(el.text);
    lines.push(sf.getLineAndCharacterOfPosition(el.getStart(sf)).line + 1);
  }
  return { values, lines };
}

/**
 * Look up a `const <id> = [...string-literals...]` binding via the same
 * TDZ-aware walk as `resolveConstBinding`. Returns the
 * `ArrayLiteralExpression` node on success; null otherwise (binding not
 * found, found via let/var, initializer isn't an array literal, or the
 * decl is positioned after the use).
 */
function resolveConstArrayBinding(id: ts.Identifier): ts.ArrayLiteralExpression | null {
  let scope: ts.Node | undefined = id.parent;
  let prev: ts.Node = id;
  while (scope) {
    let statements: ts.NodeArray<ts.Statement> | undefined;
    if (ts.isBlock(scope) || ts.isSourceFile(scope)) {
      statements = scope.statements;
    }
    if (statements) {
      const useStmt = prev;
      for (const stmt of statements) {
        if (stmt === useStmt) break;
        if (!ts.isVariableStatement(stmt)) continue;
        // eslint-disable-next-line no-bitwise
        if ((stmt.declarationList.flags & ts.NodeFlags.Const) === 0) continue;
        for (const decl of stmt.declarationList.declarations) {
          if (!ts.isIdentifier(decl.name)) continue;
          if (decl.name.text !== id.text) continue;
          if (!decl.initializer || !ts.isArrayLiteralExpression(decl.initializer)) {
            return null;
          }
          return decl.initializer;
        }
      }
    }
    prev = scope;
    scope = scope.parent;
  }
  return null;
}

export function resolveConstBinding(id: ts.Identifier): string | null {
  // Walk up enclosing scopes (Block / SourceFile / ArrowFunction-with-block-
  // body / FunctionDeclaration body), checking each for a `const <id> =
  // '<literal>'` declaration. Inner scope wins by walk order.
  //
  // TDZ (temporal dead zone) note: within the SAME block, a `const`
  // declaration that appears LEXICALLY AFTER the identifier reference is in
  // the TDZ at runtime — accessing it throws a ReferenceError. The static
  // lint must respect this: we stop iterating `scope.statements` as soon
  // as we hit the statement that contains the identifier (`useStmt`),
  // never matching a declaration that comes after it within the same
  // block.
  //
  // For OUTER scopes (declaration in a strictly enclosing block, identifier
  // captured inside an inner function/arrow body), runtime TDZ depends on
  // when the inner function is invoked — the static lint can't tell. The
  // conservative behaviour is to apply the same "must precede the inner
  // function's containing statement at this scope's level" rule, which is
  // what `useStmt` becomes at outer levels (the direct child of `scope`
  // containing the path back to `id`). This is sometimes a false-negative
  // (lint reports UNCHECKED for code that would run fine at runtime), but
  // false-negatives are merely conservative — false-positives would let
  // broken code through, which is worse.
  let scope: ts.Node | undefined = id.parent;
  let prev: ts.Node = id;
  while (scope) {
    let statements: ts.NodeArray<ts.Statement> | undefined;
    if (ts.isBlock(scope) || ts.isSourceFile(scope)) {
      statements = scope.statements;
    }
    if (statements) {
      // `prev` is the immediate child of `scope` we just walked out of.
      // When `scope` is a Block / SourceFile, `prev` is the Statement at
      // this scope level containing the identifier — only declarations
      // that lexically precede it are visible (TDZ rule).
      const useStmt = prev;
      for (const stmt of statements) {
        if (stmt === useStmt) break;
        if (!ts.isVariableStatement(stmt)) continue;
        // Must be a `const` (not `let` / `var`) — only `const` to a literal
        // is reliably a compile-time constant in this codebase's style.
        // eslint-disable-next-line no-bitwise
        if ((stmt.declarationList.flags & ts.NodeFlags.Const) === 0) continue;
        for (const decl of stmt.declarationList.declarations) {
          if (!ts.isIdentifier(decl.name)) continue;
          if (decl.name.text !== id.text) continue;
          // Name matches. Initializer must be a string literal — anything
          // else (env-var fallback, function call, template) we treat as
          // unresolvable and bail out of the binding resolver entirely
          // (so the call site shows up as UNCHECKED, not a false-positive
          // OK with a wrong value).
          if (!decl.initializer || !ts.isStringLiteral(decl.initializer)) {
            return null;
          }
          return decl.initializer.text;
        }
      }
    }
    prev = scope;
    scope = scope.parent;
  }
  return null;
}
function collectGetFunctionCalls(
  sourceFile: ts.SourceFile,
  factories: Map<string, string>,
  aliases: Map<string, string>
): {
  literal: { line: number; factoryVar: string; contractName: string; arg: string }[];
  nonLiteral: { line: number; factoryVar: string; contractName: string; argSyntax: string }[];
} {
  const literal: { line: number; factoryVar: string; contractName: string; arg: string }[] = [];
  // Non-literal calls (variable / template / ternary / etc) — captured so
  // the lint can surface the audit blind spot rather than silently drop it.
  // `argSyntax` is the verbatim source text of the first argument, useful
  // for `file:line` triage without making the operator re-open the file.
  const nonLiteral: {
    line: number;
    factoryVar: string;
    contractName: string;
    argSyntax: string;
  }[] = [];

  function resolveReceiver(expr: ts.Expression): string | null {
    // Forms we handle:
    //   factoryVar.interface     → factoryVar
    //   aliasVar                 → aliases.get(aliasVar)
    if (ts.isPropertyAccessExpression(expr) && expr.name.text === 'interface') {
      if (ts.isIdentifier(expr.expression)) {
        const name = expr.expression.text;
        if (factories.has(name)) return name;
      }
      return null;
    }
    if (ts.isIdentifier(expr)) {
      const aliasedTo = aliases.get(expr.text);
      if (aliasedTo && factories.has(aliasedTo)) return aliasedTo;
    }
    return null;
  }

  function visit(node: ts.Node) {
    if (
      ts.isCallExpression(node) &&
      ts.isPropertyAccessExpression(node.expression) &&
      node.expression.name.text === 'getFunction'
    ) {
      const recv = node.expression.expression;
      const factoryVar = resolveReceiver(recv);
      if (factoryVar) {
        const contractName = factories.get(factoryVar)!;
        const arg0 = node.arguments[0];
        const { line } = sourceFile.getLineAndCharacterOfPosition(node.getStart(sourceFile));
        if (arg0 && ts.isStringLiteral(arg0)) {
          // Pass 1: arg is itself a string literal — record verbatim.
          literal.push({
            line: line + 1,
            factoryVar,
            contractName,
            arg: arg0.text
          });
        } else if (arg0 && ts.isIdentifier(arg0)) {
          // Pass 2: arg is an identifier — try `.map(literal-array)`
          // expansion first (inner-scope binding wins), then fall back to
          // a lexically-scoped `const` binding. See the resolver docblocks
          // for the precedence rationale.
          const mapExpansion = resolveMapArrowParam(arg0);
          if (mapExpansion) {
            for (let i = 0; i < mapExpansion.values.length; i++) {
              literal.push({
                line: mapExpansion.lines[i]!,
                factoryVar,
                contractName,
                arg: mapExpansion.values[i]!
              });
            }
          } else {
            const constValue = resolveConstBinding(arg0);
            if (constValue !== null) {
              literal.push({
                line: line + 1,
                factoryVar,
                contractName,
                arg: constValue
              });
            } else {
              // Identifier didn't resolve via either pass — UNCHECKED.
              nonLiteral.push({
                line: line + 1,
                factoryVar,
                contractName,
                argSyntax: arg0.getText(sourceFile)
              });
            }
          }
        } else if (arg0) {
          // Pass 3 (failure): template strings, ternaries, property
          // access on a dynamic object, etc. Static lint can't determine
          // the runtime value — record as UNCHECKED so the call shows up
          // as an audit blind spot rather than silently dropped.
          nonLiteral.push({
            line: line + 1,
            factoryVar,
            contractName,
            argSyntax: arg0.getText(sourceFile)
          });
        }
      }
    }
    ts.forEachChild(node, visit);
  }
  visit(sourceFile);
  return { literal, nonLiteral };
}

task(
  'audit:deploy-selectors',
  'Lint deploy code: every iface.getFunction(name) must match the current ABI'
)
  // CI gate for the UNCHECKED finding category. Off by default so the lint
  // doesn't punish dev iteration on `.map(fn => iface.getFunction(fn))`
  // patterns that work correctly at runtime; on for CI/staging where any
  // audit blind spot is itself a finding worth blocking on. The deploy
  // pipeline doesn't pass this flag (deploy_contracts.sh), so the existing
  // 2 UNCHECKED cases in privacy-node.ts don't gate deploys. Operators
  // running the lint manually with --strict-unchecked get a stricter
  // posture for free.
  .addFlag(
    'strictUnchecked',
    'Treat UNCHECKED non-literal getFunction args as fatal (exit 1) in addition to MISSING'
  )
  .setAction(async (args: { strictUnchecked: boolean }, hre): Promise<DeployFinding[]> => {
    const root = hre.config.paths.root;
    const findings: DeployFinding[] = [];
    const deployFiles = discoverDeployTaskFiles(root);

    for (const abs of deployFiles) {
      const relPath = path.relative(root, abs);
      const src = fs.readFileSync(abs, 'utf8');
      const sourceFile = ts.createSourceFile(abs, src, ts.ScriptTarget.ES2020, true);

      const { factories, aliases } = collectBindings(sourceFile);
      const { literal: calls, nonLiteral: uncheckedCalls } = collectGetFunctionCalls(
        sourceFile,
        factories,
        aliases
      );

      // Surface non-literal getFunction(...) call sites as UNCHECKED findings.
      // Today the deploy code uses literals only; if a refactor introduces a
      // variable / template arg, this is the operator's signal that the lint
      // is no longer covering 100% of the surface area. Not MISSING — the
      // call may well be correct at runtime — but explicitly *not validated*.
      for (const u of uncheckedCalls) {
        findings.push({
          file: relPath,
          line: u.line,
          factoryVar: u.factoryVar,
          contractName: u.contractName,
          arg: u.argSyntax,
          status: 'UNCHECKED',
          reason: `non-literal first argument (got: ${u.argSyntax}) — static lint cannot resolve. Refactor to a string literal, or accept the audit blind spot.`
        });
      }

      for (const call of calls) {
        const abi = loadAbi(root, call.contractName);
        if (!abi) {
          findings.push({
            file: relPath,
            line: call.line,
            factoryVar: call.factoryVar,
            contractName: call.contractName,
            arg: call.arg,
            status: 'MISSING',
            reason: `no artifact found for '${call.contractName}' — did you run 'hardhat compile'?`
          });
          continue;
        }
        try {
          const iface = new ethers.Interface(abi);
          const fn = iface.getFunction(call.arg);
          if (!fn) throw new Error('null');
          findings.push({
            file: relPath,
            line: call.line,
            factoryVar: call.factoryVar,
            contractName: call.contractName,
            arg: call.arg,
            status: 'OK'
          });
        } catch (err) {
          findings.push({
            file: relPath,
            line: call.line,
            factoryVar: call.factoryVar,
            contractName: call.contractName,
            arg: call.arg,
            status: 'MISSING',
            reason: `not found on ${call.contractName}'s current ABI`
          });
        }
      }
    }

    // Render
    const missing = findings.filter((f) => f.status === 'MISSING');
    const unchecked = findings.filter((f) => f.status === 'UNCHECKED');
    const ok = findings.filter((f) => f.status === 'OK');
    console.log(
      `\nDeploy-selector lint: ${findings.length} reference${findings.length !== 1 ? 's' : ''} checked (${ok.length} OK, ${missing.length} MISSING, ${unchecked.length} UNCHECKED).\n`
    );
    if (missing.length > 0) {
      console.log(
        '  STATUS    file:line                              factory → contract                 arg'
      );
      console.log(
        '  ────────  ─────────────────────────────────────  ─────────────────────────────────  ────'
      );
      for (const f of missing) {
        const loc = `${f.file}:${f.line}`.padEnd(38);
        const factory = `${f.factoryVar} → ${f.contractName}`.padEnd(34);
        console.log(`  MISSING   ${loc}  ${factory}  '${f.arg}'  (${f.reason})`);
      }
      console.log('');
    }
    if (unchecked.length > 0) {
      // UNCHECKED is informational, not fatal — surface the call sites so
      // operators can see exactly where the lint stopped covering. The
      // existence of any UNCHECKED is a signal that the audit is missing
      // potential drift, even if today's code happens to be correct.
      console.log('  ⚠️  UNCHECKED (non-literal getFunction args — static lint cannot validate):');
      for (const f of unchecked) {
        console.log(`    ${f.file}:${f.line}  ${f.factoryVar} → ${f.contractName}  arg=${f.arg}`);
      }
      console.log('');
    }
    if (missing.length > 0) {
      console.log(
        `  ❌ LINT FAILED — ${missing.length} deploy-script reference${missing.length !== 1 ? 's' : ''} don't match current ABIs.`
      );
      if (unchecked.length > 0)
        console.log(
          `     (+ ${unchecked.length} UNCHECKED non-literal call${unchecked.length !== 1 ? 's' : ''} — see above)`
        );
      console.log('');
      process.exitCode = 1;
    } else if (args.strictUnchecked && unchecked.length > 0) {
      console.log(
        `  ❌ LINT FAILED — ${unchecked.length} UNCHECKED non-literal getFunction call${unchecked.length !== 1 ? 's' : ''} (--strict-unchecked).\n`
      );
      process.exitCode = 1;
    } else if (unchecked.length > 0) {
      console.log(
        `  ✅ LINT PASSED for ${ok.length} validated reference${ok.length !== 1 ? 's' : ''}, but ${unchecked.length} non-literal call${unchecked.length !== 1 ? 's' : ''} were NOT validated (see above; pass --strict-unchecked to make these fatal).\n`
      );
    } else {
      console.log(
        `  ✅ LINT PASSED — all ${findings.length} getFunction(...) references resolve against the current ABIs.\n`
      );
    }
    return findings;
  });
