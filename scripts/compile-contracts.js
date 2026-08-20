#!/usr/bin/env node

const { execSync } = require('child_process');
const path = require('path');
const glob = require('glob');
const fs = require('fs');

/**
 * Script for compiling Solidity contracts by subsets
 * Replaces the Hardhat compile-subset task for Docker usage
 */

// Compilation configuration based on Dockerfile.dev
const COMPILATION_STEPS = [
  {
    name: "MessageDispatcher.sol",
    patterns: ["src/MessageDispatcher.sol"]
  },
  {
    name: "SignatureStorage.sol and TokenLocker.sol", 
    patterns: ["src/SignatureStorage.sol", "src/TokenLocker.sol"]
  },
  {
    name: "privateHub directory",
    patterns: ["src/privateHub/**/*.sol"]
  },
  {
    name: "dvp directory",
    patterns: ["src/dvp/**/*.sol"]
  },
  {
    name: "lib directory", 
    patterns: ["src/lib/**/*.sol"]
  },
  {
    name: "rayls-node privacy-node directory",
    patterns: ["src/rayls-node/rayls-privacy-node/**/*.sol"]
  },
  {
    name: "rayls-protocol interfaces",
    patterns: ["src/rayls-protocol/interfaces/**/*.sol"]
  },
  {
    name: "rayls-protocol utils",
    patterns: ["src/rayls-protocol/utils/**/*.sol"] 
  },
  {
    name: "rayls-protocol DeploymentProxyRegistry",
    patterns: ["src/rayls-protocol/DeploymentProxyRegistry/**/*.sol"]
  },
  {
    name: "rayls-protocol Endpoint", 
    patterns: ["src/rayls-protocol/Endpoint/**/*.sol"]
  },
  {
    name: "rayls-protocol Enygma",
    patterns: ["src/rayls-protocol/Enygma/**/*.sol"]
  },
  {
    name: "rayls-protocol Node",
    patterns: ["src/rayls-protocol/Node/**/*.sol"]
  },
  {
    name: "rayls-protocol PNCommunicator",
    patterns: ["src/rayls-protocol/PNCommunicator/**/*.sol"]
  },
  {
    name: "rayls-protocol ParticipantStorageReplica",
    patterns: ["src/rayls-protocol/ParticipantStorageReplica/**/*.sol"]
  },
  {
    name: "rayls-protocol RaylsContractFactory",
    patterns: ["src/rayls-protocol/RaylsContractFactory/**/*.sol"]
  },
  {
    name: "rayls-protocol RaylsMessageExecutor",
    patterns: ["src/rayls-protocol/RaylsMessageExecutor/**/*.sol"]
  },
  {
    name: "rayls-protocol Dvp",
    patterns: ["src/rayls-protocol/Dvp/**/*.sol"]
  },
    {
    name: "rayls-protocol modules",
    patterns: ["src/rayls-protocol/modules/**/*.sol"]
  },
  {
    name: "rayls-protocol test-contracts",
    patterns: ["src/rayls-protocol/test-contracts/**/*.sol"]
  },
  {
    name: "rayls-protocol-sdk directory",
    patterns: ["src/rayls-protocol-sdk/**/*.sol"]
  },
  {
    name: "rayls-node directory",
    patterns: ["src/rayls-node/**/*.sol"]
  },
];


function resolveGlobPatterns(patterns) {
  let resolvedFiles = [];
  
  for (const pattern of patterns) {
    if (pattern.includes('*')) {
      // It's a glob pattern
      const matches = glob.sync(path.resolve(pattern), { cwd: process.cwd() });
      resolvedFiles.push(...matches);
    } else {
      // It's a direct file
      const resolved = path.resolve(pattern);
      if (fs.existsSync(resolved)) {
        resolvedFiles.push(resolved);
      }
    }
  }
  
  // Filter only .sol files
  resolvedFiles = resolvedFiles.filter(file => file.endsWith('.sol'));
  
  return resolvedFiles;
}


function compileSubset(stepName, patterns) {
  console.log(`📁 Compiling ${stepName}`);
  
  const resolvedFiles = resolveGlobPatterns(patterns);
  
  if (resolvedFiles.length === 0) {
    console.warn(`⚠️  No .sol files found for: ${stepName}`);
    console.warn(`   Patterns searched: ${patterns.join(', ')}`);
    return;
  }
  
  console.log(`🔍 Found ${resolvedFiles.length} files to compile:`);
  resolvedFiles.forEach(file => {
    console.log(`   • ${path.relative(process.cwd(), file)}`);
  });
  
  try {
    const quotedFiles = patterns.map(p => `"${p}"`).join(' ');
    const command = `npx hardhat compile-subset ${quotedFiles}`;
    
    console.log(`🔨 Running: ${command}`);
    
    const startTime = Date.now();
    execSync(command, { 
      stdio: 'inherit', 
      cwd: process.cwd(),
      env: process.env
    });
    const duration = ((Date.now() - startTime) / 1000).toFixed(2);
    
    console.log(`✅ Compilation for ${stepName} finished successfully in ${duration}s`);
  } catch (error) {
    console.error(`❌ Error during compilation of ${stepName}:`);
    console.error(`   Command: ${command}`);
    console.error(`   Error: ${error.message}`);
    process.exit(1);
  }
}


