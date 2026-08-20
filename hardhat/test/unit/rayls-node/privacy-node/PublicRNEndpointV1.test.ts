/**
 * @deprecated Decommissioning Teleport (vanilla, atomic).
 */
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
    deployPublicRaylsNodeSuite,
    createMockPublicRaylsNodeMessage,
    generateRandomAddress,
    PublicRaylsNodeTestSuite
} from '../utils/publicChainTestUtils';
import { Logger, LogLevel } from '../../utils/moca-logger';

const logger = new Logger();
const logLevel = Number(process.env['TEST_LOGGING_LEVEL'] || LogLevel.INFO);
logger.setLogLevel(logLevel);

describe('PublicRNEndpointV1 Unit Tests', function () {
    let suite: PublicRaylsNodeTestSuite;
    let mockReceiver: any;
    let mockReceiverAddress: string;

    const chainId = 1;
    const destinationChainId = 12345;

    beforeEach(async function () {
        logger.debug('Setting up PublicRNEndpointV1 test suite...');
        suite = await deployPublicRaylsNodeSuite();

        // Deploy mock message receiver
        const MockReceiverFactory = await ethers.getContractFactory('MockMessageReceiver');
        mockReceiver = await MockReceiverFactory.deploy();
        await mockReceiver.waitForDeployment();
        mockReceiverAddress = await mockReceiver.getAddress();
    });

    describe('Initialization', function () {
        it('should initialize with correct parameters', async function () {
            expect(await suite.publicEndpoint.currentChainId()).to.equal(chainId);
            expect(await suite.publicEndpoint.nonce()).to.equal(0);
        });

        it('should not allow double initialization', async function () {
            await expect(
                suite.publicEndpoint.initialize(chainId)
            ).to.be.revertedWithCustomError(suite.publicEndpoint, 'InvalidInitialization');
        });
    });

    describe('Contract Configuration', function () {
        it('should configure contracts correctly', async function () {
            const messageDispatcherAddr = await suite.publicEndpoint.getMessageDispatcherAddress();
            expect(messageDispatcherAddr).to.equal(await suite.messageDispatcher.getAddress());
        });

        it('should only allow authorized caller to configure contracts', async function () {
            await expect(
                suite.publicEndpoint.connect(suite.user1).configureContracts(
                    await suite.messageExecutor.getAddress(),
                    await suite.messageDispatcher.getAddress()
                )
            ).to.be.revertedWithCustomError(suite.publicEndpoint, 'RaylsAccessManaged__Unauthorized');
        });
    });

    describe('Message Sending - send()', function () {
        it('should send message successfully', async function () {
            const destination = generateRandomAddress();
            const payload = ethers.toUtf8Bytes('Hello World');

            const tx = await suite.publicEndpoint.send(
                destinationChainId,
                destination,
                payload
            );

            expect(tx).to.not.be.reverted;
            expect(await suite.publicEndpoint.nonce()).to.equal(1);
        });

        it('should send message without reverting', async function () {
            const destination = generateRandomAddress();
            const payload = ethers.toUtf8Bytes('test message');

            const tx = await suite.publicEndpoint.send(
                destinationChainId,
                destination,
                payload
            );

            expect(tx).to.not.be.reverted;
        });

        it('should increment nonce after each send', async function () {
            const destination = generateRandomAddress();
            const payload = ethers.toUtf8Bytes('test');

            expect(await suite.publicEndpoint.nonce()).to.equal(0);

            await suite.publicEndpoint.send(destinationChainId, destination, payload);
            expect(await suite.publicEndpoint.nonce()).to.equal(1);

            await suite.publicEndpoint.send(destinationChainId, destination, payload);
            expect(await suite.publicEndpoint.nonce()).to.equal(2);

            await suite.publicEndpoint.send(destinationChainId, destination, payload);
            expect(await suite.publicEndpoint.nonce()).to.equal(3);
        });

        it('should handle empty payload', async function () {
            const destination = generateRandomAddress();
            const emptyPayload = '0x';

            const tx = await suite.publicEndpoint.send(
                destinationChainId,
                destination,
                emptyPayload
            );

            expect(tx).to.not.be.reverted;
        });

        it('should handle large payload', async function () {
            const destination = generateRandomAddress();
            const largePayload = '0x' + '12'.repeat(1000); // 2000 bytes

            const tx = await suite.publicEndpoint.send(
                destinationChainId,
                destination,
                largePayload
            );

            expect(tx).to.not.be.reverted;
        });

        it('should revert when source and destination chain IDs are the same', async function () {
            const destination = generateRandomAddress();
            const payload = ethers.toUtf8Bytes('test');

            await expect(
                suite.publicEndpoint.send(
                    chainId, // Same as current chain
                    destination,
                    payload
                )
            ).to.be.revertedWithCustomError(suite.publicEndpoint, 'PublicRNEndpointV1__SourceAndDestinationChainsSame');
        });
    });

    describe('Message Sending - sendToAddress()', function () {
        it('should send message to address successfully', async function () {
            const privateChainAddress = generateRandomAddress();
            const transferMetadata = {
                assetType: 0, // ERC20
                id: 0,
                from: suite.deployer.address,
                to: generateRandomAddress(),
                tokenAddress: generateRandomAddress(),
                amount: ethers.parseEther('100')
            };

            const tx = await suite.publicEndpoint.sendToAddress(
                destinationChainId,
                privateChainAddress,
                ethers.toUtf8Bytes('transfer payload'),
                '0x', // revert data
                transferMetadata
            );

            expect(tx).to.not.be.reverted;
            expect(await suite.publicEndpoint.nonce()).to.equal(1);
        });

        it('should send message to address without reverting', async function () {
            const privateChainAddress = generateRandomAddress();
            const transferMetadata = {
                assetType: 0,
                id: 0,
                from: ethers.ZeroAddress,
                to: ethers.ZeroAddress,
                tokenAddress: ethers.ZeroAddress,
                amount: 0
            };

            const tx = await suite.publicEndpoint.sendToAddress(
                destinationChainId,
                privateChainAddress,
                ethers.toUtf8Bytes('payload'),
                '0x',
                transferMetadata
            );

            expect(tx).to.not.be.reverted;
        });

        it('should handle different asset types', async function () {
            const privateChainAddress = generateRandomAddress();
            const assetTypes = [0, 1, 2]; // ERC20, ERC721, ERC1155

            for (const assetType of assetTypes) {
                const transferMetadata = {
                    assetType: assetType,
                    id: assetType === 0 ? 0 : 123, // Non-zero ID for NFTs
                    from: suite.deployer.address,
                    to: generateRandomAddress(),
                    tokenAddress: generateRandomAddress(),
                    amount: assetType === 1 ? 1 : 100 // NFTs have amount 1
                };

                const tx = await suite.publicEndpoint.sendToAddress(
                    destinationChainId,
                    privateChainAddress,
                    ethers.toUtf8Bytes(`payload for type ${assetType}`),
                    '0x',
                    transferMetadata
                );

                expect(tx).to.not.be.reverted;
            }
        });
    });

    describe('Message Receiving', function () {
        it('should revert when called by unauthorized relayer', async function () {
            const sourceChainId = destinationChainId;
            const sourceAddress = generateRandomAddress();
            const destinationAddress = await suite.publicEndpoint.getAddress();
            const message = createMockPublicRaylsNodeMessage({ nonce: 1 });
            const messageId = ethers.keccak256(ethers.toUtf8Bytes('test-message-id'));

            await expect(
                suite.publicEndpoint.connect(suite.user1).receivePayload(
                    sourceChainId,
                    sourceAddress,
                    destinationAddress,
                    message,
                    messageId
                )
            ).to.be.revertedWithCustomError(suite.publicEndpoint, 'PublicRNEndpointV1__RelayerUnauthorizedAccount');
        });
    });

    describe('View Functions', function () {
        it('should return correct chain ID', async function () {
            expect(await suite.publicEndpoint.getChainId()).to.equal(chainId);
        });

        it('should identify trusted executor', async function () {
            const messageExecutorAddr = await suite.messageExecutor.getAddress();
            expect(await suite.publicEndpoint.isTrustedExecutor(messageExecutorAddr)).to.be.true;
            expect(await suite.publicEndpoint.isTrustedExecutor(generateRandomAddress())).to.be.false;
        });

        it('should return correct version', async function () {
            expect(await suite.publicEndpoint.version()).to.equal('2.6');
        });

        it('should return correct contract version', async function () {
            expect(await suite.publicEndpoint.contractVersion()).to.equal(1);
        });

        it('should track nonce correctly', async function () {
            const initialNonce = await suite.publicEndpoint.nonce();
            expect(initialNonce).to.equal(0);

            // Send a message to increment nonce
            await suite.publicEndpoint.send(
                destinationChainId,
                generateRandomAddress(),
                ethers.toUtf8Bytes('test')
            );

            expect(await suite.publicEndpoint.nonce()).to.equal(1);
        });

        it('should return nonce through getNonce function', async function () {
            expect(await suite.publicEndpoint.getNonce()).to.equal(0);

            await suite.publicEndpoint.send(
                destinationChainId,
                generateRandomAddress(),
                ethers.toUtf8Bytes('test')
            );

            expect(await suite.publicEndpoint.getNonce()).to.equal(1);
        });

        it('should check message execution status defaults to false', async function () {
            const messageId = ethers.keccak256(ethers.toUtf8Bytes('test-message-id'));

            expect(await suite.publicEndpoint.isExecuted(messageId)).to.be.false;
        });
    });

    describe('Access Control Edge Cases', function () {
        it('should prevent non-admin from upgrading', async function () {
            const newImplementation = generateRandomAddress();

            await expect(
                suite.publicEndpoint.connect(suite.user1).upgradeToAndCall(newImplementation, '0x')
            ).to.be.revertedWithCustomError(suite.publicEndpoint, 'RaylsAccessManaged__Unauthorized');
        });
    });

    describe('Message Flow Scenarios', function () {
        it('should handle outgoing message flow', async function () {
            // Send message from public chain to private chain
            const privateChainAddress = generateRandomAddress();
            const transferMetadata = {
                assetType: 0,
                id: 0,
                from: suite.deployer.address,
                to: generateRandomAddress(),
                tokenAddress: generateRandomAddress(),
                amount: ethers.parseEther('100')
            };

            const tx1 = await suite.publicEndpoint.sendToAddress(
                destinationChainId,
                privateChainAddress,
                ethers.toUtf8Bytes('outgoing'),
                '0x',
                transferMetadata
            );

            expect(tx1).to.not.be.reverted;
        });

        it('should handle concurrent outgoing messages', async function () {
            const destinations = [
                generateRandomAddress(),
                generateRandomAddress(),
                generateRandomAddress()
            ];

            for (const dest of destinations) {
                const tx = await suite.publicEndpoint.send(
                    destinationChainId,
                    dest,
                    ethers.toUtf8Bytes('concurrent message')
                );

                expect(tx).to.not.be.reverted;
            }

            expect(await suite.publicEndpoint.nonce()).to.equal(destinations.length);
        });
    });

    describe('Edge Cases', function () {
        it('should handle zero address destination', async function () {
            const payload = ethers.toUtf8Bytes('test');

            const tx = await suite.publicEndpoint.send(
                destinationChainId,
                ethers.ZeroAddress,
                payload
            );

            expect(tx).to.not.be.reverted;
        });

        it('should handle zero amount in transfer metadata', async function () {
            const privateChainAddress = generateRandomAddress();
            const transferMetadata = {
                assetType: 0,
                id: 0,
                from: ethers.ZeroAddress,
                to: ethers.ZeroAddress,
                tokenAddress: ethers.ZeroAddress,
                amount: 0
            };

            const tx = await suite.publicEndpoint.sendToAddress(
                destinationChainId,
                privateChainAddress,
                '0x',
                '0x',
                transferMetadata
            );

            expect(tx).to.not.be.reverted;
        });

        it('should handle maximum nonce value', async function () {
            // Fast-forward nonce to a large value
            const largeNonceCount = 100;

            for (let i = 0; i < largeNonceCount; i++) {
                await suite.publicEndpoint.send(
                    destinationChainId,
                    generateRandomAddress(),
                    '0x'
                );
            }

            expect(await suite.publicEndpoint.nonce()).to.equal(largeNonceCount);
        });
    });

    describe('Zero Address Validation', function () {
        it('should revert when configureContracts called with zero address for message executor', async function () {
            await expect(
                suite.publicEndpoint.configureContracts(
                    ethers.ZeroAddress,
                    await suite.messageDispatcher.getAddress()
                )
            ).to.be.revertedWithCustomError(suite.publicEndpoint, 'PublicRNEndpointV1__InvalidMessageExecutorAddress');
        });

        it('should revert when configureContracts called with zero address for message dispatcher', async function () {
            await expect(
                suite.publicEndpoint.configureContracts(
                    await suite.messageExecutor.getAddress(),
                    ethers.ZeroAddress
                )
            ).to.be.revertedWithCustomError(suite.publicEndpoint, 'PublicRNEndpointV1__InvalidMessageDispatcherAddress');
        });

    });
});