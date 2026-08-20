// import config before anything else
import '@nomicfoundation/hardhat-foundry';
import './hardhat/test/setup.ts';
//import '@openzeppelin/hardhat-upgrades';
import '@solarity/hardhat-gobind';
import '@typechain/hardhat';
import { config as dotEnvConfig } from 'dotenv';
import { HardhatUserConfig, task } from 'hardhat/config';
// require("hardhat-contract-sizer");
import '@nomicfoundation/hardhat-chai-matchers';
import 'hardhat-contract-sizer';
import 'hardhat-artifactor';
import 'solidity-coverage';
dotEnvConfig();
import './hardhat/tasks/index';


// Imports for resolving the solidity compilation crash with larger contracts codebases
import { TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS } from 'hardhat/builtin-tasks/task-names';
import * as path from 'path';
import * as fs from 'fs';
import * as glob from 'glob'; // Import glob for use in the task
import { execSync } from 'child_process';

// Module-scoped variable to store files to compile.
// This is how our custom task communicates with the subtask.
let filesToCompileForCurrentRun: string[] = [];

// This subtask hooks into Hardhat's internal process of finding source files.
subtask(TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS).setAction(async (taskArgs, hre, runSuper) => {
  const allSourcePaths = await runSuper(taskArgs); // Get all source paths Hardhat usually sees

  // If our custom variable has files, filter the list
  if (filesToCompileForCurrentRun.length > 0) {
    const targetAbsolutePaths = filesToCompileForCurrentRun.map((file) => path.resolve(file));
    const filteredPaths = allSourcePaths.filter((p: string) =>
      targetAbsolutePaths.includes(path.resolve(p))
    );

    if (filteredPaths.length === 0 && filesToCompileForCurrentRun.length > 0) {
      console.warn(
        `Warning: No Solidity files found matching the specified paths for this compilation step. Check paths: ${filesToCompileForCurrentRun.join(', ')}`
      );
    }
    return filteredPaths;
  }

  return allSourcePaths; // If no specific files are set, run as normal
});

// Define a custom task to compile specific files/directories
task('compile-subset', 'Compiles a specified subset of Solidity files or directories')
  .addVariadicPositionalParam<string>(
    'pathsToCompile',
    "The Solidity files or directories to compile (e.g., 'src/MyContract.sol' or 'src/myDir/**/*.sol')"
  )
  .setAction(async ({ pathsToCompile }, hre) => {
    if (!pathsToCompile || pathsToCompile.length === 0) {
      console.error('Error: No files or directories specified for compilation.');
      process.exit(1);
    }

    // Resolve glob patterns for directories
    let resolvedFiles: string[] = [];
    for (const p of pathsToCompile) {
      if (p.includes('*')) {
        // It's a glob pattern
        const matches = glob.sync(path.resolve(p), { cwd: process.cwd() }); // Ensure correct cwd
        resolvedFiles.push(...matches);
      } else {
        // It's a direct file path
        resolvedFiles.push(path.resolve(p));
      }
    }

    // Filter to ensure only .sol files are passed (glob might pick up other files)
    resolvedFiles = resolvedFiles.filter((file) => file.endsWith('.sol'));

    if (resolvedFiles.length === 0) {
      console.warn(`No .sol files found after resolving patterns: ${pathsToCompile.join(', ')}`);
      return; // Don't run compile if no files found
    }

    // Set the module-scoped variable for the subtask
    filesToCompileForCurrentRun = resolvedFiles;

    console.log(
      `\nStarting compilation for:\n - ${resolvedFiles.map((f) => path.relative(process.cwd(), f)).join('\n - ')}`
    );

    try {
      await hre.run('compile');
      console.log(`Compilation for subset finished successfully.`);
    } catch (error) {
      console.error('Error during subset compilation:', error);
      process.exit(1);
    } finally {
      // Clear the filter after compilation so subsequent `hre.run("compile")`
      // or other tasks don't inadvertently use this filter.
      filesToCompileForCurrentRun = [];
    }
  });

