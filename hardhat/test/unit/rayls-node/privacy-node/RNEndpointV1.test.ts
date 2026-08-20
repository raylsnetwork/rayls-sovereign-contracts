/**
 * @deprecated Decommissioning Teleport (vanilla, atomic).
 */
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
    deployRaylsNodeSuite,
    createMockRaylsNodeMessage,
    setupTestTokens,
    createTestUsers,
    generateRandomAddress,
    RaylsNodeTestSuite,
    TestTokenInfo,
    TestUserInfo
} from '../utils/raylsNodeTestUtils';
import { Logger, LogLevel } from '../../utils/moca-logger';

const logger = new Logger();
const logLevel = Number(process.env['TEST_LOGGING_LEVEL'] || LogLevel.INFO);
logger.setLogLevel(logLevel);

describe('RNEndpointV1 Unit Tests', function () {
    let suite: RaylsNodeTestSuite;
    let testTokens: TestTokenInfo[];
    let testUsers: TestUserInfo[];
    
    const chainId = 12345;
    const publicChainId = 1;
    const destinationChainId = 67890;
    
    beforeEach(async function () {
        logger.debug('Setting up RNEndpointV1 test suite...');
        suite = await deployRaylsNodeSuite();
        testTokens = await setupTestTokens(suite);
        testUsers = await createTestUsers(suite, 2);
        
        // Approve test users
        for (const user of testUsers) {
            await suite.userGovernance.approveUser(user.userId);
        }
    });
    
    describe('Initialization', function () {
        it('should initialize with correct parameters', async function () {
            expect(await suite.endpoint.currentChainId()).to.equal(chainId);
            expect(await suite.endpoint.publicChainId()).to.equal(publicChainId);
            expect(await suite.endpoint.getNonce()).to.equal(0);
        });
        
        it('should set deployer as initial authorized relayer', async function () {
            const authorizedRelayers = await suite.endpoint.getAuthorizedRelayAddresses();
            expect(authorizedRelayers).to.include(suite.deployer.address);
        });
    });
    
    describe('Contract Configuration', function () {
        it('should configure contracts correctly', async function () {
            const tokenRegistryAddr = await suite.endpoint.getTokenRegistryAddress();
            const userGovernanceAddr = await suite.endpoint.getUserGovernanceAddress();
            const messageDispatcherAddr = await suite.endpoint.getMessageDispatcherAddress();
            
            expect(tokenRegistryAddr).to.equal(await suite.tokenRegistry.getAddress());
            expect(userGovernanceAddr).to.equal(await suite.userGovernance.getAddress());
            expect(messageDispatcherAddr).to.equal(await suite.messageDispatcher.getAddress());
        });
        
        it('should only allow authorized caller to configure contracts', async function () {
            await expect(
                suite.endpoint.connect(suite.user1).configureContracts(
                    await suite.messageExecutor.getAddress(),
                    await suite.tokenRegistry.getAddress(),
                    await suite.userGovernance.getAddress(),
                    await suite.messageDispatcher.getAddress()
                )
            ).to.be.revertedWithCustomError(suite.endpoint, 'RaylsAccessManaged__Unauthorized');
        });
    });
    
    describe('Message Sending - send()', function () {
        it('should revert when called by unauthorized token', async function () {
            const unauthorizedToken = generateRandomAddress();
            const destination = generateRandomAddress();
            const payload = ethers.toUtf8Bytes('Hello World');
            
            await ethers.provider.send('hardhat_impersonateAccount', [unauthorizedToken]);
            const tokenSigner = await ethers.getSigner(unauthorizedToken);
            
            await suite.deployer.sendTransaction({
                to: unauthorizedToken,
                value: ethers.parseEther('1')
            });
            
            await expect(
                suite.endpoint.connect(tokenSigner).send(
                    destinationChainId,
                    destination,
                    payload
                )
            ).to.be.revertedWithCustomError(suite.endpoint, 'RNEndpointV1__TokenUnauthorizedAccount');
            
            await ethers.provider.send('hardhat_stopImpersonatingAccount', [unauthorizedToken]);
        });
        
        it('should revert when source and destination chain IDs are the same', async function () {
            const tokenAddress = testTokens[0].tokenAddress;
            const destination = generateRandomAddress();
            const payload = ethers.toUtf8Bytes('Hello World');
            
            await ethers.provider.send('hardhat_impersonateAccount', [tokenAddress]);
            const tokenSigner = await ethers.getSigner(tokenAddress);
            
            await suite.deployer.sendTransaction({
                to: tokenAddress,
                value: ethers.parseEther('1')
            });
            
            await expect(
                suite.endpoint.connect(tokenSigner).send(
                    chainId, // Same as current chain
                    destination,
                    payload
                )
            ).to.be.revertedWithCustomError(suite.endpoint, 'RNEndpointV1__SourceAndDestinationChainsSame');
            
            await ethers.provider.send('hardhat_stopImpersonatingAccount', [tokenAddress]);
        });
    });
    
    describe('Message Receiving', function () {
        it('should revert when called by unauthorized relayer', async function () {
            const sourceChainId = destinationChainId;
            const sourceAddress = generateRandomAddress();
            const destinationAddress = generateRandomAddress();
            const message = createMockRaylsNodeMessage({ nonce: 1 });
            const messageId = ethers.keccak256(ethers.toUtf8Bytes('test-message-id'));

            await expect(
                suite.endpoint.connect(suite.user1).receivePayload(
                    sourceChainId,
                    sourceAddress,
                    destinationAddress,
                    message,
                    messageId
                )
            ).to.be.revertedWithCustomError(suite.endpoint, 'RNEndpointV1__RelayerUnauthorizedAccount');
        });
    });
    
    describe('View Functions', function () {
        it('should return correct chain ID', async function () {
            expect(await suite.endpoint.getChainId()).to.equal(chainId);
        });

        it('should identify trusted executor', async function () {
            const messageExecutorAddr = await suite.messageExecutor.getAddress();
            expect(await suite.endpoint.isTrustedExecutor(messageExecutorAddr)).to.be.true;
            expect(await suite.endpoint.isTrustedExecutor(generateRandomAddress())).to.be.false;
        });
    });

    describe('Zero Address Validation', function () {
        it('should revert when configureContracts called with zero address for message executor', async function () {
            await expect(
                suite.endpoint.configureContracts(
                    ethers.ZeroAddress,
                    await suite.tokenRegistry.getAddress(),
                    await suite.userGovernance.getAddress(),
                    await suite.messageDispatcher.getAddress()
                )
            ).to.be.revertedWithCustomError(suite.endpoint, 'RNEndpointV1__InvalidMessageExecutorAddress');
        });

        it('should revert when configureContracts called with zero address for token governance', async function () {
            await expect(
                suite.endpoint.configureContracts(
                    await suite.messageExecutor.getAddress(),
                    ethers.ZeroAddress,
                    await suite.userGovernance.getAddress(),
                    await suite.messageDispatcher.getAddress()
                )
            ).to.be.revertedWithCustomError(suite.endpoint, 'RNEndpointV1__InvalidTokenRegistryAddress');
        });

        it('should revert when configureContracts called with zero address for user governance', async function () {
            await expect(
                suite.endpoint.configureContracts(
                    await suite.messageExecutor.getAddress(),
                    await suite.tokenRegistry.getAddress(),
                    ethers.ZeroAddress,
                    await suite.messageDispatcher.getAddress()
                )
            ).to.be.revertedWithCustomError(suite.endpoint, 'RNEndpointV1__InvalidUserGovernanceAddress');
        });

        it('should revert when configureContracts called with zero address for message dispatcher', async function () {
            await expect(
                suite.endpoint.configureContracts(
                    await suite.messageExecutor.getAddress(),
                    await suite.tokenRegistry.getAddress(),
                    await suite.userGovernance.getAddress(),
                    ethers.ZeroAddress
                )
            ).to.be.revertedWithCustomError(suite.endpoint, 'RNEndpointV1__InvalidMessageDispatcherAddress');
        });

    });
});