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
import { PublicChainERC1155 } from '../../../../../typechain-types';
import { Logger, LogLevel } from '../../utils/moca-logger';

const logger = new Logger();
const logLevel = Number(process.env['TEST_LOGGING_LEVEL'] || LogLevel.INFO);
logger.setLogLevel(logLevel);

describe('RaylsPublicERC1155Handler Unit Tests', function () {
    let suite: PublicRaylsNodeTestSuite;
    let token: PublicChainERC1155;
    let owner: Signer;
    let user1: Signer;
    let user2: Signer;
    let privateChainAddress: string;
    let privateChainId: number;

    const TOKEN_NAME = 'Test Multi-Token';
    const TOKEN_URI = 'https://example.com/token/{id}.json';

    beforeEach(async function () {
        logger.debug('Setting up RaylsPublicERC1155Handler test suite...');
        suite = await deployPublicRaylsNodeSuite();
        [owner, user1, user2] = await ethers.getSigners();

        privateChainAddress = generateRandomAddress();
        privateChainId = 12345;

        // Deploy test ERC1155 token
        const TokenFactory = await ethers.getContractFactory('PublicChainERC1155');
        token = await TokenFactory.connect(owner).deploy(
            TOKEN_URI,
            TOKEN_NAME,
            await suite.publicEndpoint.getAddress(),
            privateChainAddress
        ) as PublicChainERC1155;
        await token.waitForDeployment();

        // Authorize token as sender on the endpoint
        await suite.publicEndpoint.addAuthorizedSender(await token.getAddress());

        logger.debug('Test ERC1155 deployed at:', await token.getAddress());
    });

    describe('Initialization', function () {
        it('should deploy with correct parameters', async function () {
            expect(await token.name()).to.equal(TOKEN_NAME);
            expect(await token.uri(0)).to.equal(TOKEN_URI);
            expect(await token.owner()).to.equal(await owner.getAddress());
        });

        it('should set correct endpoint', async function () {
            expect(await token.getPublicRaylsNodeEndpoint()).to.equal(await suite.publicEndpoint.getAddress());
        });

        it('should support ERC1155 and ERC1155Receiver interfaces', async function () {
            // ERC1155 interface ID: 0xd9b67a26
            expect(await token.supportsInterface('0xd9b67a26')).to.be.true;
            // ERC1155Receiver interface ID: 0x4e2312e0
            expect(await token.supportsInterface('0x4e2312e0')).to.be.true;
        });
    });

    describe('Minting and Burning', function () {
        it('should allow owner to mint tokens', async function () {
            const tokenId = 1;
            const amount = 100;
            const recipient = await user1.getAddress();

            await token.connect(owner).mint(recipient, tokenId, amount, '0x');

            expect(await token.balanceOf(recipient, tokenId)).to.equal(amount);
        });

        it('should only allow owner to mint', async function () {
            const tokenId = 1;
            const amount = 100;

            await expect(
                token.connect(user1).mint(await user1.getAddress(), tokenId, amount, '0x')
            ).to.be.revertedWithCustomError(token, 'OwnableUnauthorizedAccount');
        });

        it('should allow owner to mint batch', async function () {
            const tokenIds = [1, 2, 3];
            const amounts = [100, 200, 300];
            const recipient = await user1.getAddress();

            await token.connect(owner).mintBatch(recipient, tokenIds, amounts, '0x');

            for (let i = 0; i < tokenIds.length; i++) {
                expect(await token.balanceOf(recipient, tokenIds[i])).to.equal(amounts[i]);
            }
        });

        it('should allow owner to burn tokens', async function () {
            const tokenId = 1;
            const mintAmount = 100;
            const burnAmount = 30;
            const recipient = await user1.getAddress();

            await token.connect(owner).mint(recipient, tokenId, mintAmount, '0x');
            await token.connect(owner).burn(recipient, tokenId, burnAmount);

            expect(await token.balanceOf(recipient, tokenId)).to.equal(mintAmount - burnAmount);
        });

        it('should only allow owner to burn', async function () {
            const tokenId = 1;
            const amount = 100;
            const recipient = await user1.getAddress();

            await token.connect(owner).mint(recipient, tokenId, amount, '0x');

            await expect(
                token.connect(user1).burn(recipient, tokenId, amount)
            ).to.be.revertedWithCustomError(token, 'OwnableUnauthorizedAccount');
        });

        it('should allow owner to burn batch', async function () {
            const tokenIds = [1, 2, 3];
            const amounts = [100, 200, 300];
            const burnAmounts = [50, 100, 150];
            const recipient = await user1.getAddress();

            await token.connect(owner).mintBatch(recipient, tokenIds, amounts, '0x');
            await token.connect(owner).burnBatch(recipient, tokenIds, burnAmounts);

            for (let i = 0; i < tokenIds.length; i++) {
                expect(await token.balanceOf(recipient, tokenIds[i])).to.equal(amounts[i] - burnAmounts[i]);
            }
        });
    });

    describe('Cross-Chain Minting', function () {
        it('should mint tokens via crossChainMint by executor', async function () {
            const tokenId = 10;
            const amount = 500;
            const recipient = await user1.getAddress();

            // Impersonate executor
            const executorAddress = await suite.messageExecutor.getAddress();
            await ethers.provider.send('hardhat_impersonateAccount', [executorAddress]);
            await ethers.provider.send('hardhat_setBalance', [executorAddress, '0x1000000000000000000']);
            const executorSigner = await ethers.getSigner(executorAddress);


            await token.connect(executorSigner).crossChainMint(recipient, tokenId, amount, '0x');

            expect(await token.balanceOf(recipient, tokenId)).to.equal(amount);

            await ethers.provider.send('hardhat_stopImpersonatingAccount', [executorAddress]);
        });

        it('should revert crossChainMint when called by non-executor', async function () {
            const tokenId = 10;
            const amount = 500;
            const recipient = await user1.getAddress();

            await expect(
                token.connect(user1).crossChainMint(recipient, tokenId, amount, '0x')
            ).to.be.revertedWith('This is a receive method. Only endpoint\'s executor can call this method.');
        });
    });

    describe('Lock and Unlock Events', function () {
        const tokenId = 1;
        const lockAmount = 50;

        beforeEach(async function () {
            await token.connect(owner).mint(await user1.getAddress(), tokenId, 100, '0x');
        });

        it('should emit TokensLocked when locking tokens', async function () {
            const user1Address = await user1.getAddress();

            await expect(
                token.connect(user1).crossChainLock(generateRandomAddress(), tokenId, lockAmount, privateChainId, '0x')
            ).to.emit(token, 'TokensLocked')
             .withArgs(user1Address, tokenId, lockAmount);
        });

        it('should emit TokensUnlocked when unlocking tokens', async function () {
            const user1Address = await user1.getAddress();

            await token.connect(user1).crossChainLock(generateRandomAddress(), tokenId, lockAmount, privateChainId, '0x');

            const executorAddress = await suite.messageExecutor.getAddress();
            await ethers.provider.send('hardhat_impersonateAccount', [executorAddress]);
            await ethers.provider.send('hardhat_setBalance', [executorAddress, '0x1000000000000000000']);
            const executorSigner = await ethers.getSigner(executorAddress);

            await expect(
                token.connect(executorSigner).crossChainUnlock(user1Address, tokenId, lockAmount)
            ).to.emit(token, 'TokensUnlocked')
             .withArgs(user1Address, tokenId, lockAmount);

            await ethers.provider.send('hardhat_stopImpersonatingAccount', [executorAddress]);
        });
    });

    describe('Revert Cross-Chain Lock', function () {
        const tokenId = 1;
        const lockAmount = 50;

        beforeEach(async function () {
            await token.connect(owner).mint(await user1.getAddress(), tokenId, 100, '0x');
        });

        it('should revert when trying to revert more than locked', async function () {
            const user1Address = await user1.getAddress();
            const smallLock = 20;
            const largeLock = 50;

            await token.connect(user1).crossChainLock(generateRandomAddress(), tokenId, smallLock, privateChainId, '0x');

            // Impersonate executor
            const executorAddress = await suite.messageExecutor.getAddress();
            await ethers.provider.send('hardhat_impersonateAccount', [executorAddress]);
            await ethers.provider.send('hardhat_setBalance', [executorAddress, '0x1000000000000000000']);
            const executorSigner = await ethers.getSigner(executorAddress);


            await expect(
                token.connect(executorSigner).revertCrossChainLock(user1Address, tokenId, largeLock)
            ).to.be.revertedWithCustomError(token, 'RaylsPublicERC1155Handler__InsufficientLockedTokens');

            await ethers.provider.send('hardhat_stopImpersonatingAccount', [executorAddress]);
        });
    });

    describe('Revert Cross-Chain Mint', function () {
        it('should burn minted tokens by executor', async function () {
            const tokenId = 10;
            const amount = 500;
            const recipient = await user1.getAddress();

            // Impersonate executor
            const executorAddress = await suite.messageExecutor.getAddress();
            await ethers.provider.send('hardhat_impersonateAccount', [executorAddress]);
            await ethers.provider.send('hardhat_setBalance', [executorAddress, '0x1000000000000000000']);
            const executorSigner = await ethers.getSigner(executorAddress);


            // Mint
            await token.connect(executorSigner).crossChainMint(recipient, tokenId, amount, '0x');
            expect(await token.balanceOf(recipient, tokenId)).to.equal(amount);

            // Revert mint (burn)
            await token.connect(executorSigner).revertCrossChainMint(recipient, tokenId, amount);

            expect(await token.balanceOf(recipient, tokenId)).to.equal(0);

            await ethers.provider.send('hardhat_stopImpersonatingAccount', [executorAddress]);
        });

        it('should revert when called by non-executor', async function () {
            const tokenId = 1;
            const amount = 50;
            const user1Address = await user1.getAddress();

            await token.connect(owner).mint(user1Address, tokenId, 100, '0x');

            await expect(
                token.connect(user1).revertCrossChainMint(user1Address, tokenId, amount)
            ).to.be.revertedWith('This is a receive method. Only endpoint\'s executor can call this method.');
        });
    });

    describe('View Functions', function () {
        it('should return correct URI', async function () {
            expect(await token.uri(1)).to.equal(TOKEN_URI);
            expect(await token.uri(999)).to.equal(TOKEN_URI);
        });

        it('should return zero locked amount for new address and token', async function () {
            const newAddress = generateRandomAddress();
            expect(await token.getLockedAmount(newAddress, 1)).to.equal(0);
        });

        it('should return correct locked amount after operations', async function () {
            const user1Address = await user1.getAddress();
            const tokenId = 1;

            await token.connect(owner).mint(user1Address, tokenId, 100, '0x');
            await token.connect(user1).crossChainLock(generateRandomAddress(), tokenId, 30, privateChainId, '0x');

            expect(await token.getLockedAmount(user1Address, tokenId)).to.equal(30);
        });
    });

    describe('Standard ERC1155 Operations', function () {
        beforeEach(async function () {
            const user1Address = await user1.getAddress();
            await token.connect(owner).mint(user1Address, 1, 100, '0x');
            await token.connect(owner).mint(user1Address, 2, 200, '0x');
        });

        it('should allow safeTransferFrom between users', async function () {
            const tokenId = 1;
            const amount = 30;
            const user1Address = await user1.getAddress();
            const user2Address = await user2.getAddress();

            await token.connect(user1).safeTransferFrom(user1Address, user2Address, tokenId, amount, '0x');

            expect(await token.balanceOf(user2Address, tokenId)).to.equal(amount);
            expect(await token.balanceOf(user1Address, tokenId)).to.equal(70);
        });

        it('should allow safeBatchTransferFrom', async function () {
            const tokenIds = [1, 2];
            const amounts = [30, 50];
            const user1Address = await user1.getAddress();
            const user2Address = await user2.getAddress();

            await token.connect(user1).safeBatchTransferFrom(user1Address, user2Address, tokenIds, amounts, '0x');

            expect(await token.balanceOf(user2Address, 1)).to.equal(30);
            expect(await token.balanceOf(user2Address, 2)).to.equal(50);
            expect(await token.balanceOf(user1Address, 1)).to.equal(70);
            expect(await token.balanceOf(user1Address, 2)).to.equal(150);
        });

        it('should allow setApprovalForAll', async function () {
            const user1Address = await user1.getAddress();
            const user2Address = await user2.getAddress();

            await token.connect(user1).setApprovalForAll(user2Address, true);

            expect(await token.isApprovedForAll(user1Address, user2Address)).to.be.true;

            await token.connect(user2).safeTransferFrom(user1Address, user2Address, 1, 30, '0x');

            expect(await token.balanceOf(user2Address, 1)).to.equal(30);
        });

        it('should revert transfer with insufficient balance', async function () {
            const user1Address = await user1.getAddress();
            const user2Address = await user2.getAddress();

            await expect(
                token.connect(user1).safeTransferFrom(user1Address, user2Address, 1, 1000, '0x')
            ).to.be.reverted;
        });

        it('should support balance queries', async function () {
            const user1Address = await user1.getAddress();
            const accounts = [user1Address, user1Address];
            const tokenIds = [1, 2];

            const balances = await token.balanceOfBatch(accounts, tokenIds);

            expect(balances[0]).to.equal(100);
            expect(balances[1]).to.equal(200);
        });
    });

    describe('Integration Scenarios', function () {

        it('should handle locks for multiple token IDs independently', async function () {
            const user1Address = await user1.getAddress();
            const token1Id = 1;
            const token2Id = 2;
            const token3Id = 3;

            // Mint multiple tokens
            await token.connect(owner).mintBatch(user1Address, [token1Id, token2Id, token3Id], [100, 200, 300], '0x');

            // Lock different amounts for each token
            await token.connect(user1).crossChainLock(generateRandomAddress(), token1Id, 30, privateChainId, '0x');
            await token.connect(user1).crossChainLock(generateRandomAddress(), token2Id, 50, privateChainId, '0x');
            await token.connect(user1).crossChainLock(generateRandomAddress(), token3Id, 70, privateChainId, '0x');

            expect(await token.getLockedAmount(user1Address, token1Id)).to.equal(30);
            expect(await token.getLockedAmount(user1Address, token2Id)).to.equal(50);
            expect(await token.getLockedAmount(user1Address, token3Id)).to.equal(70);

            expect(await token.balanceOf(user1Address, token1Id)).to.equal(70);
            expect(await token.balanceOf(user1Address, token2Id)).to.equal(150);
            expect(await token.balanceOf(user1Address, token3Id)).to.equal(230);
        });
    });
});