/** Return the newest mtime (ms) among files with the given extension under `dir`. */
function getNewestMtime(dir: string, ext: string): number {
  let newest = 0;
  if (!fs.existsSync(dir)) return 0;
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      newest = Math.max(newest, getNewestMtime(full, ext));
    } else if (entry.name.endsWith(ext)) {
      newest = Math.max(newest, fs.statSync(full).mtimeMs);
    }
  }
  return newest;
}

task(
  'compile',
  'Compile with Forge, convert artifacts to Hardhat v2 format, and generate TypeChain typings'
).setAction(async (_args: any, _hre: any, _runSuper: any) => {
  // If we're running coverage, skip Forge and use Hardhat's built-in compiler
  // solidity-coverage needs to instrument the contracts before compilation
  if (process.env.SOLIDITY_COVERAGE === 'true') {
    console.log('📊 Coverage mode detected - using Hardhat compiler instead of Forge');
    return _runSuper();
  }

  const startTotal = Date.now();

  // 1. Run Forge build and capture output to detect cache hit
  console.log('🔨 Running forge build...');
  const startForge = Date.now();
  const forgeOutput = execSync('forge build', { encoding: 'utf8' });
  const forgeTime = Date.now() - startForge;
  const forgeSkipped = forgeOutput.includes('No files changed');

  // 2. Smart cache: skip conversion + TypeChain if Forge had nothing to compile
  //    AND artifacts/typechain-types already exist from a previous run
  //    AND artifacts are not stale (out/ has no files newer than artifacts/).
  //
  //    The staleness check is critical: if `forge build` or `forge test` ran
  //    outside of `npx hardhat compile`, Forge's `out/` is up to date but
  //    Hardhat's `artifacts/` still has the old converted versions. Without
  //    this check, the next `npx hardhat compile` would skip conversion
  //    because Forge reports "No files changed" (out/ is already current).
  const typechainDir = path.join(__dirname, 'typechain-types');
  const artifactsDir = path.join(__dirname, 'artifacts', 'src');
  const forgeOutDir = path.join(__dirname, 'out');
  const typechainExists = fs.existsSync(typechainDir) &&
    fs.readdirSync(typechainDir).filter((f: string) => f.endsWith('.ts')).length > 0;
  const artifactsExist = fs.existsSync(artifactsDir);

  // Check if out/ has any .json file newer than the newest .json in artifacts/
  let artifactsStale = false;
  if (forgeSkipped && artifactsExist) {
    const newestArtifact = getNewestMtime(artifactsDir, '.json');
    const newestForgeOut = getNewestMtime(forgeOutDir, '.json');
    if (newestForgeOut > newestArtifact) {
      artifactsStale = true;
      console.log('⚠️  Forge out/ is newer than artifacts/ — reconverting...');
    }
  }

  if (forgeSkipped && typechainExists && artifactsExist && !artifactsStale) {
    const totalTime = Date.now() - startTotal;
    console.log(`\n⏱️  Compilation Timing Summary:`);
    console.log(`   1. Forge build:           ${(forgeTime / 1000).toFixed(2)}s (no changes)`);
    console.log(`   2. Artifact conversion:   skipped (cached)`);
    console.log(`   3. TypeChain generation:  skipped (cached)`);
    console.log(`   ────────────────────────────────────`);
    console.log(`   Total:                    ${(totalTime / 1000).toFixed(2)}s\n`);
    return;
  }

  // 3. Full pipeline: contracts changed or first run
  console.log('🔄 Converting Forge artifacts to Hardhat format...');
  const scriptPath = path.join(__dirname, 'scripts', 'forge-to-hardhat.ts');
  const startConversion = Date.now();
  execSync(`npx ts-node ${scriptPath}`, { stdio: 'pipe' });
  const conversionTime = Date.now() - startConversion;

  console.log('🔄 Generating TypeChain typings...');
  const startTypeChain = Date.now();
  execSync(`npx typechain --target ethers-v6 --out-dir typechain-types 'out/**/*.sol/*.json'`, {
    stdio: 'pipe'
  });
  const typeChainTime = Date.now() - startTypeChain;

  const totalTime = Date.now() - startTotal;

  // Print timing summary
  console.log('\n⏱️  Compilation Timing Summary:');
  console.log(`   1. Forge build:           ${(forgeTime / 1000).toFixed(2)}s`);
  console.log(`   2. Artifact conversion:   ${(conversionTime / 1000).toFixed(2)}s`);
  console.log(`   3. TypeChain generation:  ${(typeChainTime / 1000).toFixed(2)}s`);
  console.log(`   ────────────────────────────────────`);
  console.log(`   Total:                    ${(totalTime / 1000).toFixed(2)}s\n`);
});

