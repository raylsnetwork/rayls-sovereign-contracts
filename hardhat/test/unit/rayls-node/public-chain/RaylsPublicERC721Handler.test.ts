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
import { PublicChainERC721 } from '../../../../../typechain-types';
import { Logger, LogLevel } from '../../utils/moca-logger';

const logger = new Logger();
const logLevel = Number(process.env['TEST_LOGGING_LEVEL'] || LogLevel.INFO);
logger.setLogLevel(logLevel);

describe('RaylsPublicERC721Handler Unit Tests', function () {
    let suite: PublicRaylsNodeTestSuite;
    let token: PublicChainERC721;
    let owner: Signer;
    let user1: Signer;
    let user2: Signer;
    let privateChainAddress: string;
    let privateChainId: number;

    const TOKEN_NAME = 'Test NFT';
    const TOKEN_SYMBOL = 'TNFT';
    const TOKEN_URI = 'https://example.com/nft/';

    beforeEach(async function () {
        logger.debug('Setting up RaylsPublicERC721Handler test suite...');
        suite = await deployPublicRaylsNodeSuite();
        [owner, user1, user2] = await ethers.getSigners();

        privateChainAddress = generateRandomAddress();
        privateChainId = 12345;

        // Deploy test ERC721 token (msg.sender becomes owner)
        const TokenFactory = await ethers.getContractFactory('PublicChainERC721');
        token = await TokenFactory.connect(owner).deploy(
            TOKEN_URI,
            TOKEN_NAME,
            TOKEN_SYMBOL,
            await suite.publicEndpoint.getAddress(),
            privateChainAddress
        ) as PublicChainERC721;
        await token.waitForDeployment();

        // Authorize token as sender on the endpoint
        await suite.publicEndpoint.addAuthorizedSender(await token.getAddress());

        logger.debug('Test NFT deployed at:', await token.getAddress());
    });

    describe('Initialization', function () {
        it('should deploy with correct parameters', async function () {
            expect(await token.name()).to.equal(TOKEN_NAME);
            expect(await token.symbol()).to.equal(TOKEN_SYMBOL);
            expect(await token.owner()).to.equal(await owner.getAddress());
        });

        it('should set correct endpoint', async function () {
            expect(await token.getPublicRaylsNodeEndpoint()).to.equal(await suite.publicEndpoint.getAddress());
        });
    });

    describe('Minting and Burning', function () {
        it('should allow owner to mint NFT', async function () {
            const tokenId = 1;
            const recipient = await user1.getAddress();

            await token.connect(owner).mint(recipient, tokenId);

            expect(await token.ownerOf(tokenId)).to.equal(recipient);
            expect(await token.balanceOf(recipient)).to.equal(1);
        });

        it('should only allow owner to mint', async function () {
            const tokenId = 1;

            await expect(
                token.connect(user1).mint(await user1.getAddress(), tokenId)
            ).to.be.revertedWithCustomError(token, 'OwnableUnauthorizedAccount');
        });

        it('should allow owner to burn NFT', async function () {
            const tokenId = 1;
            const recipient = await user1.getAddress();

            await token.connect(owner).mint(recipient, tokenId);
            await token.connect(owner).burn(tokenId);

            await expect(token.ownerOf(tokenId)).to.be.reverted;
            expect(await token.balanceOf(recipient)).to.equal(0);
        });

        it('should only allow owner to burn', async function () {
            const tokenId = 1;
            const recipient = await user1.getAddress();

            await token.connect(owner).mint(recipient, tokenId);

            await expect(
                token.connect(user1).burn(tokenId)
            ).to.be.revertedWithCustomError(token, 'OwnableUnauthorizedAccount');
        });

        it('should revert when minting duplicate token ID', async function () {
            const tokenId = 1;
            const recipient = await user1.getAddress();

            await token.connect(owner).mint(recipient, tokenId);

            await expect(
                token.connect(owner).mint(recipient, tokenId)
            ).to.be.reverted;
        });
    });

    describe('Lock and Unlock Mechanism', function () {
        const tokenId = 1;

        beforeEach(async function () {
            await token.connect(owner).mint(await user1.getAddress(), tokenId);
        });

        it('should lock NFT successfully', async function () {
            const user1Address = await user1.getAddress();
            const destination = generateRandomAddress();

            await token.connect(user1).crossChainLock(destination, tokenId, privateChainId);

            expect(await token.ownerOf(tokenId)).to.equal(await token.getAddress());
            expect(await token.isTokenLocked(tokenId)).to.be.true;
            expect(await token.getOriginalOwner(tokenId)).to.equal(user1Address);
        });

        it('should revert when locking non-existent token', async function () {
            const nonExistentTokenId = 999;

            await expect(
                token.connect(user1).crossChainLock(generateRandomAddress(), nonExistentTokenId, privateChainId)
            ).to.be.reverted;
        });

        it('should revert when locking by non-owner', async function () {
            await expect(
                token.connect(user2).crossChainLock(generateRandomAddress(), tokenId, privateChainId)
            ).to.be.revertedWithCustomError(token, 'ERC721InsufficientApproval');
        });

        it('should allow approved operator to lock', async function () {
            const user1Address = await user1.getAddress();
            const user2Address = await user2.getAddress();

            await token.connect(user1).approve(user2Address, tokenId);
            await token.connect(user2).crossChainLock(generateRandomAddress(), tokenId, privateChainId);

            expect(await token.isTokenLocked(tokenId)).to.be.true;
            expect(await token.getOriginalOwner(tokenId)).to.equal(user1Address);
        });

        it('should revert when locking already locked token', async function () {
            await token.connect(user1).crossChainLock(generateRandomAddress(), tokenId, privateChainId);

            await expect(
                token.connect(user1).crossChainLock(generateRandomAddress(), tokenId, privateChainId)
            ).to.be.reverted;
        });

        it('should unlock NFT successfully by message executor', async function () {
            const user1Address = await user1.getAddress();

            // Lock token first
            await token.connect(user1).crossChainLock(generateRandomAddress(), tokenId, privateChainId);

            // Impersonate message executor
            const executorAddress = await suite.messageExecutor.getAddress();
            await ethers.provider.send('hardhat_impersonateAccount', [executorAddress]);
            await ethers.provider.send('hardhat_setBalance', [executorAddress, '0x1000000000000000000']);
            const executorSigner = await ethers.getSigner(executorAddress);


            await token.connect(executorSigner).crossChainUnlock(user1Address, tokenId);

            expect(await token.ownerOf(tokenId)).to.equal(user1Address);
            expect(await token.isTokenLocked(tokenId)).to.be.false;

            await ethers.provider.send('hardhat_stopImpersonatingAccount', [executorAddress]);
        });

        it('should revert unlock when called by non-executor', async function () {
            const user1Address = await user1.getAddress();

            await token.connect(user1).crossChainLock(generateRandomAddress(), tokenId, privateChainId);

            await expect(
                token.connect(user1).crossChainUnlock(user1Address, tokenId)
            ).to.be.revertedWith('This is a receive method. Only endpoint\'s executor can call this method.');
        });

        it('should revert unlock for non-locked token', async function () {
            const user1Address = await user1.getAddress();

            // Impersonate executor
            const executorAddress = await suite.messageExecutor.getAddress();
            await ethers.provider.send('hardhat_impersonateAccount', [executorAddress]);
            await ethers.provider.send('hardhat_setBalance', [executorAddress, '0x1000000000000000000']);
            const executorSigner = await ethers.getSigner(executorAddress);


            await expect(
                token.connect(executorSigner).crossChainUnlock(user1Address, tokenId)
            ).to.be.revertedWithCustomError(token, 'RaylsPublicERC721Handler__TokenNotLocked');

            await ethers.provider.send('hardhat_stopImpersonatingAccount', [executorAddress]);
        });

        it('should revert unlock to wrong original owner', async function () {
            const user1Address = await user1.getAddress();
            const wrongAddress = await user2.getAddress();

            await token.connect(user1).crossChainLock(generateRandomAddress(), tokenId, privateChainId);

            // Impersonate executor
            const executorAddress = await suite.messageExecutor.getAddress();
            await ethers.provider.send('hardhat_impersonateAccount', [executorAddress]);
            await ethers.provider.send('hardhat_setBalance', [executorAddress, '0x1000000000000000000']);
            const executorSigner = await ethers.getSigner(executorAddress);


            await expect(
                token.connect(executorSigner).crossChainUnlock(wrongAddress, tokenId)
            ).to.be.revertedWithCustomError(token, 'RaylsPublicERC721Handler__InvalidOriginalOwner');

            await ethers.provider.send('hardhat_stopImpersonatingAccount', [executorAddress]);
        });

        it('should emit TokenLocked when locking NFT', async function () {
            const user1Address = await user1.getAddress();

            await expect(
                token.connect(user1).crossChainLock(generateRandomAddress(), tokenId, privateChainId)
            ).to.emit(token, 'TokenLocked')
             .withArgs(user1Address, tokenId);
        });

        it('should emit TokenUnlocked when unlocking NFT', async function () {
            const user1Address = await user1.getAddress();

            await token.connect(user1).crossChainLock(generateRandomAddress(), tokenId, privateChainId);

            const executorAddress = await suite.messageExecutor.getAddress();
            await ethers.provider.send('hardhat_impersonateAccount', [executorAddress]);
            await ethers.provider.send('hardhat_setBalance', [executorAddress, '0x1000000000000000000']);
            const executorSigner = await ethers.getSigner(executorAddress);

            await expect(
                token.connect(executorSigner).crossChainUnlock(user1Address, tokenId)
            ).to.emit(token, 'TokenUnlocked')
             .withArgs(user1Address, tokenId);

            await ethers.provider.send('hardhat_stopImpersonatingAccount', [executorAddress]);
        });
    });

    describe('Cross-Chain Minting', function () {
        it('should mint NFT via crossChainMint by executor', async function () {
            const tokenId = 10;
            const recipient = await user1.getAddress();

            // Impersonate executor
            const executorAddress = await suite.messageExecutor.getAddress();
            await ethers.provider.send('hardhat_impersonateAccount', [executorAddress]);
            await ethers.provider.send('hardhat_setBalance', [executorAddress, '0x1000000000000000000']);
            const executorSigner = await ethers.getSigner(executorAddress);


            await token.connect(executorSigner).crossChainMint(recipient, tokenId);

            expect(await token.ownerOf(tokenId)).to.equal(recipient);

            await ethers.provider.send('hardhat_stopImpersonatingAccount', [executorAddress]);
        });

        it('should revert crossChainMint when called by non-executor', async function () {
            const tokenId = 10;
            const recipient = await user1.getAddress();

            await expect(
                token.connect(user1).crossChainMint(recipient, tokenId)
            ).to.be.revertedWith('This is a receive method. Only endpoint\'s executor can call this method.');
        });
    });

    describe('Revert Cross-Chain Lock', function () {
        const tokenId = 1;

        beforeEach(async function () {
            await token.connect(owner).mint(await user1.getAddress(), tokenId);
        });

        it('should revert lock and unlock NFT by executor', async function () {
            const user1Address = await user1.getAddress();

            // Lock token
            await token.connect(user1).crossChainLock(generateRandomAddress(), tokenId, privateChainId);

            expect(await token.isTokenLocked(tokenId)).to.be.true;

            // Impersonate executor
            const executorAddress = await suite.messageExecutor.getAddress();
            await ethers.provider.send('hardhat_impersonateAccount', [executorAddress]);
            await ethers.provider.send('hardhat_setBalance', [executorAddress, '0x1000000000000000000']);
            const executorSigner = await ethers.getSigner(executorAddress);


            // Revert the lock
            await token.connect(executorSigner).revertCrossChainLock(user1Address, tokenId);

            expect(await token.ownerOf(tokenId)).to.equal(user1Address);
            expect(await token.isTokenLocked(tokenId)).to.be.false;

            await ethers.provider.send('hardhat_stopImpersonatingAccount', [executorAddress]);
        });

        it('should revert when trying to revert non-locked token', async function () {
            const user1Address = await user1.getAddress();

            // Impersonate executor
            const executorAddress = await suite.messageExecutor.getAddress();
            await ethers.provider.send('hardhat_impersonateAccount', [executorAddress]);
            await ethers.provider.send('hardhat_setBalance', [executorAddress, '0x1000000000000000000']);
            const executorSigner = await ethers.getSigner(executorAddress);


            await expect(
                token.connect(executorSigner).revertCrossChainLock(user1Address, tokenId)
            ).to.be.revertedWithCustomError(token, 'RaylsPublicERC721Handler__TokenNotLocked');

            await ethers.provider.send('hardhat_stopImpersonatingAccount', [executorAddress]);
        });
    });

    describe('Revert Cross-Chain Mint', function () {
        it('should burn minted NFT by executor', async function () {
            const tokenId = 10;
            const recipient = await user1.getAddress();

            // Impersonate executor for minting
            const executorAddress = await suite.messageExecutor.getAddress();
            await ethers.provider.send('hardhat_impersonateAccount', [executorAddress]);
            await ethers.provider.send('hardhat_setBalance', [executorAddress, '0x1000000000000000000']);
            const executorSigner = await ethers.getSigner(executorAddress);


            // Mint
            await token.connect(executorSigner).crossChainMint(recipient, tokenId);
            expect(await token.ownerOf(tokenId)).to.equal(recipient);

            // Revert mint (burn)
            await token.connect(executorSigner).revertCrossChainMint(tokenId);

            await expect(token.ownerOf(tokenId)).to.be.reverted;

            await ethers.provider.send('hardhat_stopImpersonatingAccount', [executorAddress]);
        });

        it('should revert when called by non-executor', async function () {
            const tokenId = 1;

            await token.connect(owner).mint(await user1.getAddress(), tokenId);

            await expect(
                token.connect(user1).revertCrossChainMint(tokenId)
            ).to.be.revertedWith('This is a receive method. Only endpoint\'s executor can call this method.');
        });
    });

    describe('View Functions', function () {
        it('should return correct token metadata', async function () {
            expect(await token.name()).to.equal(TOKEN_NAME);
            expect(await token.symbol()).to.equal(TOKEN_SYMBOL);
        });

        it('should return false for locked status of unminted token', async function () {
            const nonExistentTokenId = 999;
            expect(await token.isTokenLocked(nonExistentTokenId)).to.be.false;
        });

        it('should return zero address for original owner of non-locked token', async function () {
            const tokenId = 1;
            await token.connect(owner).mint(await user1.getAddress(), tokenId);

            expect(await token.getOriginalOwner(tokenId)).to.equal(ethers.ZeroAddress);
        });

        it('should track locked status correctly', async function () {
            const tokenId = 1;
            await token.connect(owner).mint(await user1.getAddress(), tokenId);

            expect(await token.isTokenLocked(tokenId)).to.be.false;

            await token.connect(user1).crossChainLock(generateRandomAddress(), tokenId, privateChainId);

            expect(await token.isTokenLocked(tokenId)).to.be.true;
        });
    });

    describe('Standard ERC721 Operations', function () {
        beforeEach(async function () {
            await token.connect(owner).mint(await user1.getAddress(), 1);
            await token.connect(owner).mint(await user1.getAddress(), 2);
        });

        it('should allow transfers between users', async function () {
            const tokenId = 1;
            const user1Address = await user1.getAddress();
            const user2Address = await user2.getAddress();

            await token.connect(user1).transferFrom(user1Address, user2Address, tokenId);

            expect(await token.ownerOf(tokenId)).to.equal(user2Address);
            expect(await token.balanceOf(user1Address)).to.equal(1);
            expect(await token.balanceOf(user2Address)).to.equal(1);
        });

        it('should allow approve and transferFrom', async function () {
            const tokenId = 1;
            const user1Address = await user1.getAddress();
            const user2Address = await user2.getAddress();

            await token.connect(user1).approve(user2Address, tokenId);
            await token.connect(user2).transferFrom(user1Address, user2Address, tokenId);

            expect(await token.ownerOf(tokenId)).to.equal(user2Address);
        });

        it('should allow setApprovalForAll', async function () {
            const user1Address = await user1.getAddress();
            const user2Address = await user2.getAddress();

            await token.connect(user1).setApprovalForAll(user2Address, true);

            expect(await token.isApprovedForAll(user1Address, user2Address)).to.be.true;

            await token.connect(user2).transferFrom(user1Address, user2Address, 1);
            await token.connect(user2).transferFrom(user1Address, user2Address, 2);

            expect(await token.balanceOf(user2Address)).to.equal(2);
        });

        it('should revert transfer of non-existent token', async function () {
            const nonExistentTokenId = 999;

            await expect(
                token.connect(user1).transferFrom(
                    await user1.getAddress(),
                    await user2.getAddress(),
                    nonExistentTokenId
                )
            ).to.be.reverted;
        });

        it('should revert transfer by non-owner without approval', async function () {
            await expect(
                token.connect(user2).transferFrom(
                    await user1.getAddress(),
                    await user2.getAddress(),
                    1
                )
            ).to.be.reverted;
        });

        it('should not allow transfer of locked token', async function () {
            const tokenId = 1;
            const user1Address = await user1.getAddress();

            await token.connect(user1).crossChainLock(generateRandomAddress(), tokenId, privateChainId);

            // Token is now owned by the contract
            await expect(
                token.connect(user1).transferFrom(user1Address, await user2.getAddress(), tokenId)
            ).to.be.reverted;
        });
    });

    describe('Integration Scenarios', function () {
        it('should handle complete lock-unlock cycle', async function () {
            const tokenId = 1;
            const user1Address = await user1.getAddress();

            // Mint token
            await token.connect(owner).mint(user1Address, tokenId);
            expect(await token.ownerOf(tokenId)).to.equal(user1Address);

            // Lock token
            await token.connect(user1).crossChainLock(generateRandomAddress(), tokenId, privateChainId);
            expect(await token.ownerOf(tokenId)).to.equal(await token.getAddress());
            expect(await token.isTokenLocked(tokenId)).to.be.true;

            // Unlock token
            const executorAddress = await suite.messageExecutor.getAddress();
            await ethers.provider.send('hardhat_impersonateAccount', [executorAddress]);
            await ethers.provider.send('hardhat_setBalance', [executorAddress, '0x1000000000000000000']);
            const executorSigner = await ethers.getSigner(executorAddress);

            await token.connect(executorSigner).crossChainUnlock(user1Address, tokenId);

            expect(await token.ownerOf(tokenId)).to.equal(user1Address);
            expect(await token.isTokenLocked(tokenId)).to.be.false;

            await ethers.provider.send('hardhat_stopImpersonatingAccount', [executorAddress]);
        });

        it('should handle multiple locks for different tokens', async function () {
            const tokenIds = [1, 2, 3];
            const user1Address = await user1.getAddress();

            // Mint multiple tokens
            for (const tokenId of tokenIds) {
                await token.connect(owner).mint(user1Address, tokenId);
            }

            // Lock all tokens
            for (const tokenId of tokenIds) {
                await token.connect(user1).crossChainLock(generateRandomAddress(), tokenId, privateChainId);
                expect(await token.isTokenLocked(tokenId)).to.be.true;
            }

            expect(await token.balanceOf(user1Address)).to.equal(0);
            expect(await token.balanceOf(await token.getAddress())).to.equal(tokenIds.length);
        });
    });
});