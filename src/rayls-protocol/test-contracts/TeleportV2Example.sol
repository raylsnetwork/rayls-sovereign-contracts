// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import '../../rayls-protocol-sdk/libraries/Utils.sol';
import '../../privateHub/Teleport/TeleportV1.sol';

/**
 * @title Teleport
 * @dev Contract for storing privacy node data and related operations.
 * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
 */
contract TeleportV2Example is TeleportV1 {
    ///@dev returns the contract version
    function contractVersion() external pure override returns (uint256) {
        return 2;
    }
}
