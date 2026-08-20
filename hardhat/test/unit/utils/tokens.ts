import { ResourceRegistryV1, TokenExample, TokenRegistryV1, CustomTokenExample, EnygmaTokenExample, EndpointV1 } from '../../../../typechain-types';
import { ContractMethodArgs } from '../../../../typechain-types/common';
import { SharedObjects } from '../../../../typechain-types/src/privateHub/TokenRegistry/TokenRegistryV1';

import { mockRelayerEthersLastTransaction } from './RelayerMockEthers';

const TokenData = {
  name: 'TestToken',
  symbol: 'TT',
  issuerChainId: 123,
  pnRegistryAddress: '0x0000000000000000000000000000000000000001',
  bytecode: '0x0000000000000000000000000000000000000000000000000000000000000000',
  initializerParams: '0x0000000000000000000000000000000000000000000000000000000000000000',
  isFungible: true,  
  ercStandard: 0,
  totalSupply: '0x0f4240', // 1000000 in hexadecimal
  isCustom: false,
} satisfies ContractMethodArgs<[tokenData: SharedObjects.TokenRegistrationDataStruct], 'nonpayable'>[0];

export async function registerToken(tokenPN: TokenExample, tokenRegistry: TokenRegistryV1, endpointMappings: any, messageIdsAlreadyProcessed: any, resourceRegistry: ResourceRegistryV1) {
  await tokenPN.submitTokenRegistration();

  await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);
  const token = (await tokenRegistry.getAllTokens())[0];

  await tokenRegistry.updateStatus(token.resourceId, 1); // approve token

  await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);

  return token;
}

export async function deployAndRegisterToken(ethers: any, tokenRegistry: TokenRegistryV1, endpointMappings: any, messageIdsAlreadyProcessed: any, resourceRegistry: ResourceRegistryV1, endpointToRegister: string, raylsNodeEndpoint: string = ethers.ZeroAddress, userGovernance: string = ethers.ZeroAddress) {
  const tokenFactory = await ethers.getContractFactory('TokenExample');
  var randomName = Math.random().toString(36).substring(2, 15) + Math.random().toString(36).substring(2, 15);
  var randomSymbol = Math.random().toString(36).substring(2, 15) + Math.random().toString(36).substring(2, 15);

   let token = await tokenFactory.deploy(randomName, randomSymbol, endpointToRegister, raylsNodeEndpoint, userGovernance);
   const tokenAddress = await token.getAddress();

   await token.waitForDeployment();
   await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);

   // Grant ENDPOINT_SENDER_ROLE to token and tokenRegistry via AUTH-V3 manager
   const [owner] = await ethers.getSigners();
   const endpoint = await ethers.getContractAt('EndpointV1', endpointToRegister);
   const tokenRegistryAddress = await tokenRegistry.getAddress();
   const managerAddr = await endpoint.authority();
   const mgr = await ethers.getContractAt('RaylsAccessManagerV1', managerAddr);
   const roleId = await mgr.getRoleIdByName('ENDPOINT_SENDER');

   console.log(`[TOKEN] Granting ENDPOINT_SENDER_ROLE to token ${tokenAddress} and tokenRegistry ${tokenRegistryAddress}`);
   await (await mgr.connect(owner).grantRole(roleId, tokenAddress, 0)).wait();
   await (await mgr.connect(owner).grantRole(roleId, tokenRegistryAddress, 0)).wait();

   await token.submitTokenRegistration(0);
 
   await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);
 
   const allTokens = await tokenRegistry.getAllTokens();  
   const tokenFromRegistry = allTokens.find(token => token.name === randomName);
   token = await tokenRegistry.updateStatus(tokenFromRegistry!.resourceId, 1);   
   await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);

  const tokenDeployed = await ethers.getContractAt('TokenExample', tokenAddress);
 
   return tokenDeployed;
 }

