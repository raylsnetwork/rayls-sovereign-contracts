// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../../rayls-protocol-sdk/libraries/SharedObjects.sol";

/**
 * @title TokenStructs
 * @dev Library containing all structs and enums used by the TokenRegistry system
 */
library TokenStructs {
    // ========== Enums ==========
    
    enum TokenStatus {
        NEW,
        ACTIVE,
        INACTIVE
    }

    enum FreezeAction {
        UNFREEZE,
        FREEZE
    }

    // ========== Structs ==========
    
    struct Token {
        bytes32 resourceId;
        string name;
        string symbol;
        uint256 issuerChainId;
        address issuerImplementationAddress;
        address pnRegistryAddress;
        address tokenAddress;
        bool isFungible;
        TokenStatus status;
        uint256 createdAt;
        uint256 updatedAt;
        TokenMetadata metadata;
        SharedObjects.ErcStandard ercStandard;
    }

    struct TokenMetadata {
        string url;
        uint8 decimals;
    }

    struct BalanceUpdate {
        uint256 amount;
        uint256 ercId;
    }

    struct FrozenToken {
        bytes32 resourceId;
        uint256[] frozenParticipants;
    }
} 
