// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Minimal event emitter used by the audit-suite integration tests
/// in `hardhat/test/unit/audit-integration.ts`. Mirrors the shape of the
/// AccessManager's `FunctionAllowedRoleAdded` / `FunctionAllowedRoleRemoved`
/// events (same indexed-topic layout) so the tests can exercise
/// `fetchLogsChunked` + event replay end-to-end without bringing up the
/// full RaylsAccessManagerV1 (which has heavy library dependencies).
///
/// Not deployed in production; not used outside the test suite.
contract AuditEventEmitter {
    /// @dev Same indexed-topic shape as
    /// `AccessManagerRoleConfigLib.FunctionAllowedRoleAdded`. Allows tests
    /// to drive the audit's event-replay code path with realistic topics.
    event FunctionAllowedRoleAdded(
        address indexed managedContract,
        bytes4 indexed selector,
        uint64 indexed roleId
    );

    event FunctionAllowedRoleRemoved(
        address indexed managedContract,
        bytes4 indexed selector,
        uint64 indexed roleId
    );

    function emitAdded(address managedContract, bytes4 selector, uint64 roleId) external {
        emit FunctionAllowedRoleAdded(managedContract, selector, roleId);
    }

    function emitRemoved(address managedContract, bytes4 selector, uint64 roleId) external {
        emit FunctionAllowedRoleRemoved(managedContract, selector, roleId);
    }
}
