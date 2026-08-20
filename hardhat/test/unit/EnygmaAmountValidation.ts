import { loadFixture } from '@nomicfoundation/hardhat-toolbox/network-helpers';
import { expect } from 'chai';
import hre, { ethers } from 'hardhat';
import { basicDeploySetupUpgrade } from './utils/basicDeploySetupUpgrade';
import { deployAndRegisterEnygmaToken } from './utils/tokens';

describe('Enygma Amount Validation', function () {
  async function deployEnygmaFixture() {
    const {
      endpointMappings,
      endpointPN1,
      resourceRegistry,
      tokenRegistry,
    } = await loadFixture(basicDeploySetupUpgrade);

    const messageIdsAlreadyProcessed: { [messageIdConcatWithChainId: string]: boolean | null } = {};
    const enygmaToken = await deployAndRegisterEnygmaToken(
      ethers,
      tokenRegistry,
      endpointMappings,
      messageIdsAlreadyProcessed,
      resourceRegistry,
      await endpointPN1.getAddress()
    );

    const [, user] = await ethers.getSigners();

    return { enygmaToken, user };
  }

  describe('mint', function () {
    it('should revert when minting zero amount', async function () {
      const { enygmaToken, user } = await loadFixture(deployEnygmaFixture);
      await expect(
        enygmaToken.mint(user.address, 0)
      ).to.be.revertedWithCustomError(enygmaToken, 'RaylsEnygmaHandler__ZeroAmount');
    });

    it('should succeed when minting 1 wei', async function () {
      const { enygmaToken, user } = await loadFixture(deployEnygmaFixture);
      await enygmaToken.mint(user.address, 1);
      expect(await enygmaToken.balanceOf(user.address)).to.equal(1);
    });

    it('should succeed when minting a normal amount', async function () {
      const { enygmaToken, user } = await loadFixture(deployEnygmaFixture);
      const amount = ethers.parseUnits('100', 18);
      await enygmaToken.mint(user.address, amount);
      expect(await enygmaToken.balanceOf(user.address)).to.equal(amount);
    });
  });

  describe('burn', function () {
    it('should revert when burning zero amount', async function () {
      const { enygmaToken, user } = await loadFixture(deployEnygmaFixture);
      const amount = ethers.parseUnits('100', 18);
      await enygmaToken.mint(user.address, amount);

      await expect(
        enygmaToken.burn(user.address, 0)
      ).to.be.revertedWithCustomError(enygmaToken, 'RaylsEnygmaHandler__ZeroAmount');
    });

    it('should succeed when burning a valid amount', async function () {
      const { enygmaToken, user } = await loadFixture(deployEnygmaFixture);
      const amount = ethers.parseUnits('100', 18);
      await enygmaToken.mint(user.address, amount);
      await enygmaToken.burn(user.address, amount);
      expect(await enygmaToken.balanceOf(user.address)).to.equal(0);
    });
  });

  describe('depositToDvp', function () {
    it('should revert when depositing zero amount', async function () {
      const { enygmaToken, user } = await loadFixture(deployEnygmaFixture);
      await expect(
        enygmaToken.connect(user).depositToDvp(0)
      ).to.be.revertedWithCustomError(enygmaToken, 'RaylsEnygmaHandler__ZeroAmount');
    });
  });

  describe('callWithdrawFromDvp', function () {
    it('should revert when withdrawing zero amount', async function () {
      const { enygmaToken, user } = await loadFixture(deployEnygmaFixture);
      await expect(
        enygmaToken.connect(user).callWithdrawFromDvp(0)
      ).to.be.revertedWithCustomError(enygmaToken, 'RaylsEnygmaHandler__ZeroAmount');
    });
  });

  describe('decimals', function () {
    it('should return 18 decimals for the test token', async function () {
      const { enygmaToken } = await loadFixture(deployEnygmaFixture);
      expect(await enygmaToken.decimals()).to.equal(18);
    });

    it('should correctly convert human-readable amounts to base units', async function () {
      const { enygmaToken } = await loadFixture(deployEnygmaFixture);
      const decimals = await enygmaToken.decimals();

      // Verify parseUnits produces expected values
      const amount1 = ethers.parseUnits('1', decimals);
      expect(amount1).to.equal(ethers.parseEther('1'));

      const amount100 = ethers.parseUnits('100', decimals);
      expect(amount100).to.equal(ethers.parseEther('100'));

      // Fractional amount
      const amountFractional = ethers.parseUnits('0.5', decimals);
      expect(amountFractional).to.equal(ethers.parseEther('0.5'));
    });
  });
});
