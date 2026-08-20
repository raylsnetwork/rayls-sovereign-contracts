import { HardhatRuntimeEnvironment } from 'hardhat/types';
import * as fs from 'fs';
import * as path from 'path';
import { execSync } from 'child_process';

/**
 * OpenZeppelin-compatible manifest file format
 * Compatible with @openzeppelin/hardhat-upgrades plugin
 */
export interface NetworkManifest {
  manifestVersion: string;
  admin?: {
    address: string;
    txHash: string;
  };
  proxies: ProxyDeployment[];
  impls: { [layoutHash: string]: ImplementationDeployment };
}

export interface ProxyDeployment {
  address: string;
  txHash: string;
  kind: 'uups' | 'transparent' | 'beacon';
}

export interface ImplementationDeployment {
  address: string;
  txHash: string;
  layout: StorageLayout;
}

export interface StorageLayout {
  solcVersion: string;
  storage: StorageItem[];
  types: { [typeId: string]: TypeDescription };
  namespaces?: { [namespace: string]: StorageItem[] };
}

export interface StorageItem {
  label: string;
  offset: number;
  slot: string;
  type: string;
  contract: string;
  src: string;
}

export interface TypeDescription {
  label: string;
  numberOfBytes: string;
  members?: StorageItem[];
}

/**
 * Manages OpenZeppelin-compatible network manifest files
 * Compatible with @openzeppelin/hardhat-upgrades plugin
 */
export class ManifestManager {
  private manifestDir: string;
  private participantSuffix?: string;

  constructor(manifestDir: string = '.openzeppelin', participantSuffix?: string) {
    this.manifestDir = manifestDir;
    this.participantSuffix = participantSuffix;
    this.ensureManifestDir();
  }

  /**
   * Ensures the manifest directory exists
   */
  private ensureManifestDir(): void {
    if (!fs.existsSync(this.manifestDir)) {
      fs.mkdirSync(this.manifestDir, { recursive: true });
      console.log(`📁 Created manifest directory: ${this.manifestDir}`);
    }
  }

  /**
   * Gets the manifest file path for a network
   * Supports optional participant suffix for multi-participant deployments
   */
  private getManifestPath(networkName: string, chainId: number): string {
    // Map known chain IDs to network names (OpenZeppelin convention)
    const knownNetworks: { [chainId: number]: string } = {
      1: 'mainnet',
      5: 'goerli',
      11155111: 'sepolia',
      137: 'polygon',
      80001: 'mumbai',
      42161: 'arbitrum',
      10: 'optimism',
    };

    let filename = knownNetworks[chainId] || `unknown-${chainId}`;
    
    // Add participant suffix if provided (e.g., unknown-7331-A.json)
    if (this.participantSuffix) {
      filename = `${filename}-${this.participantSuffix}`;
    }
    
    return path.join(this.manifestDir, `${filename}.json`);
  }

  /**
   * Loads or creates a network manifest
   */
  private loadManifest(networkName: string, chainId: number): NetworkManifest {
    const manifestPath = this.getManifestPath(networkName, chainId);

    if (fs.existsSync(manifestPath)) {
      const content = fs.readFileSync(manifestPath, 'utf-8');
      return JSON.parse(content);
    }

    // Create new manifest with OpenZeppelin format
    return {
      manifestVersion: '3.2',
      proxies: [],
      impls: {},
    };
  }

