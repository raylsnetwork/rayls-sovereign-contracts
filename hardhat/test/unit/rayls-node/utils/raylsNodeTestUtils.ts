import { ethers } from 'hardhat';
import { Signer } from 'ethers';
import {
    RNEndpointV1,
    RNTokenGovernanceV1,
    RNUserGovernanceV1,
    RNMessageExecutorV1,
    RNMessageDispatcherV1
} from '../../../../../typechain-types';
import { Logger, LogLevel } from '../../utils/moca-logger';

const logger = new Logger();
const logLevel = Number(process.env['TEST_LOGGING_LEVEL'] || LogLevel.INFO);
logger.setLogLevel(logLevel);

export interface RaylsNodeTestSuite {
    endpoint: RNEndpointV1;
    tokenGovernance: RNTokenGovernanceV1;
    userGovernance: RNUserGovernanceV1;
    messageExecutor: RNMessageExecutorV1;
    messageDispatcher: RNMessageDispatcherV1;
    relayAuthRegistry: any;
    deployer: Signer;
    user1: Signer;
    user2: Signer;
    relayer: Signer;
}

export interface TestTokenInfo {
    name: string;
    symbol: string;
    tokenAddress: string;
    publicTokenAddress?: string;
    standard: number; // 0=ERC20, 1=ERC721, 2=ERC1155
}

export interface TestUserInfo {
    userId: string;
    publicAddress: string;
    privateAddress: string;
}

/**
 * Deploy complete Rayls Node test suite with all contracts properly configured
 */
export async function deployRaylsNodeSuite(): Promise<RaylsNodeTestSuite> {
    const [deployer, user1, user2, relayer] = await ethers.getSigners();
    
    logger.debug('Deploying Rayls Node test suite...');
    
    const chainId = 12345;
    const publicChainId = 1;

    // Deploy RelayAuthorizationRegistry first using proxy
    const RelayAuthRegistryFactory = await ethers.getContractFactory('RelayAuthorizationRegistry');
    const relayAuthRegistry = await upgrades.deployProxy(RelayAuthRegistryFactory, [deployer.address], {
        kind: 'uups',
        initializer: 'initialize(address)'
    }) as any;
    await relayAuthRegistry.waitForDeployment();

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

    // Deploy endpoint using proxy
    const EndpointFactory = await ethers.getContractFactory('RNEndpointV1');
    const endpoint = await upgrades.deployProxy(EndpointFactory, [chainId, publicChainId], {
        kind: 'uups',
        initializer: 'initialize(uint256,uint256)'
    }) as unknown as RNEndpointV1;
    await endpoint.waitForDeployment();
    
    // Deploy token governance using proxy
    const TokenGovernanceFactory = await ethers.getContractFactory('RNTokenGovernanceV1');
    const tokenGovernance = await upgrades.deployProxy(TokenGovernanceFactory, [], {
        kind: 'uups',
        initializer: 'initialize()'
    }) as unknown as RNTokenGovernanceV1;
    await tokenGovernance.waitForDeployment();

    // Deploy user governance using proxy
    const UserGovernanceFactory = await ethers.getContractFactory('RNUserGovernanceV1');
    const userGovernance = await upgrades.deployProxy(UserGovernanceFactory, [], {
        kind: 'uups',
        initializer: 'initialize()'
    }) as unknown as RNUserGovernanceV1;
    await userGovernance.waitForDeployment();
    
    // Configure endpoint with all contracts
    await endpoint.configureContracts(
        await messageExecutor.getAddress(),
        await tokenGovernance.getAddress(),
        await userGovernance.getAddress(),
        await messageDispatcher.getAddress()
    );

    // Set endpoint as authorized in message executor
    await messageExecutor.setAuthorizedEndpoint(await endpoint.getAddress());
    // Also authorize deployer for direct test access
    await messageExecutor.setAuthorizedEndpoint(deployer.address);

    // Set endpoint as authorized dispatcher
    await messageDispatcher.setAuthorizedEndpoint(await endpoint.getAddress());
    // Also authorize deployer for direct test access
    await messageDispatcher.setAuthorizedEndpoint(deployer.address);

    // Add relayer and deployer as authorized in the registry
    await relayAuthRegistry.addAuthorizedRelayAddresses([relayer.address, deployer.address]);

    logger.debug('Rayls Node test suite deployed successfully');

    return {
        endpoint,
        tokenGovernance,
        userGovernance,
        messageExecutor,
        messageDispatcher,
        relayAuthRegistry,
        deployer,
        user1,
        user2,
        relayer
    };
}

/**
 * Create mock message structures for testing
 */
export function createMockRaylsNodeMessage(params: {
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
 * Create test users with address pairs
 */
export async function createTestUsers(suite: RaylsNodeTestSuite, count: number = 2): Promise<TestUserInfo[]> {
    const users: TestUserInfo[] = [];
    
    for (let i = 0; i < count; i++) {
        const userId = ethers.keccak256(ethers.toUtf8Bytes(`user${i}`));
        const publicWallet = ethers.Wallet.createRandom();
        const privateWallet = ethers.Wallet.createRandom();
        
        // Create user
        await suite.userGovernance.createUser(userId);
        
        // Add address pair
        await suite.userGovernance.addAddressPair(
            userId,
            publicWallet.address,
            privateWallet.address
        );
        
        users.push({
            userId,
            publicAddress: publicWallet.address,
            privateAddress: privateWallet.address
        });
    }
    
    return users;
}

/**
 * Setup test tokens for testing
 */
export async function setupTestTokens(suite: RaylsNodeTestSuite): Promise<TestTokenInfo[]> {
    const tokens: TestTokenInfo[] = [
        {
            name: 'Test USDC',
            symbol: 'USDC',
            tokenAddress: '0x' + '1'.repeat(40),
            standard: 0 // ERC20
        },
        {
            name: 'Test NFT',
            symbol: 'TNFT',
            tokenAddress: '0x' + '2'.repeat(40),
            standard: 1 // ERC721
        },
        {
            name: 'Test Multi-Token',
            symbol: 'TMT',
            tokenAddress: '0x' + '3'.repeat(40),
            standard: 2 // ERC1155
        }
    ];
    
    for (const token of tokens) {
        await suite.tokenGovernance.addToken(
            token.tokenAddress,
            token.standard,
            token.name,
            '', // uri
            token.symbol
        );

        // Activate token for testing
        await suite.tokenGovernance.updateTokenStatus(token.tokenAddress, 1); // ACTIVE
    }
    
    return tokens;
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