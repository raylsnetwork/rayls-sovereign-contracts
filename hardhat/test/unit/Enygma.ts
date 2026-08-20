import { loadFixture } from '@nomicfoundation/hardhat-toolbox/network-helpers';
import { expect } from 'chai';
import hre, { ethers } from 'hardhat';
import { mockRelayerEthersLastTransaction } from './utils/RelayerMockEthers';
import { basicDeploySetupUpgrade } from './utils/basicDeploySetupUpgrade';
import { extendConfig } from 'hardhat/config';
import { EnygmaTokenExample, ResourceRegistryV1, TokenRegistryV1 } from '../../../typechain-types';
import { deployAndRegisterEnygmaToken, getEnygmaFromPNH } from './utils/tokens';

describe('Enygma', function () {
  it('Enygma deploy on PN and PNH', async function () {    

    const { endpointMappings, endpointPN1, messageIdsAlreadyProcessedOnDeploy, resourceRegistry, tokenRegistry, 
      endpointPNH} = await loadFixture(basicDeploySetupUpgrade);

      // Use fresh empty object instead of copying from deployment to avoid state pollution between tests
      const messageIdsAlreadyProcessed: { [messageIdConcatWithChainId: string]: boolean | null } = {};
      var enygmaTokenOnPN1 = await deployAndRegisterEnygmaToken(ethers, tokenRegistry, endpointMappings, messageIdsAlreadyProcessed, resourceRegistry, await endpointPN1.getAddress());

      expect(enygmaTokenOnPN1).to.not.equal(null);
      const resourceId = await enygmaTokenOnPN1.resourceId();      
      expect(resourceId).to.not.equal('0x0000000000000000000000000000000000000000000000000000000000000000');      

      const enygmaOnPNH = await getEnygmaFromPNH(ethers, enygmaTokenOnPN1, endpointPNH);
      
      expect(await enygmaOnPNH.getTotalSupply()).to.equal(0);
  
  });
});