  /**
   * Saves a network manifest
   */
  private saveManifest(
    networkName: string,
    chainId: number,
    manifest: NetworkManifest
  ): void {
    const manifestPath = this.getManifestPath(networkName, chainId);
    fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));
    console.log(`💾 Saved manifest: ${manifestPath}`);
  }

  /**
   * Reads storage layout from Forge artifacts
   */
  private async readStorageLayout(contractName: string): Promise<StorageLayout | null> {
    try {
      // Find the artifact file
      const findResult = execSync(
        `find out -name "${contractName}.json" -type f | head -1`,
        {
          encoding: 'utf-8',
          cwd: process.cwd(),
        }
      ).trim();

      if (!findResult) {
        console.log(`⚠️  Could not find artifact for ${contractName}`);
        return null;
      }

      const artifact = JSON.parse(fs.readFileSync(findResult, 'utf-8'));
      const layout = artifact.storageLayout;

      if (!layout) {
        console.log(`⚠️  No storage layout in artifact for ${contractName}`);
        return null;
      }

      // Convert Forge format to OpenZeppelin format
      return {
        solcVersion: layout.solcVersion || '0.8.24',
        storage: layout.storage || [],
        types: layout.types || {},
        namespaces: layout.namespaces || {},
      };
    } catch (error: any) {
      console.log(`⚠️  Error reading storage layout for ${contractName}: ${error.message}`);
      return null;
    }
  }

  /**
   * Computes a layout hash for an implementation
   * Uses the same approach as OpenZeppelin (hash of storage layout)
   */
  private computeLayoutHash(layout: StorageLayout): string {
    const crypto = require('crypto');
    const layoutString = JSON.stringify(layout.storage);
    return crypto.createHash('sha256').update(layoutString).digest('hex');
  }

  /**
   * Records a proxy deployment
   */
  async recordProxy(
    hre: HardhatRuntimeEnvironment,
    proxyAddress: string,
    txHash: string,
    kind: 'uups' | 'transparent' | 'beacon' = 'uups'
  ): Promise<void> {
    const chainId = (await hre.ethers.provider.getNetwork()).chainId;
    const manifest = this.loadManifest(hre.network.name, Number(chainId));

    // Check if proxy already exists
    const existingIndex = manifest.proxies.findIndex((p) => p.address === proxyAddress);

    const proxyRecord: ProxyDeployment = {
      address: proxyAddress,
      txHash,
      kind,
    };

    if (existingIndex >= 0) {
      manifest.proxies[existingIndex] = proxyRecord;
      console.log(`📝 Updated proxy record: ${proxyAddress}`);
    } else {
      manifest.proxies.push(proxyRecord);
      console.log(`📝 Recorded proxy: ${proxyAddress}`);
    }

    this.saveManifest(hre.network.name, Number(chainId), manifest);
  }

  /**
   * Records an implementation deployment
   */
  async recordImplementation(
    hre: HardhatRuntimeEnvironment,
    implAddress: string,
    txHash: string,
    contractName: string
  ): Promise<void> {
    const chainId = (await hre.ethers.provider.getNetwork()).chainId;
    const manifest = this.loadManifest(hre.network.name, Number(chainId));

    // Read storage layout from Forge artifacts
    const layout = await this.readStorageLayout(contractName);

    if (!layout) {
      console.log(`⚠️  Recording implementation without storage layout: ${implAddress}`);
      return;
    }

    // Compute layout hash (OpenZeppelin convention)
    const layoutHash = this.computeLayoutHash(layout);

    // Check if implementation already exists
    if (manifest.impls[layoutHash]) {
      console.log(`ℹ️  Implementation with same layout already recorded`);
      return;
    }

    manifest.impls[layoutHash] = {
      address: implAddress,
      txHash,
      layout,
    };

    console.log(`📝 Recorded implementation: ${implAddress}`);
    console.log(`   Layout hash: ${layoutHash.slice(0, 16)}...`);
    console.log(`   Storage slots: ${layout.storage.length}`);

    this.saveManifest(hre.network.name, Number(chainId), manifest);
  }

  /**
   * Gets a proxy record by address
   */
  async getProxy(
    hre: HardhatRuntimeEnvironment,
    proxyAddress: string
  ): Promise<ProxyDeployment | null> {
    const chainId = (await hre.ethers.provider.getNetwork()).chainId;
    const manifest = this.loadManifest(hre.network.name, Number(chainId));

    return manifest.proxies.find((p) => p.address === proxyAddress) || null;
  }

  /**
   * Gets an implementation by address
   */
  async getImplementation(
    hre: HardhatRuntimeEnvironment,
    implAddress: string
  ): Promise<ImplementationDeployment | null> {
    const chainId = (await hre.ethers.provider.getNetwork()).chainId;
    const manifest = this.loadManifest(hre.network.name, Number(chainId));

    // Find implementation by address
    for (const [hash, impl] of Object.entries(manifest.impls)) {
      if (impl.address.toLowerCase() === implAddress.toLowerCase()) {
        return impl;
      }
    }

    return null;
  }

  /**
   * Gets storage layout for a contract by implementation address
   */
  async getStorageLayout(
    hre: HardhatRuntimeEnvironment,
    implAddress: string
  ): Promise<StorageLayout | null> {
    const impl = await this.getImplementation(hre, implAddress);
    return impl?.layout || null;
  }

  /**
   * Lists all proxies in the manifest
   */
  async listProxies(hre: HardhatRuntimeEnvironment): Promise<ProxyDeployment[]> {
    const chainId = (await hre.ethers.provider.getNetwork()).chainId;
    const manifest = this.loadManifest(hre.network.name, Number(chainId));
    return manifest.proxies;
  }

  /**
   * Lists all implementations in the manifest
   */
  async listImplementations(
    hre: HardhatRuntimeEnvironment
  ): Promise<ImplementationDeployment[]> {
    const chainId = (await hre.ethers.provider.getNetwork()).chainId;
    const manifest = this.loadManifest(hre.network.name, Number(chainId));
    return Object.values(manifest.impls);
  }

  /**
   * Gets the manifest file path for the current network
   */
  async getManifestFilePath(hre: HardhatRuntimeEnvironment): Promise<string> {
    const chainId = (await hre.ethers.provider.getNetwork()).chainId;
    return this.getManifestPath(hre.network.name, Number(chainId));
  }

  /**
   * Checks if a contract with the given name has already been deployed
   * This prevents accidental duplicate deployments
   * 
   * @param hre Hardhat runtime environment
   * @param contractName Name of the contract to check
   * @returns The existing proxy deployment if found, null otherwise
   */
  async findExistingDeployment(
    hre: HardhatRuntimeEnvironment,
    contractName: string
  ): Promise<{ proxy: ProxyDeployment; implementation: ImplementationDeployment } | null> {
    try {
      const chainId = (await hre.ethers.provider.getNetwork()).chainId;
      const manifest = this.loadManifest(hre.network.name, Number(chainId));

      // Check if manifest has any proxies
      if (manifest.proxies.length === 0) {
        return null;
      }

      // Try to find implementation by contract name in storage layout
      for (const [hash, impl] of Object.entries(manifest.impls)) {
        // Check if any storage item matches the contract name
        const hasMatchingContract = impl.layout.storage.some(
          (item) => item.contract.includes(contractName)
        );

        if (hasMatchingContract) {
          // Find the proxy that uses this implementation
          // Note: We can't directly link proxy to impl without additional tracking
          // For now, we'll return the first proxy as a warning
          const proxy = manifest.proxies[0];
          return { proxy, implementation: impl };
        }
      }

      return null;
    } catch (error) {
      // Manifest doesn't exist or error reading it
      return null;
    }
  }

  /**
   * Checks if the manifest already has deployments
   * @param hre Hardhat runtime environment
   * @returns true if manifest exists and has deployments
   */
  async hasExistingDeployments(hre: HardhatRuntimeEnvironment): Promise<boolean> {
    try {
      const chainId = (await hre.ethers.provider.getNetwork()).chainId;
      const manifest = this.loadManifest(hre.network.name, Number(chainId));
      return manifest.proxies.length > 0;
    } catch (error) {
      return false;
    }
  }
}
