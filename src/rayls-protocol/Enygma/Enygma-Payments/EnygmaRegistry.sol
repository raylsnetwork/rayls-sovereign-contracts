// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {RaylsAccessManaged} from '../../../privateHub/AccessControl/RaylsAccessManaged.sol';

contract EnygmaRegistry is RaylsAccessManaged {
    mapping(bytes32 => address) public resourceIdToEnygma;
    mapping(bytes32 => address) public resourceIdToDvpIntegration;

    mapping(bytes32 => address) private vaultAddresses;
    mapping(bytes32 => address) private merkleAddresses;

    constructor(address _authority) {
        if (_authority != address(0)) _setAuthority(_authority);
    }

    function registerVault(bytes32 resourceId, address vaultAddress) external restricted {
        vaultAddresses[resourceId] = vaultAddress;
    }

    function registerMerkle(bytes32 resourceId, address merkleAddress) external restricted {
        merkleAddresses[resourceId] = merkleAddress;
    }

    function getVaultAddress(bytes32 resourceId) external view returns (address) {
        return vaultAddresses[resourceId];
    }

    function getMerkleAddress(bytes32 resourceId) external view returns (address) {
        return merkleAddresses[resourceId];
    }

    function registerEnygma(bytes32 _resourceId, address _enygmaAddr) external restricted {
        resourceIdToEnygma[_resourceId] = _enygmaAddr;
    }

    function registerDvpIntegration(bytes32 _resourceId, address _integrationAddr) external restricted {
        resourceIdToDvpIntegration[_resourceId] = _integrationAddr;
    }

    function getEnygmaAddress(bytes32 _resourceId) external view returns (address) {
        return resourceIdToEnygma[_resourceId];
    }

    function getDvpIntegrationAddress(bytes32 _resourceId) external view returns (address) {
        return resourceIdToDvpIntegration[_resourceId];
    }
}
