/**
 * @deprecated Decommissioning Teleport (vanilla, atomic).
 */
import { loadFixture } from '@nomicfoundation/hardhat-network-helpers';
import { expect } from 'chai';
import hre, { ethers } from 'hardhat';
import { mockRelayerEthersLastTransaction } from './utils/RelayerMockEthers';
import { basicDeploySetupUpgrade } from './utils/basicDeploySetupUpgrade';
import { deployAndRegisterToken } from './utils/tokens';


describe('Rayls ERC20 Example V1', function () {
  // We define a fixture to reuse the same setup in every test.
  // We use loadFixture to run this setup once, snapshot that state,
  // and reset Hardhat Network to that snapshot in every test.
  // Deploys 2 relayers, 1 private hub and 1 token on PN1

  describe('Input Validation', function () {
    const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';
    const AMOUNT = 30;
    const ZERO_AMOUNT = 0;
    const ZERO_CHAINID = "0";
    const SAME_CHAINID = "12345";

    async function createTokenForValidation() {
      const { endpointPN1, tokenRegistry, endpointMappings, resourceRegistry } = await loadFixture(basicDeploySetupUpgrade);
      const messageIdsAlreadyProcessed: { [messageIdConcatWithChainId: string]: boolean | null } = {};
      const token = await deployAndRegisterToken(ethers, tokenRegistry, endpointMappings, messageIdsAlreadyProcessed, resourceRegistry, await endpointPN1.getAddress());

      return token;
    }

    describe('teleport', function () {
      it('Should revert with RaylsErc20Handler__ZeroValueArg when value is zero', async function () {
        const { otherAccount, chainIdPN2 } = await loadFixture(basicDeploySetupUpgrade);
        const tokenPN1 = await createTokenForValidation();

        await expect(
          tokenPN1.teleport(
            otherAccount.address,
            ZERO_AMOUNT, // Zero value
            chainIdPN2
          )
        ).to.be.revertedWithCustomError(
          tokenPN1,
          'RaylsErc20Handler__ZeroValueArg'
        );
      });

      it('Should revert with RaylsErc20Handler__ZeroValueArg when address is zero', async function () {
        const { chainIdPN2 } = await loadFixture(basicDeploySetupUpgrade);
        const tokenPN1 = await createTokenForValidation();

        await expect(
          tokenPN1.teleport(
            ZERO_ADDRESS, // Zero address
            AMOUNT,
            chainIdPN2
          )
        ).to.be.revertedWithCustomError(
          tokenPN1,
          'RaylsErc20Handler__ZeroValueArg'
        );
      });

      it('Should revert with RaylsErc20Handler__ZeroValueArg when chainID is zero', async function () {
        const { otherAccount } = await loadFixture(basicDeploySetupUpgrade);
        const tokenPN1 = await createTokenForValidation();

        await expect(
          tokenPN1.teleport(
            otherAccount.address,
            AMOUNT,
            ZERO_CHAINID // Zero chainId
          )
        ).to.be.revertedWithCustomError(
          tokenPN1,
          'RaylsErc20Handler__ZeroValueArg'
        );
      });

      it('Should revert with RaylsErc20Handler__WrongFunctionForSameChainId when chainID is same as current', async function () {
        const { otherAccount, chainIdPN1 } = await loadFixture(basicDeploySetupUpgrade);
        const tokenPN1 = await createTokenForValidation();

        await expect(
          tokenPN1.teleport(
            otherAccount.address,
            AMOUNT,
            chainIdPN1 // same chainId as current chain
          )
        ).to.be.revertedWithCustomError(
          tokenPN1,
          'RaylsErc20Handler__WrongFunctionForSameChainId'
        );
      });
    });

    describe('teleportAtomic', function () {
      it('Should revert with RaylsErc20Handler__ZeroValueArg when value is zero', async function () {
        const { otherAccount, chainIdPN2 } = await loadFixture(basicDeploySetupUpgrade);
        const tokenPN1 = await createTokenForValidation();

        await expect(
          tokenPN1.teleportAtomic(
            otherAccount.address,
            ZERO_AMOUNT, // Zero value
            chainIdPN2
          )
        ).to.be.revertedWithCustomError(
          tokenPN1,
          'RaylsErc20Handler__ZeroValueArg'
        );
      });

      it('Should revert with RaylsErc20Handler__ZeroValueArg when address is zero', async function () {
        const { chainIdPN2 } = await loadFixture(basicDeploySetupUpgrade);
        const tokenPN1 = await createTokenForValidation();

        await expect(
          tokenPN1.teleportAtomic(
            ZERO_ADDRESS, // Zero address
            AMOUNT,
            chainIdPN2
          )
        ).to.be.revertedWithCustomError(
          tokenPN1,
          'RaylsErc20Handler__ZeroValueArg'
        );
      });

      it('Should revert with RaylsErc20Handler__ZeroValueArg when chainID is zero', async function () {
        const { otherAccount } = await loadFixture(basicDeploySetupUpgrade);
        const tokenPN1 = await createTokenForValidation();

        await expect(
          tokenPN1.teleportAtomic(
            otherAccount.address,
            AMOUNT,
            ZERO_CHAINID // Zero chainId
          )
        ).to.be.revertedWithCustomError(
          tokenPN1,
          'RaylsErc20Handler__ZeroValueArg'
        );
      });

      it('Should revert with RaylsErc20Handler__WrongFunctionForSameChainId when chainID is same as current', async function () {
        const { otherAccount, chainIdPN1 } = await loadFixture(basicDeploySetupUpgrade);
        const tokenPN1 = await createTokenForValidation();

        await expect(
          tokenPN1.teleportAtomic(
            otherAccount.address,
            AMOUNT,
            chainIdPN1 // same chainId as current chain
          )
        ).to.be.revertedWithCustomError(
          tokenPN1,
          'RaylsErc20Handler__WrongFunctionForSameChainId'
        );
      });
    });

    describe('teleportFrom', function () {
      it('Should revert with RaylsErc20Handler__WrongAddress when from is zero address', async function () {
        const { otherAccount, chainIdPN2 } = await loadFixture(basicDeploySetupUpgrade);
        const tokenPN1 = await createTokenForValidation();

        await expect(
          tokenPN1.connect(otherAccount).teleportFrom(
            ZERO_ADDRESS, // Zero from address
            otherAccount.address,
            AMOUNT,
            chainIdPN2
          )
        ).to.be.revertedWithCustomError(
          tokenPN1,
          'RaylsErc20Handler__WrongAddress'
        );
      });

      it('Should revert with RaylsErc20Handler__WrongAddress when from equals msg.sender', async function () {
        const { owner, otherAccount, chainIdPN2 } = await loadFixture(basicDeploySetupUpgrade);
        const tokenPN1 = await createTokenForValidation();

        await expect(
          tokenPN1.teleportFrom(
            owner.address, // from == msg.sender (should use teleport instead)
            otherAccount.address,
            AMOUNT,
            chainIdPN2
          )
        ).to.be.revertedWithCustomError(
          tokenPN1,
          'RaylsErc20Handler__WrongAddress'
        );
      });
    });

    describe('teleportAtomicFrom', function () {
      it('Should revert with RaylsErc20Handler__WrongAddress when from is zero address', async function () {
        const { otherAccount, chainIdPN2 } = await loadFixture(basicDeploySetupUpgrade);
        const tokenPN1 = await createTokenForValidation();

        await expect(
          tokenPN1.connect(otherAccount).teleportAtomicFrom(
            ZERO_ADDRESS, // Zero from address
            otherAccount.address,
            AMOUNT,
            chainIdPN2
          )
        ).to.be.revertedWithCustomError(
          tokenPN1,
          'RaylsErc20Handler__WrongAddress'
        );
      });

      it('Should revert with RaylsErc20Handler__WrongAddress when from equals msg.sender', async function () {
        const { owner, otherAccount, chainIdPN2 } = await loadFixture(basicDeploySetupUpgrade);
        const tokenPN1 = await createTokenForValidation();

        await expect(
          tokenPN1.teleportAtomicFrom(
            owner.address, // from == msg.sender (should use teleportAtomic instead)
            otherAccount.address,
            AMOUNT,
            chainIdPN2
          )
        ).to.be.revertedWithCustomError(
          tokenPN1,
          'RaylsErc20Handler__WrongAddress'
        );
      });
    });
  });

  describe('Access Control - onlyOwner Functions', function () {
    async function createTokenForOwnershipTests() {
      const { endpointPN1, tokenRegistry, endpointMappings, resourceRegistry, owner, otherAccount } = await loadFixture(basicDeploySetupUpgrade);
      const messageIdsAlreadyProcessed: { [messageIdConcatWithChainId: string]: boolean | null } = {};
      const token = await deployAndRegisterToken(ethers, tokenRegistry, endpointMappings, messageIdsAlreadyProcessed, resourceRegistry, await endpointPN1.getAddress());

      return { token, owner, otherAccount };
    }

    it('Should revert submitTokenRegistration when called by non-owner', async function () {
      const { token, otherAccount } = await createTokenForOwnershipTests();

      await expect(
        token.connect(otherAccount).submitTokenRegistration(0)
      ).to.be.revertedWithCustomError(token, 'OwnableUnauthorizedAccount')
        .withArgs(otherAccount.address);
    });

    it('Should allow submitTokenRegistration when called by owner', async function () {
      const { token, owner } = await createTokenForOwnershipTests();

      // Should not revert
      await expect(
        token.connect(owner).submitTokenRegistration(0)
      ).to.not.be.reverted;
    });

    it('Should revert mint when called by non-owner', async function () {
      const { token, otherAccount } = await createTokenForOwnershipTests();

      await expect(
        token.connect(otherAccount).mint(otherAccount.address, 100)
      ).to.be.revertedWithCustomError(token, 'OwnableUnauthorizedAccount')
        .withArgs(otherAccount.address);
    });

    it('Should revert burn when called by non-owner', async function () {
      const { token, otherAccount } = await createTokenForOwnershipTests();

      await expect(
        token.connect(otherAccount).burn(otherAccount.address, 100)
      ).to.be.revertedWithCustomError(token, 'OwnableUnauthorizedAccount')
        .withArgs(otherAccount.address);
    });

    it('Should revert submitTokenUpdate when called by non-owner', async function () {
      const { token, otherAccount } = await createTokenForOwnershipTests();

      await expect(
        token.connect(otherAccount).submitTokenUpdate(0, 100) // 0 = MINT type
      ).to.be.revertedWithCustomError(token, 'OwnableUnauthorizedAccount')
        .withArgs(otherAccount.address);
    });
  });

  it('Teleport (with local mock) - Standard Token', async function () {
    const {
          owner,
      otherAccount,
      endpointPN2,
      raylsContractFactoryPL2,
      endpointPN1,
      chainIdPN1,
      chainIdPN2,
      endpointMappings,
      messageIdsAlreadyProcessedOnDeploy,
      tokenRegistry,
      resourceRegistry
    } = await loadFixture(basicDeploySetupUpgrade);
    const amountToTransfer = 100n;
    // Use fresh empty object instead of copying from deployment to avoid state pollution between tests
    const messageIdsAlreadyProcessed: { [messageIdConcatWithChainId: string]: boolean | null } = {};

    const tokenPN1 = await deployAndRegisterToken(ethers, tokenRegistry, endpointMappings, messageIdsAlreadyProcessed, resourceRegistry, await endpointPN1.getAddress());

    // cross chain transfer from PL1 to PL2
    await tokenPN1.teleport(otherAccount.address, amountToTransfer, chainIdPN2);

    await mockRelayerEthersLastTransaction(
      endpointMappings,
      messageIdsAlreadyProcessed,
      resourceRegistry,
    );
    const deployedContractEvent = await raylsContractFactoryPL2.queryFilter(
      raylsContractFactoryPL2.filters.DeployedContract,
    );
    const resourceId = await tokenPN1.resourceId();
    const deployedContractAddress = deployedContractEvent[0].args[0];
    const tokenPN2 = await hre.ethers.getContractAt('TokenExample', deployedContractAddress);
    expect(await endpointPN2.getAddressByResourceId(resourceId)).to.be.equal(deployedContractAddress);
    expect(await endpointPN1.getAddressByResourceId(resourceId)).to.be.equal(await tokenPN1.getAddress());

    expect(await tokenPN1.getAddressByResourceId(resourceId)).to.be.equal(await tokenPN1.getAddress());

    expect(await tokenPN1.name()).to.be.equal(await tokenPN2.name());
    expect(await tokenPN1.symbol()).to.be.equal(await tokenPN2.symbol());
    expect(await tokenPN2.balanceOf(otherAccount.address)).to.be.equal(amountToTransfer);

    // cross chain transfer from PL2 to PL1
    const randomAddress = '0xdafea492d9c6733ae3d56b7ed1adb60692c98bc5';
    await tokenPN2
      .connect(otherAccount)
      .teleport(randomAddress, amountToTransfer, chainIdPN1);
    await mockRelayerEthersLastTransaction(
      endpointMappings,
      messageIdsAlreadyProcessed,
      resourceRegistry,
    );
    expect(await tokenPN1.balanceOf(randomAddress)).to.be.equal(
      amountToTransfer,
    );
    expect(await tokenPN2.balanceOf(otherAccount.address)).to.be.equal(0n);

  });

  /*
  it('Teleport Atomic (with local mock)', async function () {
    const {
      tokenPN1,
      owner,
      otherAccount,
      endpointPN2,
      raylsContractFactoryPL2,
      endpointPN1,
      chainIdPN1,
      chainIdPN2,
      endpointMappings,
      account3,
      account4,
      messageIdsAlreadyProcessedOnDeploy,
      tokenRegistry,
      resourceRegistry
    } = await loadFixture(basicDeploySetupUpgrade);
    const amountToTransfer = 100n;
    // Use fresh empty object instead of copying from deployment to avoid state pollution between tests
    const messageIdsAlreadyProcessed: { [messageIdConcatWithChainId: string]: boolean | null } = {};

    const resourceId = (
      await registerToken(
        tokenPN1,
        tokenRegistry,
        endpointMappings,
        messageIdsAlreadyProcessed,
        resourceRegistry,
      )
    ).resourceId;
    // cross chain transfer from PL1 to PL2
    await tokenPN1.teleportAtomic(
      account3.address,
      amountToTransfer,
      chainIdPN2,
    );
    const txs = await mockRelayerEthersLastTransaction(
      endpointMappings,
      messageIdsAlreadyProcessed,
      resourceRegistry,
    );
    const deployedContractEvent = await raylsContractFactoryPL2.queryFilter(
      raylsContractFactoryPL2.filters.DeployedContract,
    );
    const deployedContractAddress = deployedContractEvent[0].args[0];
    const tokenPN2 = await hre.ethers.getContractAt('TokenExample', deployedContractAddress);
    expect(await tokenPN2.getLockedAmount(account3.address)).to.be.equal(amountToTransfer);

    await tokenPN2.unlock(account3.address, amountToTransfer); // run the unlock call
    await mockRelayerEthersLastTransaction(
      endpointMappings,
      messageIdsAlreadyProcessed,
      resourceRegistry,
    ); // run private hub events on pn2

    expect(await endpointPN2.getAddressByResourceId(resourceId)).to.be.equal(deployedContractAddress);

    expect(await tokenPN2.getAddressByResourceId(resourceId)).to.be.equal(deployedContractAddress);

    expect(await endpointPN1.getAddressByResourceId(resourceId)).to.be.equal(await tokenPN1.getAddress());
    expect(await tokenPN1.name()).to.be.equal(await tokenPN2.name());
    expect(await tokenPN1.symbol()).to.be.equal(await tokenPN2.symbol());
    expect(await tokenPN2.balanceOf(account3.address)).to.be.equal(amountToTransfer);

    // cross chain transfer from PL2 to PL1
    await tokenPN2
      .connect(account3)
      .teleportAtomic(account4.address, amountToTransfer, chainIdPN1);
    await mockRelayerEthersLastTransaction(
      endpointMappings,
      messageIdsAlreadyProcessed,
      resourceRegistry,
    );
    await (await tokenPN1.unlock(account4.address, amountToTransfer)).wait(); // run the unlock call

    expect(await tokenPN1.balanceOf(account4.address)).to.be.equal(amountToTransfer);
    expect(await tokenPN2.balanceOf(otherAccount.address)).to.be.equal(0n);
  });

  it('Teleport from (with local mock)', async function () {
    const {
      tokenPN1,
      owner,
      otherAccount,
      endpointPN2,
      raylsContractFactoryPL2,
      endpointPN1,
      chainIdPN1,
      chainIdPN2,
      endpointMappings,
      messageIdsAlreadyProcessedOnDeploy,
      tokenRegistry,
      resourceRegistry
    } = await loadFixture(basicDeploySetupUpgrade);
    const amountToTransfer = 100n;
    // Use fresh empty object instead of copying from deployment to avoid state pollution between tests
    const messageIdsAlreadyProcessed: { [messageIdConcatWithChainId: string]: boolean | null } = {};

    const resourceId = (
      await registerToken(
        tokenPN1,
        tokenRegistry,
        endpointMappings,
        messageIdsAlreadyProcessed,
        resourceRegistry,
      )
    ).resourceId;

    const res = await tokenPN1
      .connect(otherAccount)
      .teleportFrom(owner, otherAccount, amountToTransfer, chainIdPN2)
      .catch(() => null);

    // Expect failure
    expect(res).to.be.equal(null);

    await tokenPN1.approve(otherAccount, amountToTransfer);

    const allowance = await tokenPN1.allowance(owner, otherAccount);

    expect(allowance).to.be.equal(amountToTransfer);

    // cross chain transfer from PL1 to PL2
    await tokenPN1.connect(otherAccount).teleportFrom(owner, otherAccount, amountToTransfer, chainIdPN2);

    const txs = await mockRelayerEthersLastTransaction(
      endpointMappings,
      messageIdsAlreadyProcessed,
      resourceRegistry,
    );
    const deployedContractEvent = await raylsContractFactoryPL2.queryFilter(
      raylsContractFactoryPL2.filters.DeployedContract,
    );
    const deployedContractAddress = deployedContractEvent[0].args[0];
    const tokenPN2 = await hre.ethers.getContractAt('TokenExample', deployedContractAddress);
    expect(await endpointPN2.getAddressByResourceId(resourceId)).to.be.equal(deployedContractAddress);
    expect(await endpointPN1.getAddressByResourceId(resourceId)).to.be.equal(await tokenPN1.getAddress());
    expect(await tokenPN1.name()).to.be.equal(await tokenPN2.name());
    expect(await tokenPN1.symbol()).to.be.equal(await tokenPN2.symbol());
    expect(await tokenPN2.balanceOf(otherAccount.address)).to.be.equal(amountToTransfer);

    // cross chain transfer from PL2 to PL1
    const randomAddress = '0xdafea492d9c6733ae3d56b7ed1adb60692c98bc5';

    await tokenPN2.connect(otherAccount).approve(owner, amountToTransfer);

    await tokenPN2
      .connect(owner)
      .teleportFrom(otherAccount, randomAddress, amountToTransfer, chainIdPN1);
    await mockRelayerEthersLastTransaction(
      endpointMappings,
      messageIdsAlreadyProcessed,
      resourceRegistry,
    );
    expect(await tokenPN1.balanceOf(randomAddress)).to.be.equal(
      amountToTransfer,
    );
    expect(await tokenPN2.balanceOf(otherAccount.address)).to.be.equal(0n);
  });

  it('Teleport Atomic From (with local mock)', async function () {
    const {
      tokenPN1,
      owner,
      otherAccount,
      endpointPN2,
      raylsContractFactoryPL2,
      endpointPN1,
      chainIdPN1,
      chainIdPN2,
      endpointMappings,
      account3,
      account4,
      messageIdsAlreadyProcessedOnDeploy,
      tokenRegistry,
      resourceRegistry
    } = await loadFixture(basicDeploySetupUpgrade);
    const amountToTransfer = 100n;
    // Use fresh empty object instead of copying from deployment to avoid state pollution between tests
    const messageIdsAlreadyProcessed: { [messageIdConcatWithChainId: string]: boolean | null } = {};

    const resourceId = (
      await registerToken(
        tokenPN1,
        tokenRegistry,
        endpointMappings,
        messageIdsAlreadyProcessed,
        resourceRegistry,
      )
    ).resourceId;

    const res = await tokenPN1
      .connect(account3)
      .teleportAtomicFrom(owner, account3, amountToTransfer, chainIdPN2)
      .catch(() => null);

    // Expect failure
    expect(res).to.be.equal(null);

    await tokenPN1.connect(owner).approve(account3, amountToTransfer);

    const allowance = await tokenPN1.allowance(owner, account3);

    expect(allowance).to.be.equal(amountToTransfer);

    // cross chain transfer from PL1 to PL2
    await tokenPN1.connect(account3).teleportAtomicFrom(owner, account3, amountToTransfer, chainIdPN2);

    const txs = await mockRelayerEthersLastTransaction(
      endpointMappings,
      messageIdsAlreadyProcessed,
      resourceRegistry,
    );
    const deployedContractEvent = await raylsContractFactoryPL2.queryFilter(
      raylsContractFactoryPL2.filters.DeployedContract,
    );
    const deployedContractAddress = deployedContractEvent[0].args[0];
    const tokenPN2 = await hre.ethers.getContractAt('TokenExample', deployedContractAddress);
    expect(await tokenPN2.getLockedAmount(account3.address)).to.be.equal(amountToTransfer);

    await tokenPN2.unlock(account3.address, amountToTransfer); // run the unlock call
    await mockRelayerEthersLastTransaction(
      endpointMappings,
      messageIdsAlreadyProcessed,
      resourceRegistry,
    ); // run private hub events on pn2

    expect(await endpointPN2.getAddressByResourceId(resourceId)).to.be.equal(deployedContractAddress);
    expect(await endpointPN1.getAddressByResourceId(resourceId)).to.be.equal(await tokenPN1.getAddress());
    expect(await tokenPN1.name()).to.be.equal(await tokenPN2.name());
    expect(await tokenPN1.symbol()).to.be.equal(await tokenPN2.symbol());
    expect(await tokenPN2.balanceOf(account3.address)).to.be.equal(amountToTransfer);

    // cross chain transfer from PL2 to PL1
    await tokenPN2.connect(account3).approve(account4, amountToTransfer);

    await tokenPN2
      .connect(account4)
      .teleportAtomicFrom(account3, account4, amountToTransfer, chainIdPN1);
    await mockRelayerEthersLastTransaction(
      endpointMappings,
      messageIdsAlreadyProcessed,
      resourceRegistry,
    );
    await (await tokenPN1.unlock(account4.address, amountToTransfer)).wait(); // run the unlock call

    expect(await tokenPN1.balanceOf(account4.address)).to.be.equal(amountToTransfer);
    expect(await tokenPN2.balanceOf(otherAccount.address)).to.be.equal(0n);
  });

  it('Change the Endpoint Address', async function () {
    const { tokenPN1, otherAccount } = await loadFixture(basicDeploySetupUpgrade);

    const oldEndpointAddress = await tokenPN1.getEndpointAddress();
    const newEndpointAddress = otherAccount.address;
    await tokenPN1._updateEndpoint(newEndpointAddress);

    const updatedEndpointAddress = await tokenPN1.getEndpointAddress();

    expect(updatedEndpointAddress).to.be.equal(newEndpointAddress);
    expect(updatedEndpointAddress).not.be.equal(oldEndpointAddress);
  });
  */

  describe('EndpointV1 - registerPrivateHubAddress Authorization', function () {
    it('Should allow owner to register private hub address', async function () {
      const { endpointPN1, owner } = await loadFixture(basicDeploySetupUpgrade);
      const testAddress = ethers.Wallet.createRandom().address;

      const tx = await endpointPN1.connect(owner).registerPrivateHubAddress('TokenRegistry', testAddress);
      await tx.wait();

      const registeredAddress = await endpointPN1.getPrivateHubAddress('TokenRegistry');
      expect(registeredAddress).to.equal(testAddress);
    });

    it('Should reject non-owner (otherAccount) from registering private hub address', async function () {
      const { endpointPN1, otherAccount } = await loadFixture(basicDeploySetupUpgrade);
      const testWallet = ethers.Wallet.createRandom().address;

      await expect(
        endpointPN1.connect(otherAccount).registerPrivateHubAddress('TokenRegistry', testWallet)
      ).to.be.revertedWithCustomError(endpointPN1, 'OwnableUnauthorizedAccount')
        .withArgs(otherAccount.address);
    });

    it('Should reject random address (non-owner) from registering private hub address', async function () {
      const { endpointPN1 } = await loadFixture(basicDeploySetupUpgrade);
      const [randomSigner] = await ethers.getSigners();
      const testAddress = ethers.Wallet.createRandom().address;

      await expect(
        endpointPN1.connect(randomSigner).registerPrivateHubAddress('TokenRegistry', testAddress)
      ).to.be.revertedWithCustomError(endpointPN1, 'OwnableUnauthorizedAccount')
        .withArgs(randomSigner.address);
    });

    it('Should reject zero address', async function () {
      const { endpointPN1, owner } = await loadFixture(basicDeploySetupUpgrade);

      await expect(
        endpointPN1.connect(owner).registerPrivateHubAddress('TokenRegistry', ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(endpointPN1, 'Endpoint__InvalidPrivateHubAddress');
    });

    it('Should reject empty contract name', async function () {
      const { endpointPN1, owner } = await loadFixture(basicDeploySetupUpgrade);
      const testAddress = ethers.Wallet.createRandom().address;

      await expect(
        endpointPN1.connect(owner).registerPrivateHubAddress('', testAddress)
      ).to.be.revertedWithCustomError(endpointPN1, 'Endpoint__EmptyContractName');
    });

    it('Should emit PrivateHubAddressRegistered event', async function () {
      const { endpointPN1, owner } = await loadFixture(basicDeploySetupUpgrade);
      const testAddress = ethers.Wallet.createRandom().address;

      await expect(
        endpointPN1.connect(owner).registerPrivateHubAddress('TokenRegistry', testAddress)
      )
        .to.emit(endpointPN1, 'PrivateHubAddressRegistered')
        .withArgs('TokenRegistry', testAddress);
    });

    it('Should allow updating existing registration', async function () {
      const { endpointPN1, owner } = await loadFixture(basicDeploySetupUpgrade);
      const firstAddress = ethers.Wallet.createRandom().address;
      const secondAddress = ethers.Wallet.createRandom().address;

      await endpointPN1.connect(owner).registerPrivateHubAddress('TokenRegistry', firstAddress);
      expect(await endpointPN1.getPrivateHubAddress('TokenRegistry')).to.equal(firstAddress);

      await expect(
        endpointPN1.connect(owner).registerPrivateHubAddress('TokenRegistry', secondAddress)
      )
        .to.emit(endpointPN1, 'PrivateHubAddressRegistered')
        .withArgs('TokenRegistry', secondAddress);

      expect(await endpointPN1.getPrivateHubAddress('TokenRegistry')).to.equal(secondAddress);
    });
  });

  describe('RaylsMessageExecutorV1 - executeMessage Authorization', function () {
    it('Should reject unauthorized address from calling executeMessage', async function () {
      const { raylsMessageExecutorPL1, messageReceiverPL1, owner, otherAccount } = await loadFixture(basicDeploySetupUpgrade);

      // Set authorized message receiver
      await raylsMessageExecutorPL1.connect(owner).setAuthorizedMessageReceiver(messageReceiverPL1);

      const mockTarget = ethers.Wallet.createRandom().address;
      const messageId = ethers.id('test-message-2');
      const fromChainId = 2;
      const fromAddress = ethers.Wallet.createRandom().address;
      const data = '0x1234';

      await expect(
        raylsMessageExecutorPL1.connect(otherAccount).executeMessage(
          mockTarget,
          data,
          messageId,
          fromChainId,
          fromAddress
        )
      ).to.be.revertedWithCustomError(raylsMessageExecutorPL1, 'RaylsMessageExecutor__UnauthorizedMessageReceiver');
    });

    it('Should reject random wallet from calling executeMessage', async function () {
      const { raylsMessageExecutorPL1, messageReceiverPL1, owner } = await loadFixture(basicDeploySetupUpgrade);

      // Set authorized message receiver
      await raylsMessageExecutorPL1.connect(owner).setAuthorizedMessageReceiver(messageReceiverPL1);

      const randomWallet = ethers.Wallet.createRandom();
      const [deployer] = await ethers.getSigners();

      // Fund random wallet
      await deployer.sendTransaction({
        to: randomWallet.address,
        value: ethers.parseEther('1.0')
      });

      const mockTarget = ethers.Wallet.createRandom().address;
      const messageId = ethers.id('test-message-3');
      const fromChainId = 2;
      const fromAddress = ethers.Wallet.createRandom().address;
      const data = '0x1234';

      await expect(
        raylsMessageExecutorPL1.connect(randomWallet).executeMessage(
          mockTarget,
          data,
          messageId,
          fromChainId,
          fromAddress
        )
      ).to.be.revertedWithCustomError(raylsMessageExecutorPL1, 'RaylsMessageExecutor__UnauthorizedMessageReceiver');
    });

    it('Should reject non-owner from setting authorized message receiver', async function () {
      const { raylsMessageExecutorPL1, otherAccount } = await loadFixture(basicDeploySetupUpgrade);

      const newReceiver = ethers.Wallet.createRandom().address;

      await expect(
        raylsMessageExecutorPL1.connect(otherAccount).setAuthorizedMessageReceiver(newReceiver)
      ).to.be.revertedWithCustomError(raylsMessageExecutorPL1, 'OwnableUnauthorizedAccount')
        .withArgs(otherAccount.address);
    });
  });

  describe('ParticipantStorageV1 - Participant Management Authorization', function () {
    it('Should allow owner to update participant status', async function () {
      const { participantStorageCC, owner, chainIdPN1 } = await loadFixture(basicDeploySetupUpgrade);

      await expect(
        participantStorageCC.connect(owner).updateStatus(chainIdPN1, 2) // 2 = FROZEN
      ).to.not.be.reverted;
    });

    it('Should reject non-owner from updating participant status', async function () {
      const { participantStorageCC, otherAccount, chainIdPN1 } = await loadFixture(basicDeploySetupUpgrade);

      await expect(
        participantStorageCC.connect(otherAccount).updateStatus(chainIdPN1, 2)
      ).to.be.revertedWithCustomError(participantStorageCC, 'OwnableUnauthorizedAccount')
        .withArgs(otherAccount.address);
    });

    it('Should reject random wallet from updating participant status', async function () {
      const { participantStorageCC, chainIdPN1 } = await loadFixture(basicDeploySetupUpgrade);

      const randomWallet = ethers.Wallet.createRandom();
      const [deployer] = await ethers.getSigners();

      // Fund random wallet
      await deployer.sendTransaction({
        to: randomWallet.address,
        value: ethers.parseEther('1.0')
      });

      await expect(
        participantStorageCC.connect(randomWallet).updateStatus(chainIdPN1, 2)
      ).to.be.revertedWithCustomError(participantStorageCC, 'OwnableUnauthorizedAccount')
        .withArgs(randomWallet.address);
    });

    it('Should allow owner to update participant role', async function () {
      const { participantStorageCC, owner, chainIdPN1 } = await loadFixture(basicDeploySetupUpgrade);

      await expect(
        participantStorageCC.connect(owner).updateRole(chainIdPN1, 0) // 0 = PARTICIPANT
      ).to.not.be.reverted;
    });

    it('Should reject non-owner from updating participant role', async function () {
      const { participantStorageCC, otherAccount, chainIdPN1 } = await loadFixture(basicDeploySetupUpgrade);

      await expect(
        participantStorageCC.connect(otherAccount).updateRole(chainIdPN1, 0)
      ).to.be.revertedWithCustomError(participantStorageCC, 'OwnableUnauthorizedAccount')
        .withArgs(otherAccount.address);
    });

    it('Should reject random wallet from updating participant role', async function () {
      const { participantStorageCC, chainIdPN1 } = await loadFixture(basicDeploySetupUpgrade);

      const randomWallet = ethers.Wallet.createRandom();
      const [deployer] = await ethers.getSigners();

      // Fund random wallet
      await deployer.sendTransaction({
        to: randomWallet.address,
        value: ethers.parseEther('1.0')
      });

      await expect(
        participantStorageCC.connect(randomWallet).updateRole(chainIdPN1, 0)
      ).to.be.revertedWithCustomError(participantStorageCC, 'OwnableUnauthorizedAccount')
        .withArgs(randomWallet.address);
    });

    it('Should allow owner to remove participant', async function () {
      const { participantStorageCC, owner, chainIdPN1 } = await loadFixture(basicDeploySetupUpgrade);

      await expect(
        participantStorageCC.connect(owner).removeParticipant(chainIdPN1)
      ).to.not.be.reverted;
    });

    it('Should reject non-owner from removing participant', async function () {
      const { participantStorageCC, otherAccount, chainIdPN1 } = await loadFixture(basicDeploySetupUpgrade);

      await expect(
        participantStorageCC.connect(otherAccount).removeParticipant(chainIdPN1)
      ).to.be.revertedWithCustomError(participantStorageCC, 'OwnableUnauthorizedAccount')
        .withArgs(otherAccount.address);
    });

    it('Should reject random wallet from removing participant', async function () {
      const { participantStorageCC, chainIdPN1 } = await loadFixture(basicDeploySetupUpgrade);

      const randomWallet = ethers.Wallet.createRandom();
      const [deployer] = await ethers.getSigners();

      // Fund random wallet
      await deployer.sendTransaction({
        to: randomWallet.address,
        value: ethers.parseEther('1.0')
      });

      await expect(
        participantStorageCC.connect(randomWallet).removeParticipant(chainIdPN1)
      ).to.be.revertedWithCustomError(participantStorageCC, 'OwnableUnauthorizedAccount')
        .withArgs(randomWallet.address);
    });
  });
});