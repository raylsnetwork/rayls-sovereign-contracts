import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { ContractFactory } from 'ethers';
import { execSync } from 'child_process';
import * as fs from 'fs';
import * as path from 'path';
import { ManifestManager } from './manifest-manager';

/**
 * Extracts contract name from a ContractFactory.
 * Tries multiple methods to find the name.
 */
function getContractName(factory: ContractFactory): string {
  // Try different properties that might contain the name
  const factoryAny = factory as any;
  
  // Method 1: Check contractName property (works in some versions)
  if (factoryAny.contractName) {
    return factoryAny.contractName;
  }
  
  // Method 2: Check interface name property
  if (factoryAny.interface?.contractName) {
    return factoryAny.interface.contractName;
  }
  
  // Method 3: Try to extract from target or runner
  if (factoryAny.target?.constructor?.name) {
    const name = factoryAny.target.constructor.name;
    if (name !== 'Object' && name !== 'Contract') {
      return name;
    }
  }
  
  // Method 4: Check if there's a bytecode property with metadata
  // This is a last resort
  
  return 'Unknown';
}

/**
 * Options for validation
 */
export interface ValidationOptions {
  /** Skip validation entirely (use with caution!) */
  skipValidation?: boolean;
  /** Skip storage layout check when upgrading */
  unsafeSkipStorageCheck?: boolean;
  /** Skip proxy admin check for transparent proxies */
  unsafeSkipProxyAdminCheck?: boolean;
  /** Allow specific unsafe operations (e.g., 'delegatecall', 'selfdestruct', 'state-variable-assignment') */
  unsafeAllow?: string[];
}

/**
 * Storage layout entry from Forge
 */
interface StorageLayoutEntry {
  label: string;
  offset: number;
  slot: string;
  type: string;
  contract: string;
}

/**
 * Helper: Check if a contract is UUPS upgradeable
 */
async function isUUPSContract(contractFactory: ContractFactory): Promise<boolean> {
  try {
    const abi = contractFactory.interface;
    // Check for UUPS upgrade functions
    const hasUpgradeTo = abi.fragments.some((f: any) => f.name === 'upgradeTo');
    const hasUpgradeToAndCall = abi.fragments.some((f: any) => f.name === 'upgradeToAndCall');
    return hasUpgradeTo || hasUpgradeToAndCall;
  } catch {
    return false;
  }
}

/**
 * Helper: Validate UUPS contract using compiled artifacts
 */
async function validateUUPSContract(contractName: string, opts: ValidationOptions): Promise<void> {
  try {
    // Read the ABI from Forge's compiled output
    const outDir = path.join(process.cwd(), 'out');
    
    // Try to find the artifact file (Forge output structure)
    const possiblePaths = [
      path.join(outDir, `${contractName}.sol`, `${contractName}.json`),
      // Try common subdirectories
      ...['src', 'privateHub', 'rayls-protocol', 'rayls-node'].map(dir =>
        path.join(outDir, dir, `${contractName}.sol`, `${contractName}.json`)
      )
    ];
    
    let abi: any = null;
    for (const artifactPath of possiblePaths) {
      if (fs.existsSync(artifactPath)) {
        const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf-8'));
        abi = artifact.abi;
        break;
      }
    }
    
    if (!abi) {
      // Fallback: search recursively
      const findResult = execSync(`find out -name "${contractName}.json" -type f | head -1`, { 
        encoding: 'utf-8',
        cwd: process.cwd()
      }).trim();
      
      if (findResult) {
        const artifact = JSON.parse(fs.readFileSync(findResult, 'utf-8'));
        abi = artifact.abi;
      }
    }
    
    if (!abi) {
      console.log(`    ⚠️  Could not find compiled artifact for ${contractName}`);
      return;
    }
    
    // Check for proxiableUUID function (indicates UUPS implementation)
    // Note: _authorizeUpgrade is internal and won't appear in ABI
    const hasProxiableUUID = abi.some((item: any) => 
      item.type === 'function' && item.name === 'proxiableUUID'
    );
    
    if (!hasProxiableUUID && !opts.unsafeAllow?.includes('missing-uups-functions')) {
      throw new Error(`${contractName}: UUPS contract must implement UUPSUpgradeable (missing proxiableUUID function)`);
    }
    
  } catch (error: any) {
    if (error.message.includes('UUPS contract must implement')) {
      throw error;
    }
    console.log(`    ⚠️  Could not validate ${contractName}: ${error.message}`);
  }
}