async function compileSubsetAsync(stepName, patterns) {
  return new Promise((resolve, reject) => {
    console.log(`📁 Compiling ${stepName}`);
    
    const resolvedFiles = resolveGlobPatterns(patterns);
    
    if (resolvedFiles.length === 0) {
      console.warn(`⚠️  No .sol files found for: ${stepName}`);
      console.warn(`   Patterns searched: ${patterns.join(', ')}`);
      resolve();
      return;
    }
    
    console.log(`🔍 Found ${resolvedFiles.length} files to compile:`);
    resolvedFiles.forEach(file => {
      console.log(`   • ${path.relative(process.cwd(), file)}`);
    });
    
    try {
      const quotedFiles = patterns.map(p => `"${p}"`).join(' ');
      const command = `npx hardhat compile-subset ${quotedFiles}`;
      
      console.log(`🔨 Running: ${command}`);
      
      const startTime = Date.now();
      execSync(command, { 
        stdio: 'inherit', 
        cwd: process.cwd(),
        env: process.env
      });
      const duration = ((Date.now() - startTime) / 1000).toFixed(2);
      
      console.log(`✅ Compilation for ${stepName} finished successfully in ${duration}s`);
      resolve();
    } catch (error) {
      console.error(`❌ Error during compilation of ${stepName}:`);
      console.error(`   Command: ${command}`);
      console.error(`   Error: ${error.message}`);
      reject(error);
    }
  });
}

async function main() {
  console.log('🚀 Starting contract compilation process...');
  console.log(`Working directory: ${process.cwd()}`);
  
 
  try {
    execSync('npx hardhat --version', { stdio: 'pipe' });
  } catch (error) {
    console.error('❌ Hardhat not found. Make sure it is installed.');
    process.exit(1);
  }
  
  const startTime = Date.now();
  
  // Check if parallel compilation is requested
  const isParallel = process.argv.includes('--parallel');
  
  if (isParallel) {
    console.log('⚡ Running parallel compilation...');
    
    const compilationPromises = COMPILATION_STEPS.map(async (step, i) => {
      console.log(`\n📦 Step ${i + 1}/${COMPILATION_STEPS.length}: ${step.name}`);
      try {
        await compileSubsetAsync(step.name, step.patterns);
        return { success: true, name: step.name };
      } catch (error) {
        console.error(`❌ Failed to compile ${step.name}:`, error.message);
        return { success: false, name: step.name, error: error.message };
      }
    });
    
    const results = await Promise.all(compilationPromises);
    const failedCompilations = results.filter(r => !r.success);
    
    if (failedCompilations.length > 0) {
      console.error(`❌ ${failedCompilations.length} compilations failed:`);
      failedCompilations.forEach(f => console.error(`  - ${f.name}: ${f.error}`));
      process.exit(1);
    }
    
    const successfulCompilations = results.filter(r => r.success).length;
    const endTime = Date.now();
    const duration = ((endTime - startTime) / 1000).toFixed(2);
    
    console.log(`🎉 All compilations completed successfully!`);
    console.log(`📊 Summary:`);
    console.log(`  - Total steps: ${COMPILATION_STEPS.length}`);
    console.log(`  - Successful: ${successfulCompilations}`);
    console.log(`  - Duration: ${duration}s`);
  } else {
    console.log('🔄 Running sequential compilation...');
    let successfulCompilations = 0;
    
    for (let i = 0; i < COMPILATION_STEPS.length; i++) {
      const step = COMPILATION_STEPS[i];
      console.log(`\\n📦 Step ${i + 1}/${COMPILATION_STEPS.length}: ${step.name}`);
      
      try {
        compileSubset(step.name, step.patterns);
        successfulCompilations++;
      } catch (error) {
        console.error(`❌ Failed to compile ${step.name}:`, error.message);
        process.exit(1);
      }
    }
    
    const endTime = Date.now();
    const duration = ((endTime - startTime) / 1000).toFixed(2);
    
    console.log(`🎉 All compilations completed successfully!`);
    console.log(`📊 Summary:`);
    console.log(`  - Total steps: ${COMPILATION_STEPS.length}`);
    console.log(`  - Successful: ${successfulCompilations}`);
    console.log(`  - Duration: ${duration}s`);
  }
}

// Execute if called directly
if (require.main === module) {
  main().catch(console.error);
}

module.exports = { compileSubset, resolveGlobPatterns, COMPILATION_STEPS };