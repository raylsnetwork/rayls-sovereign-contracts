// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IRaylsAppV1TokenRegistry
/// @notice Minimal PN TokenRegistry status surface consumed by RaylsApp guard helpers.
/// @dev Status values are decoded as uint8 to keep the SDK independent from PN registry structs.
interface IRaylsAppV1TokenRegistry {
    /// @notice Returns the local Privacy Node lifecycle status for a token.
    function getPrivacyNodeStatus(address tokenAddress) external view returns (uint8);

    /// @notice Returns the private-hub lifecycle status for a token.
    function getHubStatus(address tokenAddress) external view returns (uint8);

    /// @notice Returns the public-chain lifecycle status for a token.
    function getPublicChainStatus(address tokenAddress) external view returns (uint8);

    /// @notice Returns whether the token may perform private-hub operations.
    function isTokenActiveForHub(address tokenAddress) external view returns (bool);

    /// @notice Returns whether the token may perform public-chain operations.
    function isTokenActiveForPublicChain(address tokenAddress) external view returns (bool);
}
