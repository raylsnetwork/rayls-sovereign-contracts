// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "../../../rayls-protocol-sdk/libraries/SharedObjects.sol";

library TokenStructs {
    /// @notice Status controlled by the PN operator / local admin.
    /// @dev FROZEN blocks all token operations regardless of hub or public chain state.
    enum PrivacyNodeStatus {
        UNDEFINED,
        WAITING_APPROVAL,
        AUTHORIZED,
        UNAUTHORIZED,
        FROZEN
    }

    /// @notice Status controlled by the Private Hub via cross-chain callbacks.
    /// @dev FROZEN blocks cross-chain hub operations for this chain only.
    enum HubStatus {
        UNDEFINED,
        WAITING_APPROVAL,
        AUTHORIZED,
        UNAUTHORIZED,
        FROZEN
    }

    /// @notice Status controlled by the relayer / bridge.
    /// @dev FROZEN blocks public chain operations only.
    enum PublicChainStatus {
        UNDEFINED,
        PENDING_DEPLOYMENT,
        DEPLOYED,
        FROZEN,
        DEPRECATED
    }

    /// @notice Identifies which lifecycle layer is being frozen or unfrozen.
    enum FreezeLayer {
        PRIVACY_NODE,
        HUB,
        PUBLIC_CHAIN
    }

    struct Token {
        bytes32 resourceId;
        string name;
        string symbol;
        string uri;
        address tokenAddress;
        address publicTokenAddress;
        uint256 issuerChainId;
        SharedObjects.ErcStandard ercStandard;
        PrivacyNodeStatus privacyNodeStatus;
        HubStatus hubStatus;
        PublicChainStatus publicChainStatus;
        uint256 createdAt;
        uint256 updatedAt;
    }

    struct FrozenToken {
        bytes32 resourceId;
        uint256[] frozenParticipants;
    }
}
