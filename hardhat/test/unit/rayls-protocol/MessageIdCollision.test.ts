import { expect } from 'chai';
import { ethers } from 'hardhat';
import { Signer } from 'ethers';
import { Logger, LogLevel } from '../utils/moca-logger';

const logger = new Logger();
const logLevel = Number(process.env['TEST_LOGGING_LEVEL'] || LogLevel.INFO);
logger.setLogLevel(logLevel);

/**
 * MessageId Uniqueness Tests
 * 
 * Validates that messageId generation produces unique IDs across
 * MessageSender and BatchMessageSender contracts.
 * 
 * These tests assert that messageIds should NOT collide, even when
 * both senders are used with identical parameters.
 */
describe('MessageId Uniqueness Tests', function () {
    let deployer: Signer;
    let sender: Signer;
    let messageSender: any;
    let batchMessageSender: any;
    let mockParticipantValidator: any;
    let mockTokenValidator: any;

    const chainId = 12345;
    const privateHubChainId = 999;
    const dstChainId = 67890;

    before(async function () {
        [deployer, sender] = await ethers.getSigners();

        // Deploy mock validators that always pass validation
        const MockParticipantValidatorFactory = await ethers.getContractFactory('MockParticipantValidator');
        mockParticipantValidator = await MockParticipantValidatorFactory.deploy();
        await mockParticipantValidator.waitForDeployment();

        const MockTokenValidatorFactory = await ethers.getContractFactory('MockTokenValidator');
        mockTokenValidator = await MockTokenValidatorFactory.deploy();
        await mockTokenValidator.waitForDeployment();

        // Deploy MessageSender
        const deployerAddress = await deployer.getAddress();
        const MessageSenderFactory = await ethers.getContractFactory('MessageSender');
        messageSender = await MessageSenderFactory.deploy(
            chainId,
            privateHubChainId,
            await mockParticipantValidator.getAddress(),
            await mockTokenValidator.getAddress(),
            deployerAddress,
            deployerAddress,
            ethers.ZeroAddress
        );
        await messageSender.waitForDeployment();

        // Deploy BatchMessageSender
        const BatchMessageSenderFactory = await ethers.getContractFactory('BatchMessageSender');
        batchMessageSender = await BatchMessageSenderFactory.deploy(
            privateHubChainId,
            await mockParticipantValidator.getAddress(),
            await mockTokenValidator.getAddress(),
            deployerAddress,
            deployerAddress,
            ethers.ZeroAddress
        );
        await batchMessageSender.waitForDeployment();
    });

    describe('Nonce Counter Independence', function () {
        it('should have independent nonce counters starting at 0', async function () {
            const singleNonce = await messageSender.getOutboundNonce(dstChainId);
            const batchNonce = await batchMessageSender.outboundNonce(dstChainId);

            expect(singleNonce).to.equal(0n);
            expect(batchNonce).to.equal(0n);
        });
    });

    describe('MessageId Uniqueness Validation', function () {
        it('should produce unique messageIds when MessageSender and BatchMessageSender use identical parameters', async function () {
            const senderAddress = await sender.getAddress();
            const destination = ethers.ZeroAddress;
            const resourceId = ethers.ZeroHash;
            const payload = ethers.toUtf8Bytes('test payload');

            // Create identical SendRequest
            const sendRequest = {
                dstChainId: dstChainId,
                destination: destination,
                payload: payload,
                resourceId: resourceId,
                newResourceMetadata: {
                    valid: false,
                    resourceDeployType: 0,
                    bytecode: '0x',
                    factoryTemplate: 0,
                    initializerParams: '0x'
                },
                lockData: '0x',
                revertDataSender: '0x',
                revertDataReceiver: '0x',
                transferMetadata: {
                    assetType: 0,
                    id: 0,
                    from: ethers.ZeroAddress,
                    to: ethers.ZeroAddress,
                    tokenAddress: ethers.ZeroAddress,
                    amount: 0
                }
            };

            // Get messageId from MessageSender (nonce will be 1)
            const singleResult = await messageSender.prepareMessage.staticCall(sendRequest, senderAddress);
            const singleMessageId = singleResult.messageId;
            const singleNonce = singleResult.nonce;

            // Get messageId from BatchMessageSender (nonce will also be 1)
            const batchResult = await batchMessageSender.prepareBatch.staticCall([sendRequest], senderAddress, chainId);
            const batchMessageId = batchResult.messages[0].messageId;
            const batchNonce = batchResult.nonces[0];

            logger.debug('=== UNIQUENESS TEST ===' );
            logger.debug(`Single Message nonce: ${singleNonce.toString()}`);
            logger.debug(`Batch Message nonce: ${batchNonce.toString()}`);
            logger.debug(`Single MessageId: ${singleMessageId}`);
            logger.debug(`Batch MessageId: ${batchMessageId}`);
            logger.debug(`Are they equal?: ${singleMessageId === batchMessageId}`);

            // Both should use nonce=1 (first message for each)
            expect(singleNonce).to.equal(1n, 'Single message should use nonce 1');
            expect(batchNonce).to.equal(1n, 'Batch message should use nonce 1');

            // MessageIds must be unique across different sender types
            expect(singleMessageId).to.not.equal(
                batchMessageId,
                'MessageIds must be unique: MessageSender and BatchMessageSender should not produce same messageId'
            );
        });

        it('should show nonces increment independently', async function () {
            const senderAddress = await sender.getAddress();

            const sendRequest = {
                dstChainId: dstChainId,
                destination: ethers.ZeroAddress,
                payload: '0x',
                resourceId: ethers.ZeroHash,
                newResourceMetadata: {
                    valid: false,
                    resourceDeployType: 0,
                    bytecode: '0x',
                    factoryTemplate: 0,
                    initializerParams: '0x'
                },
                lockData: '0x',
                revertDataSender: '0x',
                revertDataReceiver: '0x',
                transferMetadata: {
                    assetType: 0,
                    id: 0,
                    from: ethers.ZeroAddress,
                    to: ethers.ZeroAddress,
                    tokenAddress: ethers.ZeroAddress,
                    amount: 0
                }
            };

            // Actually execute prepareMessage to increment nonce
            await messageSender.prepareMessage(sendRequest, senderAddress);
            await messageSender.prepareMessage(sendRequest, senderAddress);

            // Check nonces
            const singleNonce = await messageSender.getOutboundNonce(dstChainId);
            const batchNonce = await batchMessageSender.outboundNonce(dstChainId);

            logger.debug('=== NONCE INDEPENDENCE ===');
            logger.debug(`MessageSender nonce after 2 messages: ${singleNonce.toString()}`);
            logger.debug(`BatchMessageSender nonce (unchanged): ${batchNonce.toString()}`);

            expect(singleNonce).to.equal(2n, 'MessageSender should have nonce=2');
            expect(batchNonce).to.equal(0n, 'BatchMessageSender should still have nonce=0');
        });

        it('should produce unique messageIds with fresh contract instances', async function () {
            // Reset by deploying fresh contracts
            const MockParticipantValidatorFactory = await ethers.getContractFactory('MockParticipantValidator');
            const freshMockParticipantValidator = await MockParticipantValidatorFactory.deploy();
            
            const MockTokenValidatorFactory = await ethers.getContractFactory('MockTokenValidator');
            const freshMockTokenValidator = await MockTokenValidatorFactory.deploy();

            const freshDeployerAddress = await deployer.getAddress();
            const MessageSenderFactory = await ethers.getContractFactory('MessageSender');
            const freshMessageSender = await MessageSenderFactory.deploy(
                chainId,
                privateHubChainId,
                await freshMockParticipantValidator.getAddress(),
                await freshMockTokenValidator.getAddress(),
                freshDeployerAddress,
                freshDeployerAddress,
                ethers.ZeroAddress
            );

            const BatchMessageSenderFactory = await ethers.getContractFactory('BatchMessageSender');
            const freshBatchMessageSender = await BatchMessageSenderFactory.deploy(
                privateHubChainId,
                await freshMockParticipantValidator.getAddress(),
                await freshMockTokenValidator.getAddress(),
                freshDeployerAddress,
                freshDeployerAddress,
                ethers.ZeroAddress
            );

            const senderAddress = await sender.getAddress();

            // Create request with specific data
            const sendRequest = {
                dstChainId: dstChainId,
                destination: ethers.ZeroAddress,
                payload: ethers.toUtf8Bytes('collision test'),
                resourceId: ethers.keccak256(ethers.toUtf8Bytes('test-resource')),
                newResourceMetadata: {
                    valid: false,
                    resourceDeployType: 0,
                    bytecode: '0x',
                    factoryTemplate: 0,
                    initializerParams: '0x'
                },
                lockData: '0x',
                revertDataSender: '0x',
                revertDataReceiver: '0x',
                transferMetadata: {
                    assetType: 0,
                    id: 0,
                    from: ethers.ZeroAddress,
                    to: ethers.ZeroAddress,
                    tokenAddress: ethers.ZeroAddress,
                    amount: 0
                }
            };

            // Both start at nonce=0, will both use nonce=1 for first message
            const [, singleId,] = await freshMessageSender.prepareMessage.staticCall(sendRequest, senderAddress);
            const batchResult = await freshBatchMessageSender.prepareBatch.staticCall([sendRequest], senderAddress, chainId);
            const batchId = batchResult.messages[0].messageId;

            logger.debug('=== FRESH CONTRACTS UNIQUENESS TEST ===');
            logger.debug(`Fresh Single MessageId: ${singleId}`);
            logger.debug(`Fresh Batch MessageId: ${batchId}`);
            logger.debug(`Are unique: ${singleId !== batchId}`);

            // MessageIds must be unique even with fresh contracts
            expect(singleId).to.not.equal(batchId, 'Fresh contracts must produce unique messageIds');
        });
    });
});
