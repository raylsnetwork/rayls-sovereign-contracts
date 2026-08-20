import { expect } from 'chai';
import { ethers } from 'hardhat';
import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';

describe('UUPS Upgradability Test - Manual Deployment', function () {
  let owner: SignerWithAddress;
  let nonOwner: SignerWithAddress;
  let proxyAddress: string;
  let implV1Address: string;
  let implV2Address: string;

  before(async function () {
    [owner, nonOwner] = await ethers.getSigners();
  });

  it('Should deploy TestContractV1 using manual UUPS deployment', async function () {
    console.log('\n📦 Step 1: Deploy V1 via Manual UUPS Proxy');
    
    // 1. Deploy implementation V1
    const V1Factory = await ethers.getContractFactory('TestContractV1');
    const implV1 = await V1Factory.deploy();
    await implV1.waitForDeployment();
    implV1Address = await implV1.getAddress();
    console.log(`   ✅ Implementation V1 deployed: ${implV1Address}`);

    // 2. Encode initialization data
    const initData = V1Factory.interface.encodeFunctionData('initialize', [owner.address]);
    
    // 3. Deploy RaylsERC1967Proxy pointing to implementation
    const ProxyFactory = await ethers.getContractFactory('RaylsERC1967Proxy');
    const proxy = await ProxyFactory.deploy(implV1Address, initData);
    await proxy.waitForDeployment();
    proxyAddress = await proxy.getAddress();
    console.log(`   ✅ Proxy deployed: ${proxyAddress}`);
    
    // 4. Get proxy as TestContractV1 interface
    const contractProxy = V1Factory.attach(proxyAddress) as any;
    
    // 5. Verify initialization worked
    const version = await contractProxy.version();
    expect(version).to.equal(1n);
    console.log(`   ✅ Contract version: ${version}`);
    
    const val1 = await contractProxy.getVal1();
    expect(val1).to.equal(0n);
    console.log(`   ✅ Initial _val1: ${val1}`);
  });

  it('Should be able to use V1 getters and setters', async function () {
    console.log('\n📦 Step 2: Test V1 Functionality');
    
    const V1Factory = await ethers.getContractFactory('TestContractV1');
    const contractProxy = V1Factory.attach(proxyAddress) as any;
    
    // Set _val1 to 42
    console.log(`   🔧 Setting _val1 to 42...`);
    const setTx = await contractProxy.setVal1(42);
    await setTx.wait();
    
    // Get _val1 and verify
    const val1 = await contractProxy.getVal1();
    expect(val1).to.equal(42n);
    console.log(`   ✅ _val1 getter works: ${val1}`);
    
    // Set _val1 to 100
    console.log(`   🔧 Setting _val1 to 100...`);
    await (await contractProxy.setVal1(100)).wait();
    
    const val1Updated = await contractProxy.getVal1();
    expect(val1Updated).to.equal(100n);
    console.log(`   ✅ _val1 setter works: ${val1Updated}`);
  });

  it('Should be able to upgrade the proxy to V2', async function () {
    console.log('\n📦 Step 3: Upgrade V1 → V2');
    
    // 1. Deploy new implementation V2
    const V2Factory = await ethers.getContractFactory('TestContractV2');
    const implV2 = await V2Factory.deploy();
    await implV2.waitForDeployment();
    implV2Address = await implV2.getAddress();
    console.log(`   ✅ Implementation V2 deployed: ${implV2Address}`);
    
    // 2. Get proxy as V1 to perform upgrade
    const V1Factory = await ethers.getContractFactory('TestContractV1');
    const contractProxy = V1Factory.attach(proxyAddress) as any;
    
    // 3. Call upgradeToAndCall (UUPS upgrade function)
    console.log(`   🔧 Calling upgradeToAndCall()...`);
    const upgradeTx = await contractProxy.upgradeToAndCall(implV2Address, '0x');
    await upgradeTx.wait();
    console.log(`   ✅ Upgraded proxy to V2 implementation`);
    
    // 4. Get proxy as V2 interface
    const contractProxyV2 = V2Factory.attach(proxyAddress) as any;
    
    // 5. Verify version changed
    const version = await contractProxyV2.version();
    expect(version).to.equal(2n);
    console.log(`   ✅ Version after upgrade: ${version}`);
    
    // 6. Verify V1 state was preserved
    const val1 = await contractProxyV2.getVal1();
    expect(val1).to.equal(100n);
    console.log(`   ✅ V1 state preserved: _val1 = ${val1}`);
    
    // 7. Verify V2 storage initialized to 0
    const val2 = await contractProxyV2.getVal2();
    expect(val2).to.equal(0n);
    console.log(`   ✅ V2 storage initialized: _val2 = ${val2}`);
  });

  it('Should be able to use both V1 and V2 getters/setters after upgrade', async function () {
    console.log('\n📦 Step 4: Test V2 Functionality (V1 + V2 storage)');
    
    const V2Factory = await ethers.getContractFactory('TestContractV2');
    const contractProxyV2 = V2Factory.attach(proxyAddress) as any;
    
    // Test V1 functionality still works
    console.log(`   🔧 Testing V1 storage (_val1)...`);
    const val1Before = await contractProxyV2.getVal1();
    console.log(`   📊 Current _val1: ${val1Before}`);
    
    await (await contractProxyV2.setVal1(200)).wait();
    const val1After = await contractProxyV2.getVal1();
    expect(val1After).to.equal(200n);
    console.log(`   ✅ V1 setter/getter works: _val1 = ${val1After}`);
    
    // Test V2 functionality
    console.log(`   🔧 Testing V2 storage (_val2)...`);
    const val2Before = await contractProxyV2.getVal2();
    expect(val2Before).to.equal(0n);
    console.log(`   📊 Current _val2: ${val2Before}`);
    
    await (await contractProxyV2.setVal2(42)).wait();
    const val2After = await contractProxyV2.getVal2();
    expect(val2After).to.equal(42n);
    console.log(`   ✅ V2 setter/getter works: _val2 = ${val2After}`);
    
    // Verify V1 storage wasn't affected by V2 operations
    const val1Final = await contractProxyV2.getVal1();
    expect(val1Final).to.equal(200n);
    console.log(`   ✅ V1 storage unaffected by V2: _val1 = ${val1Final}`);
    
    // Set both values again to ensure no interference
    await (await contractProxyV2.setVal1(999)).wait();
    await (await contractProxyV2.setVal2(888)).wait();
    
    expect(await contractProxyV2.getVal1()).to.equal(999n);
    expect(await contractProxyV2.getVal2()).to.equal(888n);
    console.log(`   ✅ Both storage variables work independently`);
    console.log(`   📊 Final state: _val1 = 999, _val2 = 888`);
  });

  it('Should verify the implementation address changed', async function () {
    console.log('\n📦 Step 5: Verify Implementation Changed');
    
    // Read the implementation slot from the proxy
    // ERC1967 implementation slot: 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
    const IMPLEMENTATION_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';
    
    const implSlotValue = await ethers.provider.getStorage(proxyAddress, IMPLEMENTATION_SLOT);
    const currentImplAddress = ethers.getAddress('0x' + implSlotValue.slice(-40));
    
    console.log(`   📍 Current implementation: ${currentImplAddress}`);
    console.log(`   📍 V1 implementation: ${implV1Address}`);
    console.log(`   📍 V2 implementation: ${implV2Address}`);
    
    expect(currentImplAddress.toLowerCase()).to.equal(implV2Address.toLowerCase());
    expect(currentImplAddress.toLowerCase()).to.not.equal(implV1Address.toLowerCase());
    console.log(`   ✅ Implementation successfully upgraded from V1 to V2!`);
  });

  it('Should prevent non-owner from upgrading', async function () {
    console.log('\n📦 Step 6: Test Access Control');
    
    const V2Factory = await ethers.getContractFactory('TestContractV2');
    const contractProxy = V2Factory.attach(proxyAddress) as any;
    
    const V1Factory = await ethers.getContractFactory('TestContractV1');
    const newImpl = await V1Factory.deploy();
    await newImpl.waitForDeployment();
    const newImplAddress = await newImpl.getAddress();
    
    // Try to upgrade as non-owner (should fail)
    await expect(
      contractProxy.connect(nonOwner).upgradeToAndCall(newImplAddress, '0x')
    ).to.be.reverted;
    
    console.log(`   ✅ Non-owner cannot upgrade (access control working)`);
  });
});
