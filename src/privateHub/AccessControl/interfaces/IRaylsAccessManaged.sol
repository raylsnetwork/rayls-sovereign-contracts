// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IRaylsAccessManaged
/// @notice Minimal interface exposed by consumer contracts that integrate with RaylsAccessManagerV1.
interface IRaylsAccessManaged {
    /// @notice Returns the address of the authority (RaylsAccessManagerV1) governing this contract.
    function authority() external view returns (address);
}