const config: HardhatUserConfig = {
  solidity: {
    version: '0.8.24',
    settings: {
      optimizer: {
        enabled: true,
        runs: 50
      },
      evmVersion: 'paris'
    }
  },
  typechain: {
    outDir: 'typechain-types',
    target: 'ethers-v6',
    alwaysGenerateOverloads: false,
    externalArtifacts: ['external/*.json']
  },
  paths: {
    tests: './hardhat/test',
    artifacts: './artifacts',
    cache: './cache_hardhat',
    sources: './src'
  },
  networks: (() => {
    const networks: any = {
      // Local docker-compose networks. Deployer is the well-known public
      // Anvil/Hardhat account #0 test key (see .env.example-local).
      localPNH: {
        url: 'http://private-hub:3445',
        // Deployer = PRIVATE_KEY_SYSTEM so the PNH deploy and the post-deploy
        // activate-business-roles-pnh task (which signs with PRIVATE_KEY_SYSTEM) use
        // the SAME account -> the access-manager admin matches. Falls back to the
        // well-known Anvil account #0 key when PRIVATE_KEY_SYSTEM is unset.
        accounts: [process.env['PRIVATE_KEY_SYSTEM'] ?? 'ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80'],
        timeout: 80000,
        chainId: 1337,
        gasPrice: 0
      },
      localPublicChain: {
        url: 'http://public-chain:8845',
        accounts: ['ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80'],
        timeout: 80000,
        chainId: 7331,
        // Public chain (axyl) is non-gasless: there's a 48 Gwei base-fee
        // floor (MIN_RAYLS_PROTOCOL_BASE_FEE). `gasPrice: 0` is rejected as
        // "transaction underpriced". 100 Gwei = comfortable headroom over
        // the floor; deployer is richly funded so the wei cost is irrelevant.
        // Override via LOCAL_PC_GAS_PRICE=<wei> if the floor changes upstream.
        gasPrice: Number(process.env.LOCAL_PC_GAS_PRICE ?? 100000000000)
      },
      localPC: {
        url: 'http://public-chain:8845',
        accounts: ['ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80'],
        timeout: 80000,
        chainId: 7331,
        // See note on localPublicChain — axyl's 48 Gwei base-fee floor
        // requires a positive gasPrice; 100 Gwei is the chosen headroom.
        gasPrice: Number(process.env.LOCAL_PC_GAS_PRICE ?? 100000000000)
      },
      localA: {
        url: 'http://pn-a:8545',
        accounts: ['ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80'],
        timeout: 80000,
        chainId: 12345,
        gasPrice: 0
      },
      localB: {
        url: 'http://pn-b:8546',
        accounts: ['ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80'],
        timeout: 80000,
        chainId: 12346,
        gasPrice: 0
      },
      localC: {
        url: 'http://pn-c:8547',
        accounts: ['ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80'],
        timeout: 80000,
        chainId: 12347,
        gasPrice: 0
      },
      localD: {
        url: 'http://pn-d:8548',
        accounts: ['ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80'],
        timeout: 80000,
        chainId: 12348,
        gasPrice: 0
      },
      localE: {
        url: 'http://pn-e:8549',
        accounts: ['ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80'],
        timeout: 80000,
        chainId: 12349,
        gasPrice: 0
      },
      localF: {
        url: 'http://pn-f:8550',
        accounts: ['ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80'],
        timeout: 80000,
        chainId: 12350,
        gasPrice: 0
      },
    };

    // Add custom_pnh    };

    // Add custom_pnh network if PNH_RPC_URL is available
    if (process.env['PNH_RPC_URL']) {
      networks.custom_pnh = {
        url: process.env['PNH_RPC_URL']!,
        accounts: [process.env['PRIVATE_KEY_SYSTEM']!],
        timeout: 80000,
        chainId: +process.env['PNH_CHAIN_ID']!,
        gasPrice: 0,
        initialBaseFeePerGas: 0
      };
    }

    // Add custom_pn network if PRIVACY_NODE_RPC_URL is available
    if (process.env['PRIVACY_NODE_RPC_URL']) {
      networks.custom_pn = {
        url: process.env['PRIVACY_NODE_RPC_URL']!,
        accounts: [process.env['PRIVATE_KEY_SYSTEM']!],
        timeout: 80000,
        chainId: +process.env['PRIVACY_NODE_CHAIN_ID']!,
        gasPrice: 0,
        initialBaseFeePerGas: 0
      };
    }

    // Add public chain network if PUBLIC_CHAIN_RPC_URL is available
    if (process.env['PUBLIC_CHAIN_RPC_URL']) {
      // Deploy to a self-provided public chain with the funded public-chain key
      // (PUBLIC_CHAIN_PRIVATE_KEY), falling back to PRIVATE_KEY_SYSTEM when it
      // isn't set. On a non-gasless external chain the signer must actually hold
      // funds, so prefer a dedicated PUBLIC_CHAIN_PRIVATE_KEY there. Normalize
      // the 0x prefix (the key may be provided without it).
      const pcKey = (process.env['PUBLIC_CHAIN_PRIVATE_KEY'] || process.env['PRIVATE_KEY_SYSTEM'] || '').trim();

      // Fail here rather than let hardhat build an unusable network. An unset
      // chain id becomes NaN and an unset key becomes the account '0x'; both
      // are accepted at config load and only surface much later, as an error
      // that names neither variable.
      const pcChainId = Number(process.env['PUBLIC_CHAIN_ID']);
      if (!Number.isInteger(pcChainId) || pcChainId <= 0) {
        throw new Error(
          `PUBLIC_CHAIN_RPC_URL is set but PUBLIC_CHAIN_ID is ${process.env['PUBLIC_CHAIN_ID'] === undefined ? 'not set' : `"${process.env['PUBLIC_CHAIN_ID']}"`} — the public_chain network needs both.`
        );
      }
      if (!pcKey) {
        throw new Error(
          'PUBLIC_CHAIN_RPC_URL is set but neither PUBLIC_CHAIN_PRIVATE_KEY nor PRIVATE_KEY_SYSTEM is configured — the public_chain network has no account to sign with.'
        );
      }

      // Same reasoning as the chain id: a non-numeric override becomes NaN,
      // which hardhat only rejects later, at task invocation. An empty value
      // counts as unset — `??` would let it through as 0, which this chain
      // rejects as underpriced.
      const pcGasPriceRaw = (process.env['PUBLIC_CHAIN_GAS_PRICE'] ?? '').trim();
      const pcGasPrice = pcGasPriceRaw === '' ? 100000000000 : Number(pcGasPriceRaw);
      if (!Number.isFinite(pcGasPrice) || pcGasPrice <= 0) {
        throw new Error(
          `PUBLIC_CHAIN_GAS_PRICE must be a number in wei (got "${process.env['PUBLIC_CHAIN_GAS_PRICE']}").`
        );
      }

      networks.public_chain = {
        url: process.env['PUBLIC_CHAIN_RPC_URL']!,
        accounts: [pcKey.startsWith('0x') ? pcKey : '0x' + pcKey],
        timeout: 80000,
        chainId: pcChainId,
        // The public chain is NON-gasless (EIP-1559 base-fee floor), exactly like the
        // local public chain (localPC). gasPrice: 0 is rejected as "underpriced", so use
        // a positive legacy gasPrice. Override via PUBLIC_CHAIN_GAS_PRICE=<wei>.
        gasPrice: pcGasPrice
      };
    }

    return networks;
  })(),
  contractSizer: {
    alphaSort: true,
    runOnCompile: false,
    disambiguatePaths: false
  },
  mocha: {
    timeout: 40000,
    reporter: process.env.CI ? 'mocha-junit-reporter' : 'spec',
    reporterOptions: {
      mochaFile: './test-results.xml',
      toConsole: true
    }
  }
};
export default config;
