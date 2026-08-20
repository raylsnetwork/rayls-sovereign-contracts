// scripts/forge-to-hardhat.ts
import fs from "fs";
import path from "path";
import crypto from "crypto";

const forgeOutDir = path.join(__dirname, "..", "out");
const forgeCacheFile = path.join(__dirname, "..", "cache_forge", "solidity-files-cache.json");

const hardhatArtifactsDir = path.join(__dirname, "..", "artifacts");
const buildInfoDir = path.join(hardhatArtifactsDir, "build-info");
const hardhatCacheDir = path.join(__dirname, "..", "cache_hardhat");
const hardhatCacheFile = path.join(hardhatCacheDir, "solidity-files-cache.json");

interface ForgeArtifact {
  abi: any[];
  bytecode?: {
    object: string;
    opcodes?: string;
    sourceMap?: string;
    linkReferences?: any;
  };
  deployedBytecode?: {
    object: string;
    opcodes?: string;
    sourceMap?: string;
    linkReferences?: any;
    immutableReferences?: any;
  };
  methodIdentifiers?: any;
  metadata?: string | object;
}

function normalizeSourceName(p: string): string {
  let s = p.replace(/\\/g, "/");
  if (s.startsWith("node_modules/")) s = s.replace(/^node_modules\//, "");
  return s;
}

function extractSourceName(
  forgeArtifact: ForgeArtifact,
  contractName: string,
  defaultFile: string
): string {
  if (forgeArtifact.metadata) {
    try {
      const meta =
        typeof forgeArtifact.metadata === "string"
          ? JSON.parse(forgeArtifact.metadata)
          : (forgeArtifact.metadata as any);

      const targets = meta.settings?.compilationTarget ?? {};
      for (const [sourcePath, name] of Object.entries(targets)) {
        if (name === contractName) {
          return sourcePath;
        }
      }
    } catch (err) {
      console.warn(`⚠️ Failed to parse metadata for ${contractName}: ${(err as Error).message}`);
    }
  }
  return path.join("src", defaultFile);
}

function convertAll() {
  // Clean artifacts and cache_hardhat directories first
  if (fs.existsSync(hardhatArtifactsDir)) {
    fs.rmSync(hardhatArtifactsDir, { recursive: true, force: true });
    console.log(`🧹 Deleted existing artifacts directory`);
  }
  if (fs.existsSync(hardhatCacheDir)) {
    fs.rmSync(hardhatCacheDir, { recursive: true, force: true });
    console.log(`🧹 Deleted existing cache_hardhat directory`);
  }

  let solcLongVersion: string | null = null;
  let mergedLanguage: string | null = null;
  let mergedSettings: any = null;

  const mergedSources: Record<string, any> = {};
  const mergedContracts: Record<string, any> = {};

  const files = fs.readdirSync(forgeOutDir);
  for (const file of files) {
    if (!file.endsWith(".sol")) continue;

    const contractDir = path.join(forgeOutDir, file);
    const contractJsons = fs.readdirSync(contractDir).filter((f) => f.endsWith(".json"));

    for (const jsonFile of contractJsons) {
      const contractName = path.basename(jsonFile, ".json");
      const forgeArtifactPath = path.join(contractDir, jsonFile);
      const forgeArtifact: ForgeArtifact = JSON.parse(fs.readFileSync(forgeArtifactPath, "utf8"));

      let meta: any = null;
      if (forgeArtifact.metadata) {
        meta =
          typeof forgeArtifact.metadata === "string"
            ? JSON.parse(forgeArtifact.metadata)
            : forgeArtifact.metadata;
      }

      if (meta) {
        mergedLanguage = mergedLanguage || meta.language;
        mergedSettings = mergedSettings || meta.settings;
        solcLongVersion = solcLongVersion || meta.compiler?.version;

        if (meta.sources) {
          for (const [srcPath, srcInfo] of Object.entries<any>(meta.sources)) {
            const norm = normalizeSourceName(srcPath);
            mergedSources[norm] = mergedSources[norm] || {};
            Object.assign(mergedSources[norm], srcInfo);
          }
        }
      }

      let sourceName = extractSourceName(forgeArtifact, contractName, file);
      sourceName = normalizeSourceName(sourceName);

      const hhArtifact = {
        _format: "hh-sol-artifact-1",
        contractName,
        sourceName,
        abi: forgeArtifact.abi,
        bytecode: forgeArtifact.bytecode?.object || "0x",
        deployedBytecode: forgeArtifact.deployedBytecode?.object || "0x",
        linkReferences: forgeArtifact.bytecode?.linkReferences || {},
        deployedLinkReferences: forgeArtifact.deployedBytecode?.linkReferences || {},
      };

      const outDir = path.join(hardhatArtifactsDir, sourceName);
      fs.mkdirSync(outDir, { recursive: true });
      const outPath = path.join(outDir, `${contractName}.json`);
      fs.writeFileSync(outPath, JSON.stringify(hhArtifact, null, 2));
      console.log(`✅ Converted ${contractName} → ${outPath}`);

      mergedContracts[sourceName] = mergedContracts[sourceName] || {};
      mergedContracts[sourceName][contractName] = {
        abi: forgeArtifact.abi,
        evm: {
          bytecode: {
            object: forgeArtifact.bytecode?.object || "0x",
            opcodes: forgeArtifact.bytecode?.opcodes || "",
            sourceMap: forgeArtifact.bytecode?.sourceMap || "",
            linkReferences: forgeArtifact.bytecode?.linkReferences || {},
          },
          deployedBytecode: {
            object: forgeArtifact.deployedBytecode?.object || "0x",
            opcodes: forgeArtifact.deployedBytecode?.opcodes || "",
            sourceMap: forgeArtifact.deployedBytecode?.sourceMap || "",
            linkReferences: forgeArtifact.deployedBytecode?.linkReferences || {},
            immutableReferences: forgeArtifact.deployedBytecode?.immutableReferences || {},
          },
          methodIdentifiers: forgeArtifact.methodIdentifiers || {},
        },
      };
    }
  }

  // Populate content field for all sources - Hardhat requires this
  console.log(`\n🔍 Populating content field for all sources...`);
  let missingCount = 0;
  let addedCount = 0;
  
  for (const [srcPath, srcInfo] of Object.entries(mergedSources)) {
    if (!srcInfo.content) {
      missingCount++;
      // Try multiple path resolution strategies
      const possiblePaths = [
        path.resolve(__dirname, "..", srcPath),
        path.resolve(__dirname, "..", "src", srcPath),
        path.resolve(__dirname, "..", srcPath.replace(/^src\//, "")),
      ];
      
      let contentFound = false;
      for (const fullPath of possiblePaths) {
        if (fs.existsSync(fullPath)) {
          try {
            srcInfo.content = fs.readFileSync(fullPath, "utf8");
            addedCount++;
            contentFound = true;
            console.log(`  ✅ Added content for ${srcPath}`);
            break;
          } catch (err) {
            // Try next path
          }
        }
      }
      
      if (!contentFound) {
        console.warn(`  ⚠️ Could not find source file for ${srcPath}`);
        // Set empty content as fallback to prevent Hardhat error
        srcInfo.content = "";
      }
    }
  }
  
  console.log(`📊 Sources summary: ${missingCount} missing content, ${addedCount} added, ${missingCount - addedCount} still missing\n`);

  // Build-info
  if (solcLongVersion && mergedLanguage && mergedSettings) {
    const solcVersion = solcLongVersion.split("+")[0];
    
    // Ensure outputSelection is present for Hardhat compatibility
    if (!mergedSettings.outputSelection) {
      mergedSettings.outputSelection = {
        "*": {
          "*": [
            "abi",
            "evm.bytecode",
            "evm.deployedBytecode",
            "evm.methodIdentifiers",
            "metadata"
          ],
          "": ["ast"]
        }
      };
    }
    
    const input = { language: mergedLanguage, settings: mergedSettings, sources: mergedSources };
    const output = {
      contracts: mergedContracts,
      sources: {},  // Hardhat expects this even if empty
      errors: []    // Hardhat expects this even if empty
    };
    const id = crypto.createHash("sha1").update(JSON.stringify(input)).digest("hex");

    const buildInfo = {
      id,
      _format: "hh-sol-build-info-1",
      solcVersion,
      solcLongVersion,
      input,
      output,
    };

    fs.mkdirSync(buildInfoDir, { recursive: true });
    const outPath = path.join(buildInfoDir, `${id}.json`);
    fs.writeFileSync(outPath, JSON.stringify(buildInfo, null, 2));
    console.log(`📝 Wrote merged build-info → ${outPath}`);
  }

  // Hardhat cache from Forge cache
  if (fs.existsSync(forgeCacheFile)) {
    const forgeCache = JSON.parse(fs.readFileSync(forgeCacheFile, "utf8"));
    const hhCache: any = { files: {} };

    for (const [srcPath, entry] of Object.entries<any>(forgeCache)) {
      const norm = normalizeSourceName(srcPath);
      hhCache.files[norm] = {
        lastModificationDate: entry.lastModificationDate,
        contentHash: entry.contentHash,
        sourceName: norm,
        artifacts: entry.artifacts || [],
      };
    }

    fs.mkdirSync(hardhatCacheDir, { recursive: true });
    fs.writeFileSync(hardhatCacheFile, JSON.stringify(hhCache, null, 2));
    console.log(`🗂️ Wrote Hardhat cache → ${hardhatCacheFile}`);
  } else {
    console.warn("⚠️ Forge cache not found, Hardhat cache not generated");
  }
}

convertAll();