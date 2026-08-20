// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockDvpTeleport
 * @notice Stub DvpTeleport for unit tests - accepts all calls without reverting
 * @dev Used for testing CoinVault without full DvpTeleport setup
 */
contract MockDvpTeleport {
    // Stub: accept all calls to emitCommitments and emitNullifiers
    function emitCommitments(address, uint256, uint256, uint256[] calldata) external {}
    function emitNullifiers(address, uint256, uint256[] calldata) external {}

}
