// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library Utils {
    uint64 constant ENYGMA_DVP_SWAP_DEFAULT_VALIDITY_TIME = 2 days;
    uint64 constant ENYGMA_DVP_SWAP_MAX_VALIDITY_TIME = 14 days;
    uint64 constant ENYGMA_DVP_SWAP_MIN_VALIDITY_TIME = 5 hours;


    function addressToBytes32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a) << 96));
    }

    // Enum representing the possible statuses of a message
    enum MessageStatus {
        Pending,
        Executed,
        Rejected,
        Reverted
    }
}