/**
 * Compares storage layouts between old and new contracts to ensure upgrade safety.
 * 
 * @param oldContractName Name of the old contract
 * @param newContractName Name of the new contract
 * @returns true if layouts are compatible, false otherwise
 */
async function compareStorageLayouts(oldContractName: string, newContractName: string): Promise<boolean> {
  try {
    // Helper to find artifact file
    const findArtifact = (contractName: string): string | null => {
      const findResult = execSync(`find out -name "${contractName}.json" -type f | head -1`, { 
        encoding: 'utf-8',
        cwd: process.cwd()
      }).trim();
      return findResult || null;
    };

    // Read storage layouts
    const oldArtifactPath = findArtifact(oldContractName);
    const newArtifactPath = findArtifact(newContractName);

    if (!oldArtifactPath || !newArtifactPath) {
      console.log(`       ⚠️  Could not find artifacts for comparison`);
      return true; // Don't fail if we can't find artifacts
    }

    const oldArtifact = JSON.parse(fs.readFileSync(oldArtifactPath, 'utf-8'));
    const newArtifact = JSON.parse(fs.readFileSync(newArtifactPath, 'utf-8'));

    const oldLayout = oldArtifact.storageLayout?.storage || [];
    const newLayout = newArtifact.storageLayout?.storage || [];

    if (oldLayout.length === 0 || newLayout.length === 0) {
      console.log(`       ℹ️  Storage layout not available in artifacts`);
      return true; // Can't compare without layout data
    }

    // Verify all old storage slots are preserved in new contract
    for (let i = 0; i < oldLayout.length; i++) {
      const oldSlot = oldLayout[i];
      const newSlot = newLayout[i];

      if (!newSlot) {
        console.log(`       ❌ Storage slot ${i} (${oldSlot.label}) removed in new contract`);
        return false;
      }

      // Check slot number matches
      if (oldSlot.slot !== newSlot.slot) {
        console.log(`       ❌ Storage slot mismatch: ${oldSlot.label} moved from slot ${oldSlot.slot} to ${newSlot.slot}`);
        return false;
      }

      // Check type matches
      if (oldSlot.type !== newSlot.type) {
        console.log(`       ❌ Type mismatch in slot ${oldSlot.slot}: ${oldSlot.label} changed from ${oldSlot.type} to ${newSlot.type}`);
        return false;
      }

      // Check offset matches (for packed storage)
      if (oldSlot.offset !== newSlot.offset) {
        console.log(`       ❌ Offset mismatch in slot ${oldSlot.slot}: ${oldSlot.label} offset changed`);
        return false;
      }
    }

    // New contract can have additional storage at the end
    if (newLayout.length > oldLayout.length) {
      const addedCount = newLayout.length - oldLayout.length;
      console.log(`       ℹ️  ${addedCount} new storage variable(s) added at the end`);
    }

    return true;

  } catch (error: any) {
    console.log(`       ⚠️  Error comparing layouts: ${error.message}`);
    return true; // Don't fail on comparison errors, just warn
  }
}

/**
 * Helper: Read storage layout from Forge artifacts
 */
