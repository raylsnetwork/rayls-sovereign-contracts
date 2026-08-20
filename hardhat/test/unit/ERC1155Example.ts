/**
 * @deprecated Decommissioning Teleport (vanilla, atomic).
 */
import { time, loadFixture } from '@nomicfoundation/hardhat-toolbox/network-helpers';
import { expect } from 'chai';
import hre, { ethers } from 'hardhat';
import { mockRelayerEthersLastTransaction } from './utils/RelayerMockEthers';
import { RaylsErc1155Example, ResourceRegistryV1, TokenRegistryV1 } from '../../../typechain-types';
import { basicDeploySetupUpgrade } from './utils/basicDeploySetupUpgrade';

describe('Rayls ERC1155 Example V2', function () {
  // We define a fixture to reuse the same setup in every test.
  // We use loadFixture to run this setup once, snapshot that state,
  // and reset Hardhat Network to that snapshot in every test.
  // Deploys 2 relayers, 1 private hub and 1 token on PL1

  describe('Send Message', function () {
    let tokenPN1: RaylsErc1155Example;
    let tokenPN2: RaylsErc1155Example;
    let resourceId: string;
    const tokenId = 0;

    it('Teleport (e2e, with local mock)', async function () {
      const { owner, otherAccount, endpointPN2, raylsContractFactoryPL2, endpointPN1, chainIdPN1, chainIdPN2, endpointMappings, messageIdsAlreadyProcessedOnDeploy, tokenRegistry, resourceRegistry } =
        await loadFixture(basicDeploySetupUpgrade);


      tokenPN1 = await tokenSetup({
        name: 'RaylsErc1155Example',
        pnEndpointAddress: await endpointPN1.getAddress()
      });

      const amountToTransfer = 100n;
      // Use fresh empty object instead of copying from deployment to avoid state pollution between tests
      const messageIdsAlreadyProcessed: { [messageIdConcatWithChainId: string]: boolean | null } = {};

      //await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);

      resourceId = (await registerTokenErc11155(tokenPN1, tokenRegistry, endpointMappings, messageIdsAlreadyProcessed, resourceRegistry, endpointPN1, owner)).resourceId;


      // cross chain transfer from PL1 to PL2
      await tokenPN1.teleport(otherAccount.address, tokenId, amountToTransfer, chainIdPN2, Buffer.from(tokenId.toString()));

      const txs = await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);

      const deployedContractEvent = await raylsContractFactoryPL2.queryFilter(raylsContractFactoryPL2.filters.DeployedContract);
      const deployedContractAddress = deployedContractEvent[0].args[0];

      tokenPN2 = await hre.ethers.getContractAt('RaylsErc1155Example', deployedContractAddress);

      expect(await endpointPN2.getAddressByResourceId(resourceId)).to.be.equal(deployedContractAddress);
      expect(await endpointPN1.getAddressByResourceId(resourceId)).to.be.equal(await tokenPN1.getAddress());
      expect(await tokenPN1.name()).to.be.equal(await tokenPN2.name());
      expect(await tokenPN2.balanceOf(otherAccount.address, tokenId)).to.be.equal(amountToTransfer);

      // cross chain transfer from PL2 to PL1
      const randomAddress = '0xdafea492d9c6733ae3d56b7ed1adb60692c98bc5';
      await tokenPN2.connect(otherAccount).teleport(randomAddress, tokenId, amountToTransfer, chainIdPN1, Buffer.from(tokenId.toString()));

      await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);
      expect(await tokenPN1.balanceOf(randomAddress, tokenId)).to.be.equal(amountToTransfer);
      expect(await tokenPN2.balanceOf(otherAccount.address, tokenId)).to.be.equal(0n);

    });

    it('Teleport Atomic (e2e, with local mock)', async function () {
      const { owner, otherAccount, endpointPN1, chainIdPN1, chainIdPN2, endpointMappings, account3, account4, messageIdsAlreadyProcessedOnDeploy, tokenRegistry, resourceRegistry } =
        await loadFixture(basicDeploySetupUpgrade);
      const amountToTransfer = 100n;
      // Use fresh empty object instead of copying from deployment to avoid state pollution between tests
      const messageIdsAlreadyProcessed: { [messageIdConcatWithChainId: string]: boolean | null } = {};

      tokenPN1 = await tokenSetup({
        name: 'RaylsErc1155Example',
        pnEndpointAddress: await endpointPN1.getAddress()
      });

      await registerTokenErc11155(tokenPN1, tokenRegistry, endpointMappings, messageIdsAlreadyProcessed, resourceRegistry, endpointPN1, owner);

      // cross chain transfer from PL1 to PL2
      await tokenPN1.teleportAtomic(account3.address, tokenId, amountToTransfer, chainIdPN2, Buffer.from(tokenId.toString()));

      const txs = await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);

      expect(await tokenPN2.getLockedAmount(account3.address, tokenId)).to.be.equal(amountToTransfer);

      await tokenPN2.unlock(account3.address, tokenId, amountToTransfer, Buffer.from(tokenId.toString())); // run the unlock call

      await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry); // run private hub events on pn2

      expect(await endpointPN1.getAddressByResourceId(resourceId)).to.be.equal(await tokenPN1.getAddress());
      expect(await tokenPN1.name()).to.be.equal(await tokenPN2.name());
      expect(await tokenPN2.balanceOf(account3.address, tokenId)).to.be.equal(amountToTransfer);

      // cross chain transfer from PL2 to PL1
      await tokenPN2.connect(account3).teleportAtomic(account4.address, tokenId, amountToTransfer, chainIdPN1, Buffer.from(tokenId.toString()));
      await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);
      await (await tokenPN1.unlock(account4.address, tokenId, amountToTransfer, Buffer.from(tokenId.toString()))).wait(); // run the unlock call

      expect(await tokenPN1.balanceOf(account4.address, tokenId)).to.be.equal(amountToTransfer);
      expect(await tokenPN2.balanceOf(otherAccount.address, tokenId)).to.be.equal(0n);
    });

  });

  describe('Input Validation', function () {
    async function createTokenForValidation() {
      const { owner, endpointPN1, tokenRegistry, endpointMappings, resourceRegistry } = await loadFixture(basicDeploySetupUpgrade);
      const messageIdsAlreadyProcessed: { [messageIdConcatWithChainId: string]: boolean | null } = {};

      const tokenPN1 = await tokenSetup({
        name: 'RaylsErc1155Example',
        pnEndpointAddress: await endpointPN1.getAddress()
      });

      await registerTokenErc11155(tokenPN1, tokenRegistry, endpointMappings, messageIdsAlreadyProcessed, resourceRegistry, endpointPN1, owner);
      return tokenPN1;
    }

    it('Should revert teleport with zero address', async function () {
      const { chainIdPN2 } = await loadFixture(basicDeploySetupUpgrade);
      const tokenPN1 = await createTokenForValidation();
      const tokenId = 0;
      const amount = 100;

      await expect(
        tokenPN1.teleport(ethers.ZeroAddress, tokenId, amount, chainIdPN2, Buffer.from(tokenId.toString()))
      ).to.be.revertedWithCustomError(tokenPN1, 'RaylsErc1155Handler__ZeroValueArg');
    });

    it('Should revert teleport with zero value', async function () {
      const { otherAccount, chainIdPN2 } = await loadFixture(basicDeploySetupUpgrade);
      const tokenPN1 = await createTokenForValidation();
      const tokenId = 0;
      const amount = 0;

      await expect(
        tokenPN1.teleport(otherAccount.address, tokenId, amount, chainIdPN2, Buffer.from(tokenId.toString()))
      ).to.be.revertedWithCustomError(tokenPN1, 'RaylsErc1155Handler__ZeroValueArg');
    });

    it('Should revert teleport with zero chainId', async function () {
      const { otherAccount } = await loadFixture(basicDeploySetupUpgrade);
      const tokenPN1 = await createTokenForValidation();
      const tokenId = 0;
      const amount = 100;

      await expect(
        tokenPN1.teleport(otherAccount.address, tokenId, amount, 0, Buffer.from(tokenId.toString()))
      ).to.be.revertedWithCustomError(tokenPN1, 'RaylsErc1155Handler__ZeroValueArg');
    });

    it('Should revert teleport with same chainId', async function () {
      const { otherAccount, chainIdPN1 } = await loadFixture(basicDeploySetupUpgrade);
      const tokenPN1 = await createTokenForValidation();
      const tokenId = 0;
      const amount = 100;

      await expect(
        tokenPN1.teleport(otherAccount.address, tokenId, amount, chainIdPN1, Buffer.from(tokenId.toString()))
      ).to.be.revertedWithCustomError(tokenPN1, 'RaylsErc1155Handler__WrongFunctionForSameChainId');
    });

    it('Should revert teleportAtomic with zero address', async function () {
      const { chainIdPN2 } = await loadFixture(basicDeploySetupUpgrade);
      const tokenPN1 = await createTokenForValidation();
      const tokenId = 0;
      const amount = 100;

      await expect(
        tokenPN1.teleportAtomic(ethers.ZeroAddress, tokenId, amount, chainIdPN2, Buffer.from(tokenId.toString()))
      ).to.be.revertedWithCustomError(tokenPN1, 'RaylsErc1155Handler__ZeroValueArg');
    });

    it('Should revert teleportAtomic with zero value', async function () {
      const { otherAccount, chainIdPN2 } = await loadFixture(basicDeploySetupUpgrade);
      const tokenPN1 = await createTokenForValidation();
      const tokenId = 0;
      const amount = 0;

      await expect(
        tokenPN1.teleportAtomic(otherAccount.address, tokenId, amount, chainIdPN2, Buffer.from(tokenId.toString()))
      ).to.be.revertedWithCustomError(tokenPN1, 'RaylsErc1155Handler__ZeroValueArg');
    });

    it('Should revert teleportAtomic with zero chainId', async function () {
      const { otherAccount } = await loadFixture(basicDeploySetupUpgrade);
      const tokenPN1 = await createTokenForValidation();
      const tokenId = 0;
      const amount = 100;

      await expect(
        tokenPN1.teleportAtomic(otherAccount.address, tokenId, amount, 0, Buffer.from(tokenId.toString()))
      ).to.be.revertedWithCustomError(tokenPN1, 'RaylsErc1155Handler__ZeroValueArg');
    });

    it('Should revert teleportAtomic with same chainId', async function () {
      const { otherAccount, chainIdPN1 } = await loadFixture(basicDeploySetupUpgrade);
      const tokenPN1 = await createTokenForValidation();
      const tokenId = 0;
      const amount = 100;

      await expect(
        tokenPN1.teleportAtomic(otherAccount.address, tokenId, amount, chainIdPN1, Buffer.from(tokenId.toString()))
      ).to.be.revertedWithCustomError(tokenPN1, 'RaylsErc1155Handler__WrongFunctionForSameChainId');
    });
  });

  describe('Access Control - onlyOwner Functions', function () {
    it('Should revert submitTokenRegistration when called by non-owner', async function () {
      const { endpointPN1, owner, otherAccount } = await loadFixture(basicDeploySetupUpgrade);

      const token = await tokenSetup({
        name: 'RaylsErc1155Example',
        pnEndpointAddress: await endpointPN1.getAddress()
      });

      await expect(
        token.connect(otherAccount).submitTokenRegistration(0)
      ).to.be.revertedWithCustomError(token, 'OwnableUnauthorizedAccount')
        .withArgs(otherAccount.address);
    });

    it('Should allow submitTokenRegistration when called by owner', async function () {
      const { endpointPN1, owner } = await loadFixture(basicDeploySetupUpgrade);

      const token = await tokenSetup({
        name: 'RaylsErc1155Example',
        pnEndpointAddress: await endpointPN1.getAddress()
      });

      // Grant ENDPOINT_SENDER_ROLE to token via AUTH-V3 manager
      const tokenAddress = await token.getAddress();
      const mgr1155 = await ethers.getContractAt('RaylsAccessManagerV1', await endpointPN1.authority());
      const roleId1155 = await mgr1155.getRoleIdByName('ENDPOINT_SENDER');
      await (await mgr1155.connect(owner).grantRole(roleId1155, tokenAddress, 0)).wait();

      // Should not revert
      await expect(
        token.submitTokenRegistration(0)
      ).to.not.be.reverted;
    });

    it('Should revert mint when called by non-owner', async function () {
      const { endpointPN1, otherAccount } = await loadFixture(basicDeploySetupUpgrade);

      const token = await tokenSetup({
        name: 'RaylsErc1155Example',
        pnEndpointAddress: await endpointPN1.getAddress()
      });

      await expect(
        token.connect(otherAccount).mint(otherAccount.address, 1, 100, Buffer.from(''))
      ).to.be.revertedWithCustomError(token, 'OwnableUnauthorizedAccount')
        .withArgs(otherAccount.address);
    });

    it('Should revert burn when called by non-owner', async function () {
      const { endpointPN1, otherAccount } = await loadFixture(basicDeploySetupUpgrade);

      const token = await tokenSetup({
        name: 'RaylsErc1155Example',
        pnEndpointAddress: await endpointPN1.getAddress()
      });

      await expect(
        token.connect(otherAccount).burn(otherAccount.address, 1, 100)
      ).to.be.revertedWithCustomError(token, 'OwnableUnauthorizedAccount')
        .withArgs(otherAccount.address);
    });

    it('Should revert submitTokenUpdate when called by non-owner', async function () {
      const { endpointPN1, otherAccount } = await loadFixture(basicDeploySetupUpgrade);

      const token = await tokenSetup({
        name: 'RaylsErc1155Example',
        pnEndpointAddress: await endpointPN1.getAddress()
      });

      await expect(
        token.connect(otherAccount).submitTokenUpdate(0, 1, 100) // 0 = MINT type
      ).to.be.revertedWithCustomError(token, 'OwnableUnauthorizedAccount')
        .withArgs(otherAccount.address);
    });
  });
});

