// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import '../interfaces/ITokenRegistryValidator.sol';

/**
 * @title MockTokenValidator
 * @dev Mock validator for testing - always passes validation
 */
contract MockTokenValidator is ITokenRegistryValidator {
    function validateTokenForParticipant(bytes32, uint256) external pure override {
        // Always passes - no validation
    }
}