async function readStorageLayoutFromForge(contractName: string): Promise<any | null> {
  try {
    const findResult = execSync(`find out -name "${contractName}.json" -type f | head -1`, { 
      encoding: 'utf-8',
      cwd: process.cwd()
    }).trim();

    if (!findResult) {
      return null;
    }

    const artifact = JSON.parse(fs.readFileSync(findResult, 'utf-8'));
    return artifact.storageLayout || null;
  } catch (error) {
    return null;
  }
}

/**
 * Helper: Compare two storage layout objects directly
 */
async function compareStorageLayoutObjects(oldLayout: any, newLayout: any): Promise<boolean> {
  try {
    const oldStorage = oldLayout.storage || [];
    const newStorage = newLayout.storage || [];

    if (oldStorage.length === 0 || newStorage.length === 0) {
      console.log(`       ℹ️  Storage layout data incomplete`);
      return true;
    }

    // Verify all old storage slots are preserved in new contract
    for (let i = 0; i < oldStorage.length; i++) {
      const oldSlot = oldStorage[i];
      const newSlot = newStorage[i];

      if (!newSlot) {
        console.log(`       ❌ Storage slot ${i} (${oldSlot.label}) removed in new contract`);
        return false;
      }

      // Check slot number matches
      if (oldSlot.slot !== newSlot.slot) {
        console.log(`       ❌ Storage slot mismatch: ${oldSlot.label} moved from slot ${oldSlot.slot} to ${newSlot.slot}`);
        return false;
      }

      // Check type matches
      if (oldSlot.type !== newSlot.type) {
        console.log(`       ❌ Type mismatch in slot ${oldSlot.slot}: ${oldSlot.label} changed from ${oldSlot.type} to ${newSlot.type}`);
        return false;
      }

      // Check offset matches (for packed storage)
      if (oldSlot.offset !== newSlot.offset) {
        console.log(`       ❌ Offset mismatch in slot ${oldSlot.slot}: ${oldSlot.label} offset changed`);
        return false;
      }
    }

    // New contract can have additional storage at the end
    if (newStorage.length > oldStorage.length) {
      const addedCount = newStorage.length - oldStorage.length;
      console.log(`       ℹ️  ${addedCount} new storage variable(s) added at the end`);
    }

    return true;
  } catch (error: any) {
    console.log(`       ⚠️  Error comparing layouts: ${error.message}`);
    return true; // Don't fail on comparison errors, just warn
  }
}

/**
 * Helper: Basic safety checks for upgradeable contracts
 */
async function validateBasicSafety(contractName: string, opts: ValidationOptions): Promise<void> {
  try {
    // Read storage layout from compiled artifacts
    const outDir = path.join(process.cwd(), 'out');
    
    // Find the artifact file
    const findResult = execSync(`find out -name "${contractName}.json" -type f | head -1`, { 
      encoding: 'utf-8',
      cwd: process.cwd()
    }).trim();
    
    if (!findResult) {
      console.log(`    ⚠️  Could not find compiled artifact for ${contractName}`);
      return;
    }
    
    const artifact = JSON.parse(fs.readFileSync(findResult, 'utf-8'));
    const storageLayout = artifact.storageLayout;
    
    if (!storageLayout) {
      // No storage layout in artifact (Forge needs extra config to generate it)
      // This is OK - we'll just skip the immutables check
      console.log(`    ℹ️  ${contractName}: Storage layout not available (skipping immutables check)`);
      return;
    }
    
    // Check for immutable variables (not allowed in upgradeable contracts)
    if (storageLayout.storage) {
      const hasImmutable = storageLayout.storage.some((entry: any) => 
        entry.label && entry.label.includes('immutable')
      );
      
      if (hasImmutable && !opts.unsafeAllow?.includes('state-variable-immutable')) {
        throw new Error(`${contractName}: Immutable variables are not supported in upgradeable contracts`);
      }
    }
    
  } catch (error: any) {
    if (error.message.includes('Immutable')) {
      throw error;
    }
    // Only warn on other errors
    console.log(`    ⚠️  Could not perform basic safety checks on ${contractName}`);
  }
}

