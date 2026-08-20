const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const fsp = require('fs/promises');

const relayerContracts = [
  'src/rayls-protocol/Enygma/Enygma-Payments/EnygmaV1.sol',
  'src/rayls-protocol/Enygma/Enygma-DVP/DvpTeleport.sol',
  'src/rayls-protocol/interfaces/IEnygmaDvpIntegration.sol',
  'src/privateHub/Teleport/TeleportV1.sol',
  'src/privateHub/ParticipantStorage/ParticipantStorageV1.sol',
  'src/privateHub/ParticipantStorage/modules/AuditManager/AuditManagerV1.sol',
  'src/rayls-protocol/Enygma/Enygma-DVP/DvpErc1155PNH.sol',
  'src/rayls-protocol/Enygma/Enygma-DVP/DvpErc721PNH.sol',
  'src/rayls-protocol/PNCommunicator/PNCommunicatorV1.sol',
  'src/rayls-protocol/ParticipantStorageReplica/ParticipantStorageReplicaV1.sol',
  'src/privateHub/TemplateRegistry/TemplateRegistryV1.sol',
  'src/rayls-protocol/TemplateRegistryReplica/TemplateRegistryReplicaV1.sol',
  'src/rayls-protocol/ProgrammabilityExecutor/ProgrammabilityExecutorV1.sol',
  'src/privateHub/Proofs/Proofs.sol',
  'src/privateHub/ResourceRegistry/ResourceRegistryV1.sol',
  'src/rayls-protocol/TokenRegistry/PNTokenRegistryV1.sol',
  'src/rayls-protocol/TokenRegistry/modules/TokenCore/PNTokenCoreV1.sol',
  'src/rayls-protocol/TokenRegistry/modules/TokenFreezeManager/PNTokenFreezeManagerV1.sol',
  'src/rayls-protocol/Endpoint/EndpointV1.sol',
  'src/rayls-protocol/Enygma/Enygma-Payments/EnygmaPNEvents.sol',
  'src/rayls-protocol/DeploymentProxyRegistry/DeploymentProxyRegistryV1.sol',
  'src/rayls-protocol-sdk/contracts/EnygmaPNHEvents.sol',
  'src/rayls-protocol/Enygma/Enygma-Payments/EnygmaDvpIntegration.sol',
  'src/rayls-protocol-sdk/tokens/RaylsEnygmaHandler.sol',
  'src/rayls-protocol-sdk/tokens/RaylsErc1155DvpHandler.sol',
  'src/rayls-protocol-sdk/tokens/RaylsErc721DvpHandler.sol',
  'src/rayls-protocol/Enygma/Enygma-DVP/Dvp.sol',
  'src/rayls-protocol/Enygma/Enygma-Payments/EnygmaTeleport.sol',
  // Access control
  'src/privateHub/AccessControl/RaylsAccessManagerV1.sol',
  // Rayls Node contracts
  'src/rayls-node/rayls-privacy-node/RNEndpointV1.sol',
  'src/rayls-node/rayls-privacy-node/PublicRNEndpointV1.sol',
  'src/rayls-node/rayls-privacy-node/RNMessageDispatcherV1.sol',
  'src/rayls-node/rayls-privacy-node/RNUserGovernanceV1.sol',
  'src/rayls-node/rayls-public-chain/tokens/PublicChainERC1155.sol',
  'src/rayls-node/rayls-public-chain/tokens/PublicChainERC20.sol',
  'src/rayls-node/rayls-public-chain/tokens/PublicChainERC721.sol',
];

const governanceContracts = [
  // Core contracts processed by BlockProcessor
  'src/privateHub/Teleport/TeleportV1.sol',
  'src/rayls-protocol/Enygma/Enygma-Payments/EnygmaTeleport.sol',
  'src/rayls-protocol/Enygma/Enygma-DVP/DvpTeleport.sol',
  'src/privateHub/TokenRegistry/modules/EnygmaTokenManager/EnygmaTokenManagerV1.sol',
  'src/privateHub/TokenRegistry/modules/TokenCore/TokenCoreV1.sol',
  'src/privateHub/ParticipantStorage/modules/ParticipantCore/ParticipantCoreV1.sol',
  'src/privateHub/ParticipantStorage/modules/AuditManager/AuditManagerV1.sol',
  'src/privateHub/ParticipantStorage/ParticipantStorageV1.sol',
  'src/privateHub/TokenRegistry/TokenRegistryV1.sol',
  'src/rayls-protocol/DeploymentProxyRegistry/DeploymentProxyRegistryV1.sol',
  'src/privateHub/Proofs/Proofs.sol',
  'src/privateHub/TokenRegistry/modules/TokenFreezeManager/TokenFreezeManagerV1.sol'
];

