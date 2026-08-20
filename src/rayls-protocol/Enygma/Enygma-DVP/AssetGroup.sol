// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.0;

import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {IRaylsAccessManager} from "../../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol";

import {IDvp} from "../../interfaces/IDvp.sol";
import {IAbstractCoinVault} from "../../interfaces/IAbstractCoinVault.sol";
import {IAssetGroup} from "../../interfaces/IAssetGroup.sol";
import {Merkle} from "./Merkle.sol";

contract AssetGroup is IAssetGroup, Merkle, RaylsAccessManaged {

    uint256 constant GROUP_ID_OFFSET = 1000; // first 1000 ids have been reserved for vaults

    // Getting fired whenever a new member is inserted
    // vaultId: the ID of the vault
    // tokenId: the unique identifier of the token
    event MemberInserted(
        uint256 indexed vaultId,
        uint256 indexed tokenId
    );

    // Getting fired Whenever a new commitment
    // is generated and added to on-chain merkleTree
    event MemberRemoved(
        uint256 indexed vaultId, 
        uint256 indexed tokenId
    );

    ///////////////////////////////////////////////
    //           Private attributes
    //////////////////////////////////////////////

    // name identifier for Dvp smart contract
    string internal _name;

    // the address of PoseidonWrapper smart contract
    address internal _hashContractAddress;

    // address of non-generic verifier that pack the proofs
    // and utilizes the generic Gorth16 verifier smart contract
    address internal _verifierContractAddress;

    address internal _dvpContractAddress;

    uint256 internal _assetGroupId;

    bool internal _isFungible;

    mapping(uint256 => bool) internal _vaultMembers;

    function getHashContractAddress() public view returns (address){
        return _hashContractAddress;
    }
    function getVerifierContractAddress() public view returns (address){
        return _verifierContractAddress;
    }

    function getRoot() public view returns (uint256 root) {
        return currentRoot();
    }

    constructor(
        address dvpAddress,
        address authority_
    )
    Merkle()
    {
      _dvpContractAddress = dvpAddress;

      _setAuthority(authority_);

      bytes4[] memory ownerSels = new bytes4[](0);
      bytes4[] memory dvpSels = new bytes4[](3);
      dvpSels[0] = this.initializeAssetGroup.selector;
      dvpSels[1] = this.insertTokenMember.selector;
      dvpSels[2] = this.insertVaultMember.selector;
      IRaylsAccessManager.SelectorRoleMapping[] memory mappings = new IRaylsAccessManager.SelectorRoleMapping[](1);
      mappings[0] = IRaylsAccessManager.SelectorRoleMapping("DVP_CONTRACT", dvpSels);
      IRaylsAccessManager(authority_).selfRegisterManagedContract(msg.sender, ownerSels, mappings);
    }
    
    function initializeAssetGroup(
        uint256 assetGroupId,
        string memory name,
        bool isFungible,
        uint256 treeDepth
    ) public restricted returns  (bool) {
        
        _assetGroupId = assetGroupId;
        _name = name;
        _isFungible = isFungible;

        _hashContractAddress = IDvp(_dvpContractAddress).hashContractAddress();
        _verifierContractAddress = IDvp(_dvpContractAddress).verifierContractAddress();
        
        initializeMerkle(treeDepth, GROUP_ID_OFFSET + _assetGroupId, _hashContractAddress);
        
        return true;

    }

    function isFungible()
    public view returns(bool){
        return _isFungible;
    }

    function isVaultMember(
        uint256 vaultId
    ) public view returns(bool){
        return _vaultMembers[vaultId];
    }

    function isTokenMember(
        uint256 vaultId,
        uint256 assetUniqueId
    ) public view returns (bool){
        return isValidNullifier(0, assetUniqueId);
    }

    function isMemberFromProofReceipt(
        uint256 vaultId,
        IDvp.ProofReceipt memory receipt
    ) public view returns (bool){

        bool isVaultAMember = _vaultMembers[vaultId];

        // The asset group merkle root is stored in the message field
        // as it's a special value that was previously the last element in the statement array
        uint256 assetGroupMerkleRoot = receipt.message;

        // TODO:: connect treeNumber
        bool isTokenAMember = isValidRoot(0, assetGroupMerkleRoot);

        return (isVaultAMember || isTokenAMember);
    }

    function insertTokenMember( // AccessControlled by Dvp
        uint256 vaultId,
        uint256 assetUniqueId
    ) public restricted returns (bool){

        // using zero for treeId
        // using nullifier to check whether the tokenId
        // has been inserted or not.
        if(!isValidNullifier(0, assetUniqueId)){ // if nullifier has not been registered
            uint256[] memory params = new uint256[](1);
            params[0] = assetUniqueId;
            insertLeaves(params);
            setNullifier(0, assetUniqueId);
        }
        else{
            revert TokenAlreadyInserted();
        }

        emit MemberInserted(_assetGroupId , assetUniqueId);
    } 

    function insertVaultMember(
        uint256 vaultId
    ) public restricted returns (bool){
        if(_vaultMembers[vaultId]){
            revert VaultAlreadyInserted();
        }

        _vaultMembers[vaultId] = true;

        return true;
    }

}