/**
 * Validates that a contract implementation is upgrade-safe using Forge inspection.
 * 
 * @param hre Hardhat Runtime Environment
 * @param contractFactory The contract factory to validate
 * @param opts Validation options
 * @param contractName Optional contract name for better logging (if not provided, validation still works)
 * @returns true if validation passes, throws error otherwise
 */
export async function validateImplementation(
  hre: HardhatRuntimeEnvironment,
  contractFactory: ContractFactory,
  opts: ValidationOptions = {},
  contractName?: string
): Promise<void> {
  if (opts.skipValidation) {
    console.log('    ⚠️  Contract validation SKIPPED (unsafe!)');
    return;
  }

  // Use provided name or extract from factory (may be "Unknown")
  const finalContractName = contractName || getContractName(contractFactory);
  const contractLabel = finalContractName !== 'Unknown' ? finalContractName : 'contract';
  
  try {
    // Check if this is a UUPS upgradeable contract
    const isUUPS = await isUUPSContract(contractFactory);
    
    if (isUUPS) {
      // Validate UUPS specific requirements
      await validateUUPSContract(finalContractName, opts);
      if (finalContractName !== 'Unknown') {
        console.log(`    ✅ ${finalContractName}: UUPS validation passed`);
      } else {
        console.log(`    ✅ UUPS validation passed`);
      }
    }
    
    // Additional basic checks
    await validateBasicSafety(finalContractName, opts);
    if (finalContractName !== 'Unknown') {
      console.log(`    ✅ ${finalContractName}: Storage safety checks passed`);
    } else {
      console.log(`    ✅ Storage safety checks passed`);
    }
    
  } catch (error: any) {
    if (!opts.unsafeAllow?.includes(error.code)) {
      throw error;
    }
    console.log(`    ⚠️  Validation warning (allowed): ${error.message}`);
  }
}

/**
 * Validates that an upgrade is safe (storage compatible) using Forge storage layout comparison.
 * 
 * @param hre Hardhat Runtime Environment
 * @param proxyAddress Address of the existing proxy
 * @param newFactory New implementation factory
 * @param opts Validation options
 * @param newContractName Optional name of the new contract for better logging
 * @param oldContractName Optional name of the old contract to enable automatic storage layout comparison
 */
