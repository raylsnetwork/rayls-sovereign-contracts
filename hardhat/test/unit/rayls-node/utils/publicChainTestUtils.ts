import { ethers } from 'hardhat';
import { Signer } from 'ethers';
import {
    PublicRNEndpointV1,
    RNMessageExecutorV1,
    RNMessageDispatcherV1
} from '../../../../../typechain-types';
import { Logger, LogLevel } from '../../utils/moca-logger';

const logger = new Logger();
const logLevel = Number(process.env['TEST_LOGGING_LEVEL'] || LogLevel.INFO);
logger.setLogLevel(logLevel);

export interface PublicRaylsNodeTestSuite {
    publicEndpoint: PublicRNEndpointV1;
    messageExecutor: RNMessageExecutorV1;
    messageDispatcher: RNMessageDispatcherV1;
    deployer: Signer;
    user1: Signer;
    user2: Signer;
    relayer: Signer;
}

/**
 * Deploy complete Public Rayls Node test suite with all contracts properly configured
 */
export async function deployPublicRaylsNodeSuite(): Promise<PublicRaylsNodeTestSuite> {
    const [deployer, user1, user2, relayer] = await ethers.getSigners();

    logger.debug('Deploying Public Rayls Node test suite...');

    const chainId = 1; // Public chain ID

    // Deploy message executor using proxy
    const MessageExecutorFactory = await ethers.getContractFactory('RNMessageExecutorV1');
    const messageExecutor = await upgrades.deployProxy(MessageExecutorFactory, [], {
        kind: 'uups',
        initializer: 'initialize()'
    }) as unknown as RNMessageExecutorV1;
    await messageExecutor.waitForDeployment();

    // Deploy message dispatcher using proxy
    const MessageDispatcherFactory = await ethers.getContractFactory('RNMessageDispatcherV1');
    const messageDispatcher = await upgrades.deployProxy(MessageDispatcherFactory, [], {
        kind: 'uups',
        initializer: 'initialize()'
    }) as unknown as RNMessageDispatcherV1;
    await messageDispatcher.waitForDeployment();

    // Deploy public endpoint using proxy
    const PublicEndpointFactory = await ethers.getContractFactory('PublicRNEndpointV1');
    const publicEndpoint = await upgrades.deployProxy(PublicEndpointFactory, [chainId], {
        kind: 'uups',
        initializer: 'initialize(uint256)'
    }) as unknown as PublicRNEndpointV1;
    await publicEndpoint.waitForDeployment();

    // Configure public endpoint with contracts
    await publicEndpoint.configureContracts(
        await messageExecutor.getAddress(),
        await messageDispatcher.getAddress()
    );

    // Set endpoint as authorized in message executor
    await messageExecutor.setAuthorizedEndpoint(await publicEndpoint.getAddress());

    // Set endpoint as authorized dispatcher
    await messageDispatcher.setAuthorizedEndpoint(await publicEndpoint.getAddress());

    // Add deployer as authorized sender for testing
    await publicEndpoint.addAuthorizedSender(deployer.address);

    logger.debug('Public Rayls Node test suite deployed successfully');

    return {
        publicEndpoint,
        messageExecutor,
        messageDispatcher,
        deployer,
        user1,
        user2,
        relayer
    };
}

/**
 * Helper to generate random addresses for testing
 */
export function generateRandomAddress(): string {
    return ethers.getAddress(ethers.hexlify(ethers.randomBytes(20)));
}

/**
 * Helper to generate random bytes32 for testing
 */
export function generateRandomBytes32(): string {
    return ethers.hexlify(ethers.randomBytes(32));
}

/**
 * Create mock message structures for testing
 */
export function createMockPublicRaylsNodeMessage(params: {
    nonce?: number;
    payload?: string | Uint8Array;
}): any {
    return {
        messageMetadata: {
            nonce: params.nonce || 1,
            newResourceMetadata: {
                resourceDeployType: 0,
                bytecode: '0x',
                factoryTemplate: 0,
                initializerParams: '0x'
            },
            revertPayloadData: '0x',
            transferMetadata: {
                assetType: 0,
                id: 0,
                from: ethers.ZeroAddress,
                to: ethers.ZeroAddress,
                tokenAddress: ethers.ZeroAddress,
                amount: 0
            }
        },
        payload: params.payload || '0x'
    };
}

/**
 * Helper to advance time in tests
 */
export async function advanceTime(seconds: number): Promise<void> {
    await ethers.provider.send('evm_increaseTime', [seconds]);
    await ethers.provider.send('evm_mine', []);
}

/**
 * Helper to get latest block timestamp
 */
export async function getLatestBlockTimestamp(): Promise<number> {
    const block = await ethers.provider.getBlock('latest');
    return block!.timestamp;
}