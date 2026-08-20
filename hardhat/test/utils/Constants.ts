import { createRandomWallet, generateRandomHex, pollCondition } from './Utils';
import { BaseContract, ContractFactory, ContractTransactionResponse, ethers, ZeroAddress } from 'ethers';
import { DeploymentProxyRegistryV1 } from '../../../typechain-types/src/rayls-protocol/DeploymentProxyRegistry/DeploymentProxyRegistryV1';
import { Logger } from './Log';
import { expect } from 'chai';
import { HardhatRuntimeEnvironment } from "hardhat/types";

export class RaylsNode {
  public rpcUrl: string;
  public provider: ethers.JsonRpcProvider;
  public endpointAddress: string;
  public raylsNodeEndpointAddress: string;
  public raylsNodeUserGovernance: string;
  public chainId: string;
  public wallet: ethers.HDNodeWallet | ethers.Wallet;
  public signer: ethers.HDNodeWallet | ethers.Wallet;
  public db: {
    connection: string;
  };
  public node: string;

  public hre: HardhatRuntimeEnvironment;

  public contract: { [key: string]: BaseContract } = {};

  constructor(node: string, hre: HardhatRuntimeEnvironment) {
    this.rpcUrl = RPC_URL[node];
    this.provider = PROVIDER[node];
    this.endpointAddress = ENDPOINT_ADDRESS[node];
    this.raylsNodeEndpointAddress = RAYLS_NODE_ENDPOINT_ADDRESS[node];
    this.raylsNodeUserGovernance = RAYLS_NODE_USER_GOVERNANCE[node];
    this.chainId = CHAIN_ID[node];
    this.wallet = createRandomWallet();
    this.signer = this.wallet.connect(this.provider);
    this.db = {
      connection: DB_CONNECTION[node]
    };

    this.hre = hre;
    this.node = node;
  }

  async initialize() {
    //Private connection Endpoint
    this.endpointAddress = await this.getEndpointAddress(this.node);
    this.getContractAt('EndpointV1', this.endpointAddress, 'EndpointV1');

    //Public connection Endpoint
    this.raylsNodeEndpointAddress = await this.getContractAddressFromProxyRegistry(`PRIVACY_NODE_${this.node}_DEPLOYMENT_PROXY_REGISTRY`, 'RNEndpoint');
    this.getContractAt('RNEndpointV1', this.raylsNodeEndpointAddress, 'RNEndpointV1');

    //Public Governance
    this.raylsNodeUserGovernance = await this.getContractAddressFromProxyRegistry(`PRIVACY_NODE_${this.node}_DEPLOYMENT_PROXY_REGISTRY`, 'RNUserGovernance');
    this.getContractAt('RNUserGovernanceV1', this.raylsNodeUserGovernance, 'RNUserGovernanceV1');
  }

  //Generic function to get contract address from proxy registry. Need to refine later
  async getContractAddressFromProxyRegistry(deploymentProxyRegistryType: string, contractName: string) {

    const deploymentProxyRegistryAddress = deploymentProxyRegistryType;

    if (!process.env[deploymentProxyRegistryAddress]) throw new Error(`${deploymentProxyRegistryAddress} is not set in the .env file`);

    const deploymentProxyRegistry = await this.getContractAt<DeploymentProxyRegistryV1>(
      'DeploymentProxyRegistryV1',
      process.env[deploymentProxyRegistryAddress],
      'DeploymentProxyRegistryV1'
    );

    const deployment = await deploymentProxyRegistry.getContract(contractName);

    return deployment;
  }
  
  async getEndpointAddress(node: string) {

    const deploymentProxyRegistryAddressForNode = `PRIVACY_NODE_${node}_DEPLOYMENT_PROXY_REGISTRY`;

    if (!process.env[deploymentProxyRegistryAddressForNode]) throw new Error(`${deploymentProxyRegistryAddressForNode} is not set in the .env file`);

    const deploymentProxyRegistry = await this.getContractAt<DeploymentProxyRegistryV1>(
      'DeploymentProxyRegistryV1',
      process.env[deploymentProxyRegistryAddressForNode],
      'DeploymentProxyRegistryV1'
    );

    const deployment = await deploymentProxyRegistry.getContract("Endpoint");

    return deployment;
  }

  getContract<T extends BaseContract>(key: string): T {
    return this.contract[key] as T;
  }

  setContract(key: string, contract: BaseContract) {
    this.contract[key] = contract;
  }

  async getContractAt<T extends BaseContract>(name: string, address: string, key: string): Promise<T> {
    /*
    if (this.getContract<T>(key)) 
      return this.getContract<T>(key);
    */

    const contract = await this.hre.ethers.getContractAt(name, address, this.signer);

    this.setContract(key, contract);

    return this.getContract<T>(key);
  }

  async deploy<T extends BaseContract>(
    contractFactory: ContractFactory,
    key: string,
    ...args: Parameters<typeof contractFactory.deploy>
  ) {
    const instance = await contractFactory.deploy(...args);
    await instance.waitForDeployment();

    this.contract[key] = instance;
    return instance as T;
  }
}

