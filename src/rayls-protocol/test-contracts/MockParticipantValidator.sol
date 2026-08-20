// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import '../interfaces/IParticipantValidator.sol';
import '../../privateHub/ParticipantStorage/libraries/ParticipantStructs.sol';

/**
 * @title MockParticipantValidator
 * @dev Mock validator for testing - always passes validation
 */
contract MockParticipantValidator is IParticipantValidator {
    function validateMessageParticipants(uint256, uint256) external pure override {
        // Always passes - no validation
    }

    function validateParticipantStatus(uint256) external pure override {
        // Always passes - no validation
    }

    function getAllParticipants() external pure override returns (ParticipantStructs.Participant[] memory) {
        return new ParticipantStructs.Participant[](0);
    }
}