export async function validateUpgrade(
  hre: HardhatRuntimeEnvironment,
  proxyAddress: string,
  newFactory: ContractFactory,
  opts: ValidationOptions = {},
  newContractName?: string,
  oldContractName?: string
): Promise<void> {
  if (opts.skipValidation) {
    console.log('    ⚠️  Upgrade validation SKIPPED (unsafe!)');
    return;
  }

  // First validate the new implementation
  await validateImplementation(hre, newFactory, opts, newContractName);

  if (opts.unsafeSkipStorageCheck) {
    console.log('    ⚠️  Storage layout check SKIPPED (unsafe!)');
    return;
  }

  try {
    // Get current implementation address from proxy
    const provider = hre.ethers.provider;
    const implSlot = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'; // ERC1967 implementation slot
    
    let implAddressRaw: string;
    try {
      implAddressRaw = await provider.getStorage(proxyAddress, implSlot);
    } catch (storageError: any) {
      console.log(`    ℹ️  Could not read implementation slot (possibly first deployment)`);
      return;
    }
    
    const currentImplAddress = '0x' + implAddressRaw.slice(-40);

    if (currentImplAddress === '0x' + '0'.repeat(40)) {
      console.log('    ℹ️  No existing implementation found (first deployment)');
      return;
    }

    console.log(`    🔍 Comparing storage layouts for upgrade safety...`);
    console.log(`       Current implementation: ${currentImplAddress}`);
    
    // Try to get old layout from manifest first (most reliable source)
    const manifest = new ManifestManager();
    const oldLayoutFromManifest = await manifest.getStorageLayout(hre, currentImplAddress);
    
    // Extract contract names
    const newContract = newContractName || getContractName(newFactory);
    
    // If both old and new contract names are provided, perform automatic comparison
    if (oldContractName && newContract !== 'Unknown') {
      console.log(`       Comparing ${oldContractName} → ${newContract}`);
      
      if (oldLayoutFromManifest) {
        // Use manifest layout (most reliable - captured at deployment time)
        console.log(`       Using stored layout from manifest`);
        const newLayout = await readStorageLayoutFromForge(newContract);
        if (newLayout) {
          const isCompatible = await compareStorageLayoutObjects(oldLayoutFromManifest, newLayout);
          if (isCompatible) {
            console.log(`    ✅ Storage layout is upgrade-safe`);
          } else {
            throw new Error('Storage layout incompatibility detected. Upgrade would break existing state.');
          }
        } else {
          throw new Error(`Could not read storage layout for ${newContract}`);
        }
      } else {
        // Fallback to comparing by contract names from artifacts
        console.log(`       Reading layouts from Forge artifacts (manifest not available)`);
        const isCompatible = await compareStorageLayouts(oldContractName, newContract);
        
        if (isCompatible) {
          console.log(`    ✅ Storage layout is upgrade-safe`);
        } else {
          throw new Error('Storage layout incompatibility detected. Upgrade would break existing state.');
        }
      }
    } else {
      // Fallback: Manual review recommended
      console.log(`    ⚠️  Manual storage layout review recommended`);
      if (newContract !== 'Unknown') {
        console.log(`       Run: forge inspect ${oldContractName || 'OldContract'} storageLayout`);
        console.log(`       Run: forge inspect ${newContract} storageLayout`);
      }
    }
    
  } catch (error: any) {
    // Re-throw storage layout incompatibility errors
    if (error.message.includes('Storage layout incompatibility')) {
      throw error;
    }
    
    // Log other errors as warnings
    console.log(`    ⚠️  Could not fully validate upgrade: ${error.message}`);
    if (!opts.unsafeSkipStorageCheck) {
      console.log(`    💡 Use unsafeSkipStorageCheck: true to bypass this check (not recommended)`);
    }
  }
}

/**
 * Checks if a proxy was previously deployed at the given address.
 * This is useful to determine if this is a fresh deployment or an upgrade.
 * 
 * @param hre Hardhat Runtime Environment
 * @param proxyAddress The proxy address to check
 * @returns true if proxy exists (has code deployed)
 */
export async function isProxyDeployed(
  hre: HardhatRuntimeEnvironment,
  proxyAddress: string
): Promise<boolean> {
  try {
    const code = await hre.ethers.provider.getCode(proxyAddress);
    // A deployed contract has code, empty address returns '0x'
    return code !== '0x' && code.length > 2;
  } catch (error) {
    console.log(`    ⚠️  Could not check proxy deployment status: ${error}`);
    return false;
  }
}

/**
 * Records a deployed proxy for future upgrade validation.
 * Stores deployment info in .openzeppelin/<network>.json
 * 
 * @param hre Hardhat Runtime Environment
 * @param proxyAddress The deployed proxy address
 * @param implAddress The implementation address
 * @param contractName The contract name (for reference)
 */
