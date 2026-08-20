/**
 * @deprecated Decommissioning Teleport (vanilla, atomic).
 */
import { time, loadFixture } from '@nomicfoundation/hardhat-toolbox/network-helpers';
import { expect } from 'chai';
import hre, { ethers } from 'hardhat';
import { mockRelayerEthersLastTransaction } from './utils/RelayerMockEthers';
import { basicDeploySetupUpgrade } from './utils/basicDeploySetupUpgrade';
import { deployAndRegisterCustomToken } from './utils/tokens';

describe('Rayls ERC20 Custom Example V1', function () {
  // We define a fixture to reuse the same setup in every test.
  // We use loadFixture to run this setup once, snapshot that state,
  // and reset Hardhat Network to that snapshot in every test.
  // Deploys 2 relayers, 1 private hub and 1 token on PL1

  // Use unique test names to avoid conflicts
  it('Teleport (with local mock) - Custom Token', async function () {
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
      resourceRegistry,      
    } = await loadFixture(basicDeploySetupUpgrade);
    const amountToTransfer = 100n;
    // Use fresh empty object instead of copying from deployment to avoid state pollution between tests
    const messageIdsAlreadyProcessed: { [messageIdConcatWithChainId: string]: boolean | null } = {};

    const tokenCustomPN1 = await deployAndRegisterCustomToken(ethers, tokenRegistry, endpointMappings, messageIdsAlreadyProcessed, resourceRegistry, chainIdPN1.toString(), owner);


    const attestationUuid = '0x00000000000000000000000000000000000000000000000000000000686f6c61';
    await tokenCustomPN1.setAttestationUuid(attestationUuid);
    await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);

    const resourceId = await tokenCustomPN1.resourceId();

    await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);

    await tokenCustomPN1.mint(owner.address, 10000n);

    await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);

    // cross chain transfer from PL1 to PL2
    await tokenCustomPN1.teleport(otherAccount.address, amountToTransfer, chainIdPN2);

    const txs = await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);
    const deployedContractEvent = await raylsContractFactoryPL2.queryFilter(raylsContractFactoryPL2.filters.DeployedContract);
    const deployedContractAddress = deployedContractEvent[0].args[0];
    const tokenPN2 = await hre.ethers.getContractAt('CustomTokenExample', deployedContractAddress);
    expect(await endpointPN2.getAddressByResourceId(resourceId)).to.be.equal(deployedContractAddress);
    expect(await endpointPN1.getAddressByResourceId(resourceId)).to.be.equal(await tokenCustomPN1.getAddress());

    expect(await tokenCustomPN1.getAddressByResourceId(resourceId)).to.be.equal(await tokenCustomPN1.getAddress());

    expect(await tokenCustomPN1.name()).to.be.equal(await tokenPN2.name());
    expect(await tokenCustomPN1.symbol()).to.be.equal(await tokenPN2.symbol());
    expect(await tokenPN2.balanceOf(otherAccount.address)).to.be.equal(amountToTransfer);

    // cross chain transfer from PL2 to PL1
    const randomAddress = '0xdafea492d9c6733ae3d56b7ed1adb60692c98bc5';
    await tokenPN2.connect(otherAccount).teleport(randomAddress, amountToTransfer, chainIdPN1);
    await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);
    expect(await tokenCustomPN1.balanceOf(randomAddress)).to.be.equal(amountToTransfer);
    expect(await tokenPN2.balanceOf(otherAccount.address)).to.be.equal(0n);

    //TODO: Check this
   // const at = await tokenPN2.attestationUid();

   // expect(attestationUuid).to.be.equal(at);


  }); 
});