const opsServicesContracts = [
  'src/rayls-protocol/RaylsContractFactory/AbstractContractFactoryV1.sol',
  'src/rayls-protocol/DeploymentProxyRegistry/DeploymentProxyRegistryV1.sol',
  'src/privateHub/AccessControl/RaylsAccessManagerV1.sol',
  'src/rayls-node/rayls-privacy-node/RNEndpointV1.sol',
  'src/rayls-protocol/TokenRegistry/PNTokenRegistryV1.sol',
  'src/rayls-protocol/TokenRegistry/modules/TokenCore/PNTokenCoreV1.sol',
  'src/rayls-protocol/TokenRegistry/modules/TokenFreezeManager/PNTokenFreezeManagerV1.sol',
  'src/rayls-node/rayls-privacy-node/RNUserGovernanceV1.sol',
  'src/rayls-node/rayls-privacy-node/RNMessageDispatcherV1.sol',
  'src/rayls-node/rayls-privacy-node/RNMessageExecutorV1.sol',
  'src/rayls-node/rayls-privacy-node/RNContractFactoryV1.sol',
  'src/rayls-node/rayls-privacy-node/RNMessageLib.sol',
  'src/rayls-node/rayls-privacy-node/RNReentrancyGuardV1.sol',
 ];

// Verify command line arguments
const args = process.argv.slice(2);
const contractType = args[0];

if (!contractType || (contractType !== 'relayer' && contractType !== 'governance' && contractType !== 'ops-service')) {
  console.log('❌ Usage: node generate-bindings.js [relayer|governance|ops-service]');
  console.log('');
  console.log('Examples:');
  console.log('  node generate-bindings.js relayer     # Generate bindings for relayer contracts');
  console.log('  node generate-bindings.js governance  # Generate bindings for governance contracts');
  console.log('  node generate-bindings.js ops-service # Generate bindings for ops-service contracts');
  process.exit(1);
}

// Select contracts based on the contract type
const contracts = contractType === 'relayer' ? relayerContracts : contractType === 'governance' ? governanceContracts : opsServicesContracts ;

console.log(`📋 Generating bindings to ${contractType} (${contracts.length} contracts) — abigen v2`);

const bindingsDir = './bindings';
const artifactsDir = './artifacts';
const foundryOutDir = './out';

function getArtifactPath(sourceName, contractName) {
  const hardhatArtifactPath = path.join(artifactsDir, sourceName, `${contractName}.json`);
  if (fs.existsSync(hardhatArtifactPath)) {
    return hardhatArtifactPath;
  }

  // No source-name overrides are needed: the PN TokenRegistry contracts are now
  // PN-prefixed (PNTokenRegistryV1/PNTokenCoreV1/PNTokenFreezeManagerV1), so their
  // Foundry artifacts land at flat, unambiguous paths handled by the fallback below.
  const foundryCandidatesBySourceName = {};

  const foundryCandidates = [...(foundryCandidatesBySourceName[sourceName] || [])];
  foundryCandidates.push(path.join(foundryOutDir, `${contractName}.sol`, `${contractName}.json`));

  return foundryCandidates.find((candidate) => fs.existsSync(candidate)) || null;
}

function normalizeArtifact(artifact, sourceName, contractName) {
  artifact.sourceName = artifact.sourceName || sourceName;
  artifact.contractName = artifact.contractName || contractName;
  artifact.linkReferences = artifact.linkReferences || artifact.bytecode?.linkReferences || {};
  return artifact;
}

function getBytecode(artifact) {
  if (typeof artifact.bytecode === 'string') {
    return artifact.bytecode;
  }

  return artifact.bytecode?.object || '';
}

function readArtifactByPath(sourceName, contractName) {
  const p = getArtifactPath(sourceName, contractName);
  if (!p || !fs.existsSync(p)) return null;
  return normalizeArtifact(JSON.parse(fs.readFileSync(p, 'utf8')), sourceName, contractName);
}