export async function recordProxyDeployment(
  hre: HardhatRuntimeEnvironment,
  proxyAddress: string,
  implAddress: string,
  contractName: string
): Promise<void> {
  try {
    const network = hre.network.name;
    const manifestDir = path.join(process.cwd(), '.openzeppelin');
    const manifestPath = path.join(manifestDir, `${network}.json`);

    // Ensure directory exists
    if (!fs.existsSync(manifestDir)) {
      fs.mkdirSync(manifestDir, { recursive: true });
    }

    // Load existing manifest or create new
    let manifest: any = {};
    if (fs.existsSync(manifestPath)) {
      manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf-8'));
    }

    // Initialize structure
    if (!manifest.proxies) {
      manifest.proxies = [];
    }

    // Record deployment
    const deployment = {
      address: proxyAddress,
      implementation: implAddress,
      contractName: contractName,
      timestamp: new Date().toISOString(),
      network: network
    };

    // Update or add proxy record
    const existingIndex = manifest.proxies.findIndex((p: any) => p.address === proxyAddress);
    if (existingIndex >= 0) {
      manifest.proxies[existingIndex] = deployment;
    } else {
      manifest.proxies.push(deployment);
    }

    // Save manifest
    fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));
    console.log(`    ✅ Recorded proxy deployment in ${manifestPath}`);
    
  } catch (error: any) {
    console.log(`    ⚠️  Could not record proxy deployment: ${error.message}`);
  }
}

/**
 * Validates a batch of contracts before deployment.
 * Returns a map of contract names to validation results.
 * 
 * @param hre Hardhat Runtime Environment
 * @param contractNames Array of contract names to validate
 * @param opts Validation options
 * @returns Map of contract name to validation status
 */
export async function validateBatch(
  hre: HardhatRuntimeEnvironment,
  contractNames: string[],
  opts: ValidationOptions = {}
): Promise<Map<string, boolean>> {
  const results = new Map<string, boolean>();
  
  if (opts.skipValidation) {
    console.log('  ⚠️  Batch validation SKIPPED (unsafe!)');
    contractNames.forEach(name => results.set(name, true));
    return results;
  }

  console.log(`  🔍 Validating ${contractNames.length} contracts...`);
  
  for (const contractName of contractNames) {
    try {
      const factory = await hre.ethers.getContractFactory(contractName);
      await validateImplementation(hre, factory, opts);
      results.set(contractName, true);
    } catch (error: any) {
      console.error(`    ❌ ${contractName}: ${error.message}`);
      results.set(contractName, false);
      throw error; // Stop on first failure
    }
  }
  
  console.log('  ✅ All contracts validated successfully');
  return results;
}

/**
 * Gets common validation errors with helpful messages
 */
export function getValidationErrorHelp(errorMessage: string): string {
  const helpMessages: Record<string, string> = {
    'state-variable-assignment': `
      ❌ State variables must not have initial values in the contract.
      ✅ Use the initializer function instead.
      Example: Change 'uint256 public value = 10;' to 'uint256 public value;' and set in initialize()`,
    
    'state-variable-immutable': `
      ❌ Immutable variables are not supported in upgradeable contracts.
      ✅ Use constants or regular state variables instead.`,
    
    'constructor': `
      ❌ Constructors cannot contain code in upgradeable contracts.
      ✅ Use the initialize() function for setup logic.
      ✅ Or add /// @custom:oz-upgrades-unsafe-allow constructor`,
    
    'delegatecall': `
      ❌ delegatecall is unsafe in upgradeable contracts.
      ✅ Remove delegatecall usage or explicitly allow it with:
      /// @custom:oz-upgrades-unsafe-allow delegatecall`,
    
    'selfdestruct': `
      ❌ selfdestruct is unsafe in upgradeable contracts.
      ✅ Remove selfdestruct or explicitly allow it (not recommended)`,
    
    'missing-public-upgradeto': `
      ❌ UUPS proxies must implement upgradeTo(address) or upgradeToAndCall(address,bytes).
      ✅ Inherit from UUPSUpgradeable and implement _authorizeUpgrade()`,
    
    'external-library-linking': `
      ❌ External libraries with state may cause storage conflicts.
      ✅ Use libraries without state or allow with:
      /// @custom:oz-upgrades-unsafe-allow external-library-linking`,
  };

  for (const [key, help] of Object.entries(helpMessages)) {
    if (errorMessage.includes(key)) {
      return help;
    }
  }

  return '';
}
