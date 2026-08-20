// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '../libraries/SharedObjects.sol';

struct BalanceUpdate {
    uint256 amount;
    uint256 ercId;
}

event TokenBalanceUpdated(bytes32 resourceId, uint256 issuerChainId, SharedObjects.BalanceUpdateType updateType, BalanceUpdate payload);

enum TokenStatus {
    NEW,
    ACTIVE,
    INACTIVE
}
/**
 * @dev Represents a token registered to the VEN
 */

struct Token {
    bytes32 resourceId;
    string name;
    string symbol;
    uint256 issuerChainId;
    address issuerImplementationAddress; // used to reply the resourceId to issuer
    bool isFungible;
    TokenStatus status;
    uint256 createdAt;
    uint256 updatedAt;
    TokenMetadata metadata;
    SharedObjects.ErcStandard ercStandard;
}

struct FrozenToken {
    bytes32 resourceId;
    uint256[] frozenParticipants;
}

struct TokenMetadata {
    string url;
    uint8 decimals;
}
interface ITokenRegistryV1 {
    event Erc20TokenRegistered(bytes32 resourceId, uint256 indexed issuerChainId, uint256 blockNumber, string name, uint256 initialSupply);
    event Erc721TokenRegistered(bytes32 resourceId, uint256 indexed issuerChainId, uint256 blockNumber, string name, uint256[] initialSupply);
    event Erc1155TokenRegistered(bytes32 resourceId, uint256 indexed issuerChainId, uint256 blockNumber, string name, SharedObjects.ERC1155Supply[] initialSupply);
    event TokenStatusUpdated(uint256 issuerChainId, string name, TokenStatus status);
    event EnygmaTokenFreezed(bytes32 resourceId);
    event EnygmaTokenUnfreezed(bytes32 resourceId);
    event EnygmaTokenRegistered(bytes32 resourceId, uint256 indexed issuerChainId, uint256 blockNumber, string name, uint256 initialSupply);

    function initialize(address _endpoint) external;

    function addToken(SharedObjects.TokenRegistrationData calldata tokenData) external returns (bytes32);

    function updateTokenBalance(uint256 issuerChainId, bytes32 resourceId, SharedObjects.BalanceUpdateType updateType, bytes memory metadata) external;

    function getTokenByResourceId(bytes32 resourceId) external view returns (Token memory);

    function updateStatus(bytes32 resourceId, TokenStatus status) external;

    function freezeToken(bytes32 resourceId, uint256[] calldata chainIds) external;

    function unfreezeToken(bytes32 resourceId, uint256[] memory chainIds) external;

    function broadcastCurrentFrozenResourcesForNewParticipant() external;

    function getAllTokens() external view returns (Token[] memory);

    function updateEnygmaFactory(address _enygmaFactory) external;

    function freezeEnygmaToken(bytes32 resourceId) external;

    function unfreezeEnygmaToken(bytes32 resourceId) external;

    function tokenEnygmaIsFreeze(bytes32 resourceId) external view returns (bool);

    function contractVersion() external pure returns (uint256);
}