export class PrivateHub extends RaylsNode {
  public deployNamesAndAddresses: { [key: string]: string };
  public resourceRegistryAddress: string;
  public teleportAddress: string;
  public endpointAddress: string;
  public tokenRegistryAddress: string;
  public proofsAddress: string;
  public participantStorageAddress: string;
  public dvpAddress: string;
  public dvpTeleportAddress: string;
  public enygmaPnhEventsAddress: string;

  constructor(hre: HardhatRuntimeEnvironment) {
    super('PNH', hre);
    this.wallet = new ethers.Wallet(VEN_OPERATOR_WALLET);
    this.signer = this.wallet.connect(this.provider);

    this.resourceRegistryAddress = ZERO_ADDRESS;
    this.teleportAddress = ZERO_ADDRESS;
    this.endpointAddress = ZERO_ADDRESS;
    this.tokenRegistryAddress = ZERO_ADDRESS;
    this.proofsAddress = ZERO_ADDRESS;
    this.participantStorageAddress = ZERO_ADDRESS;
    this.dvpAddress = ZERO_ADDRESS;
    this.dvpTeleportAddress = ZERO_ADDRESS;
    this.enygmaPnhEventsAddress = ZERO_ADDRESS;
    this.deployNamesAndAddresses = {};
  }

  async initialize() {
    await this.getProxyRegistryDeployment();
  }

  async getProxyRegistryDeployment() {
    if (Object.keys(this.deployNamesAndAddresses).length > 0) return this.deployNamesAndAddresses;

    const deploymentProxyRegistryAddress = DEPLOYMENT_PROXY_REGISTRY_ADDRESS[this.node];
    console.log(deploymentProxyRegistryAddress);
    const deploymentProxyRegistry = await this.getContractAt<DeploymentProxyRegistryV1>(
      'DeploymentProxyRegistryV1',
      deploymentProxyRegistryAddress,
      'DeploymentProxyRegistryV1'
    );

    const deployment = await deploymentProxyRegistry.getAllContracts();

    this.deployNamesAndAddresses = deployment.names.reduce((acc, name, index) => {
      acc[name] = deployment.addresses[index];
      return acc;
    }, {} as { [key: string]: string });

    await this.getContractAt('ResourceRegistryV1', this.deployNamesAndAddresses['ResourceRegistry'], 'ResourceRegistryV1');
    await this.getContractAt('TeleportV1', this.deployNamesAndAddresses['Teleport'], 'TeleportV1');
    await this.getContractAt('EndpointV1', this.deployNamesAndAddresses['Endpoint'], 'EndpointV1');
    await this.getContractAt('TokenRegistryV1', this.deployNamesAndAddresses['TokenRegistry'], 'TokenRegistryV1');
    await this.getContractAt('TokenCoreV1', this.deployNamesAndAddresses['TokenCore'], 'TokenCoreV1');
    await this.getContractAt('Proofs', this.deployNamesAndAddresses['Proofs'], 'Proofs');
    await this.getContractAt('ParticipantStorageV1', this.deployNamesAndAddresses['ParticipantStorage'], 'ParticipantStorageV1');
    await this.getContractAt('Dvp', this.deployNamesAndAddresses['Dvp'], 'Dvp');
    await this.getContractAt('DvpTeleport', this.deployNamesAndAddresses['DvpTeleport'], 'DvpTeleport');
    await this.getContractAt('EnygmaPNHEvents', this.deployNamesAndAddresses['EnygmaPNHEvents'], 'EnygmaPNHEvents');

    this.resourceRegistryAddress = this.deployNamesAndAddresses['ResourceRegistry'];
    this.teleportAddress = this.deployNamesAndAddresses['Teleport'];
    this.endpointAddress = this.deployNamesAndAddresses['Endpoint'];
    this.tokenRegistryAddress = this.deployNamesAndAddresses['TokenRegistry'];
    this.proofsAddress = this.deployNamesAndAddresses['Proofs'];
    this.participantStorageAddress = this.deployNamesAndAddresses['ParticipantStorage'];
    this.dvpAddress = this.deployNamesAndAddresses['Dvp'];
    this.dvpTeleportAddress = this.deployNamesAndAddresses['DvpTeleport'];
    this.enygmaPnhEventsAddress = this.deployNamesAndAddresses['EnygmaPNHEvents'];

    return this.deployNamesAndAddresses;
  }

  async wait(transaction: Promise<ContractTransactionResponse>, message: string) {
    LOGGER.load(message);
    const response = await transaction;
    const receipt = await response.wait();

    const initialBlockNumber = await this.provider.getBlockNumber();
    const targetBlockNumber = initialBlockNumber + NUMBER_OF_BLOCKS_TO_WAIT;

    expect(await pollCondition(async (): Promise<boolean> => {
      const currentBlockNumber = await this.provider.getBlockNumber();
      return currentBlockNumber >= targetBlockNumber;
    }, 1000, 300)).to.be.true;

    expect(receipt?.status).to.be.equal(1);
    LOGGER.loadSuccess();
  }

