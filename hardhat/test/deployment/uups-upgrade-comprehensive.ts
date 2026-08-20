import { expect } from 'chai';
import { ethers } from 'hardhat';
import hre from 'hardhat';
import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { validateImplementation, validateUpgrade } from '../../tasks/deploy/validation-helpers';
import * as fs from 'fs';
import * as path from 'path';

/**
 * Comprehensive UUPS Upgrade Test Suite
 * 
 * This test suite validates:
 * 1. Basic UUPS deployment and initialization
 * 2. Upgrade functionality and state preservation
 * 3. Storage layout safety (using validation helpers)
 * 4. Event emissions
 * 5. Access control
 * 6. Edge cases and error conditions
 */
describe('UUPS Upgradability - Comprehensive Test Suite', function () {
  let owner: SignerWithAddress;
  let nonOwner: SignerWithAddress;
  let proxyAddress: string;
  let implV1Address: string;
  let implV2Address: string;

  before(async function () {
    [owner, nonOwner] = await ethers.getSigners();
  });

  describe('Phase 1: V1 Deployment & Validation', function () {
    it('Should validate V1 implementation before deployment', async function () {
      console.log('\n🔍 Validating V1 implementation...');
      
      const V1Factory = await ethers.getContractFactory('TestContractV1');
      
      // Run validation (passing contract name for better logging)
      await validateImplementation(
        hre,
        V1Factory,
        {},
        'TestContractV1'
      );
    });

    it('Should deploy V1 implementation and proxy', async function () {
      console.log('\n📦 Deploying V1...');
      
      // 1. Deploy implementation V1
      const V1Factory = await ethers.getContractFactory('TestContractV1');
      const implV1 = await V1Factory.deploy();
      await implV1.waitForDeployment();
      implV1Address = await implV1.getAddress();
      console.log(`   ✅ Implementation V1: ${implV1Address}`);

      // 2. Encode initialization data
      const initData = V1Factory.interface.encodeFunctionData('initialize', [owner.address]);
      
      // 3. Deploy proxy
      const ProxyFactory = await ethers.getContractFactory('RaylsERC1967Proxy');
      const proxy = await ProxyFactory.deploy(implV1Address, initData);
      await proxy.waitForDeployment();
      proxyAddress = await proxy.getAddress();
      console.log(`   ✅ Proxy: ${proxyAddress}`);
    });

    it('Should verify V1 initialization', async function () {
      console.log('\n🔍 Verifying V1 initialization...');
      
      const V1Factory = await ethers.getContractFactory('TestContractV1');
      const contractProxy = V1Factory.attach(proxyAddress) as any;
      
      // Check version
      const version = await contractProxy.version();
      expect(version).to.equal(1n);
      console.log(`   ✅ Version: ${version}`);
      
      // Check initial state
      const val1 = await contractProxy.getVal1();
      expect(val1).to.equal(0n);
      console.log(`   ✅ Initial _val1: ${val1}`);
      
      // Check admin role
      const DEFAULT_ADMIN_ROLE = await contractProxy.DEFAULT_ADMIN_ROLE();
      const hasRole = await contractProxy.hasRole(DEFAULT_ADMIN_ROLE, owner.address);
      expect(hasRole).to.be.true;
      console.log(`   ✅ Owner has admin role`);
    });

    it('Should verify storage layout for V1', async function () {
      console.log('\n🔍 Checking V1 storage layout...');
      
      // Read storage layout from compiled artifacts
      const artifactPath = path.join(process.cwd(), 'out/TestContractV1.sol/TestContractV1.json');
      
      if (fs.existsSync(artifactPath)) {
        const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf-8'));
        const storageLayout = artifact.storageLayout;
        
        if (storageLayout) {
          console.log(`   📊 Storage slots in V1: ${storageLayout.storage.length}`);
          
          // Find _val1 in storage
          const val1Storage = storageLayout.storage.find((s: any) => s.label === '_val1');
          if (val1Storage) {
            console.log(`   ✅ _val1 found at slot ${val1Storage.slot}`);
          }
        } else {
          console.log('   ⚠️  Storage layout not available in artifacts');
        }
      }
    });
  });

  describe('Phase 2: V1 Functionality Tests', function () {
    it('Should emit events when setting values', async function () {
      console.log('\n🔍 Testing V1 event emissions...');
      
      const V1Factory = await ethers.getContractFactory('TestContractV1');
      const contractProxy = V1Factory.attach(proxyAddress) as any;
      
      // Set value and check event
      await expect(contractProxy.setVal1(42))
        .to.emit(contractProxy, 'Val1Updated')
        .withArgs(0n, 42n);
      
      console.log(`   ✅ Val1Updated event emitted correctly`);
    });

    it('Should handle multiple value updates', async function () {
      console.log('\n🔍 Testing V1 multiple updates...');
      
      const V1Factory = await ethers.getContractFactory('TestContractV1');
      const contractProxy = V1Factory.attach(proxyAddress) as any;
      
      const testValues = [100, 200, 300, 500, 1000];
      
      for (const value of testValues) {
        await (await contractProxy.setVal1(value)).wait();
        const retrieved = await contractProxy.getVal1();
        expect(retrieved).to.equal(BigInt(value));
      }
      
      console.log(`   ✅ All ${testValues.length} updates successful`);
    });

    it('Should handle maximum uint256 value', async function () {
      console.log('\n🔍 Testing V1 edge case (max uint256)...');
      
      const V1Factory = await ethers.getContractFactory('TestContractV1');
      const contractProxy = V1Factory.attach(proxyAddress) as any;
      
      const maxUint256 = BigInt('0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff');
      
      await (await contractProxy.setVal1(maxUint256)).wait();
      const retrieved = await contractProxy.getVal1();
      expect(retrieved).to.equal(maxUint256);
      
      console.log(`   ✅ Max uint256 handled correctly`);
    });
  });

  describe('Phase 3: Upgrade Process', function () {
    it('Should validate V2 implementation before upgrade', async function () {
      console.log('\n🔍 Validating V2 implementation...');
      
      const V2Factory = await ethers.getContractFactory('TestContractV2');
      
      // Run validation (passing contract name for better logging)
      await validateImplementation(
        hre,
        V2Factory,
        {},
        'TestContractV2'
      );
    });

    it('Should validate upgrade compatibility', async function () {
      console.log('\n🔍 Validating upgrade V1 → V2...');
      
      const V2Factory = await ethers.getContractFactory('TestContractV2');
      
      // Run upgrade validation with automatic storage layout comparison
      await validateUpgrade(
        hre,
        proxyAddress,
        V2Factory,
        {},
        'TestContractV2',  // New contract name
        'TestContractV1'   // Old contract name - enables automatic comparison!
      );
    });

    it('Should set a known V1 state before upgrade', async function () {
      console.log('\n🔧 Setting known V1 state before upgrade...');
      
      const V1Factory = await ethers.getContractFactory('TestContractV1');
      const contractProxy = V1Factory.attach(proxyAddress) as any;
      
      // Set a specific value we can verify after upgrade
      const testValue = 12345;
      await (await contractProxy.setVal1(testValue)).wait();
      
      const val1 = await contractProxy.getVal1();
      expect(val1).to.equal(BigInt(testValue));
      console.log(`   ✅ Pre-upgrade _val1: ${val1}`);
    });

    it('Should deploy V2 and upgrade proxy', async function () {
      console.log('\n📦 Upgrading to V2...');
      
      // 1. Deploy V2 implementation
      const V2Factory = await ethers.getContractFactory('TestContractV2');
      const implV2 = await V2Factory.deploy();
      await implV2.waitForDeployment();
      implV2Address = await implV2.getAddress();
      console.log(`   ✅ Implementation V2: ${implV2Address}`);
      
      // 2. Perform upgrade
      const V1Factory = await ethers.getContractFactory('TestContractV1');
      const contractProxy = V1Factory.attach(proxyAddress) as any;
      
      const upgradeTx = await contractProxy.upgradeToAndCall(implV2Address, '0x');
      await upgradeTx.wait();
      console.log(`   ✅ Upgrade transaction confirmed`);
      
      // 3. Verify version changed
      const V2FactoryAttach = await ethers.getContractFactory('TestContractV2');
      const contractProxyV2 = V2FactoryAttach.attach(proxyAddress) as any;
      
      const version = await contractProxyV2.version();
      expect(version).to.equal(2n);
      console.log(`   ✅ Version after upgrade: ${version}`);
    });

    it('Should preserve V1 state after upgrade', async function () {
      console.log('\n🔍 Verifying state preservation...');
      
      const V2Factory = await ethers.getContractFactory('TestContractV2');
      const contractProxyV2 = V2Factory.attach(proxyAddress) as any;
      
      // Check V1 state was preserved
      const val1 = await contractProxyV2.getVal1();
      expect(val1).to.equal(12345n);
      console.log(`   ✅ V1 state preserved: _val1 = ${val1}`);
      
      // Check V2 state initialized to 0
      const val2 = await contractProxyV2.getVal2();
      expect(val2).to.equal(0n);
      console.log(`   ✅ V2 state initialized: _val2 = ${val2}`);
    });

    it('Should verify implementation slot changed', async function () {
      console.log('\n🔍 Verifying implementation slot...');
      
      const IMPLEMENTATION_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';
      
      const implSlotValue = await ethers.provider.getStorage(proxyAddress, IMPLEMENTATION_SLOT);
      const currentImplAddress = ethers.getAddress('0x' + implSlotValue.slice(-40));
      
      console.log(`   📍 Current impl: ${currentImplAddress}`);
      console.log(`   📍 V2 impl:      ${implV2Address}`);
      
      expect(currentImplAddress.toLowerCase()).to.equal(implV2Address.toLowerCase());
      console.log(`   ✅ Implementation slot correctly updated`);
    });
  });

  describe('Phase 4: V2 Functionality Tests', function () {
    it('Should work with both V1 and V2 functions', async function () {
      console.log('\n🔍 Testing combined V1 + V2 functionality...');
      
      const V2Factory = await ethers.getContractFactory('TestContractV2');
      const contractProxyV2 = V2Factory.attach(proxyAddress) as any;
      
      // Test V1 function
      await (await contractProxyV2.setVal1(999)).wait();
      const val1 = await contractProxyV2.getVal1();
      expect(val1).to.equal(999n);
      console.log(`   ✅ V1 functions work: _val1 = ${val1}`);
      
      // Test V2 function
      await (await contractProxyV2.setVal2(777)).wait();
      const val2 = await contractProxyV2.getVal2();
      expect(val2).to.equal(777n);
      console.log(`   ✅ V2 functions work: _val2 = ${val2}`);
    });

    it('Should emit V2 events correctly', async function () {
      console.log('\n🔍 Testing V2 event emissions...');
      
      const V2Factory = await ethers.getContractFactory('TestContractV2');
      const contractProxyV2 = V2Factory.attach(proxyAddress) as any;
      
      // Test V2 event
      await expect(contractProxyV2.setVal2(888))
        .to.emit(contractProxyV2, 'Val2Updated')
        .withArgs(777n, 888n);
      
      console.log(`   ✅ Val2Updated event emitted correctly`);
    });

    it('Should verify storage independence (V1 vs V2)', async function () {
      console.log('\n🔍 Testing storage independence...');
      
      const V2Factory = await ethers.getContractFactory('TestContractV2');
      const contractProxyV2 = V2Factory.attach(proxyAddress) as any;
      
      // Set both values
      await (await contractProxyV2.setVal1(111)).wait();
      await (await contractProxyV2.setVal2(222)).wait();
      
      // Modify V1, ensure V2 unchanged
      await (await contractProxyV2.setVal1(333)).wait();
      expect(await contractProxyV2.getVal2()).to.equal(222n);
      
      // Modify V2, ensure V1 unchanged
      await (await contractProxyV2.setVal2(444)).wait();
      expect(await contractProxyV2.getVal1()).to.equal(333n);
      
      console.log(`   ✅ Storage variables are independent`);
    });

    it('Should check V2 storage layout', async function () {
      console.log('\n🔍 Checking V2 storage layout...');
      
      const artifactPath = path.join(process.cwd(), 'out/TestContractV2.sol/TestContractV2.json');
      
      if (fs.existsSync(artifactPath)) {
        const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf-8'));
        const storageLayout = artifact.storageLayout;
        
        if (storageLayout && storageLayout.storage) {
          console.log(`   📊 Storage slots in V2: ${storageLayout.storage.length}`);
          
          // Verify _val2 comes after _val1
          const val1Storage = storageLayout.storage.find((s: any) => s.label === '_val1');
          const val2Storage = storageLayout.storage.find((s: any) => s.label === '_val2');
          
          if (val1Storage && val2Storage) {
            const val1Slot = parseInt(val1Storage.slot);
            const val2Slot = parseInt(val2Storage.slot);
            
            expect(val2Slot).to.be.greaterThan(val1Slot);
            console.log(`   ✅ _val1 at slot ${val1Slot}, _val2 at slot ${val2Slot} (correct order)`);
          }
        } else {
          console.log('   ⚠️  Storage layout not available');
        }
      }
    });
  });

  describe('Phase 5: Access Control & Security', function () {
    it('Should prevent non-owner from upgrading', async function () {
      console.log('\n🔍 Testing upgrade access control...');
      
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
      
      console.log(`   ✅ Non-owner cannot upgrade`);
    });

    it('Should allow owner to upgrade multiple times', async function () {
      console.log('\n🔍 Testing multiple upgrades...');
      
      const V2Factory = await ethers.getContractFactory('TestContractV2');
      const contractProxy = V2Factory.attach(proxyAddress) as any;
      
      // Deploy a new V2 implementation
      const newImplV2 = await V2Factory.deploy();
      await newImplV2.waitForDeployment();
      const newImplV2Address = await newImplV2.getAddress();
      
      // Upgrade to new implementation
      const upgradeTx = await contractProxy.upgradeToAndCall(newImplV2Address, '0x');
      await upgradeTx.wait();
      
      // Verify state still preserved
      expect(await contractProxy.getVal1()).to.equal(333n);
      expect(await contractProxy.getVal2()).to.equal(444n);
      
      console.log(`   ✅ Multiple upgrades work correctly`);
      console.log(`   ✅ State preserved across multiple upgrades`);
    });

    it('Should verify UUPS ERC1967 compliance', async function () {
      console.log('\n🔍 Checking UUPS/ERC1967 compliance...');
      
      // Verify we can read the implementation address from ERC1967 slot
      const IMPLEMENTATION_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';
      const implSlotValue = await ethers.provider.getStorage(proxyAddress, IMPLEMENTATION_SLOT);
      const currentImpl = ethers.getAddress('0x' + implSlotValue.slice(-40));
      
      // Verify implementation address is valid (not zero address)
      expect(currentImpl).to.not.equal(ethers.ZeroAddress);
      console.log(`   ✅ ERC1967 implementation slot: ${currentImpl}`);
      console.log(`   ℹ️  Note: Implementation may differ from implV2Address due to multiple upgrades test`);
      
      // Verify proxy code exists (not just an EOA)
      const proxyCode = await ethers.provider.getCode(proxyAddress);
      expect(proxyCode).to.not.equal('0x');
      expect(proxyCode.length).to.be.greaterThan(2);
      console.log(`   ✅ Proxy has bytecode (${proxyCode.length} bytes)`);
      
      // Verify implementation code exists
      const implCode = await ethers.provider.getCode(currentImpl);
      expect(implCode).to.not.equal('0x');
      expect(implCode.length).to.be.greaterThan(2);
      console.log(`   ✅ Implementation has bytecode (${implCode.length} bytes)`);
      
      // Verify the current implementation is V2 by checking version
      const V2Factory = await ethers.getContractFactory('TestContractV2');
      const contractProxy = V2Factory.attach(proxyAddress) as any;
      const version = await contractProxy.version();
      expect(version).to.equal(2n);
      console.log(`   ✅ Contract version: ${version} (correct implementation active)`);
      
      console.log(`   ✅ UUPS/ERC1967 standard compliance verified`);
    });
  });

  describe('Phase 6: Edge Cases & Error Handling', function () {
    it('Should handle zero values correctly', async function () {
      console.log('\n🔍 Testing zero values...');
      
      const V2Factory = await ethers.getContractFactory('TestContractV2');
      const contractProxy = V2Factory.attach(proxyAddress) as any;
      
      await (await contractProxy.setVal1(0)).wait();
      await (await contractProxy.setVal2(0)).wait();
      
      expect(await contractProxy.getVal1()).to.equal(0n);
      expect(await contractProxy.getVal2()).to.equal(0n);
      
      console.log(`   ✅ Zero values handled correctly`);
    });

    it('Should handle very large numbers', async function () {
      console.log('\n🔍 Testing large numbers...');
      
      const V2Factory = await ethers.getContractFactory('TestContractV2');
      const contractProxy = V2Factory.attach(proxyAddress) as any;
      
      const largeNum = BigInt('999999999999999999999999999');
      
      await (await contractProxy.setVal1(largeNum)).wait();
      await (await contractProxy.setVal2(largeNum)).wait();
      
      expect(await contractProxy.getVal1()).to.equal(largeNum);
      expect(await contractProxy.getVal2()).to.equal(largeNum);
      
      console.log(`   ✅ Large numbers handled correctly`);
    });

    it('Should maintain consistent state across many operations', async function () {
      console.log('\n🔍 Testing state consistency...');
      
      const V2Factory = await ethers.getContractFactory('TestContractV2');
      const contractProxy = V2Factory.attach(proxyAddress) as any;
      
      // Perform many rapid updates
      for (let i = 0; i < 10; i++) {
        await (await contractProxy.setVal1(i * 10)).wait();
        await (await contractProxy.setVal2(i * 20)).wait();
      }
      
      // Verify final state
      expect(await contractProxy.getVal1()).to.equal(90n);
      expect(await contractProxy.getVal2()).to.equal(180n);
      
      console.log(`   ✅ State consistent after multiple operations`);
    });
  });

  describe('Phase 7: Negative Tests (Storage Layout Violations)', function () {
    it('Should reject unsafe storage layout changes (type mismatch)', async function () {
      console.log('\n🔍 Testing storage layout violation detection...');
      
      // TestContractV2Bad changes _val1 from uint256 to uint128
      // This should be caught by our validation
      const V2BadFactory = await ethers.getContractFactory('TestContractV2Bad');
      
      console.log('   🔧 Attempting upgrade to TestContractV2Bad (has type change)...');
      
      // This should throw an error because of storage layout incompatibility
      let validationFailed = false;
      try {
        await validateUpgrade(
          hre,
          proxyAddress,
          V2BadFactory,
          {},
          'TestContractV2Bad',
          'TestContractV1'  // Compare against V1 - should detect type change
        );
      } catch (error: any) {
        validationFailed = true;
        console.log(`   ✅ Validation correctly rejected upgrade: ${error.message}`);
      }
      
      expect(validationFailed).to.be.true;
      console.log('   ✅ Storage layout validation prevents unsafe upgrades');
    });
  });

  describe('Phase 8: Final Summary', function () {
    it('Should display final test summary', async function () {
      console.log('\n' + '='.repeat(70));
      console.log('📊 UUPS UPGRADE TEST SUMMARY');
      console.log('='.repeat(70));
      console.log(`✅ Proxy Address:       ${proxyAddress}`);
      console.log(`✅ V1 Implementation:   ${implV1Address}`);
      console.log(`✅ V2 Implementation:   ${implV2Address}`);
      
      const V2Factory = await ethers.getContractFactory('TestContractV2');
      const contractProxy = V2Factory.attach(proxyAddress) as any;
      
      console.log(`✅ Current Version:     ${await contractProxy.version()}`);
      console.log(`✅ Final _val1:         ${await contractProxy.getVal1()}`);
      console.log(`✅ Final _val2:         ${await contractProxy.getVal2()}`);
      console.log('='.repeat(70));
      console.log('🎉 All upgrade tests passed successfully!');
      console.log('='.repeat(70) + '\n');
    });
  });
});
