// SPDX-License-Identifier: Apache-2.0

pragma solidity 0.8.24;

import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import {IERC1155} from '@openzeppelin/contracts/token/ERC1155/IERC1155.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IDvp} from '../../interfaces/IDvp.sol';
import {IMerkle} from '../../interfaces/IMerkle.sol';
import {IPoseidonWrapper} from '../../interfaces/IPoseidonWrapper.sol';
import {IDvpVerifierAggregator} from '../../interfaces/IDvpVerifierAggregator.sol';
import '@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

import {RaylsAccessManaged} from '../../../privateHub/AccessControl/RaylsAccessManaged.sol';
import {IRaylsAccessManager} from '../../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol';

import {IAssetGroup} from '../../interfaces/IAssetGroup.sol';
import {IAbstractCoinVault} from '../../interfaces/IAbstractCoinVault.sol';
import {IZkAuction} from '../../interfaces/IZkAuction.sol';
import {DvpTeleport} from './DvpTeleport.sol';

contract Dvp is IDvp, RaylsAccessManaged, ReentrancyGuard {
    ///////////////////////////////////////////////
    //              Constants
    //////////////////////////////////////////////

    uint256 constant SNARK_SCALAR_FIELD =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;


    uint256 constant GROUP_ID_FUNGIBLES = 0;
    uint256 constant GROUP_ID_NON_FUNGIBLES = 1;

    ///////////////////////////////////////////////
    //           Private attributes
    //////////////////////////////////////////////

    // name identifier for Dvp smart contract
    string private _name;

    // the address of PoseidonWrapper smart contract
    address private _hashContractAddress;

    // DvpTeleport contract for emitting encrypted balance update events
    DvpTeleport private _dvpTeleport;

    // address of non-generic verifier that aggregates the verifiers
    address private _verifierContractAddress;

    address private _zkAuctionContractAddress;

    // Use mappings instead of arrays for unlimited scalability without constructor gas costs
    mapping(uint256 => address) private _coinVaultAddressById;
    mapping(address => uint256) private _vaultIdsByTokenAddress;
    uint256 _coinVaultAddressByIdCount;

    mapping(uint256 => bool) private _rottenChallenges;

    mapping(uint256 => bool) private _swapGroupPairs;
    mapping(uint256 => bool) private _exchangeGroupPairs;

    mapping(uint256 => address) private _assetGroups;
    uint256 _assetGroupsCount;

    // mapping from uniqueUTXO id and the vaultId
    // we are using the first output commitment of the receipt as the
    // uniqueId of the receipt
    mapping(uint256 => TransactionMetadata) private _pendingTransactions;

    // first broker_blindedPublicKey =>
    mapping(uint256 => ProofReceipt) private _registeredBrokers;

    // auditor's mapping AuditorId -> AuditorData
    mapping(uint256 => AuditorData) private _registeredAuditors;

    ///////////////////////////////////////////////
    //              Constructor
    //////////////////////////////////////////////

    constructor(
        address hashPoseidonContractAddress,
        address enygmaFactoryAddress,
        address dvpErc721FactoryAddress,
        address dvpErc1155FactoryAddress,
        address dvpTeleportAddr,
        address authority_
    ) {
        _name = 'DVP smart contract';
        _hashContractAddress = hashPoseidonContractAddress;
        _dvpTeleport = DvpTeleport(dvpTeleportAddr);

        _setAuthority(authority_);

        // Owner-gated selectors → TOKEN_OWNER
        bytes4[] memory ownerSels = new bytes4[](12);
        ownerSels[0] = this.addEnygmaDvpIntegrationAddress.selector;
        ownerSels[1] = this.initializeDvp.selector;
        ownerSels[2] = this.registerAssetGroup.selector;
        ownerSels[3] = this.registerSwapGroupPair.selector;
        ownerSels[4] = this.registerExchangeGroupPair.selector;
        ownerSels[5] = this.registerVault.selector;
        ownerSels[6] = this.registerZkAuction.selector;
        ownerSels[7] = this.registerAuditor.selector;
        ownerSels[8] = this.unregisterAuditor.selector;
        ownerSels[9] = this.registerBroker.selector;
        ownerSels[10] = this.addTokenToGroup.selector;
        ownerSels[11] = this.addVaultToGroup.selector;

        // ENYGMA_CREATOR role selectors
        bytes4[] memory enygmaSels = new bytes4[](3);
        enygmaSels[0] = this.depositEnygma.selector;
        enygmaSels[1] = this.withdrawEnygma.selector;
        enygmaSels[2] = this.mixFunds.selector;

        // COIN_VAULT role selectors
        bytes4[] memory vaultSels = new bytes4[](3);
        vaultSels[0] = this.checkAndRegisterChallenge.selector;
        vaultSels[1] = this.addTokenToGroup.selector;
        vaultSels[2] = this.addVaultToGroup.selector;

        IRaylsAccessManager.SelectorRoleMapping[] memory mappings = new IRaylsAccessManager.SelectorRoleMapping[](2);
        mappings[0] = IRaylsAccessManager.SelectorRoleMapping("ENYGMA_CREATOR", enygmaSels);
        mappings[1] = IRaylsAccessManager.SelectorRoleMapping("COIN_VAULT", vaultSels);

        // Register Dvp as its OWN contract authority so that internal
        // grants in addEnygmaDvpIntegrationAddress / registerVault can use
        // `grantContractScopedRole(..., address(this), 0)`. Deploy-script calls
        // to `grantContractScopedRole` for TOKEN_OWNER still work because the
        // deployer signer holds ADMIN (ADMIN fallback in _checkIsContractAuthority).
        IRaylsAccessManager(authority_).selfRegisterManagedContract(address(this), ownerSels, mappings);
    }

    ///////////////////////////////////////////////
    //              Public Getters
    //////////////////////////////////////////////
    function name() public view returns (string memory) {
        return _name;
    }

    // Get vault by vaultId
    function vaultById(uint256 vaultId) public view returns (address) {
        return _coinVaultAddressById[vaultId];
    }

    // Get vaultId by contract address
    function getVaultIdByAddress(address contractAddress) public view returns (uint256) {
        uint256 vaultId = _vaultIdsByTokenAddress[contractAddress];
        require(vaultId != 0, "Contract address not registered");
        return vaultId;
    }

    function hashContractAddress() public view returns (address) {
        return _hashContractAddress;
    }

    function verifierContractAddress() public view returns (address) {
        return _verifierContractAddress;
    }

    function dvpTeleportAddress() public view returns (address) {
        return address(_dvpTeleport);
    }

    ///////////////////////////////////////////////
    //      enygma add function
    //////////////////////////////////////////////

    function addEnygmaDvpIntegrationAddress(
        address enygmaDvpIntegrationAddress
    ) public restricted returns (bool) {
        address mgr = authority();
        // F17 fix: scope the ENYGMA_CREATOR grant to Dvp so it does not leak
        // into other managed contracts that map ENYGMA_CREATOR (e.g.
        // EnygmaFactory.initiateEnygmaCreation).
        IRaylsAccessManager(mgr).grantContractScopedRole(
            IRaylsAccessManager(mgr).getRoleIdByName("ENYGMA_CREATOR"),
            enygmaDvpIntegrationAddress,
            address(this),
            0
        );
        return true;
    }

    ///////////////////////////////////////////////
    //       initialization functions
    //////////////////////////////////////////////
    function initializeDvp(
        address verifierAddress
    ) public restricted returns (bool) {
        _verifierContractAddress = verifierAddress;
        return true;
    }

    ///////////////////////////////////////////////
    //       Asset Group functions
    //////////////////////////////////////////////

    function registerAssetGroup(
        address assetGroupContractAddress,
        string memory assetGroupName,
        bool isAssetGroupFungible,
        uint256 treeDepth
    ) public restricted nonReentrant returns (bool) {
        uint256 groupId = _assetGroupsCount;
        _assetGroups[groupId] = assetGroupContractAddress;
        IAssetGroup(assetGroupContractAddress).initializeAssetGroup(
            groupId,
            assetGroupName,
            isAssetGroupFungible,
            treeDepth
        );

        _assetGroupsCount++;
        return true;
    }

    function registerSwapGroupPair(uint256 groupId1, uint256 groupId2) public restricted returns (bool) {
        if (groupId1 >= _assetGroupsCount || groupId2 >= _assetGroupsCount) {
            revert Dvp__GroupIdOutOfRange();
        }

        // checking group 1 to be fungible
        IAssetGroup assetGroup1 = IAssetGroup(_assetGroups[groupId1]);
        if (!assetGroup1.isFungible()) {
            revert Dvp__GroupFungibilityMismatch();
        }

        // checking group 2 not to be fungible
        IAssetGroup assetGroup2 = IAssetGroup(_assetGroups[groupId2]);
        if (assetGroup2.isFungible()) {
            revert Dvp__GroupFungibilityMismatch();
        }

        // generating the groupPairId
        uint256 groupPairId = uint256(keccak256(abi.encodePacked(groupId1, groupId2)));

        // if already registered revert
        if (_swapGroupPairs[groupPairId]) {
            revert Dvp__GroupPairAlreadyRegistered();
        } else {
            // if not already registered, register it
            _swapGroupPairs[groupPairId] = true;
        }

        return true;
    }

    function registerExchangeGroupPair(uint256 groupId1, uint256 groupId2) public restricted returns (bool) {
        if (groupId1 >= _assetGroupsCount || groupId2 >= _assetGroupsCount) {
            revert Dvp__GroupIdOutOfRange();
        }

        // checking group 1 to be fungible
        IAssetGroup assetGroup1 = IAssetGroup(_assetGroups[groupId1]);
        if (!assetGroup1.isFungible()) {
            revert Dvp__GroupFungibilityMismatch();
        }

        // checking group 2 to be fungible
        IAssetGroup assetGroup2 = IAssetGroup(_assetGroups[groupId2]);
        if (!assetGroup2.isFungible()) {
            revert Dvp__GroupFungibilityMismatch();
        }

        uint256 groupPairId = getGroupPairId(groupId1, groupId2);
        if (_exchangeGroupPairs[groupPairId]) {
            revert Dvp__GroupPairAlreadyRegistered();
        } else {
            _exchangeGroupPairs[groupPairId] = true;
        }

        return true;
    }

    function isValidSwapGroupPair(uint256 groupId1, uint256 groupId2) public view returns (bool) {
        uint256 groupPairId = getGroupPairId(groupId1, groupId2);
        return _swapGroupPairs[groupPairId];
    }

    function isValidExchangeGroupPair(
        uint256 groupId1,
        uint256 groupId2
    ) public view returns (bool) {
        uint256 groupPairId = getGroupPairId(groupId1, groupId2);
        return _exchangeGroupPairs[groupPairId];
    }

    function getGroupPairId(uint256 groupId1, uint256 groupId2) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(groupId1, groupId2)));
    }

    function addTokenToGroup(
        uint256 vaultId,
        uint256[] memory uniqueIdParams,
        uint256 groupId
    ) public restricted returns (bool) {
        IAssetGroup assetGroupContract = IAssetGroup(_assetGroups[groupId]);
        IAbstractCoinVault vaultContract = IAbstractCoinVault(_coinVaultAddressById[vaultId]);

        uint256 uniqueId = vaultContract.generateUniqueId(uniqueIdParams);
        assetGroupContract.insertTokenMember(vaultId, uniqueId);

        emit TokenAddedToGroup(vaultId, uniqueId, groupId);
        return true;
    }

    function addVaultToGroup(
        uint256 vaultId,
        uint256 groupId
    ) public restricted returns (bool) {
        IAssetGroup assetGroupContract = IAssetGroup(_assetGroups[groupId]);
        assetGroupContract.insertVaultMember(vaultId);
        emit VaultAddedToGroup(vaultId, groupId);
        return true;
    }

    function isTokenMemberOf(
        uint256 vaultId,
        uint256[] memory uniqueIdParams,
        uint256 groupId
    ) public view returns (bool) {
        uint256[] memory p2 = new uint256[](5);
        // first paramater is reserved for value.
        // copying the rest
        // TODO:: check the length < 5
        for (uint256 i = 1; i < uniqueIdParams.length; i++) {
            p2[i] = uniqueIdParams[i];
        }

        IAssetGroup assetGroupContract = IAssetGroup(_assetGroups[groupId]);

        uint256 tokenUniqueId = IAbstractCoinVault(_coinVaultAddressById[vaultId]).generateUniqueId(p2);

        return assetGroupContract.isTokenMember(vaultId, tokenUniqueId);
    }

    function isVaultMemberOf(uint256 vaultId, uint256 groupId) public view returns (bool) {
        // TODO:: implement it
        IAssetGroup assetGroupContract = IAssetGroup(_assetGroups[groupId]);

        return assetGroupContract.isVaultMember(vaultId);
    }

    function isMemberOfFromProofReceipt(
        uint256 vaultId,
        ProofReceipt memory receipt,
        uint256 groupId
    ) public view returns (bool) {
        // TODO:: implement it
        IAssetGroup assetGroupContract = IAssetGroup(_assetGroups[groupId]);

        return assetGroupContract.isMemberFromProofReceipt(vaultId, receipt);
    }

    ///////////////////////////////////////////////
    //    CoinVault (Deposit, Withdraw) functions
    //////////////////////////////////////////////

    function registerVault(
        address vaultContractAddress,
        address assetContractAddress,
        uint256 treeDepth
    ) public restricted returns (uint256) {
        // registering the vault smart contract address and vaultId

        uint256 vaultId = _coinVaultAddressByIdCount + 1;
        _coinVaultAddressById[vaultId] = vaultContractAddress;
        _vaultIdsByTokenAddress[assetContractAddress] = vaultId;

        // initializing CoinVault
        IAbstractCoinVault(_coinVaultAddressById[vaultId]).initializeVault(
            vaultId,
            //  vaultIdentifiersCount,
            assetContractAddress,
            treeDepth,
            _hashContractAddress,
            _verifierContractAddress,
            _zkAuctionContractAddress
        );

        // COIN_VAULT is a CROSS-CONTRACT role by design: registered vaults
        // legitimately need authority on both Dvp (for internal calls) AND
        // DvpTeleport.emitCommitments/emitNullifier (mapping at
        // hardhat/tasks/deploy/private-hub.ts:304). A global grant is the
        // intended model here. The F17 scoping fix applies to ENYGMA_CREATOR,
        // which has no legitimate cross-contract usage — see
        // addEnygmaDvpIntegrationAddress above.
        address mgr = authority();
        IRaylsAccessManager(mgr).grantRole(
            IRaylsAccessManager(mgr).getRoleIdByName("COIN_VAULT"),
            vaultContractAddress,
            0
        );

        _coinVaultAddressByIdCount++;

        return vaultId;
    }

    // user directly calls deposit Enygma function
    function depositEnygma(
        uint256 vaultId,
        uint256 hashCommitment
    ) public restricted returns (bool) {
        // Get the Enygma vault using the provided vaultId
        address enygmaVaultAddress = _coinVaultAddressById[vaultId];
        require(enygmaVaultAddress != address(0), 'Enygma vault not registered');

        // Prepare deposit parameters - just pass the commitment hash
        uint256[] memory depositParams = new uint256[](1);
        depositParams[0] = hashCommitment;

        // Call the vault's deposit function
        bool success = IAbstractCoinVault(enygmaVaultAddress).deposit(depositParams);
        require(success, 'Enygma deposit failed');

        return true;
    }

    function depositERC721(address contractAddress, uint256 nftId, uint256 publicKey, uint256 salt, bytes calldata encryptedBalanceUpdate) public nonReentrant returns (bool) {
        // Get the vaultId from the contract address
        uint256 vaultId = getVaultIdByAddress(contractAddress);

        // Get the vault using the vaultId
        address erc721VaultAddress = _coinVaultAddressById[vaultId];
        require(erc721VaultAddress != address(0), 'Erc721 vault not registered');

        // Get the asset contract address from the vault
        address assetContractAddress = IAbstractCoinVault(erc721VaultAddress)
            .getAssetContractAddress();

        // Transfer the NFT from the user to the vault
        IERC721(assetContractAddress).transferFrom(msg.sender, erc721VaultAddress, nftId);

        // Prepare deposit parameters
        uint256[] memory depositParams = new uint256[](3);
        depositParams[0] = nftId;
        depositParams[1] = publicKey;
        depositParams[2] = salt;

        // Call the vault's deposit function
        bool success = IAbstractCoinVault(erc721VaultAddress).deposit(depositParams);
        require(success, 'Erc721 deposit failed');

        _dvpTeleport.ercDvpBalanceUpdated(encryptedBalanceUpdate);

        return true;
    }

    function depositERC1155(
        address contractAddress,
        uint256 tokenId,
        uint256 amountOrOne,
        bytes memory data,
        uint256 publicKey,
        uint256 salt,
        bytes calldata encryptedBalanceUpdate
    ) public nonReentrant returns (bool) {
        // Get the vaultId from the contract address
        uint256 vaultId = getVaultIdByAddress(contractAddress);

        // Get the vault using the vaultId
        address erc1155VaultAddress = _coinVaultAddressById[vaultId];
        require(erc1155VaultAddress != address(0), 'Erc1155 vault not registered');

        // Get the asset contract address from the vault
        address assetContractAddress = IAbstractCoinVault(erc1155VaultAddress)
            .getAssetContractAddress();

        // Transfer the ERC1155 tokens from the user to the vault
        IERC1155(assetContractAddress).safeTransferFrom(
            msg.sender,
            erc1155VaultAddress,
            tokenId,
            amountOrOne,
            data
        );

        // Prepare deposit parameters
        uint256[] memory depositParams = new uint256[](4);
        depositParams[0] = amountOrOne;
        depositParams[1] = tokenId;
        depositParams[2] = publicKey;
        depositParams[3] = salt;

        // Call the vault's deposit function
        bool success = IAbstractCoinVault(erc1155VaultAddress).deposit(depositParams);
        require(success, 'Erc1155 deposit failed');

        // Communication with the Private Network Hub
        _dvpTeleport.ercDvpBalanceUpdated(encryptedBalanceUpdate);

        return true;
    }

    function withdrawEnygma(
        uint256 vaultId,
        IDvp.ProofReceipt memory _tx
    ) public restricted returns (bool) {
        // Get the Enygma vault using the provided vaultId
        address enygmaVaultAddress = _coinVaultAddressById[vaultId];
        require(enygmaVaultAddress != address(0), 'Enygma vault not registered');

        // Call the vault's withdraw function with empty params and no recipient
        uint256[] memory emptyParams = new uint256[](0);
        bool success = IAbstractCoinVault(enygmaVaultAddress).withdraw(
            emptyParams,
            address(0),
            _tx
        );
        require(success, 'Enygma withdraw failed');

        return true;
    }

    function withdrawERC721(
        address contractAddress,
        uint256 nftId,
        address recipient,
        uint256 salt,
        IDvp.ProofReceipt memory proofTx,
        bytes calldata encryptedBalanceUpdate
    ) public nonReentrant returns (bool) {
        // Get the vaultId from the contract address
        uint256 vaultId = getVaultIdByAddress(contractAddress);

        // Get the vault using the vaultId
        address erc721VaultAddress = _coinVaultAddressById[vaultId];
        require(erc721VaultAddress != address(0), 'Erc721 vault not registered');

        // Call the vault's withdraw function with amount = 1
        uint256[] memory withdrawParams = new uint256[](3);
        withdrawParams[0] = 1;
        withdrawParams[1] = nftId;
        withdrawParams[2] = salt;
        bool success = IAbstractCoinVault(erc721VaultAddress).withdraw(
            withdrawParams,
            recipient,
            proofTx
        );
        require(success, 'Erc721 withdraw failed');

        _dvpTeleport.ercDvpBalanceUpdated(encryptedBalanceUpdate);

        return true;
    }

    function withdrawERC1155(
        address contractAddress,
        uint256 tokenId,
        uint256 amount,
        address recipient,
        uint256 salt,
        IDvp.ProofReceipt memory proofTx,
        bytes calldata encryptedBalanceUpdate
    ) public nonReentrant returns (bool) {
        // Get the vaultId from the contract address
        uint256 vaultId = getVaultIdByAddress(contractAddress);

        // Get the vault using the vaultId
        address erc1155VaultAddress = _coinVaultAddressById[vaultId];
        require(erc1155VaultAddress != address(0), 'Erc1155 vault not registered');

        // Call the vault's withdraw function with the specified amount
        uint256[] memory withdrawParams = new uint256[](3);
        withdrawParams[0] = amount;
        withdrawParams[1] = tokenId;
        withdrawParams[2] = salt;
        bool success = IAbstractCoinVault(erc1155VaultAddress).withdraw(
            withdrawParams,
            recipient,
            proofTx
        );
        require(success, 'Erc1155 withdraw failed');

        _dvpTeleport.ercDvpBalanceUpdated(encryptedBalanceUpdate);

        return true;
    }

    ///////////////////////////////////////////////
    //          Swap/exchange/mix functions
    //////////////////////////////////////////////

    // Internal helper function for mixing/consolidating funds
    function _mixFundsInternal(
        uint256 vaultId,
        IDvp.ProofReceipt memory _tx,
        string memory errorMessage
    ) internal returns (bool) {
        address vaultAddress = _coinVaultAddressById[vaultId];
        require(vaultAddress != address(0), 'Vault not registered');

        // Call the transfer function from the vault
        bool success = IAbstractCoinVault(vaultAddress).transfer(_tx);
        require(success, errorMessage);

        return true;
    }

    // Mixing up to 10 Enygma coins in 2 output coins
    function mixFunds(
        uint256 vaultId,
        IDvp.ProofReceipt memory _tx
    ) public restricted returns (bool) {
        return _mixFundsInternal(vaultId, _tx, 'Enygma mix funds failed');
    }

    // Mixing/consolidating ERC1155 coins
    // No role restriction: ZK proof verification in Erc1155CoinVault.transfer() provides security.
    // Unlike Enygma (which uses EnygmaDvpIntegration as intermediary with DEFAULT_ENYGMA_ROLE),
    // ERC1155 operations are called directly by the relayer with CTS-generated keys.
    // Consistent with depositERC1155() and withdrawERC1155() which are also public.
    function mixFundsERC1155(
        address contractAddress,
        IDvp.ProofReceipt memory _tx
    ) public nonReentrant returns (bool) {
        uint256 vaultId = getVaultIdByAddress(contractAddress);
        return _mixFundsInternal(vaultId, _tx, 'ERC1155 mix funds failed');
    }

    function _settleOnGroupPair(
        ProofReceipt memory receipt1,
        ProofReceipt memory receipt2,
        uint256 vaultId1,
        uint256 vaultId2,
        uint256 groupId1,
        uint256 groupId2
    ) internal returns (bool) {
         //-----------------------
        // [[VERIFICATION]]
        //-----------------------

         // Validate cross-receipt message matching
        if (receipt1.message != receipt2.commitments[0]) {
            revert Dvp__InvalidPaymentMessage();
        }
        if (receipt2.message != receipt1.commitments[0]) {
            revert Dvp__InvalidDeliveryMessage();
        }

         // asserting item proof shows that item belongs to group1
        if (!IAssetGroup(_assetGroups[groupId1]).isMemberFromProofReceipt(vaultId1, receipt1)) {
            revert GroupMembershipMismatch();
        }

        // receipt1 (initiator) was already verified via checkReceiptConditions in initiateSwap

        // asserting item proof shows that item belongs to group2
        if (!IAssetGroup(_assetGroups[groupId2]).isMemberFromProofReceipt(vaultId2, receipt2)) {
            revert GroupMembershipMismatch();
        }

        // checking other conditions of the delivery vault
        IAbstractCoinVault(_coinVaultAddressById[vaultId2]).checkReceiptConditions(receipt2);

         //-----------------------
        // [[SETTLEMENT]]
        //-----------------------

        // inserting payment commitments into payment vault
        IAbstractCoinVault(_coinVaultAddressById[vaultId1]).insertCommitmentsFromReceipt(receipt1);
        // inserting delivery commitments into delivery vault
        IAbstractCoinVault(_coinVaultAddressById[vaultId2]).insertCommitmentsFromReceipt(receipt2);

        // Nullifying the old coins
        IAbstractCoinVault(_coinVaultAddressById[vaultId2]).nullifyFromReceipt(receipt2);
        IAbstractCoinVault(_coinVaultAddressById[vaultId1]).nullifyFromReceipt(receipt1);

        emit Settled(receipt2.message, receipt1.message);

        return true;
    }

    ///////////////////////////////////////////////

    //From now on these are not implemented in the product yet

    ///////////////////////////////////////////////

    function _proofType(ProofReceipt memory receipt) internal pure returns (uint256) {
        uint256 numberOfInputs = receipt.nullifiers.length;
        uint256 numberOfOutputs = receipt.commitments.length;

        uint256 expectedBatchSize = 1 + 6 * numberOfInputs;
        uint256 expectedNormalSize = 3 + 3 * numberOfInputs + numberOfOutputs;
        uint256 expectedBrokerSize = 5 + 3 * numberOfInputs + numberOfOutputs;

        // TODO:: needs audit, not secure
        if (receipt.treeNumbers.length == expectedNormalSize) {
            return 1;
        } else if (receipt.treeNumbers.length == expectedBatchSize) {
            return 2;
        } else if (receipt.treeNumbers.length == expectedBrokerSize) {
            return 3;
        }

        revert Dvp__InvalidStatementSize();
    }

    ///////////////////////////////////////////////
    //          Auction functions
    //////////////////////////////////////////////
    //Do it in another contract?

    // Index of verification keys that has been
    // used directly in ZkdDvp
    uint256 public constant VK_ID_AUCTION_INIT = 6;
    uint256 public constant VK_ID_AUCTION_BID = 7;
    uint256 public constant VK_ID_AUCTION_PRIVATE_OPENING = 8;
    uint256 public constant VK_ID_AUCTION_NOT_WINNING_BID = 9;
    uint256 public constant VK_ID_BROKER_REGISTRATION = 11;
    uint256 public constant VK_ID_LEGIT_BROKER = 12;

    mapping(uint256 => AuctionData) private _auctions;

    function registerZkAuction(
        address zkAuctionContractAddress
    ) public restricted returns (bool) {
        _zkAuctionContractAddress = zkAuctionContractAddress;

        // initializing the verifier by registering Snark circuits' verification keys.
        // and the genericGroth16 verifier
        IZkAuction(_zkAuctionContractAddress).initializeZkAuction(
            _hashContractAddress,
            _verifierContractAddress
        );

        return true;
    }

    ///////////////////////////////////////////////
    //          Auditor functions
    //////////////////////////////////////////////

    function registerAuditor(
        uint256 auditorOffchainId,
        uint256 auditorGroupId,
        uint256[2] memory auditorPublicKey
    ) public restricted returns (bool) {
        // TODO:: check auditorPublicKey be on curve.

        uint256 auditorOnchainId = uint256(
            keccak256(abi.encodePacked(auditorPublicKey[0], auditorPublicKey[1]))
        );

        // Auditor has not been registered
        if (_registeredAuditors[auditorOnchainId].auditorPublicKey[0] == 0) {
            AuditorData memory newAuditor;
            newAuditor.auditorOffchainId = auditorOffchainId;
            newAuditor.auditorGroupId = auditorGroupId;
            newAuditor.auditorPublicKey = auditorPublicKey;
            _registeredAuditors[auditorOnchainId] = newAuditor;

            emit AuditorRegistered(
                auditorOnchainId,
                auditorOffchainId,
                auditorGroupId,
                auditorPublicKey
            );
        } else {
            revert Dvp__AuditorAlreadyRegistered(auditorOffchainId, auditorGroupId);
        }

        return true;
    }

    function unregisterAuditor(
        uint256 auditorOnchainId
    ) public restricted returns (bool) {
        if (_registeredAuditors[auditorOnchainId].auditorPublicKey[0] == 0) {
            revert AuditorNotRegistered(auditorOnchainId);
        } else {
            delete _registeredAuditors[auditorOnchainId];
            emit AuditorUnregistered(auditorOnchainId);
        }

        return true;
    }

    function isAuditorRegistered(uint256[2] memory publicKey) public view returns (bool) {
        uint256 onchainAuditorId = uint256(keccak256(abi.encodePacked(publicKey[0], publicKey[1])));

        if (_registeredAuditors[onchainAuditorId].auditorPublicKey[0] != 0) {
            return true;
        } else {
            return false;
        }
    }

    ///////////////////////////////////////////////
    //          Broker functions
    //////////////////////////////////////////////

    function registerBroker(ProofReceipt memory brokerRegistrationProof) public restricted returns (bool) {
        checkRegisterBrokerProof(brokerRegistrationProof);

        // For broker registration proof structure:
        // treeNumbers[0] contains vaultId (based on circuit structure)
        uint256 vaultId = brokerRegistrationProof.treeNumbers.length > 0
            ? brokerRegistrationProof.treeNumbers[0]
            : 0;

        // blindedPublicKey is stored after all input arrays
        // unused: uint256 numberOfInputs = brokerRegistrationProof.nullifiers.length;
        // The blinded public key is typically the last commitment or a specific field
        uint256 blindedPublicKey = brokerRegistrationProof.commitments.length > 0
            ? brokerRegistrationProof.commitments[0]
            : 0;

        // Checking the key has not been set
        // TODO:: needs audit
        if (_registeredBrokers[blindedPublicKey].nullifiers.length == 0) {
            _registeredBrokers[blindedPublicKey] = brokerRegistrationProof;

            emit BrokerRegistered(vaultId, blindedPublicKey);
        } else {
            revert Dvp__BrokerAlreadyRegistered();
        }

        return true;
    }

    function checkRegisterBrokerProof(ProofReceipt memory receipt) internal returns (bool) {
        // signal input st_beacon;
        // signal input st_vaultId;
        // signal input st_groupId;
        // signal input st_delegator_treeNumbers[tm_numOfInputs];
        // signal input st_delegator_merkleRoots[tm_numOfInputs];
        // signal input st_delegator_nullifiers[tm_numOfInputs];
        // signal input st_broker_blindedPublicKey;

        // signal input st_assetGroup_treeNumber;
        // signal input st_assetGroup_merkleRoot;

        // TODO:: connect beacon

        uint256 numberOfInputs = receipt.nullifiers.length;
        uint256 numberOfOutputs = receipt.commitments.length;

        if (numberOfInputs < 2) {
            revert InvalidNumberOfInputs();
        }

        if (numberOfOutputs != 0) {
            revert InvalidNumberOfOutputs();
        }

        // For broker registration, vaultId and groupId are in the first tree numbers
        uint256 vaultId = receipt.treeNumbers.length > 0 ? receipt.treeNumbers[0] : 0;
        uint256 groupId = receipt.treeNumbers.length > 1 ? receipt.treeNumbers[1] : 0;

        // asserting item proof shows that item belongs to group1
        if (!IAssetGroup(_assetGroups[groupId]).isMemberFromProofReceipt(vaultId, receipt)) {
            revert GroupMembershipMismatch();
        }

        IAbstractCoinVault(_coinVaultAddressById[vaultId]).checkRegisterBrokerProofConditions(receipt);

        // Build statement array for verification
        uint256[] memory statement = new uint256[](1 + numberOfInputs * 3 + 2);
        statement[0] = receipt.message;
        uint256 idx = 1;
        for (uint256 i = 0; i < numberOfInputs; i++) {
            statement[idx++] = receipt.treeNumbers[i];
        }
        for (uint256 i = 0; i < numberOfInputs; i++) {
            statement[idx++] = receipt.merkleRoots[i];
        }
        for (uint256 i = 0; i < numberOfInputs; i++) {
            statement[idx++] = receipt.nullifiers[i];
        }

        IDvpVerifierAggregator(_verifierContractAddress).verifyBrokerProof(
            VK_ID_BROKER_REGISTRATION,
            receipt.proof,
            statement
        );

        return true;
    }

    function verifyLegitBrokerReceipt(ProofReceipt memory receipt) public nonReentrant returns (bool) {
        uint256 beacon = receipt.message;
        uint256 blindedPublicKey = receipt.treeNumbers.length > 0 ? receipt.treeNumbers[0] : 0;

        // Build statement array for verification
        uint256[] memory statement = new uint256[](2);
        statement[0] = beacon;
        statement[1] = blindedPublicKey;

        IDvpVerifierAggregator(_verifierContractAddress).verifyBrokerProof(
            VK_ID_LEGIT_BROKER,
            receipt.proof,
            statement
        );
        emit LegitBrokerReceipt(beacon, blindedPublicKey);
        return true;
    }

    ///////////////////////////////////////////////
    //          Random oracle functions
    //////////////////////////////////////////////

    // TODO:: this can later check the freshness of the challenge
    // with Random Oracle

    /// @notice Registers a challenge as used ("rotten") to prevent replay attacks in DVP operations.
    /// @dev Only callable by registered CoinVault contracts (Erc20CoinVault, Erc721CoinVault,
    ///      Erc1155CoinVault) which receive DEFAULT_VAULT_ROLE via registerVault().
    ///      Each challenge can only be registered once; subsequent attempts revert with RottenChallenge().
    ///      TODO: this can later check the freshness of the challenge with Random Oracle.
    /// @param challenge_ The unique challenge value to mark as used.
    /// @return True if the challenge was successfully registered.
    function checkAndRegisterChallenge(uint256 challenge_) public restricted returns (bool) {
        bool isRotten = _rottenChallenges[challenge_];

        if (isRotten) {
            revert RottenChallenge();
        }

        // TODO:: Require to check that challenge != valid address

        _rottenChallenges[challenge_] = true;

        return true;
    }

    ///////////////////////////////////////////////
    //          DvP v2 Swap functions
    //////////////////////////////////////////////

    struct SwapData {
        bytes32 sharedId;
        uint256 initiatorVaultId;
        IDvp.SwapProofType initiatorProofType;
        IDvp.ProofReceipt initiatorReceipt;
        uint256 passphrase;
        uint64 expiresAt;
        SwapStatus status;
    }

    mapping(bytes32 dvpId => SwapData) private _swaps;
    mapping(bytes32 sharedId => bytes32 dvpId) private _sharedIdToDvpId;

    error Dvp__SwapAlreadyExists();
    error Dvp__SwapNotFound();
    error Dvp__SwapNotPending();
    error Dvp__SwapNotExpired();
    error Dvp__InvalidRevertCommitment();
    error Dvp__InvalidPassphrase();

    /**
     * @notice Initiates a new DvP swap
     * @dev Extracts commitments and nullifier from the proof receipt.
     *      Locks the initiator's nullifier (not spent yet).
     *      Stores swap data and emits SwapInitiated via DvpTeleport.
     * @param sharedId Unique identifier shared between initiator and responder
     * @param encryptedData AES-GCM encrypted trade data for the responder
     * @param ciphertext ML-KEM encapsulated ciphertext for salt recovery
     * @param tokenAddress The token contract address (resolved to vaultId internally)
     * @param proofType Whether this proof is for the Payment or Delivery side
     * @param proof The ZK proof receipt containing commitments and nullifiers
     * @param validityTime Duration in seconds before the swap expires
     * @param passphrase Poseidon hash commitment used to authorize cancellation
     * @return dvpId The computed DvP identifier
     */
    function initiateSwap(
        bytes32 sharedId,
        bytes calldata encryptedData,
        bytes calldata ciphertext,
        address tokenAddress,
        IDvp.SwapProofType proofType,
        IDvp.ProofReceipt memory proof,
        uint64 validityTime,
        uint256 passphrase
    ) public nonReentrant returns (bytes32 dvpId) {
        // Reject duplicate sharedId early
        if (_sharedIdToDvpId[sharedId] != bytes32(0)) {
            revert Dvp__SwapAlreadyExists();
        }

        // Resolve vault, verify proof, lock nullifier
        uint256 vaultId = getVaultIdByAddress(tokenAddress);
        address vaultAddress = _coinVaultAddressById[vaultId];
        IAbstractCoinVault(vaultAddress).checkReceiptConditions(proof);

        if (proof.revertCommitment == 0) {
            revert Dvp__InvalidRevertCommitment();
        }
        if (passphrase == 0) {
            revert Dvp__InvalidPassphrase();
        }

        for (uint256 i = 0; i < proof.nullifiers.length; i++) {
            IAbstractCoinVault(vaultAddress).lockCoin(proof.treeNumbers[i], proof.nullifiers[i]);
        }

        // Compute dvpId
        dvpId = _computeDvpId(proof.commitments[0], proof.message);

        if (_swaps[dvpId].status != SwapStatus.None) {
            revert Dvp__SwapAlreadyExists();
        }

        SwapData storage swapData = _swaps[dvpId];
        swapData.sharedId = sharedId;
        swapData.initiatorVaultId = vaultId;
        swapData.initiatorProofType = proofType;
        swapData.initiatorReceipt = proof;
        swapData.passphrase = passphrase;
        swapData.expiresAt = uint64(block.timestamp) + validityTime;
        swapData.status = SwapStatus.Pending;

        _sharedIdToDvpId[swapData.sharedId] = dvpId;

        _dvpTeleport.emitSwapInitiated(swapData.sharedId, encryptedData, ciphertext, proof.commitments[0], swapData.expiresAt);

        return dvpId;
    }

    /**
     * @notice Completes a pending DvP swap (called by the responder)
     * @dev If the swap has timed out, reverts the initiator's funds and emits SwapTimedOut.
     *      Otherwise: unlocks initiator's nullifier, then settles via _settleOnGroupPair.
     * @param sharedId The shared identifier of the swap to complete
     * @param tokenAddress The token contract address for the responder's vault
     * @param proofType Whether this proof is for the Payment or Delivery side
     * @param proof The ZK proof receipt from the responder
     */
    function completeSwap(
        bytes32 sharedId,
        address tokenAddress,
        IDvp.SwapProofType proofType,
        IDvp.ProofReceipt memory proof,
        bytes calldata encryptedData
    ) public nonReentrant {
        // Compute dvpId
        bytes32 dvpId = _computeDvpId(proof.message, proof.commitments[0]);
        SwapData storage swapData = _swaps[dvpId];

        if (_sharedIdToDvpId[sharedId] != dvpId) {
            revert Dvp__SwapNotFound();
        }

        if (isSwapExpired(sharedId)) {
            _expireSwap(sharedId);
            return;
        }

        if (swapData.status != SwapStatus.Pending) {
            revert Dvp__SwapNotPending();
        }

        // Resolve responder vault
        uint256 responderVaultId = getVaultIdByAddress(tokenAddress);

        // Unlock initiator's nullifiers so _settleOnGroupPair can nullify them
        for (uint256 i = 0; i < swapData.initiatorReceipt.nullifiers.length; i++) {
            IAbstractCoinVault(_coinVaultAddressById[swapData.initiatorVaultId]).unlockCoin(
                swapData.initiatorReceipt.treeNumbers[i],
                swapData.initiatorReceipt.nullifiers[i]
            );
        }

        // Determine group IDs from proof types
        uint256 initiatorGroupId = _proofTypeToGroupId(swapData.initiatorProofType);
        uint256 responderGroupId = _proofTypeToGroupId(proofType);

        // Update swap state
        swapData.status = SwapStatus.Completed;

        // Settle using existing settlement logic
        _settleOnGroupPair(
            swapData.initiatorReceipt,
            proof,
            swapData.initiatorVaultId,
            responderVaultId,
            initiatorGroupId,
            responderGroupId
        );

        _dvpTeleport.emitSwapCompleted(sharedId, encryptedData);
    }

    /**
     * @notice Computes a unique DvP identifier from two commitment values.
     * @dev The caller controls argument order: initiateSwap passes (commitment, message)
     *      while completeSwap passes (message, commitment), producing the same dvpId
     *      because the initiator's commitment equals the responder's message and vice versa.
     * @param commitment0 The first commitment value.
     * @param commitment1 The second commitment value.
     * @return The computed DvP identifier.
     */
    function _computeDvpId(uint256 commitment0, uint256 commitment1) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(commitment0, commitment1));
    }

    /**
     * @notice Maps a SwapProofType to the corresponding asset group ID
     * @param proofType The proof type (Payment or Delivery)
     * @return groupId The asset group ID (fungibles or non-fungibles)
     */
    function _proofTypeToGroupId(IDvp.SwapProofType proofType) internal pure returns (uint256) {
        if (proofType == IDvp.SwapProofType.Payment) {
            return GROUP_ID_FUNGIBLES;
        }
        return GROUP_ID_NON_FUNGIBLES;
    }

    /**
     * @notice Internal helper to revert initiator's funds
     * @dev Inserts initiatorRevertCommitment into the Merkle tree and
     *      unlocks + nullifies the initiator's locked nullifier.
     */
    function _revertSwap(SwapData storage swapData) internal {
        address initiatorVaultAddress = _coinVaultAddressById[swapData.initiatorVaultId];

        uint256[] memory revertCommitments = new uint256[](1);
        revertCommitments[0] = swapData.initiatorReceipt.revertCommitment;
        IAbstractCoinVault(initiatorVaultAddress).registerCoins(revertCommitments);

        // Unlock and nullify all initiator's locked nullifiers
        for (uint256 i = 0; i < swapData.initiatorReceipt.nullifiers.length; i++) {
            IAbstractCoinVault(initiatorVaultAddress).unlockCoin(
                swapData.initiatorReceipt.treeNumbers[i],
                swapData.initiatorReceipt.nullifiers[i]
            );
            IAbstractCoinVault(initiatorVaultAddress).nullifyCoin(
                swapData.initiatorReceipt.treeNumbers[i],
                swapData.initiatorReceipt.nullifiers[i]
            );
        }
    }

    function isSwapExpired(bytes32 sharedId) public view returns (bool) {
        bytes32 dvpId = _sharedIdToDvpId[sharedId];
        SwapData storage swapData = _swaps[dvpId];

        if (swapData.status == SwapStatus.None) {
            return false;
        }

        return block.timestamp >= swapData.expiresAt;
    }

    /// @dev Internal expiry logic shared by completeSwap and expireSwap,
    ///      avoiding nested nonReentrant calls.
    function _expireSwap(bytes32 sharedId) private {
        bytes32 dvpId = _sharedIdToDvpId[sharedId];
        SwapData storage swapData = _swaps[dvpId];

        if (swapData.status != SwapStatus.Pending) {
            revert Dvp__SwapNotPending();
        }

        swapData.status = SwapStatus.TimedOut;
        _revertSwap(swapData);
        _dvpTeleport.emitSwapTimedOut(sharedId);
    }

    /// @notice Cancels a pending DvP swap and reverts the initiator's funds.
    /// @dev The caller must provide a preimage that, when Poseidon-hashed, matches the
    ///      passphrase stored during initiateSwap. This ensures only the party holding
    ///      the preimage can cancel the swap.
    /// @param sharedId The shared identifier of the swap to cancel.
    /// @param preimage The preimage whose Poseidon hash must equal the stored passphrase.
    function cancelSwap(bytes32 sharedId, uint256 preimage) public nonReentrant {
        bytes32 dvpId = _sharedIdToDvpId[sharedId];
        SwapData storage swapData = _swaps[dvpId];

        if (swapData.status != SwapStatus.Pending) {
            revert Dvp__SwapNotPending();
        }

        uint256 potentialPassphrase = IPoseidonWrapper(_hashContractAddress).poseidon([preimage, preimage]);
        if (potentialPassphrase != swapData.passphrase) {
            revert Dvp__InvalidPassphrase();
        }

        swapData.status = SwapStatus.Cancelled;
        _revertSwap(swapData);
        _dvpTeleport.emitSwapCancelled(sharedId);
    }

    /// @notice Expires a timed-out DvP swap and reverts the initiator's funds.
    /// @dev Can be called by anyone once the swap's validity window has elapsed.
    ///      Reverts if the swap is not expired or not in Pending status.
    /// @param sharedId The shared identifier of the swap to expire.
    function expireSwap(bytes32 sharedId) public nonReentrant {
        if (!isSwapExpired(sharedId)) {
            revert Dvp__SwapNotExpired();
        }
        _expireSwap(sharedId);
    }
}