export async function deployAndRegisterEnygmaToken(ethers: any, tokenRegistry: TokenRegistryV1, endpointMappings: any, messageIdsAlreadyProcessed: any, resourceRegistry: ResourceRegistryV1, endpointToRegister: string) {
 const enygmaFactory = await ethers.getContractFactory('EnygmaTokenExample');
 var randomName = Math.random().toString(36).substring(2, 15) + Math.random().toString(36).substring(2, 15);
 var randomSymbol = Math.random().toString(36).substring(2, 15) + Math.random().toString(36).substring(2, 15);
 
  const enygma = await enygmaFactory.deploy(randomName, randomSymbol, endpointToRegister);
  const enygmaAddress = await enygma.getAddress();

  await enygma.waitForDeployment();
  await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);

  // Grant ENDPOINT_SENDER_ROLE to enygma and tokenRegistry via AUTH-V3 manager
  const [owner] = await ethers.getSigners();
  const endpoint = await ethers.getContractAt('EndpointV1', endpointToRegister);
  const tokenRegistryAddress = await tokenRegistry.getAddress();
  const managerAddr = await endpoint.authority();
  const mgr = await ethers.getContractAt('RaylsAccessManagerV1', managerAddr);
  const roleId = await mgr.getRoleIdByName('ENDPOINT_SENDER');

  console.log(`[ENYGMA] Granting ENDPOINT_SENDER_ROLE to enygma ${enygmaAddress} and tokenRegistry ${tokenRegistryAddress}`);
  await (await mgr.connect(owner).grantRole(roleId, enygmaAddress, 0)).wait();
  await (await mgr.connect(owner).grantRole(roleId, tokenRegistryAddress, 0)).wait();

  await enygma.submitTokenRegistration(0);

  await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);

  const allTokens = await tokenRegistry.getAllTokens();  
  const resourceIdToUpdate = allTokens.find(token => token.name === randomName)?.resourceId;

  tokenRegistry.updateStatus(resourceIdToUpdate!, 1);   
  await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);

  return enygma;
}

export async function getEnygmaFromPNH(ethers: any, enygmaToken: EnygmaTokenExample, endpointPNH: EndpointV1) {
  const enygmaResourceId = await enygmaToken.resourceId();
  const enygmaAddressOnPNH = await endpointPNH.getAddressByResourceId(enygmaResourceId);

  const enygmaOnPNH = await ethers.getContractAt('EnygmaV1', enygmaAddressOnPNH);

  return enygmaOnPNH;
}

export async function deployAndRegisterCustomToken(ethers: any, tokenRegistry: TokenRegistryV1, endpointMappings: any, messageIdsAlreadyProcessed: any, resourceRegistry: ResourceRegistryV1, chainIdToRegister: string, owner: any) {
  const customTokenFactory = await ethers.getContractFactory('CustomTokenExample');
  var randomName = Math.random().toString(36).substring(2, 15) + Math.random().toString(36).substring(2, 15);
  var randomSymbol = Math.random().toString(36).substring(2, 15) + Math.random().toString(36).substring(2, 15);
  const endpointToRegister = endpointMappings[chainIdToRegister];
  const endpointAddrToRegister = await endpointToRegister.getAddress();
  
   const customToken = await customTokenFactory.deploy(randomName, randomSymbol, chainIdToRegister, owner.address, endpointAddrToRegister);
   await customToken.waitForDeployment();
   const customTokenAddress = await customToken.getAddress();

   await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);

   // Grant ENDPOINT_SENDER_ROLE to custom token and tokenRegistry via AUTH-V3 manager
   const tokenRegistryAddress = await tokenRegistry.getAddress();
   const managerAddr = await endpointToRegister.authority();
   const mgr = await ethers.getContractAt('RaylsAccessManagerV1', managerAddr);
   const roleId = await mgr.getRoleIdByName('ENDPOINT_SENDER');

   console.log(`[CUSTOM] Granting ENDPOINT_SENDER_ROLE to custom token ${customTokenAddress} and tokenRegistry ${tokenRegistryAddress}`);
   await (await mgr.connect(owner).grantRole(roleId, customTokenAddress, 0)).wait();
   await (await mgr.connect(owner).grantRole(roleId, tokenRegistryAddress, 0)).wait();

   await customToken.submitTokenRegistration(0);
 
   await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);
 
   const allTokens = await tokenRegistry.getAllTokens();     
   const resourceIdToUpdate = allTokens.find(token => token.name === randomName)?.resourceId;
   console.log('resourceIdToUpdate', resourceIdToUpdate);
   tokenRegistry.updateStatus(resourceIdToUpdate!, 1);  
   await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);

   const customTokenDeployed = await ethers.getContractAt('CustomTokenExample', customTokenAddress);
 
   return customTokenDeployed;
 }
 
