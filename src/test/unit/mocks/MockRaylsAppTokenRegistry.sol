// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IRaylsAppV1TokenRegistry} from "../../../rayls-protocol-sdk/interfaces/IRaylsAppV1TokenRegistry.sol";

/// @dev Configurable stub for IRaylsAppV1TokenRegistry.
///      Defaults: privacyNodeStatus = 2 (AUTHORIZED), hub/publicChain active = true.
///      Tests can override individual fields per-token via setters; overrides are independent.
contract MockRaylsAppTokenRegistry is IRaylsAppV1TokenRegistry {
    uint8 private constant _DEFAULT_STATUS = 2; // AUTHORIZED

    mapping(address => uint8) private _privacyNodeStatus;
    mapping(address => uint8) private _hubStatus;
    mapping(address => uint8) private _publicChainStatus;
    mapping(address => bool)  private _hubActive;
    mapping(address => bool)  private _publicChainActive;

    // Per-field override flags so setting one field doesn't zero out others.
    mapping(address => bool) private _privacyNodeStatusSet;
    mapping(address => bool) private _hubStatusSet;
    mapping(address => bool) private _publicChainStatusSet;
    mapping(address => bool) private _hubActiveSet;
    mapping(address => bool) private _publicChainActiveSet;

    /// @notice Override the mock Privacy Node status for a token.
    /// @param token Token address being configured.
    /// @param status Mock Privacy Node status code to return.
    function setPrivacyNodeStatus(address token, uint8 status) external {
        _privacyNodeStatus[token] = status;
        _privacyNodeStatusSet[token] = true;
    }

    /// @notice Override the mock hub status for a token.
    /// @param token Token address being configured.
    /// @param status Mock hub status code to return.
    function setHubStatus(address token, uint8 status) external {
        _hubStatus[token] = status;
        _hubStatusSet[token] = true;
    }

    /// @notice Override the mock public-chain status for a token.
    /// @param token Token address being configured.
    /// @param status Mock public-chain status code to return.
    function setPublicChainStatus(address token, uint8 status) external {
        _publicChainStatus[token] = status;
        _publicChainStatusSet[token] = true;
    }

    /// @notice Override whether a token is active for private-hub operations.
    /// @param token Token address being configured.
    /// @param active Mock private-hub active flag to return.
    function setHubActive(address token, bool active) external {
        _hubActive[token] = active;
        _hubActiveSet[token] = true;
    }

    /// @notice Override whether a token is active for public-chain operations.
    /// @param token Token address being configured.
    /// @param active Mock public-chain active flag to return.
    function setPublicChainActive(address token, bool active) external {
        _publicChainActive[token] = active;
        _publicChainActiveSet[token] = true;
    }

    /// @notice Return the effective mock Privacy Node status for a token.
    /// @param tokenAddress Token address being queried.
    /// @return Effective Privacy Node status code.
    function getPrivacyNodeStatus(address tokenAddress) external view returns (uint8) {
        return _getPrivacyNodeStatus(tokenAddress);
    }

    /// @dev Shared effective Privacy Node status logic used by direct and active-status queries.
    /// @param tokenAddress Token address being queried.
    /// @return Explicitly configured status, or AUTHORIZED by default.
    function _getPrivacyNodeStatus(address tokenAddress) internal view returns (uint8) {
        if (_privacyNodeStatusSet[tokenAddress]) return _privacyNodeStatus[tokenAddress];
        return _DEFAULT_STATUS;
    }

    /// @notice Return the effective mock hub status for a token.
    /// @param tokenAddress Token address being queried.
    /// @return Explicitly configured hub status, or AUTHORIZED by default.
    function getHubStatus(address tokenAddress) external view returns (uint8) {
        if (_hubStatusSet[tokenAddress]) return _hubStatus[tokenAddress];
        return _DEFAULT_STATUS;
    }

    /// @notice Return the effective mock public-chain status for a token.
    /// @param tokenAddress Token address being queried.
    /// @return Explicitly configured public-chain status, or AUTHORIZED by default.
    function getPublicChainStatus(address tokenAddress) external view returns (uint8) {
        if (_publicChainStatusSet[tokenAddress]) return _publicChainStatus[tokenAddress];
        return _DEFAULT_STATUS;
    }

    /// @notice Return whether the token is active for private-hub operations.
    /// @param tokenAddress Token address being queried.
    /// @return Explicitly configured active flag, or true when the effective PN status is AUTHORIZED.
    function isTokenActiveForHub(address tokenAddress) external view returns (bool) {
        if (_hubActiveSet[tokenAddress]) return _hubActive[tokenAddress];
        return _getPrivacyNodeStatus(tokenAddress) == _DEFAULT_STATUS;
    }

    /// @notice Return whether the token is active for public-chain operations.
    /// @param tokenAddress Token address being queried.
    /// @return Explicitly configured active flag, or true when the effective PN status is AUTHORIZED.
    function isTokenActiveForPublicChain(address tokenAddress) external view returns (bool) {
        if (_publicChainActiveSet[tokenAddress]) return _publicChainActive[tokenAddress];
        return _getPrivacyNodeStatus(tokenAddress) == _DEFAULT_STATUS;
    }
}
