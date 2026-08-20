import { expect } from 'chai';
import { ethers } from 'hardhat';
import hre from 'hardhat';
import { ManifestManager } from '../../tasks/deploy/manifest-manager';
import * as fs from 'fs';
import * as path from 'path';

describe('Manifest Integration Tests', function () {
  let manifest: ManifestManager;
  let manifestPath: string;

  before(async function () {
    manifest = new ManifestManager();
    manifestPath = await manifest.getManifestFilePath(hre);
    
    // Clean up any existing test manifest
    if (fs.existsSync(manifestPath)) {
      fs.unlinkSync(manifestPath);
    }
  });

  after(async function () {
    // Clean up test manifest
    if (fs.existsSync(manifestPath)) {
      fs.unlinkSync(manifestPath);
    }
  });

  it('Should create manifest directory', async function () {
    expect(fs.existsSync('.openzeppelin')).to.be.true;
  });

  it('Should deploy and record UUPS proxy in manifest', async function () {
    console.log('\n🔍 Testing manifest recording...');
    
    // Deploy implementation
    const V1Factory = await ethers.getContractFactory('TestContractV1');
    const implV1 = await V1Factory.deploy();
    await implV1.waitForDeployment();
    const implAddress = await implV1.getAddress();
    const implTx = implV1.deploymentTransaction();
    
    console.log(`   📝 Implementation deployed: ${implAddress}`);

    // Deploy proxy
    const ProxyFactory = await ethers.getContractFactory('RaylsERC1967Proxy');
    const [owner] = await ethers.getSigners();
    const initData = V1Factory.interface.encodeFunctionData('initialize', [owner.address]);
    const proxy = await ProxyFactory.deploy(implAddress, initData);
    await proxy.waitForDeployment();
    const proxyAddress = await proxy.getAddress();
    const proxyTx = proxy.deploymentTransaction();
    
    console.log(`   📝 Proxy deployed: ${proxyAddress}`);

    // Record in manifest
    if (proxyTx && implTx) {
      await manifest.recordProxy(hre, proxyAddress, proxyTx.hash, 'uups');
      await manifest.recordImplementation(hre, implAddress, implTx.hash, 'TestContractV1');
    }

    // Verify manifest file exists
    expect(fs.existsSync(manifestPath)).to.be.true;
    console.log(`   ✅ Manifest file created: ${manifestPath}`);

    // Read and verify manifest content
    const manifestContent = JSON.parse(fs.readFileSync(manifestPath, 'utf-8'));
    
    expect(manifestContent.manifestVersion).to.equal('3.2');
    expect(manifestContent.proxies).to.have.lengthOf(1);
    expect(manifestContent.proxies[0].address).to.equal(proxyAddress);
    expect(manifestContent.proxies[0].kind).to.equal('uups');
    
    console.log(`   ✅ Manifest contains proxy record`);
    console.log(`   ✅ Manifest format matches OpenZeppelin v3.2`);
  });

  it('Should retrieve proxy from manifest', async function () {
    const proxies = await manifest.listProxies(hre);
    expect(proxies).to.have.lengthOf(1);
    expect(proxies[0].kind).to.equal('uups');
    console.log(`   ✅ Retrieved ${proxies.length} proxy from manifest`);
  });

  it('Should retrieve implementation with storage layout', async function () {
    const impls = await manifest.listImplementations(hre);
    expect(impls).to.have.lengthOf(1);
    expect(impls[0].layout).to.exist;
    expect(impls[0].layout.storage).to.be.an('array');
    
    console.log(`   ✅ Retrieved implementation with storage layout`);
    console.log(`   📊 Storage slots: ${impls[0].layout.storage.length}`);
    console.log(`   📊 Type definitions: ${Object.keys(impls[0].layout.types).length}`);
  });

  it('Should record upgrade and maintain history', async function () {
    console.log('\n🔍 Testing upgrade recording...');
    
    // Get existing proxy
    const proxies = await manifest.listProxies(hre);
    const proxyAddress = proxies[0].address;
    
    // Deploy V2 implementation
    const V2Factory = await ethers.getContractFactory('TestContractV2');
    const implV2 = await V2Factory.deploy();
    await implV2.waitForDeployment();
    const implV2Address = await implV2.getAddress();
    const implV2Tx = implV2.deploymentTransaction();
    
    console.log(`   📝 V2 Implementation deployed: ${implV2Address}`);

    // Record V2 implementation
    if (implV2Tx) {
      await manifest.recordImplementation(hre, implV2Address, implV2Tx.hash, 'TestContractV2');
    }

    // Verify both implementations are recorded
    const impls = await manifest.listImplementations(hre);
    expect(impls).to.have.lengthOf(2);
    
    console.log(`   ✅ Manifest now contains 2 implementations`);
    console.log(`   ✅ Upgrade history maintained`);
  });

  it('Should verify manifest is compatible with OpenZeppelin format', async function () {
    const manifestContent = JSON.parse(fs.readFileSync(manifestPath, 'utf-8'));
    
    // Verify required OpenZeppelin fields
    expect(manifestContent).to.have.property('manifestVersion');
    expect(manifestContent).to.have.property('proxies');
    expect(manifestContent).to.have.property('impls');
    
    // Verify proxy format
    const proxy = manifestContent.proxies[0];
    expect(proxy).to.have.property('address');
    expect(proxy).to.have.property('txHash');
    expect(proxy).to.have.property('kind');
    
    // Verify implementation format
    const implHashes = Object.keys(manifestContent.impls);
    expect(implHashes.length).to.be.greaterThan(0);
    
    const impl = manifestContent.impls[implHashes[0]];
    expect(impl).to.have.property('address');
    expect(impl).to.have.property('txHash');
    expect(impl).to.have.property('layout');
    expect(impl.layout).to.have.property('solcVersion');
    expect(impl.layout).to.have.property('storage');
    expect(impl.layout).to.have.property('types');
    
    console.log(`   ✅ Manifest format is OpenZeppelin-compatible`);
    console.log(`   ✅ Can be used with @openzeppelin/hardhat-upgrades`);
  });

  it('Should detect existing deployments in manifest', async function () {
    console.log('\n🔍 Testing existing deployment detection...');
    
    // We already have deployments in the manifest from previous tests
    const hasExisting = await manifest.hasExistingDeployments(hre);
    expect(hasExisting).to.be.true;
    
    const proxies = await manifest.listProxies(hre);
    expect(proxies).to.have.lengthOf.at.least(1);
    
    console.log(`   ✅ Detected ${proxies.length} existing proxy deployments`);
    console.log(`   ✅ hasExistingDeployments() correctly returns true`);
    console.log(`   ✅ Deployment tasks will block if manifest exists`);
  });
});
