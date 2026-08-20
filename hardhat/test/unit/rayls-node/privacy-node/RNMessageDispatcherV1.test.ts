/**
 * @deprecated Decommissioning Teleport (vanilla, atomic).
 */
import { expect } from 'chai';
import { ethers } from 'hardhat';
import {
    deployRaylsNodeSuite,
    createMockRaylsNodeMessage,
    generateRandomAddress,
    generateRandomBytes32,
    RaylsNodeTestSuite
} from '../utils/raylsNodeTestUtils';
import { Logger, LogLevel } from '../../utils/moca-logger';

const logger = new Logger();
const logLevel = Number(process.env['TEST_LOGGING_LEVEL'] || LogLevel.INFO);
logger.setLogLevel(logLevel);

describe('RNMessageDispatcherV1 Unit Tests', function () {
    let suite: RaylsNodeTestSuite;

    const fromChainId = 12345;
    const toChainId = 67890;

    beforeEach(async function () {
        logger.debug('Setting up RNMessageDispatcherV1 test suite...');
        suite = await deployRaylsNodeSuite();

        // Set the endpoint as authorized dispatcher
        await suite.messageDispatcher.setAuthorizedEndpoint(await suite.endpoint.getAddress());
    });

    describe('Initialization', function () {
        it('should initialize with correct owner', async function () {
            expect(await suite.messageDispatcher.owner()).to.equal(suite.deployer.address);
        });

        it('should have no authorized endpoint initially', async function () {
            const DispatcherFactory = await ethers.getContractFactory('RNMessageDispatcherV1');
            const newDispatcher = await upgrades.deployProxy(DispatcherFactory, [], {
                kind: 'uups',
                initializer: 'initialize()'
            });
            await newDispatcher.waitForDeployment();

            expect(await newDispatcher.authorizedEndpoint()).to.equal(ethers.ZeroAddress);
        });

        it('should not allow double initialization', async function () {
            await expect(
                suite.messageDispatcher.initialize()
            ).to.be.revertedWithCustomError(suite.messageDispatcher, 'InvalidInitialization');
        });
    });

    describe('Authorized Endpoint Management', function () {
        it('should set authorized endpoint successfully', async function () {
            const newEndpoint = generateRandomAddress();

            await suite.messageDispatcher.setAuthorizedEndpoint(newEndpoint);

            expect(await suite.messageDispatcher.authorizedEndpoint()).to.equal(newEndpoint);
        });

        it('should revert when setting zero address as endpoint', async function () {
            await expect(
                suite.messageDispatcher.setAuthorizedEndpoint(ethers.ZeroAddress)
            ).to.be.revertedWithCustomError(suite.messageDispatcher, 'RNMessageDispatcherV1__InvalidEndpointAddress');
        });

        it('should only allow authorized caller to set authorized endpoint', async function () {
            const newEndpoint = generateRandomAddress();

            await expect(
                suite.messageDispatcher.connect(suite.user1).setAuthorizedEndpoint(newEndpoint)
            ).to.be.revertedWithCustomError(suite.messageDispatcher, 'RaylsAccessManaged__Unauthorized');
        });

        it('should allow updating authorized endpoint', async function () {
            const firstEndpoint = generateRandomAddress();
            const secondEndpoint = generateRandomAddress();

            await suite.messageDispatcher.setAuthorizedEndpoint(firstEndpoint);
            expect(await suite.messageDispatcher.authorizedEndpoint()).to.equal(firstEndpoint);

            await suite.messageDispatcher.setAuthorizedEndpoint(secondEndpoint);
            expect(await suite.messageDispatcher.authorizedEndpoint()).to.equal(secondEndpoint);
        });
    });

    describe('View Functions', function () {
        it('should return correct version', async function () {
            expect(await suite.messageDispatcher.version()).to.equal('1.0');
        });

        it('should return correct contract version', async function () {
            expect(await suite.messageDispatcher.contractVersion()).to.equal(1);
        });
    });

    describe('Access Control Edge Cases', function () {
        it('should prevent non-admin from upgrading', async function () {
            const newImplementation = generateRandomAddress();

            await expect(
                suite.messageDispatcher.connect(suite.user1).upgradeToAndCall(newImplementation, '0x')
            ).to.be.revertedWithCustomError(suite.messageDispatcher, 'RaylsAccessManaged__Unauthorized');
        });
    });

});