// Recursively walks linkReferences to collect every transitive library
// artifact the contract depends on. Throws if any artifact is missing.
function collectLibraryArtifacts(artifact, seen = new Set()) {
  const libs = [];
  const linkRefs = artifact.linkReferences || {};
  for (const [sourceName, libsByName] of Object.entries(linkRefs)) {
    for (const libName of Object.keys(libsByName)) {
      const key = `${sourceName}:${libName}`;
      if (seen.has(key)) continue;
      seen.add(key);
      const libArtifact = readArtifactByPath(sourceName, libName);
      if (!libArtifact) {
        throw new Error(`Library artifact not found for dependency ${key}. Run 'npx hardhat compile' first.`);
      }
      libs.push(libArtifact);
      libs.push(...collectLibraryArtifacts(libArtifact, seen));
    }
  }
  return libs;
}

function buildCombinedJson(mainArtifact, libraryArtifacts) {
  const contracts = {};

  // ParseCombinedJSON in go-ethereum unconditionally json.Unmarshal's the
  // abi/userdoc/devdoc fields as strings; missing fields fail with
  // "unexpected end of JSON input". Provide empty stubs where unused.
  const mainBin = getBytecode(mainArtifact);
  contracts[`${mainArtifact.sourceName}:${mainArtifact.contractName}`] = {
    abi: JSON.stringify(mainArtifact.abi),
    bin: mainBin.startsWith('0x') ? mainBin.slice(2) : mainBin,
    userdoc: '{}',
    devdoc: '{}',
  };

  // Library deps are included only so abigen can populate its libs map and
  // emit qualified Deps references. We pass an empty ABI so abigen generates
  // only their MetaData var (with the correct keccak256 ID derived from the
  // sourceName:contractName key) — no method bindings, no Pack/Unpack output
  // structs that would collide with the main contract on shared method names
  // like canCall/hasRole. Bytecode is also unused by abigen for dep entries.
  for (const lib of libraryArtifacts) {
    contracts[`${lib.sourceName}:${lib.contractName}`] = {
      abi: '[]',
      bin: '',
      userdoc: '{}',
      devdoc: '{}',
    };
  }
  return JSON.stringify({ contracts, version: '0.8.24' });
}

async function runAbigenWithChildProcess(abigenArgs) {
  return new Promise((resolve, reject) => {
    const argsJson = JSON.stringify(abigenArgs);
    const childProcess = spawn('node', [
      '-e', `
        const fs = require('fs');
        const path = require('path');
        require('./node_modules/@solarity/hardhat-gobind/src/abigen/wasm/wasm_exec_node');
        const fsp = require('fs/promises');

        async function runAbigen() {
          try {
            const Go = globalThis.Go;
            const go = new Go();
            go.argv = ['abigen', ...${argsJson}];
            go.env = Object.assign({ TMPDIR: require('os').tmpdir() }, process.env);

            const abigenPath = './node_modules/@solarity/hardhat-gobind/bin/abigen.wasm';
            const wasmBuffer = await fsp.readFile(abigenPath);
            const abigenObj = await WebAssembly.instantiate(wasmBuffer, go.importObject);

            await go.run(abigenObj.instance);
            process.exit(0);
          } catch (error) {
            console.error('Error in child process:', error.message);
            process.exit(1);
          }
        }

        runAbigen();
      `
    ], {
      stdio: ['pipe', 'pipe', 'pipe'],
      cwd: process.cwd()
    });

    let stdout = '';
    let stderr = '';

    childProcess.stdout.on('data', (data) => {
      stdout += data.toString();
    });

    childProcess.stderr.on('data', (data) => {
      stderr += data.toString();
    });

    childProcess.on('close', (code) => {
      if (code === 0) {
        resolve();
      } else {
        reject(new Error(`Child process failed with code ${code}. Stderr: ${stderr}`));
      }
    });

    childProcess.on('error', (error) => {
      reject(error);
    });
  });
}

// Create directory for bindings if it doesn't exist
if (!fs.existsSync(bindingsDir)) {
  fs.mkdirSync(bindingsDir, { recursive: true });
}

