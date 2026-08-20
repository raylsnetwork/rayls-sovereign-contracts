import { expect } from 'chai';
import { ethers } from 'hardhat';
import { 
    deployRaylsNodeSuite,
    generateRandomAddress,
    generateRandomBytes32,
    getLatestBlockTimestamp,
    RaylsNodeTestSuite
} from '../utils/raylsNodeTestUtils';
import { Logger, LogLevel } from '../../utils/moca-logger';

const logger = new Logger();
const logLevel = Number(process.env['TEST_LOGGING_LEVEL'] || LogLevel.INFO);
logger.setLogLevel(logLevel);

describe('RNUserGovernanceV1 Unit Tests', function () {
    let suite: RaylsNodeTestSuite;
    
    // Approval status enum values
    const ApprovalStatus = {
        PENDING: 0,
        APPROVED: 1,
        REJECTED: 2
    };
    
    beforeEach(async function () {
        logger.debug('Setting up RNUserGovernanceV1 test suite...');
        suite = await deployRaylsNodeSuite();
    });
    
    describe('Initialization', function () {
        it('should initialize with correct parameters', async function () {
            expect(await suite.userGovernance.owner()).to.equal(suite.deployer.address);
            expect(await suite.userGovernance.getUserCount()).to.equal(0);
        });
    });
    
    describe('User Creation', function () {
        it('should create user successfully', async function () {
            const userId = generateRandomBytes32();
            
            const tx = await suite.userGovernance.createUser(userId);
            
            await expect(tx).to.emit(suite.userGovernance, 'UserCreated')
                .withArgs(userId);
            
            expect(await suite.userGovernance.userExists(userId)).to.be.true;
            expect(await suite.userGovernance.hasUser(userId)).to.be.true;
            expect(await suite.userGovernance.getUserCount()).to.equal(1);
        });
        
        it('should prevent duplicate user creation', async function () {
            const userId = generateRandomBytes32();
            
            await suite.userGovernance.createUser(userId);
            
            await expect(
                suite.userGovernance.createUser(userId)
            ).to.be.revertedWithCustomError(suite.userGovernance, 'RNUserGovernanceV1__UserAlreadyExists');
        });
        
        it('should revert with zero user ID', async function () {
            await expect(
                suite.userGovernance.createUser(ethers.ZeroHash)
            ).to.be.revertedWithCustomError(suite.userGovernance, 'RNUserGovernanceV1__InvalidUserId');
        });
        
        it('should only allow owner to create users', async function () {
            const userId = generateRandomBytes32();
            
            await expect(
                suite.userGovernance.connect(suite.user1).createUser(userId)
            ).to.be.revertedWithCustomError(suite.userGovernance, 'OwnableUnauthorizedAccount');
        });
    });
    
    describe('Address Pair Management', function () {
        let userId: string;
        let publicAddress: string;
        let privateAddress: string;
        
        beforeEach(async function () {
            userId = generateRandomBytes32();
            publicAddress = generateRandomAddress();
            privateAddress = generateRandomAddress();
            
            await suite.userGovernance.createUser(userId);
        });
        
        it('should add address pair successfully', async function () {
            const tx = await suite.userGovernance.addAddressPair(userId, publicAddress, privateAddress);
            
            await expect(tx).to.emit(suite.userGovernance, 'AddressPairAdded')
                .withArgs(userId, publicAddress, privateAddress);
            
            const addressPairs = await suite.userGovernance.getUserAddressPairs(userId);
            expect(addressPairs.length).to.equal(1);
            
            const pair = addressPairs[0];
            expect(pair.publicAddress).to.equal(publicAddress);
            expect(pair.privateAddress).to.equal(privateAddress);
            expect(pair.isActive).to.be.false;
            expect(pair.approvalStatus).to.equal(ApprovalStatus.PENDING);
            
            expect(await suite.userGovernance.publicAddressToUserId(publicAddress)).to.equal(userId);
            expect(await suite.userGovernance.privateAddressToUserId(privateAddress)).to.equal(userId);
        });
        
        it('should revert when adding address pair to non-existent user', async function () {
            const nonExistentUser = generateRandomBytes32();
            
            await expect(
                suite.userGovernance.addAddressPair(nonExistentUser, publicAddress, privateAddress)
            ).to.be.revertedWithCustomError(suite.userGovernance, 'RNUserGovernanceV1__UserDoesNotExist');
        });
        
        it('should prevent duplicate public address mapping', async function () {
            await suite.userGovernance.addAddressPair(userId, publicAddress, privateAddress);
            
            const anotherPrivateAddress = generateRandomAddress();
            await expect(
                suite.userGovernance.addAddressPair(userId, publicAddress, anotherPrivateAddress)
            ).to.be.revertedWithCustomError(suite.userGovernance, 'RNUserGovernanceV1__PublicAddressAlreadyMapped');
        });
        
        it('should prevent duplicate private address mapping', async function () {
            await suite.userGovernance.addAddressPair(userId, publicAddress, privateAddress);
            
            const anotherPublicAddress = generateRandomAddress();
            await expect(
                suite.userGovernance.addAddressPair(userId, anotherPublicAddress, privateAddress)
            ).to.be.revertedWithCustomError(suite.userGovernance, 'RNUserGovernanceV1__PrivateAddressAlreadyMapped');
        });
        
        it('should reject zero addresses', async function () {
            await expect(
                suite.userGovernance.addAddressPair(userId, ethers.ZeroAddress, privateAddress)
            ).to.be.revertedWithCustomError(suite.userGovernance, 'RNUserGovernanceV1__InvalidPublicAddress');
            
            await expect(
                suite.userGovernance.addAddressPair(userId, publicAddress, ethers.ZeroAddress)
            ).to.be.revertedWithCustomError(suite.userGovernance, 'RNUserGovernanceV1__InvalidPrivateAddress');
        });
        
        it('should only allow owner to add address pairs', async function () {
            await expect(
                suite.userGovernance.connect(suite.user1).addAddressPair(userId, publicAddress, privateAddress)
            ).to.be.revertedWithCustomError(suite.userGovernance, 'OwnableUnauthorizedAccount');
        });
    });
    
    describe('Address Pair Removal', function () {
        let userId: string;
        let publicAddress: string;
        let privateAddress: string;
        
        beforeEach(async function () {
            userId = generateRandomBytes32();
            publicAddress = generateRandomAddress();
            privateAddress = generateRandomAddress();
            
            await suite.userGovernance.createUser(userId);
            await suite.userGovernance.addAddressPair(userId, publicAddress, privateAddress);
        });
        
        it('should remove address pair successfully', async function () {
            const tx = await suite.userGovernance.removeAddressPair(userId, publicAddress, privateAddress);
            
            await expect(tx).to.emit(suite.userGovernance, 'AddressPairRemoved')
                .withArgs(userId, publicAddress, privateAddress);
            
            const addressPairs = await suite.userGovernance.getUserAddressPairs(userId);
            expect(addressPairs.length).to.equal(0);
            
            expect(await suite.userGovernance.publicAddressToUserId(publicAddress)).to.equal(ethers.ZeroHash);
            expect(await suite.userGovernance.privateAddressToUserId(privateAddress)).to.equal(ethers.ZeroHash);
        });
        
        it('should revert when removing from non-existent user', async function () {
            const nonExistentUser = generateRandomBytes32();
            
            await expect(
                suite.userGovernance.removeAddressPair(nonExistentUser, publicAddress, privateAddress)
            ).to.be.revertedWithCustomError(suite.userGovernance, 'RNUserGovernanceV1__UserDoesNotExist');
        });
        
        it('should revert when public address not mapped to user', async function () {
            const anotherPublicAddress = generateRandomAddress();
            
            await expect(
                suite.userGovernance.removeAddressPair(userId, anotherPublicAddress, privateAddress)
            ).to.be.revertedWithCustomError(suite.userGovernance, 'RNUserGovernanceV1__PublicAddressNotMappedToUser');
        });
        
        it('should revert when private address not mapped to user', async function () {
            const anotherPrivateAddress = generateRandomAddress();
            
            await expect(
                suite.userGovernance.removeAddressPair(userId, publicAddress, anotherPrivateAddress)
            ).to.be.revertedWithCustomError(suite.userGovernance, 'RNUserGovernanceV1__PrivateAddressNotMappedToUser');
        });
        
        it('should handle removal from middle of array', async function () {
            // Add two more address pairs
            const public2 = generateRandomAddress();
            const private2 = generateRandomAddress();
            const public3 = generateRandomAddress();
            const private3 = generateRandomAddress();
            
            await suite.userGovernance.addAddressPair(userId, public2, private2);
            await suite.userGovernance.addAddressPair(userId, public3, private3);
            
            // Remove middle pair
            await suite.userGovernance.removeAddressPair(userId, public2, private2);
            
            const addressPairs = await suite.userGovernance.getUserAddressPairs(userId);
            expect(addressPairs.length).to.equal(2);
            
            // Verify remaining pairs are still accessible
            expect(await suite.userGovernance.publicAddressToUserId(publicAddress)).to.equal(userId);
            expect(await suite.userGovernance.publicAddressToUserId(public3)).to.equal(userId);
            expect(await suite.userGovernance.publicAddressToUserId(public2)).to.equal(ethers.ZeroHash);
        });
    });
    
    
    describe('User Approval Management', function () {
        let userId: string;
        let addressPairs: Array<{ public: string; private: string }>;
        
        beforeEach(async function () {
            userId = generateRandomBytes32();
            addressPairs = [
                { public: generateRandomAddress(), private: generateRandomAddress() },
                { public: generateRandomAddress(), private: generateRandomAddress() }
            ];
            
            await suite.userGovernance.createUser(userId);
            
            for (const pair of addressPairs) {
                await suite.userGovernance.addAddressPair(userId, pair.public, pair.private);
            }
        });
        
        it('should approve user and activate all address pairs', async function () {
            const tx = await suite.userGovernance.approveUser(userId);
            
            // Should emit approval events for each pending address pair
            for (const pair of addressPairs) {
                await expect(tx).to.emit(suite.userGovernance, 'AddressPairApprovalChanged')
                    .withArgs(userId, pair.public, pair.private, ApprovalStatus.PENDING, ApprovalStatus.APPROVED);
            }
            
            const userAddressPairs = await suite.userGovernance.getUserAddressPairs(userId);
            for (const pair of userAddressPairs) {
                expect(pair.approvalStatus).to.equal(ApprovalStatus.APPROVED);
                expect(pair.isActive).to.be.true;
            }
            
            expect(await suite.userGovernance.getApprovedAddressPairCount(userId)).to.equal(addressPairs.length);
            expect(await suite.userGovernance.getPendingAddressPairCount(userId)).to.equal(0);
        });
        
        it('should reject user and deactivate all address pairs', async function () {
            const tx = await suite.userGovernance.rejectUser(userId);
            
            for (const pair of addressPairs) {
                await expect(tx).to.emit(suite.userGovernance, 'AddressPairApprovalChanged')
                    .withArgs(userId, pair.public, pair.private, ApprovalStatus.PENDING, ApprovalStatus.REJECTED);
            }
            
            const userAddressPairs = await suite.userGovernance.getUserAddressPairs(userId);
            for (const pair of userAddressPairs) {
                expect(pair.approvalStatus).to.equal(ApprovalStatus.REJECTED);
                expect(pair.isActive).to.be.false;
            }
        });
        
        it('should only approve pending address pairs', async function () {
            // Approve first, then try to approve again
            await suite.userGovernance.approveUser(userId);
            
            // Add new pending address pair
            const newPublic = generateRandomAddress();
            const newPrivate = generateRandomAddress();
            await suite.userGovernance.addAddressPair(userId, newPublic, newPrivate);
            
            // Approve again - should only affect the new pending pair
            const tx = await suite.userGovernance.approveUser(userId);
            
            await expect(tx).to.emit(suite.userGovernance, 'AddressPairApprovalChanged')
                .withArgs(userId, newPublic, newPrivate, ApprovalStatus.PENDING, ApprovalStatus.APPROVED);
        });
        
        it('should set individual address pair approval status', async function () {
            const pair = addressPairs[0];
            
            const tx = await suite.userGovernance.setAddressPairApprovalStatus(
                userId,
                pair.public,
                pair.private,
                ApprovalStatus.APPROVED
            );
            
            await expect(tx).to.emit(suite.userGovernance, 'AddressPairApprovalChanged')
                .withArgs(userId, pair.public, pair.private, ApprovalStatus.PENDING, ApprovalStatus.APPROVED);
            
            const status = await suite.userGovernance.getAddressPairApprovalStatus(userId, pair.public, pair.private);
            expect(status).to.equal(ApprovalStatus.APPROVED);
            
            expect(await suite.userGovernance.isAddressPairApproved(userId, pair.public, pair.private)).to.be.true;
        });
        
        it('should activate address pair when approved', async function () {
            const pair = addressPairs[0];
            
            await suite.userGovernance.setAddressPairApprovalStatus(
                userId,
                pair.public,
                pair.private,
                ApprovalStatus.APPROVED
            );
            
            expect(await suite.userGovernance.isAddressPairActive(userId, pair.public, pair.private)).to.be.true;
        });
        
        it('should deactivate address pair when not approved', async function () {
            const pair = addressPairs[0];
            
            // First approve
            await suite.userGovernance.setAddressPairApprovalStatus(
                userId,
                pair.public,
                pair.private,
                ApprovalStatus.APPROVED
            );
            
            // Then reject
            await suite.userGovernance.setAddressPairApprovalStatus(
                userId,
                pair.public,
                pair.private,
                ApprovalStatus.REJECTED
            );
            
            expect(await suite.userGovernance.isAddressPairActive(userId, pair.public, pair.private)).to.be.false;
        });
    });
    
    describe('Address Lookup Functions', function () {
        let userId: string;
        let publicAddress: string;
        let privateAddress: string;
        
        beforeEach(async function () {
            userId = generateRandomBytes32();
            publicAddress = generateRandomAddress();
            privateAddress = generateRandomAddress();
            
            await suite.userGovernance.createUser(userId);
            await suite.userGovernance.addAddressPair(userId, publicAddress, privateAddress);
            await suite.userGovernance.approveUser(userId);
        });
        
        it('should get user ID by public address', async function () {
            expect(await suite.userGovernance.getUserIdByPublicAddress(publicAddress)).to.equal(userId);
        });
        
        it('should get user ID by private address', async function () {
            expect(await suite.userGovernance.getUserIdByPrivateAddress(privateAddress)).to.equal(userId);
        });
        
        it('should get public address from private address', async function () {
            expect(await suite.userGovernance.getPublicAddressFromPrivate(privateAddress)).to.equal(publicAddress);
        });
        
        it('should get private address from public address', async function () {
            expect(await suite.userGovernance.getPrivateAddressFromPublic(publicAddress)).to.equal(privateAddress);
        });
        
        it('should return zero address for non-approved address pairs', async function () {
            // Create another user with rejected address pair
            const userId2 = generateRandomBytes32();
            const publicAddress2 = generateRandomAddress();
            const privateAddress2 = generateRandomAddress();
            
            await suite.userGovernance.createUser(userId2);
            await suite.userGovernance.addAddressPair(userId2, publicAddress2, privateAddress2);
            await suite.userGovernance.rejectUser(userId2);
            
            expect(await suite.userGovernance.getPublicAddressFromPrivate(privateAddress2)).to.equal(ethers.ZeroAddress);
            expect(await suite.userGovernance.getPrivateAddressFromPublic(publicAddress2)).to.equal(ethers.ZeroAddress);
        });
        
        it('should check if user is approved by private address', async function () {
            expect(await suite.userGovernance.checkUserIsApprovedByPrivateAddress(privateAddress)).to.be.true;
            
            // Create rejected user
            const userId2 = generateRandomBytes32();
            const privateAddress2 = generateRandomAddress();
            
            await suite.userGovernance.createUser(userId2);
            await suite.userGovernance.addAddressPair(userId2, generateRandomAddress(), privateAddress2);
            await suite.userGovernance.rejectUser(userId2);
            
            expect(await suite.userGovernance.checkUserIsApprovedByPrivateAddress(privateAddress2)).to.be.false;
        });
    });
    
    describe('User Retrieval Functions', function () {
        let users: Array<{ id: string; publicAddr: string; privateAddr: string }>;
        
        beforeEach(async function () {
            users = [];
            
            for (let i = 0; i < 3; i++) {
                const userId = generateRandomBytes32();
                const publicAddr = generateRandomAddress();
                const privateAddr = generateRandomAddress();
                
                await suite.userGovernance.createUser(userId);
                await suite.userGovernance.addAddressPair(userId, publicAddr, privateAddr);
                
                users.push({ id: userId, publicAddr, privateAddr });
            }
            
            // Approve first user, reject second, leave third pending
            await suite.userGovernance.approveUser(users[0].id);
            await suite.userGovernance.rejectUser(users[1].id);
        });
        
        it('should get all users', async function () {
            const allUsers = await suite.userGovernance.getAllUsers();
            expect(allUsers.length).to.equal(users.length);
            
            for (const user of users) {
                expect(allUsers).to.include(user.id);
            }
        });
        
        it('should get user count', async function () {
            expect(await suite.userGovernance.getUserCount()).to.equal(users.length);
        });
        
        it('should get address pairs by approval status', async function () {
            const approvedPairs = await suite.userGovernance.getApprovedAddressPairs(users[0].id);
            const rejectedPairs = await suite.userGovernance.getRejectedAddressPairs(users[1].id);
            const pendingPairs = await suite.userGovernance.getPendingAddressPairs(users[2].id);
            
            expect(approvedPairs.length).to.equal(1);
            expect(rejectedPairs.length).to.equal(1);
            expect(pendingPairs.length).to.equal(1);
            
            expect(approvedPairs[0].approvalStatus).to.equal(ApprovalStatus.APPROVED);
            expect(rejectedPairs[0].approvalStatus).to.equal(ApprovalStatus.REJECTED);
            expect(pendingPairs[0].approvalStatus).to.equal(ApprovalStatus.PENDING);
        });
        
        it('should get all pending address pairs across users', async function () {
            const [usersWithPending, pendingPairs] = await suite.userGovernance.getAllPendingAddressPairs();
            
            expect(usersWithPending.length).to.equal(1);
            expect(usersWithPending[0]).to.equal(users[2].id);
            expect(pendingPairs.length).to.equal(1);
            expect(pendingPairs[0].length).to.equal(1);
        });
        
        it('should check address mapping status', async function () {
            expect(await suite.userGovernance.isPublicAddressMapped(users[0].publicAddr)).to.be.true;
            expect(await suite.userGovernance.isPrivateAddressMapped(users[0].privateAddr)).to.be.true;
            expect(await suite.userGovernance.isPublicAddressMapped(generateRandomAddress())).to.be.false;
            expect(await suite.userGovernance.isPrivateAddressMapped(generateRandomAddress())).to.be.false;
        });
    });
    
    describe('User Removal', function () {
        let userId: string;
        let publicAddress: string;
        let privateAddress: string;
        
        beforeEach(async function () {
            userId = generateRandomBytes32();
            publicAddress = generateRandomAddress();
            privateAddress = generateRandomAddress();
            
            await suite.userGovernance.createUser(userId);
            await suite.userGovernance.addAddressPair(userId, publicAddress, privateAddress);
        });
        
        it('should remove user successfully', async function () {
            const initialCount = await suite.userGovernance.getUserCount();
            
            await suite.userGovernance.removeUser(userId);
            
            expect(await suite.userGovernance.getUserCount()).to.equal(initialCount - 1n);
            expect(await suite.userGovernance.userExists(userId)).to.be.false;
            
            // Address mappings should be cleared
            expect(await suite.userGovernance.publicAddressToUserId(publicAddress)).to.equal(ethers.ZeroHash);
            expect(await suite.userGovernance.privateAddressToUserId(privateAddress)).to.equal(ethers.ZeroHash);
            
            // Should revert when trying to access removed user
            await expect(
                suite.userGovernance.getUserAddressPairs(userId)
            ).to.be.revertedWithCustomError(suite.userGovernance, 'RNUserGovernanceV1__UserDoesNotExist');
        });
        
        it('should revert when removing non-existent user', async function () {
            await expect(
                suite.userGovernance.removeUser(generateRandomBytes32())
            ).to.be.revertedWithCustomError(suite.userGovernance, 'RNUserGovernanceV1__UserDoesNotExist');
        });
        
        it('should maintain array integrity after removal', async function () {
            // Add multiple users
            const user1 = generateRandomBytes32();
            const user2 = generateRandomBytes32();
            const user3 = generateRandomBytes32();
            
            await suite.userGovernance.createUser(user1);
            await suite.userGovernance.createUser(user2);
            await suite.userGovernance.createUser(user3);
            
            // Remove middle user
            await suite.userGovernance.removeUser(user2);
            
            // Verify remaining users are accessible
            expect(await suite.userGovernance.userExists(user1)).to.be.true;
            expect(await suite.userGovernance.userExists(user2)).to.be.false;
            expect(await suite.userGovernance.userExists(user3)).to.be.true;
            
            const allUsers = await suite.userGovernance.getAllUsers();
            expect(allUsers.length).to.equal(3); // original + 2 new users
        });
    });
    
    describe('Edge Cases and Error Handling', function () {
        it('should handle user with no address pairs gracefully', async function () {
            const userId = generateRandomBytes32();
            await suite.userGovernance.createUser(userId);
            
            expect(await suite.userGovernance.getUserAddressPairCount(userId)).to.equal(0);
            expect(await suite.userGovernance.getActiveAddressPairCount(userId)).to.equal(0);
            expect(await suite.userGovernance.getApprovedAddressPairCount(userId)).to.equal(0);
            expect(await suite.userGovernance.getPendingAddressPairCount(userId)).to.equal(0);
            
            const addressPairs = await suite.userGovernance.getUserAddressPairs(userId);
            expect(addressPairs.length).to.equal(0);
            
            const activeAddressPairs = await suite.userGovernance.getActiveAddressPairs(userId);
            expect(activeAddressPairs.length).to.equal(0);
        });
        
        it('should handle large number of address pairs per user', async function () {
            const userId = generateRandomBytes32();
            await suite.userGovernance.createUser(userId);
            
            const addressPairs = [];
            const pairCount = 5; // Keep reasonable for test performance
            
            for (let i = 0; i < pairCount; i++) {
                const publicAddr = generateRandomAddress();
                const privateAddr = generateRandomAddress();
                
                await suite.userGovernance.addAddressPair(userId, publicAddr, privateAddr);
                addressPairs.push({ publicAddr, privateAddr });
            }
            
            expect(await suite.userGovernance.getUserAddressPairCount(userId)).to.equal(pairCount);
            
            // Approve all
            await suite.userGovernance.approveUser(userId);
            
            expect(await suite.userGovernance.getApprovedAddressPairCount(userId)).to.equal(pairCount);
            expect(await suite.userGovernance.getActiveAddressPairCount(userId)).to.equal(pairCount);
            expect(await suite.userGovernance.getPendingAddressPairCount(userId)).to.equal(0);
        });
        
        it('should handle address pair status transitions correctly', async function () {
            const userId = generateRandomBytes32();
            const publicAddr = generateRandomAddress();
            const privateAddr = generateRandomAddress();
            
            await suite.userGovernance.createUser(userId);
            await suite.userGovernance.addAddressPair(userId, publicAddr, privateAddr);
            
            // Test all status transitions
            const statuses = [ApprovalStatus.APPROVED, ApprovalStatus.REJECTED, ApprovalStatus.PENDING];
            
            for (const status of statuses) {
                await suite.userGovernance.setAddressPairApprovalStatus(userId, publicAddr, privateAddr, status);
                
                const currentStatus = await suite.userGovernance.getAddressPairApprovalStatus(userId, publicAddr, privateAddr);
                expect(currentStatus).to.equal(status);
                
                const isActive = await suite.userGovernance.isAddressPairActive(userId, publicAddr, privateAddr);
                expect(isActive).to.equal(status === ApprovalStatus.APPROVED);
            }
        });
    });
});