async function tokenSetup(payload: { name: string; pnEndpointAddress: string }) {
  const { name, pnEndpointAddress } = payload;
  const tokenFactory = await hre.ethers.getContractFactory('RaylsErc1155Example');

  // Using environment variables for real Rayls Node parameters (not address(0) for standard tokens)
  const raylsNodeEndpointAddress = process.env['PRIVACY_NODE_A_RAYLS_NODE_ENDPOINT_ADDRESS'] || hre.ethers.ZeroAddress;
  const userGovernanceAddress = process.env['PRIVACY_NODE_A_RAYLS_NODE_USER_GOVERNANCE'] || hre.ethers.ZeroAddress;

  const token = await tokenFactory.deploy('url', name, pnEndpointAddress, raylsNodeEndpointAddress, userGovernanceAddress);

  const res = await token.waitForDeployment();

  return res;
}

async function registerTokenErc11155(tokenPN: RaylsErc1155Example, tokenRegistry: TokenRegistryV1, endpointMappings: any, messageIdsAlreadyProcessed: any, resourceRegistry: ResourceRegistryV1, endpointPN: any, owner: any) {
  console.log("registering token 1");

  // Grant ENDPOINT_SENDER_ROLE to token via AUTH-V3 manager
  const tokenAddress = await tokenPN.getAddress();
  console.log(`[ERC1155] Granting ENDPOINT_SENDER_ROLE to token ${tokenAddress}`);
  const mgr = await ethers.getContractAt('RaylsAccessManagerV1', await endpointPN.authority());
  const roleId = await mgr.getRoleIdByName('ENDPOINT_SENDER');
  await (await mgr.connect(owner).grantRole(roleId, tokenAddress, 0)).wait();

  await tokenPN.submitTokenRegistration(2);
  await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);
  console.log("registering token 2");
  const token = (await tokenRegistry.getAllTokens())[0];
  console.log("registering token 3");
  await tokenRegistry.updateStatus(token.resourceId, 1); // approve tokens
  console.log("registering token 4");
  await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);
  console.log("registering token 5");
  return token;
}
