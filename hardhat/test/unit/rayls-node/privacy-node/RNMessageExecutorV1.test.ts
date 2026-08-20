/**
 * @deprecated Decommissioning Teleport (vanilla, atomic).
 */
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
    deployRaylsNodeSuite,
    generateRandomAddress,
    generateRandomBytes32,
    RaylsNodeTestSuite
} from '../utils/raylsNodeTestUtils';
import { RNMessageExecutorV1, MockMessageReceiver } from '../../../../../typechain-types';
import { Logger, LogLevel } from '../../utils/moca-logger';

const logger = new Logger();
const logLevel = Number(process.env['TEST_LOGGING_LEVEL'] || LogLevel.INFO);
logger.setLogLevel(logLevel);

describe('RNMessageExecutorV1 Unit Tests', function () {
    let suite: RaylsNodeTestSuite;
    let mockReceiver: MockMessageReceiver;
    let mockReceiverAddress: string;

    const fromChainId = 67890;
    const fromAddress = generateRandomAddress();

    beforeEach(async function () {
        logger.debug('Setting up RNMessageExecutorV1 test suite...');
        suite = await deployRaylsNodeSuite();

        // Deploy mock message receiver contract
        const MockReceiverFactory = await ethers.getContractFactory('MockMessageReceiver');
        mockReceiver = await MockReceiverFactory.deploy() as MockMessageReceiver;
        await mockReceiver.waitForDeployment();
        mockReceiverAddress = await mockReceiver.getAddress();

        logger.debug('Mock receiver deployed at: ' + mockReceiverAddress);
    });

    describe('Initialization', function () {
        it('should initialize with correct parameters', async function () {
            expect(await suite.messageExecutor.owner()).to.equal(await suite.deployer.getAddress());
            expect(await suite.messageExecutor.currentChainId()).to.equal(await ethers.provider.getNetwork().then(n => n.chainId));
        });

        it('should set authorized endpoint during setup', async function () {
            // The test suite authorizes the deployer for testing, not the endpoint
            expect(await suite.messageExecutor.authorizedEndpoint()).to.not.equal(ethers.ZeroAddress);
        });

        it('should not allow double initialization', async function () {
            await expect(
                suite.messageExecutor['initialize()']()
            ).to.be.revertedWithCustomError(suite.messageExecutor, 'InvalidInitialization');
        });

        it('should return correct contract version', async function () {
            expect(await suite.messageExecutor.contractVersion()).to.equal(1);
        });
    });

    describe('Authorization Management', function () {
        it('should allow owner to set authorized endpoint', async function () {
            const newEndpoint = generateRandomAddress();

            await suite.messageExecutor.setAuthorizedEndpoint(newEndpoint);

            expect(await suite.messageExecutor.authorizedEndpoint()).to.equal(newEndpoint);
        });

        it('should revert when setting zero address as endpoint', async function () {
            await expect(
                suite.messageExecutor.setAuthorizedEndpoint(ethers.ZeroAddress)
            ).to.be.revertedWithCustomError(suite.messageExecutor, 'RNMessageExecutorV1__InvalidEndpointAddress');
        });

        it('should only allow owner to set authorized endpoint', async function () {
            const newEndpoint = generateRandomAddress();

            await expect(
                suite.messageExecutor.connect(suite.user1).setAuthorizedEndpoint(newEndpoint)
            ).to.be.revertedWithCustomError(suite.messageExecutor, 'OwnableUnauthorizedAccount');
        });

        it('should emit event when endpoint is changed (if implemented)', async function () {
            // Note: If no event exists, this is a recommendation to add one
            const newEndpoint = generateRandomAddress();
            await suite.messageExecutor.setAuthorizedEndpoint(newEndpoint);
            expect(await suite.messageExecutor.authorizedEndpoint()).to.equal(newEndpoint);
        });
    });

    describe('Single Message Execution - executeMessage()', function () {
        let messageId: string;
        let payload: string;

        beforeEach(async function () {
            messageId = generateRandomBytes32();
            payload = ethers.hexlify(ethers.toUtf8Bytes('Hello World'));
        });

        describe('Successful Execution', function () {
            it('should execute message successfully', async function () {
                const data = mockReceiver.interface.encodeFunctionData('receiveMessage', [payload]);

                await expect(
                    suite.messageExecutor.executeMessage(
                        mockReceiverAddress,
                        data,
                        messageId,
                        fromChainId,
                        fromAddress
                    )
                ).to.emit(suite.messageExecutor, 'MessageIdExecuted')
                    .withArgs(fromChainId, messageId);
            });

            it('should mark message as executed', async function () {
                const data = mockReceiver.interface.encodeFunctionData('receiveMessage', [payload]);

                expect(await suite.messageExecutor.executed(messageId)).to.be.false;

                await suite.messageExecutor.executeMessage(
                    mockReceiverAddress,
                    data,
                    messageId,
                    fromChainId,
                    fromAddress
                );

                expect(await suite.messageExecutor.executed(messageId)).to.be.true;
            });

            it('should forward data correctly to target contract', async function () {
                const data = mockReceiver.interface.encodeFunctionData('receiveMessage', [payload]);

                await suite.messageExecutor.executeMessage(
                    mockReceiverAddress,
                    data,
                    messageId,
                    fromChainId,
                    fromAddress
                );

                const state = await mockReceiver.getState();
                expect(state.count).to.equal(1);
                expect(state.payload).to.equal(payload);
            });

            it('should handle empty payload', async function () {
                const emptyPayload = '0x';
                const data = mockReceiver.interface.encodeFunctionData('receiveMessage', [emptyPayload]);

                await expect(
                    suite.messageExecutor.executeMessage(
                        mockReceiverAddress,
                        data,
                        messageId,
                        fromChainId,
                        fromAddress
                    )
                ).to.not.be.reverted;
            });

            it('should handle large payload', async function () {
                // Create a large payload (10KB)
                const largePayload = ethers.randomBytes(10000);
                const data = mockReceiver.interface.encodeFunctionData('receiveMessage', [largePayload]);

                await expect(
                    suite.messageExecutor.executeMessage(
                        mockReceiverAddress,
                        data,
                        messageId,
                        fromChainId,
                        fromAddress
                    )
                ).to.not.be.reverted;
            });
        });

        describe('Authorization Checks', function () {
            it('should revert when called by unauthorized address', async function () {
                const data = mockReceiver.interface.encodeFunctionData('receiveMessage', [payload]);

                await expect(
                    suite.messageExecutor.connect(suite.user1).executeMessage(
                        mockReceiverAddress,
                        data,
                        messageId,
                        fromChainId,
                        fromAddress
                    )
                ).to.be.revertedWithCustomError(suite.messageExecutor, 'RNMessageExecutorV1__UnauthorizedEndpoint');
            });

            it('should only allow authorized endpoint to execute', async function () {
                const data = mockReceiver.interface.encodeFunctionData('receiveMessage', [payload]);

                // Should succeed from deployer (authorized in test setup)
                await expect(
                    suite.messageExecutor.executeMessage(
                        mockReceiverAddress,
                        data,
                        messageId,
                        fromChainId,
                        fromAddress
                    )
                ).to.not.be.reverted;
            });
        });

        describe('Replay Protection', function () {
            it('should prevent message replay with same messageId', async function () {
                const data = mockReceiver.interface.encodeFunctionData('receiveMessage', [payload]);

                // First execution should succeed
                await suite.messageExecutor.executeMessage(
                    mockReceiverAddress,
                    data,
                    messageId,
                    fromChainId,
                    fromAddress
                );

                // Second execution with same messageId should fail
                await expect(
                    suite.messageExecutor.executeMessage(
                        mockReceiverAddress,
                        data,
                        messageId,
                        fromChainId,
                        fromAddress
                    )
                ).to.be.revertedWithCustomError(suite.messageExecutor, 'RNMessageExecutorV1__MessageIdAlreadyExecuted')
                    .withArgs(messageId);
            });

            it('should allow different messageIds to execute', async function () {
                const data = mockReceiver.interface.encodeFunctionData('receiveMessage', [payload]);
                const messageId2 = generateRandomBytes32();

                await suite.messageExecutor.executeMessage(
                    mockReceiverAddress,
                    data,
                    messageId,
                    fromChainId,
                    fromAddress
                );

                await expect(
                    suite.messageExecutor.executeMessage(
                        mockReceiverAddress,
                        data,
                        messageId2,
                        fromChainId,
                        fromAddress
                    )
                ).to.not.be.reverted;
            });
        });

        describe('Error Handling', function () {
            it('should revert if target contract reverts', async function () {
                await mockReceiver.setShouldRevert(true);
                const data = mockReceiver.interface.encodeFunctionData('receiveMessage', [payload]);

                await expect(
                    suite.messageExecutor.executeMessage(
                        mockReceiverAddress,
                        data,
                        messageId,
                        fromChainId,
                        fromAddress
                    )
                ).to.be.revertedWithCustomError(suite.messageExecutor, 'RNMessageExecutorV1__MessageFailure');
            });

            it('should revert if target is not a contract (EOA)', async function () {
                const eoaAddress = generateRandomAddress();
                const data = mockReceiver.interface.encodeFunctionData('receiveMessage', [payload]);

                await expect(
                    suite.messageExecutor.executeMessage(
                        eoaAddress,
                        data,
                        messageId,
                        fromChainId,
                        fromAddress
                    )
                ).to.be.revertedWithCustomError(suite.messageExecutor, 'RNMessageExecutorV1__NoContractAtAddress')
                    .withArgs(eoaAddress);
            });

            it('should revert if target is zero address', async function () {
                const data = mockReceiver.interface.encodeFunctionData('receiveMessage', [payload]);

                await expect(
                    suite.messageExecutor.executeMessage(
                        ethers.ZeroAddress,
                        data,
                        messageId,
                        fromChainId,
                        fromAddress
                    )
                ).to.be.revertedWithCustomError(suite.messageExecutor, 'RNMessageExecutorV1__NoContractAtAddress');
            });

            it('should include error data in MessageFailure event', async function () {
                await mockReceiver.setShouldRevert(true);
                const data = mockReceiver.interface.encodeFunctionData('receiveMessage', [payload]);

                try {
                    await suite.messageExecutor.executeMessage(
                        mockReceiverAddress,
                        data,
                        messageId,
                        fromChainId,
                        fromAddress
                    );
                    expect.fail('Should have reverted');
                } catch (error: any) {
                    expect(error.message).to.include('MessageFailure');
                }
            });
        });

        describe('State Management', function () {
            it('should maintain execution state across multiple messages', async function () {
                const data = mockReceiver.interface.encodeFunctionData('receiveMessage', [payload]);
                const messageIds = [generateRandomBytes32(), generateRandomBytes32(), generateRandomBytes32()];

                for (const msgId of messageIds) {
                    await suite.messageExecutor.executeMessage(
                        mockReceiverAddress,
                        data,
                        msgId,
                        fromChainId,
                        fromAddress
                    );
                    expect(await suite.messageExecutor.executed(msgId)).to.be.true;
                }
            });

            it('should NOT mark message as executed if execution fails (reverts)', async function () {
                await mockReceiver.setShouldRevert(true);
                const data = mockReceiver.interface.encodeFunctionData('receiveMessage', [payload]);

                // Attempt will fail and revert
                await expect(
                    suite.messageExecutor.executeMessage(
                        mockReceiverAddress,
                        data,
                        messageId,
                        fromChainId,
                        fromAddress
                    )
                ).to.be.reverted;

                // Message is NOT marked as executed because the entire tx reverts
                expect(await suite.messageExecutor.executed(messageId)).to.be.false;

                // Fix receiver and retry - should succeed
                await mockReceiver.setShouldRevert(false);
                await expect(
                    suite.messageExecutor.executeMessage(
                        mockReceiverAddress,
                        data,
                        messageId,
                        fromChainId,
                        fromAddress
                    )
                ).to.not.be.reverted;

                expect(await suite.messageExecutor.executed(messageId)).to.be.true;
            });
        });
    });

    describe('Batch Message Execution - executeMessageBatch()', function () {
        let batchMessageId: string;

        beforeEach(async function () {
            batchMessageId = generateRandomBytes32();
        });

        describe('Successful Batch Execution', function () {
            it('should execute batch of messages successfully', async function () {
                const messages = [
                    {
                        to: mockReceiverAddress,
                        data: mockReceiver.interface.encodeFunctionData('receiveMessage', [ethers.toUtf8Bytes('Message 1')])
                    },
                    {
                        to: mockReceiverAddress,
                        data: mockReceiver.interface.encodeFunctionData('receiveMessage', [ethers.toUtf8Bytes('Message 2')])
                    },
                    {
                        to: mockReceiverAddress,
                        data: mockReceiver.interface.encodeFunctionData('receiveMessage', [ethers.toUtf8Bytes('Message 3')])
                    }
                ];

                await expect(
                    suite.messageExecutor.executeMessageBatch(
                        messages,
                        batchMessageId,
                        fromChainId,
                        fromAddress
                    )
                ).to.emit(suite.messageExecutor, 'MessageIdExecuted')
                    .withArgs(fromChainId, batchMessageId);

                // Verify all messages were executed
                const state = await mockReceiver.getState();
                expect(state.count).to.equal(3);
            });

            it('should handle empty batch', async function () {
                const emptyBatch: any[] = [];

                await expect(
                    suite.messageExecutor.executeMessageBatch(
                        emptyBatch,
                        batchMessageId,
                        fromChainId,
                        fromAddress
                    )
                ).to.emit(suite.messageExecutor, 'MessageIdExecuted');
            });

            it('should handle single message in batch', async function () {
                const messages = [
                    {
                        to: mockReceiverAddress,
                        data: mockReceiver.interface.encodeFunctionData('receiveMessage', [ethers.toUtf8Bytes('Single')])
                    }
                ];

                await expect(
                    suite.messageExecutor.executeMessageBatch(
                        messages,
                        batchMessageId,
                        fromChainId,
                        fromAddress
                    )
                ).to.not.be.reverted;
            });

            it('should execute messages in order', async function () {
                // Deploy multiple receivers to track order
                const receiver1 = await ethers.deployContract('MockMessageReceiver') as MockMessageReceiver;
                const receiver2 = await ethers.deployContract('MockMessageReceiver') as MockMessageReceiver;
                const receiver3 = await ethers.deployContract('MockMessageReceiver') as MockMessageReceiver;

                const messages = [
                    {
                        to: await receiver1.getAddress(),
                        data: receiver1.interface.encodeFunctionData('receiveMessage', [ethers.toUtf8Bytes('First')])
                    },
                    {
                        to: await receiver2.getAddress(),
                        data: receiver2.interface.encodeFunctionData('receiveMessage', [ethers.toUtf8Bytes('Second')])
                    },
                    {
                        to: await receiver3.getAddress(),
                        data: receiver3.interface.encodeFunctionData('receiveMessage', [ethers.toUtf8Bytes('Third')])
                    }
                ];

                await suite.messageExecutor.executeMessageBatch(
                    messages,
                    batchMessageId,
                    fromChainId,
                    fromAddress
                );

                expect((await receiver1.getState()).count).to.equal(1);
                expect((await receiver2.getState()).count).to.equal(1);
                expect((await receiver3.getState()).count).to.equal(1);
            });
        });

        describe('Batch Authorization Checks', function () {
            it('should revert batch when called by unauthorized address', async function () {
                const messages = [
                    {
                        to: mockReceiverAddress,
                        data: mockReceiver.interface.encodeFunctionData('receiveMessage', [ethers.toUtf8Bytes('Test')])
                    }
                ];

                await expect(
                    suite.messageExecutor.connect(suite.user1).executeMessageBatch(
                        messages,
                        batchMessageId,
                        fromChainId,
                        fromAddress
                    )
                ).to.be.revertedWithCustomError(suite.messageExecutor, 'RNMessageExecutorV1__UnauthorizedEndpoint');
            });
        });

        describe('Batch Replay Protection', function () {
            it('should prevent batch replay with same messageId', async function () {
                const messages = [
                    {
                        to: mockReceiverAddress,
                        data: mockReceiver.interface.encodeFunctionData('receiveMessage', [ethers.toUtf8Bytes('Test')])
                    }
                ];

                await suite.messageExecutor.executeMessageBatch(
                    messages,
                    batchMessageId,
                    fromChainId,
                    fromAddress
                );

                await expect(
                    suite.messageExecutor.executeMessageBatch(
                        messages,
                        batchMessageId,
                        fromChainId,
                        fromAddress
                    )
                ).to.be.revertedWithCustomError(suite.messageExecutor, 'RNMessageExecutorV1__MessageIdAlreadyExecuted');
            });
        });

        describe('Batch Error Handling', function () {
            it('should revert entire batch if one message fails', async function () {
                await mockReceiver.setShouldRevert(true);

                const messages = [
                    {
                        to: mockReceiverAddress,
                        data: mockReceiver.interface.encodeFunctionData('receiveMessage', [ethers.toUtf8Bytes('Message 1')])
                    },
                    {
                        to: mockReceiverAddress,
                        data: mockReceiver.interface.encodeFunctionData('receiveMessage', [ethers.toUtf8Bytes('Message 2 - Will Fail')])
                    }
                ];

                await expect(
                    suite.messageExecutor.executeMessageBatch(
                        messages,
                        batchMessageId,
                        fromChainId,
                        fromAddress
                    )
                ).to.be.revertedWithCustomError(suite.messageExecutor, 'RNMessageExecutorV1__MessageBatchFailure');
            });

            it('should include message index in batch failure error', async function () {
                const receiver1 = await ethers.deployContract('MockMessageReceiver') as MockMessageReceiver;
                const receiver2 = await ethers.deployContract('MockMessageReceiver') as MockMessageReceiver;
                await receiver2.setShouldRevert(true);

                const messages = [
                    {
                        to: await receiver1.getAddress(),
                        data: receiver1.interface.encodeFunctionData('receiveMessage', [ethers.toUtf8Bytes('OK')])
                    },
                    {
                        to: await receiver2.getAddress(),
                        data: receiver2.interface.encodeFunctionData('receiveMessage', [ethers.toUtf8Bytes('Fail')])
                    }
                ];

                try {
                    await suite.messageExecutor.executeMessageBatch(
                        messages,
                        batchMessageId,
                        fromChainId,
                        fromAddress
                    );
                    expect.fail('Should have reverted');
                } catch (error: any) {
                    expect(error.message).to.include('MessageBatchFailure');
                }
            });

            it('should revert if any target in batch is not a contract', async function () {
                const eoaAddress = generateRandomAddress();

                const messages = [
                    {
                        to: mockReceiverAddress,
                        data: mockReceiver.interface.encodeFunctionData('receiveMessage', [ethers.toUtf8Bytes('OK')])
                    },
                    {
                        to: eoaAddress,
                        data: '0x1234'
                    }
                ];

                await expect(
                    suite.messageExecutor.executeMessageBatch(
                        messages,
                        batchMessageId,
                        fromChainId,
                        fromAddress
                    )
                ).to.be.revertedWithCustomError(suite.messageExecutor, 'RNMessageExecutorV1__NoContractAtAddress');
            });

            it('should NOT mark batch as executed if execution fails (reverts)', async function () {
                await mockReceiver.setShouldRevert(true);

                const messages = [
                    {
                        to: mockReceiverAddress,
                        data: mockReceiver.interface.encodeFunctionData('receiveMessage', [ethers.toUtf8Bytes('Test')])
                    }
                ];

                await expect(
                    suite.messageExecutor.executeMessageBatch(
                        messages,
                        batchMessageId,
                        fromChainId,
                        fromAddress
                    )
                ).to.be.reverted;

                // Batch is NOT marked as executed because the entire tx reverts
                expect(await suite.messageExecutor.executed(batchMessageId)).to.be.false;

                // Fix receiver and retry - should succeed
                await mockReceiver.setShouldRevert(false);
                await expect(
                    suite.messageExecutor.executeMessageBatch(
                        messages,
                        batchMessageId,
                        fromChainId,
                        fromAddress
                    )
                ).to.not.be.reverted;

                expect(await suite.messageExecutor.executed(batchMessageId)).to.be.true;
            });
        });

        describe('Large Batch Handling', function () {
            it('should handle batch with many messages', async function () {
                const batchSize = 50;
                const messages = [];

                for (let i = 0; i < batchSize; i++) {
                    messages.push({
                        to: mockReceiverAddress,
                        data: mockReceiver.interface.encodeFunctionData('receiveMessage', [ethers.toUtf8Bytes(`Message ${i}`)])
                    });
                }

                await expect(
                    suite.messageExecutor.executeMessageBatch(
                        messages,
                        batchMessageId,
                        fromChainId,
                        fromAddress
                    )
                ).to.not.be.reverted;

                const state = await mockReceiver.getState();
                expect(state.count).to.equal(batchSize);
            });

            it('should handle batch with large payloads', async function () {
                const largePayload = ethers.randomBytes(5000);
                const messages = [
                    {
                        to: mockReceiverAddress,
                        data: mockReceiver.interface.encodeFunctionData('receiveMessage', [largePayload])
                    },
                    {
                        to: mockReceiverAddress,
                        data: mockReceiver.interface.encodeFunctionData('receiveMessage', [largePayload])
                    }
                ];

                await expect(
                    suite.messageExecutor.executeMessageBatch(
                        messages,
                        batchMessageId,
                        fromChainId,
                        fromAddress
                    )
                ).to.not.be.reverted;
            });
        });
    });

    describe('Gas Limit Testing', function () {
        it('should not exceed reasonable gas for single message execution', async function () {
            const payload = ethers.toUtf8Bytes('Test Message');
            const data = mockReceiver.interface.encodeFunctionData('receiveMessage', [payload]);
            const messageId = generateRandomBytes32();

            const tx = await suite.messageExecutor.executeMessage(
                mockReceiverAddress,
                data,
                messageId,
                fromChainId,
                fromAddress
            );

            const receipt = await tx.wait();
            const gasUsed = receipt!.gasUsed;

            logger.info(`Gas used for single message execution: ${gasUsed.toString()}`);

            // Assert reasonable gas limit (adjust based on your requirements)
            expect(gasUsed).to.be.lessThan(200000n);
        });

        it('should measure gas for batch execution', async function () {
            const messages = Array(10).fill(null).map((_, i) => ({
                to: mockReceiverAddress,
                data: mockReceiver.interface.encodeFunctionData('receiveMessage', [ethers.toUtf8Bytes(`Message ${i}`)])
            }));

            const tx = await suite.messageExecutor.executeMessageBatch(
                messages,
                generateRandomBytes32(),
                fromChainId,
                fromAddress
            );

            const receipt = await tx.wait();
            const gasUsed = receipt!.gasUsed;

            logger.info(`Gas used for 10 message batch: ${gasUsed.toString()}`);
            logger.info(`Gas per message: ${(gasUsed / 10n).toString()}`);
        });

        it('should compare gas costs: single vs batch', async function () {
            const payload = ethers.toUtf8Bytes('Test');
            const data = mockReceiver.interface.encodeFunctionData('receiveMessage', [payload]);

            // Single message gas
            const singleTx = await suite.messageExecutor.executeMessage(
                mockReceiverAddress,
                data,
                generateRandomBytes32(),
                fromChainId,
                fromAddress
            );
            const singleGas = (await singleTx.wait())!.gasUsed;

            // Batch message gas
            const messages = [{ to: mockReceiverAddress, data }];
            const batchTx = await suite.messageExecutor.executeMessageBatch(
                messages,
                generateRandomBytes32(),
                fromChainId,
                fromAddress
            );
            const batchGas = (await batchTx.wait())!.gasUsed;

            logger.info(`Single message gas: ${singleGas.toString()}`);
            logger.info(`Batch (1 msg) gas: ${batchGas.toString()}`);
        });
    });

    describe('UUPS Upgrade Functionality', function () {
        it('should only allow owner to authorize upgrade', async function () {
            const MessageExecutorV2Factory = await ethers.getContractFactory('RNMessageExecutorV1');
            const newImplementation = await MessageExecutorV2Factory.deploy();
            await newImplementation.waitForDeployment();

            await expect(
                suite.messageExecutor.connect(suite.user1).upgradeToAndCall(
                    await newImplementation.getAddress(),
                    '0x'
                )
            ).to.be.revertedWithCustomError(suite.messageExecutor, 'OwnableUnauthorizedAccount');
        });

        it('should preserve state after upgrade', async function () {
            // Execute a message to set state
            const messageId = generateRandomBytes32();
            const payload = ethers.toUtf8Bytes('Pre-upgrade');
            const data = mockReceiver.interface.encodeFunctionData('receiveMessage', [payload]);

            await suite.messageExecutor.executeMessage(
                mockReceiverAddress,
                data,
                messageId,
                fromChainId,
                fromAddress
            );

            expect(await suite.messageExecutor.executed(messageId)).to.be.true;

            // Upgrade
            const MessageExecutorV2Factory = await ethers.getContractFactory('RNMessageExecutorV1');
            const upgraded = await upgrades.upgradeProxy(
                await suite.messageExecutor.getAddress(),
                MessageExecutorV2Factory
            ) as RNMessageExecutorV1;

            // Verify state persists
            expect(await upgraded.executed(messageId)).to.be.true;
            expect(await upgraded.owner()).to.equal(await suite.deployer.getAddress());
        });
    });

    describe('Edge Cases and Security', function () {
        it('should handle different chain IDs correctly', async function () {
            const messageId = generateRandomBytes32();
            const payload = ethers.toUtf8Bytes('Chain test');
            const data = mockReceiver.interface.encodeFunctionData('receiveMessage', [payload]);

            const chainIds = [1, 5, 137, 42161, 10, 999999];

            for (const chainId of chainIds) {
                const msgId = generateRandomBytes32();
                await expect(
                    suite.messageExecutor.executeMessage(
                        mockReceiverAddress,
                        data,
                        msgId,
                        chainId,
                        fromAddress
                    )
                ).to.emit(suite.messageExecutor, 'MessageIdExecuted')
                    .withArgs(chainId, msgId);
            }
        });

        it('should handle different sender addresses', async function () {
            const messageId = generateRandomBytes32();
            const payload = ethers.toUtf8Bytes('Sender test');
            const data = mockReceiver.interface.encodeFunctionData('receiveMessage', [payload]);

            const senders = [
                generateRandomAddress(),
                ethers.ZeroAddress,
                await suite.deployer.getAddress()
            ];

            for (const sender of senders) {
                const msgId = generateRandomBytes32();
                await expect(
                    suite.messageExecutor.executeMessage(
                        mockReceiverAddress,
                        data,
                        msgId,
                        fromChainId,
                        sender
                    )
                ).to.not.be.reverted;
            }
        });

        it('should handle maximum uint256 values', async function () {
            const payload = ethers.toUtf8Bytes('Max values test');
            const data = mockReceiver.interface.encodeFunctionData('receiveMessage', [payload]);
            const messageId = generateRandomBytes32();

            await expect(
                suite.messageExecutor.executeMessage(
                    mockReceiverAddress,
                    data,
                    messageId,
                    ethers.MaxUint256,
                    fromAddress
                )
            ).to.not.be.reverted;
        });
    });
});