// Process each contract to generate bindings
async function generateBindings() {

  // Remove all files from bindingsDir
  console.log('🧹 Cleaning bindings directory...');
  fs.readdirSync(bindingsDir).forEach(file => {
    const filePath = path.join(bindingsDir, file);
    const stats = fs.statSync(filePath);

    if (stats.isDirectory()) {
      // Remove directory recursively
      fs.rmSync(filePath, { recursive: true, force: true });
    } else {
      // Remove file
      fs.unlinkSync(filePath);
    }
  });
  console.log('🧹 ✅ Cleaning bindings directory... done');

  const processContract = async (contract) => {
    console.log(`🔍 Processing: ${contract}`);

    // Build path to the JSON file in artifacts
    const contractName = path.basename(contract, '.sol');
    const artifactPath = getArtifactPath(contract, contractName);

    if (!artifactPath) {
      throw new Error(`Artifact not found for ${contract}`);
    }

    const artifactContent = fs.readFileSync(artifactPath, 'utf8');
    const artifact = normalizeArtifact(JSON.parse(artifactContent), contract, contractName);

    if (!artifact.abi) {
      throw new Error(`ABI not found in artifact ${contract}`);
    }

    const abiPath = path.join(bindingsDir, `${contractName}.abi`);
    const binPath = path.join(bindingsDir, `${contractName}.bin`);
    const jsonPath = path.join(bindingsDir, `${contractName}.combined.json`);
    const goPath = path.join(bindingsDir, `${contractName}.go`);

    const packageName = contractName.replaceAll('-', '').replaceAll('_', '');
    const hasLibDeps = artifact.linkReferences && Object.keys(artifact.linkReferences).length > 0;

    try {
      // Contracts that link external libraries (Solidity `library` with public/external
      // functions) require --combined-json so abigen v2 can populate the libs map and
      // emit valid Deps entries. With --abi/--bin alone, the libs map is empty and the
      // generated Deps reference is broken (`&MetaData` with no qualifier). See
      // accounts/abi/abigen/bindv2.go in go-ethereum.
      if (hasLibDeps) {
        const libArtifacts = collectLibraryArtifacts(artifact);
        fs.writeFileSync(jsonPath, buildCombinedJson(artifact, libArtifacts));

        const args = [
          '--v2',
          '--combined-json', jsonPath,
          '--pkg', packageName,
          '--out', goPath,
        ];
        console.log(`⚒️  Executing: abigen ${args.join(' ')} (with ${libArtifacts.length} library deps)`);
        await runAbigenWithChildProcess(args);
      } else {
        fs.writeFileSync(abiPath, JSON.stringify(artifact.abi, null, 2));
        const bytecode = getBytecode(artifact);
        if (bytecode) {
          fs.writeFileSync(binPath, bytecode);
        }
        const args = [
          '--v2',
          '--abi', abiPath,
          '--bin', binPath,
          '--pkg', packageName,
          '--type', contractName,
          '--out', goPath,
        ];
        console.log(`⚒️  Executing: abigen ${args.join(' ')}`);
        await runAbigenWithChildProcess(args);
      }

      console.log(`⚒️  ✅ ${contract} processed successfully`);
    } finally {
      // Clean up temporary files regardless of success/failure
      for (const p of [abiPath, binPath, jsonPath]) {
        if (fs.existsSync(p)) fs.unlinkSync(p);
      }
    }
  };

  // Each per-contract promise is wrapped to resolve to a {contract, ok, error}
  // tag instead of rejecting, so Promise.all never short-circuits on the first
  // failure — we want a complete failure report at the end.
  const results = await Promise.all(
    contracts.map((contract) =>
      processContract(contract).then(
        () => ({ contract, ok: true }),
        (error) => ({ contract, ok: false, error })
      )
    )
  );

  const failures = results.filter((r) => !r.ok);
  if (failures.length > 0) {
    console.error(`\n❌ ${failures.length}/${contracts.length} contract(s) failed:`);
    for (const { contract, error } of failures) {
      console.error(`  - ${contract}: ${error.message}`);
    }
    throw new Error(`Binding generation failed for ${failures.length} contract(s)`);
  }
}

generateBindings().then(() => {

  console.log('📁 Organizing .go files in subdirectories...');
  fs.readdirSync(bindingsDir).forEach(file => {
    if (file.endsWith('.go')) {
      const filename = file.slice(0, -3); // remove .go
      const dirPath = path.join(bindingsDir, filename);
      if (!fs.existsSync(dirPath)) {
        fs.mkdirSync(dirPath);
      }
      fs.renameSync(
        path.join(bindingsDir, file),
        path.join(dirPath, file)
      );
    }
  });
  console.log('📁 Organization completed!');
  console.log('🎉 Generation of bindings completed!');
}).catch((error) => {
  console.error(error.message || error);
  process.exitCode = 1;
});
