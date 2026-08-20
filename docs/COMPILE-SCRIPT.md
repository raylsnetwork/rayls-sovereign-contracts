# Contract Compilation Script

This document explains how to use the `compile-contracts.js` script, which replaces the `compile-subset` Hardhat task for use in Docker.

## Overview

The `compile-contracts.js` script was created to replicate the functionality of the custom `compile-subset` task defined in `hardhat.config.ts`. It compiles specific subsets of Solidity contracts, which is useful for:

- Reducing compilation time in Docker
- Avoiding memory issues with large codebases
- Maintaining the same compilation sequence used in Dockerfile.dev

## Usage

### Option 1: Via npm script (Recommended)
```bash
npm run compile:subset
```

### Option 2: Directly with Node.js
```bash
node scripts/compile-contracts.js
```

### Option 3: As an executable
```bash
./scripts/compile-contracts.js
```

## Features

### Step-by-Step Compilation
The script runs compilation in 20 specific steps, following the same order as Dockerfile.dev:

1. MessageDispatcher.sol
2. SignatureStorage.sol and TokenLocker.sol
3. privateHub directory
4. dvp directory
5. lib directory
6. privacy-node directory
7. rayls-protocol interfaces
8. rayls-protocol utils
9. rayls-protocol DeploymentProxyRegistry
10. rayls-protocol Endpoint
11. rayls-protocol Enygma
12. rayls-protocol Node
13. rayls-protocol PNCommunicator
14. rayls-protocol ParticipantStorageReplica
15. rayls-protocol RaylsContractFactory
16. rayls-protocol RaylsMessageExecutor
17. rayls-protocol TokenRegistryReplica
18. rayls-protocol Dvp
19. rayls-protocol test-contracts
20. rayls-protocol-sdk directory

### Detailed Logs
The script provides detailed logs including:
- Number of files found per step
- List of files to be compiled
- Compilation time per step
- Final summary with statistics

### Error Handling
- Dependency verification (Hardhat)
- .sol file validation
- Immediate stop on compilation error
- Detailed error messages

## Code Structure

### Main Functions

- `resolveGlobPatterns(patterns)`: Resolves glob patterns to find .sol files
- `compileSubset(stepName, patterns)`: Compiles a specific set of files
- `main()`: Main function that runs all steps

### Configuration
The compilation steps are defined in the `COMPILATION_STEPS` constant, which can be modified as needed.

## Docker

### Alternative Dockerfile
A `Dockerfile.dev.alternative` was created that uses this script:

```dockerfile
# Replaces all npx hardhat compile-subset calls with:
RUN npm run compile:subset
```

### Docker Usage
```bash
# Build using the alternative Dockerfile
docker build -f Dockerfile.dev.alternative -t rayls-contracts:dev .
```

## Advantages Over the Hardhat Task

1. **Standalone**: Does not depend on complex Hardhat configuration
2. **Improved logs**: Friendlier interface with emojis and statistics
3. **Flexibility**: Can be easily modified without changing hardhat.config.ts
4. **Debugging**: Easier to debug compilation issues
5. **Portability**: Works independently of the Hardhat environment

## Requirements

- Node.js
- npm with dependencies installed
- Hardhat available via npx
- `glob` package (already included in devDependencies)

## Troubleshooting

### "Hardhat not found"
Make sure dependencies are installed:
```bash
npm ci
```

### "No .sol files found"
Verify that the file paths are correct and that the files exist in the `src/` directory.

### Compilation error
The script stops at the first failing step. Check the logs to identify the problematic file.
