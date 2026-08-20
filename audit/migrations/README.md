# `audit/migrations/`

Auto-generated AccessManager migration scripts produced by:

```sh
npx hardhat audit:pnh:generate-migration            # PNH AccessManager
npx hardhat audit:pn:generate-migration --pn A      # PN A's own chain
npx hardhat audit:pc:generate-migration --pn A      # PN A's PC AccessManager
# Pass --registry 0x… to override the env-var fallback.
```

Each file in this directory is a runnable hardhat script that brings on-chain `AccessManager` state into sync with the current source by calling `removeFunctionAllowedRoles` for every **STALE** mapping the audit reports (an on-chain `(target, selector, role)` tuple whose selector no longer matches any function on the target's current ABI).

**Every file here is auto-generated. Treat them as ephemeral artifacts, not source of truth.** Inspect before running:

```sh
# Review the generated file
$EDITOR audit/migrations/<timestamp>-access-manager-drift.ts

# Apply (only after review)
npx hardhat run audit/migrations/<timestamp>-access-manager-drift.ts --network <name>

# Confirm clean state
npx hardhat audit:pnh:onchain-selectors      # or :pn / :pc per the chain you migrated
```

See [`../../docs/access-manager-migration.md`](../../docs/access-manager-migration.md) for the full operator workflow.
