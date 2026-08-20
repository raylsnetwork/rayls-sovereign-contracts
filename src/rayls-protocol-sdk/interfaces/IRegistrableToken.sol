// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRegistrableToken
/// @notice Minimal interface implemented by all Rayls token base classes (RaylsApp, RaylsAppV1).
///         Used by the PN TokenRegistry to set the resource ID on a token after PNH approval.
interface IRegistrableToken {
    /// @notice Assigns the resource ID approved by the Private Hub.
    /// @param _resourceId Resource ID assigned to the token.
    function setResourceId(bytes32 _resourceId) external;
}
