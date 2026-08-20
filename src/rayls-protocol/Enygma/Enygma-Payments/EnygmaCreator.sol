// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import './EnygmaV1.sol';

// Struct to avoid stack too deep error
struct EnygmaCreationParams {
    string name;
    string symbol;
    uint8 decimals;
    bytes32 resourceId;
    address owner;
    uint256 ownerChainId;
    address participantStorageContract;
    address endpoint;
    address tokenRegistryContract;
    address enygmaTeleport;
    address factory;
}

contract EnygmaCreator {
    error EnygmaCreatorDeployFailed();
    bytes private _creationCode;

    constructor() {
        _creationCode = type(EnygmaV1).creationCode;
    }

    function createEnygma(
        EnygmaCreationParams calldata params
    ) external returns (address) {
        bytes memory initCode = abi.encodePacked(_creationCode, abi.encode(params));
        address addr;
        assembly {
            addr := create(0, add(initCode, 0x20), mload(initCode))
        }
        if (addr == address(0)) revert EnygmaCreatorDeployFailed();
        return addr;
    }
}