  async waitUntil(
    check: () => Promise<boolean>,
    message: string
  ) {
    LOGGER.load(message);
    expect(
      await pollCondition(
        check,
        1 * SECOND,
        DEFAULT_TIMEOUT
      )
    ).to.be.true;
    LOGGER.loadSuccess();
  }
}

export class Token {
  public name: string;
  public symbol: string;
  public resourceId: string;
  public address: { [chainId: string]: string };

  constructor() {
    const randomHex = generateRandomHex(6);

    this.name = randomHex;
    this.symbol = randomHex;
    this.resourceId = ZERO_HASH;
    this.address = {};
  }

  log() {
    LOGGER.data(JSON.stringify(this, null, 2));
  }
}

export class ERC721 extends Token {
  public uri: string;
  public id: number;

  constructor(id: number = 1) {
    super();
    const randomHex = generateRandomHex(6);

    this.name = randomHex;
    this.symbol = randomHex;
    this.uri = randomHex;
    this.resourceId = ZERO_HASH;
    this.id = id;
  }
}

export class ERC1155 extends Token {
  public uri: string;

  constructor() {
    super();
    const randomHex = generateRandomHex(6);

    this.name = randomHex;
    this.symbol = randomHex;
    this.uri = randomHex;
    this.resourceId = ZERO_HASH;
  }

  data(value: string = "") {
    return Buffer.from(value);
  }
}

export const PRIVACY_NODES = ['A', 'B', 'C', 'D', 'E', 'F'];
export const RAYLS_NODES = [...PRIVACY_NODES, 'PNH'];
export const RPC_URL: { [NODE: string]: string } = {};
export const PROVIDER: { [NODE: string]: ethers.JsonRpcProvider } = {};
export const ENDPOINT_ADDRESS: { [NODE: string]: string } = {};
export const RAYLS_NODE_ENDPOINT_ADDRESS: { [NODE: string]: string } = {};
export const RAYLS_NODE_USER_GOVERNANCE: { [NODE: string]: string } = {};
export const CHAIN_ID: { [NODE: string]: string } = {};
export const DB_CONNECTION: { [NODE: string]: string } = {};
export const DEPLOYMENT_PROXY_REGISTRY_ADDRESS: { [NODE: string]: string } = {};

RAYLS_NODES.forEach((NODE) => {
  const rpcUrl = process.env[`PRIVACY_NODE_${NODE}_RPC_URL`]!;
  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const endpointAddress = process.env[`PRIVACY_NODE_${NODE}_ENDPOINT_ADDRESS`]!;
  const raylsNodeEndpointAddress = process.env[`PRIVACY_NODE_${NODE}_RAYLS_NODE_ENDPOINT_ADDRESS`] || ethers.ZeroAddress;
  const raylsNodeUserGovernance = process.env[`PRIVACY_NODE_${NODE}_RAYLS_NODE_USER_GOVERNANCE`] || ethers.ZeroAddress;
  //const endpointAddress = process.env[`PRIVACY_NODE_${NODE}_ENDPOINT_ADDRESS`]!;
  const deploymentProxyRegistryAddress = process.env[`PRIVACY_NODE_${NODE}_DEPLOYMENT_PROXY_REGISTRY`]!;
  const chainId = process.env[`PRIVACY_NODE_${NODE}_CHAIN_ID`]!;
  const dbConnection = process.env[`PRIVACY_NODE_${NODE}_DB_CS`]!;

  provider.pollingInterval = 200;

  RPC_URL[NODE] = rpcUrl;
  PROVIDER[NODE] = provider;
  ENDPOINT_ADDRESS[NODE] = endpointAddress;
  RAYLS_NODE_ENDPOINT_ADDRESS[NODE] = raylsNodeEndpointAddress;
  RAYLS_NODE_USER_GOVERNANCE[NODE] = raylsNodeUserGovernance;
  //ENDPOINT_ADDRESS[NODE] = endpointAddress;
  CHAIN_ID[NODE] = chainId;
  DB_CONNECTION[NODE] = dbConnection;
  DEPLOYMENT_PROXY_REGISTRY_ADDRESS[NODE] = deploymentProxyRegistryAddress;
});

export const VEN_OPERATOR_WALLET = process.env['PRIVATE_KEY_SYSTEM']!;

export const USE_DB_CHECKS = process.env['USE_DB_CHECKS']! === 'true';
export const CLEAN_ENYGMA_DB_BEFORE_TESTS = process.env['CLEAN_ENYGMA_DB_BEFORE_TESTS']! === 'true';

export const SECOND = 1000;
export const MINUTE = 60 * SECOND;

export const ZERO_ADDRESS = ethers.ZeroAddress;
export const ZERO_HASH = ethers.ZeroHash;

export const NUMBER_OF_BLOCKS_TO_WAIT = 4;
export const DEFAULT_TIMEOUT = 4 * MINUTE;

export const GAS_LIMIT = 5000000;
export const LOGGER = new Logger();