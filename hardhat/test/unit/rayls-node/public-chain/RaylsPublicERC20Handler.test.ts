/**
 * @deprecated Decommissioning Teleport (vanilla, atomic).
 */
import { expect } from 'chai';
import { ethers } from 'hardhat';
import { Signer } from 'ethers';
import {
    deployPublicRaylsNodeSuite,
    generateRandomAddress,
    PublicRaylsNodeTestSuite
} from '../utils/publicChainTestUtils';
import { PublicChainERC20 } from '../../../../../typechain-types';
import { Logger, LogLevel } from '../../utils/moca-logger';

const logger = new Logger();
const logLevel = Number(process.env['TEST_LOGGING_LEVEL'] || LogLevel.INFO);
logger.setLogLevel(logLevel);

describe('RaylsPublicERC20Handler Unit Tests', function () {
    let suite: PublicRaylsNodeTestSuite;
    let token: PublicChainERC20;
    let owner: Signer;
    let user1: Signer;
    let user2: Signer;
    let privateChainAddress: string;
    let privateChainId: number;

    const TOKEN_NAME = 'Test USDC';
    const TOKEN_SYMBOL = 'USDC';
    const INITIAL_SUPPLY = ethers.parseEther('1000000');

    beforeEach(async function () {
        logger.debug('Setting up RaylsPublicERC20Handler test suite...');
        suite = await deployPublicRaylsNodeSuite();
        [owner, user1, user2] = await ethers.getSigners();

        privateChainAddress = generateRandomAddress();
        privateChainId = 12345;

        // Deploy test ERC20 token
        const TokenFactory = await ethers.getContractFactory('PublicChainERC20');
        token = await TokenFactory.connect(owner).deploy(
            TOKEN_NAME,
            TOKEN_SYMBOL,
            await suite.publicEndpoint.getAddress(),
            0, // initialSupply
            privateChainAddress
        ) as PublicChainERC20;
        await token.waitForDeployment();

        // Authorize token as sender on the endpoint
        await suite.publicEndpoint.addAuthorizedSender(await token.getAddress());

        logger.debug('Test token deployed at:', await token.getAddress());
    });

    describe('Initialization', function () {
        it('should deploy with correct parameters', async function () {
            expect(await token.name()).to.equal(TOKEN_NAME);
            expect(await token.symbol()).to.equal(TOKEN_SYMBOL);
            expect(await token.decimals()).to.equal(18);
            expect(await token.privateChainAddress()).to.equal(privateChainAddress);
            expect(await token.owner()).to.equal(await owner.getAddress());
        });

        it('should have zero initial supply', async function () {
            expect(await token.totalSupply()).to.equal(0);
        });

        it('should set correct endpoint', async function () {
            expect(await token.getPublicRaylsNodeEndpoint()).to.equal(await suite.publicEndpoint.getAddress());
        });
    });

    describe('Minting and Burning', function () {
        it('should allow owner to mint tokens', async function () {
            const mintAmount = ethers.parseEther('1000');
            const recipient = await user1.getAddress();

            await token.connect(owner).mint(recipient, mintAmount);

            expect(await token.balanceOf(recipient)).to.equal(mintAmount);
            expect(await token.totalSupply()).to.equal(mintAmount);
        });

        it('should only allow owner to mint', async function () {
            const mintAmount = ethers.parseEther('1000');

            await expect(
                token.connect(user1).mint(await user1.getAddress(), mintAmount)
            ).to.be.revertedWithCustomError(token, 'OwnableUnauthorizedAccount');
        });

        it('should allow owner to burn tokens', async function () {
            const mintAmount = ethers.parseEther('1000');
            const burnAmount = ethers.parseEther('300');
            const recipient = await user1.getAddress();

            await token.connect(owner).mint(recipient, mintAmount);
            await token.connect(owner).burn(recipient, burnAmount);

            expect(await token.balanceOf(recipient)).to.equal(mintAmount - burnAmount);
            expect(await token.totalSupply()).to.equal(mintAmount - burnAmount);
        });

        it('should only allow owner to burn', async function () {
            const mintAmount = ethers.parseEther('1000');
            const recipient = await user1.getAddress();

            await token.connect(owner).mint(recipient, mintAmount);

            await expect(
                token.connect(user1).burn(recipient, mintAmount)
            ).to.be.revertedWithCustomError(token, 'OwnableUnauthorizedAccount');
        });
    });

    describe('Lock and Unlock Mechanism', function () {
        const lockAmount = ethers.parseEther('500');

        beforeEach(async function () {
            // Mint tokens to user1
            await token.connect(owner).mint(await user1.getAddress(), ethers.parseEther('1000'));
        });

        it('should lock tokens successfully', async function () {
            const user1Address = await user1.getAddress();
            const initialBalance = await token.balanceOf(user1Address);

            await token.connect(user1).crossChainLock(
                generateRandomAddress(),
                lockAmount,
                privateChainId
            );

            const finalBalance = await token.balanceOf(user1Address);
            const contractBalance = await token.balanceOf(await token.getAddress());
            const lockedAmount = await token.getLockedAmount(user1Address);

            expect(finalBalance).to.equal(initialBalance - lockAmount);
            expect(contractBalance).to.equal(lockAmount);
            expect(lockedAmount).to.equal(lockAmount);
        });

        it('should revert lock with zero amount', async function () {
            await expect(
                token.connect(user1).crossChainLock(
                    generateRandomAddress(),
                    0,
                    privateChainId
                )
            ).to.be.revertedWithCustomError(token, 'RaylsPublicERC20Handler__AmountMustBeGreaterThanZero');
        });

        it('should revert lock with insufficient balance', async function () {
            const user1Balance = await token.balanceOf(await user1.getAddress());
            const excessAmount = user1Balance + ethers.parseEther('1');

            await expect(
                token.connect(user1).crossChainLock(
                    generateRandomAddress(),
                    excessAmount,
                    privateChainId
                )
            ).to.be.revertedWithCustomError(token, 'RaylsPublicERC20Handler__InsufficientBalanceToLock');
        });

        it('should track locked amount correctly across multiple locks', async function () {
            const user1Address = await user1.getAddress();
            const lock1 = ethers.parseEther('100');
            const lock2 = ethers.parseEther('200');

            await token.connect(user1).crossChainLock(generateRandomAddress(), lock1, privateChainId);
            await token.connect(user1).crossChainLock(generateRandomAddress(), lock2, privateChainId);

            expect(await token.getLockedAmount(user1Address)).to.equal(lock1 + lock2);
        });

        it('should unlock tokens successfully by message executor', async function () {
            const user1Address = await user1.getAddress();

            // Lock tokens first
            await token.connect(user1).crossChainLock(
                generateRandomAddress(),
                lockAmount,
                privateChainId
            );

            // Impersonate message executor
            const executorAddress = await suite.messageExecutor.getAddress();
            await ethers.provider.send('hardhat_impersonateAccount', [executorAddress]);
            await ethers.provider.send('hardhat_setBalance', [executorAddress, '0x1000000000000000000']);
            const executorSigner = await ethers.getSigner(executorAddress);

            const balanceBeforeUnlock = await token.balanceOf(user1Address);

            await token.connect(executorSigner).crossChainUnlock(user1Address, lockAmount);

            const balanceAfterUnlock = await token.balanceOf(user1Address);
            const lockedAmount = await token.getLockedAmount(user1Address);

            expect(balanceAfterUnlock).to.equal(balanceBeforeUnlock + lockAmount);
            expect(lockedAmount).to.equal(0);

            await ethers.provider.send('hardhat_stopImpersonatingAccount', [executorAddress]);
        });

        it('should revert unlock when called by non-executor', async function () {
            const user1Address = await user1.getAddress();

            await token.connect(user1).crossChainLock(
                generateRandomAddress(),
                lockAmount,
                privateChainId
            );

            await expect(
                token.connect(user1).crossChainUnlock(user1Address, lockAmount)
            ).to.be.revertedWith('This is a receive method. Only endpoint\'s executor can call this method.');
        });

        it('should revert unlock with insufficient locked amount', async function () {
            const user1Address = await user1.getAddress();
            const smallLock = ethers.parseEther('100');
            const largeLock = ethers.parseEther('500');

            await token.connect(user1).crossChainLock(generateRandomAddress(), smallLock, privateChainId);

            // Impersonate executor
            const executorAddress = await suite.messageExecutor.getAddress();
            await ethers.provider.send('hardhat_impersonateAccount', [executorAddress]);
            await ethers.provider.send('hardhat_setBalance', [executorAddress, '0x1000000000000000000']);
            const executorSigner = await ethers.getSigner(executorAddress);


            await expect(
                token.connect(executorSigner).crossChainUnlock(user1Address, largeLock)
            ).to.be.revertedWithCustomError(token, 'RaylsPublicERC20Handler__InsufficientLockedFunds');

            await ethers.provider.send('hardhat_stopImpersonatingAccount', [executorAddress]);
        });

        it('should revert unlock with insufficient locked amount for zero address', async function () {
            const user1Address = await user1.getAddress();

            await token.connect(user1).crossChainLock(generateRandomAddress(), lockAmount, privateChainId);

            // Impersonate executor
            const executorAddress = await suite.messageExecutor.getAddress();
            await ethers.provider.send('hardhat_impersonateAccount', [executorAddress]);
            await ethers.provider.send('hardhat_setBalance', [executorAddress, '0x1000000000000000000']);
            const executorSigner = await ethers.getSigner(executorAddress);


            await expect(
                token.connect(executorSigner).crossChainUnlock(ethers.ZeroAddress, lockAmount)
            ).to.be.revertedWithCustomError(token, 'RaylsPublicERC20Handler__InsufficientLockedFunds');

            await ethers.provider.send('hardhat_stopImpersonatingAccount', [executorAddress]);
        });

        it('should emit TokensLocked when locking tokens', async function () {
            const user1Address = await user1.getAddress();

            await expect(
                token.connect(user1).crossChainLock(generateRandomAddress(), lockAmount, privateChainId)
            ).to.emit(token, 'TokensLocked')
             .withArgs(user1Address, lockAmount);
        });

        it('should emit TokensUnlocked when unlocking tokens', async function () {
            const user1Address = await user1.getAddress();

            await token.connect(user1).crossChainLock(generateRandomAddress(), lockAmount, privateChainId);

            const executorAddress = await suite.messageExecutor.getAddress();
            await ethers.provider.send('hardhat_impersonateAccount', [executorAddress]);
            await ethers.provider.send('hardhat_setBalance', [executorAddress, '0x1000000000000000000']);
            const executorSigner = await ethers.getSigner(executorAddress);

            await expect(
                token.connect(executorSigner).crossChainUnlock(user1Address, lockAmount)
            ).to.emit(token, 'TokensUnlocked')
             .withArgs(user1Address, lockAmount);

            await ethers.provider.send('hardhat_stopImpersonatingAccount', [executorAddress]);
        });
    });

    describe('Cross-Chain Minting', function () {
        it('should mint tokens via crossChainMint by executor', async function () {
            const recipient = await user1.getAddress();
            const mintAmount = ethers.parseEther('500');

            // Impersonate executor
            const executorAddress = await suite.messageExecutor.getAddress();
            await ethers.provider.send('hardhat_impersonateAccount', [executorAddress]);
            await ethers.provider.send('hardhat_setBalance', [executorAddress, '0x1000000000000000000']);
            const executorSigner = await ethers.getSigner(executorAddress);


            await token.connect(executorSigner).crossChainMint(recipient, mintAmount);

            expect(await token.balanceOf(recipient)).to.equal(mintAmount);

            await ethers.provider.send('hardhat_stopImpersonatingAccount', [executorAddress]);
        });

        it('should revert crossChainMint when called by non-executor', async function () {
            const recipient = await user1.getAddress();
            const mintAmount = ethers.parseEther('500');

            await expect(
                token.connect(user1).crossChainMint(recipient, mintAmount)
            ).to.be.revertedWith('This is a receive method. Only endpoint\'s executor can call this method.');
        });

        it('should revert crossChainMint to zero address', async function () {
            const mintAmount = ethers.parseEther('500');

            // Impersonate executor
            const executorAddress = await suite.messageExecutor.getAddress();
            await ethers.provider.send('hardhat_impersonateAccount', [executorAddress]);
            await ethers.provider.send('hardhat_setBalance', [executorAddress, '0x1000000000000000000']);
            const executorSigner = await ethers.getSigner(executorAddress);


            await expect(
                token.connect(executorSigner).crossChainMint(ethers.ZeroAddress, mintAmount)
            ).to.be.revertedWithCustomError(token, 'RaylsPublicERC20Handler__DestinationIsZeroAddress');

            await ethers.provider.send('hardhat_stopImpersonatingAccount', [executorAddress]);
        });
    });

    describe('Revert Cross-Chain Lock', function () {
        const lockAmount = ethers.parseEther('500');

        beforeEach(async function () {
            await token.connect(owner).mint(await user1.getAddress(), ethers.parseEther('1000'));
        });

        it('should revert lock and unlock tokens', async function () {
            const user1Address = await user1.getAddress();

            // Lock tokens
            await token.connect(user1).crossChainLock(
                generateRandomAddress(),
                lockAmount,
                privateChainId
            );

            const balanceAfterLock = await token.balanceOf(user1Address);
            const lockedAfterLock = await token.getLockedAmount(user1Address);

            expect(lockedAfterLock).to.equal(lockAmount);

            // Revert the lock
            await token.revertCrossChainLock(user1Address, lockAmount);

            const balanceAfterRevert = await token.balanceOf(user1Address);
            const lockedAfterRevert = await token.getLockedAmount(user1Address);

            expect(balanceAfterRevert).to.equal(balanceAfterLock + lockAmount);
            expect(lockedAfterRevert).to.equal(0);
        });

        it('should revert when trying to revert more than locked', async function () {
            const user1Address = await user1.getAddress();
            const smallLock = ethers.parseEther('100');
            const largeLock = ethers.parseEther('500');

            await token.connect(user1).crossChainLock(generateRandomAddress(), smallLock, privateChainId);

            await expect(
                token.revertCrossChainLock(user1Address, largeLock)
            ).to.be.revertedWithCustomError(token, 'RaylsPublicERC20Handler__InsufficientLockedFunds');
        });
    });

    describe('View Functions', function () {
        it('should return correct token metadata', async function () {
            expect(await token.name()).to.equal(TOKEN_NAME);
            expect(await token.symbol()).to.equal(TOKEN_SYMBOL);
            expect(await token.decimals()).to.equal(18);
        });

        it('should return correct private chain address', async function () {
            expect(await token.privateChainAddress()).to.equal(privateChainAddress);
        });

        it('should return zero locked amount for new address', async function () {
            const newAddress = generateRandomAddress();
            expect(await token.getLockedAmount(newAddress)).to.equal(0);
        });

        it('should return correct locked amount after multiple operations', async function () {
            const user1Address = await user1.getAddress();
            await token.connect(owner).mint(user1Address, ethers.parseEther('1000'));

            const lock1 = ethers.parseEther('100');
            const lock2 = ethers.parseEther('200');

            await token.connect(user1).crossChainLock(generateRandomAddress(), lock1, privateChainId);
            expect(await token.getLockedAmount(user1Address)).to.equal(lock1);

            await token.connect(user1).crossChainLock(generateRandomAddress(), lock2, privateChainId);
            expect(await token.getLockedAmount(user1Address)).to.equal(lock1 + lock2);
        });
    });

    describe('Standard ERC20 Operations', function () {
        beforeEach(async function () {
            await token.connect(owner).mint(await user1.getAddress(), ethers.parseEther('1000'));
        });

        it('should allow transfers between users', async function () {
            const transferAmount = ethers.parseEther('100');
            const user1Address = await user1.getAddress();
            const user2Address = await user2.getAddress();

            await token.connect(user1).transfer(user2Address, transferAmount);

            expect(await token.balanceOf(user2Address)).to.equal(transferAmount);
            expect(await token.balanceOf(user1Address)).to.equal(ethers.parseEther('900'));
        });

        it('should allow approve and transferFrom', async function () {
            const approveAmount = ethers.parseEther('200');
            const transferAmount = ethers.parseEther('100');
            const user1Address = await user1.getAddress();
            const user2Address = await user2.getAddress();

            await token.connect(user1).approve(user2Address, approveAmount);
            await token.connect(user2).transferFrom(user1Address, user2Address, transferAmount);

            expect(await token.balanceOf(user2Address)).to.equal(transferAmount);
            expect(await token.allowance(user1Address, user2Address)).to.equal(approveAmount - transferAmount);
        });

        it('should revert transfer with insufficient balance', async function () {
            const user1Balance = await token.balanceOf(await user1.getAddress());
            const excessAmount = user1Balance + ethers.parseEther('1');

            await expect(
                token.connect(user1).transfer(await user2.getAddress(), excessAmount)
            ).to.be.reverted;
        });
    });

    describe('Integration Scenarios', function () {
        it('should handle complete lock-unlock cycle', async function () {
            const user1Address = await user1.getAddress();
            const initialMint = ethers.parseEther('1000');
            const lockAmount = ethers.parseEther('300');

            // Mint tokens
            await token.connect(owner).mint(user1Address, initialMint);
            expect(await token.balanceOf(user1Address)).to.equal(initialMint);

            // Lock tokens
            await token.connect(user1).crossChainLock(
                generateRandomAddress(),
                lockAmount,
                privateChainId
            );
            expect(await token.balanceOf(user1Address)).to.equal(initialMint - lockAmount);
            expect(await token.getLockedAmount(user1Address)).to.equal(lockAmount);

            // Unlock tokens (impersonate executor)
            const executorAddress = await suite.messageExecutor.getAddress();
            await ethers.provider.send('hardhat_impersonateAccount', [executorAddress]);
            await ethers.provider.send('hardhat_setBalance', [executorAddress, '0x1000000000000000000']);
            const executorSigner = await ethers.getSigner(executorAddress);

            await token.connect(executorSigner).crossChainUnlock(user1Address, lockAmount);

            expect(await token.balanceOf(user1Address)).to.equal(initialMint);
            expect(await token.getLockedAmount(user1Address)).to.equal(0);

            await ethers.provider.send('hardhat_stopImpersonatingAccount', [executorAddress]);
        });

        it('should handle partial unlocks', async function () {
            const user1Address = await user1.getAddress();
            const mintAmount = ethers.parseEther('1000');
            const lockAmount = ethers.parseEther('600');
            const unlock1 = ethers.parseEther('200');
            const unlock2 = ethers.parseEther('400');

            await token.connect(owner).mint(user1Address, mintAmount);
            await token.connect(user1).crossChainLock(generateRandomAddress(), lockAmount, privateChainId);

            // Impersonate executor
            const executorAddress = await suite.messageExecutor.getAddress();
            await ethers.provider.send('hardhat_impersonateAccount', [executorAddress]);
            await ethers.provider.send('hardhat_setBalance', [executorAddress, '0x1000000000000000000']);
            const executorSigner = await ethers.getSigner(executorAddress);

            // First unlock
            await token.connect(executorSigner).crossChainUnlock(user1Address, unlock1);
            expect(await token.getLockedAmount(user1Address)).to.equal(lockAmount - unlock1);

            // Second unlock
            await token.connect(executorSigner).crossChainUnlock(user1Address, unlock2);
            expect(await token.getLockedAmount(user1Address)).to.equal(0);

            await ethers.provider.send('hardhat_stopImpersonatingAccount', [executorAddress]);
        });
    });
});