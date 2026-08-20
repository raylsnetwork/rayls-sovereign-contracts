// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {RaylsAccessManaged} from "../../../../privateHub/AccessControl/RaylsAccessManaged.sol";

/**
 * @title F17_EnygmaFactoryVictim
 * @notice Stand-in for `EnygmaFactory`. Its `initiateEnygmaCreation`
 *         selector is intended to be mapped to `ENYGMA_CREATOR` at the
 *         AccessManager — matching the live mapping at
 *         `hardhat/tasks/deploy/private-hub.ts:280`.
 */
contract F17_EnygmaFactoryVictim is RaylsAccessManaged {
    uint256 public lastInvocationCount;
    address public lastCaller;

    constructor(address authority_) {
        _initializeAuthority(authority_);
    }

    /// Gated by `restricted`; role mapping is added by the test to avoid
    /// pulling in the full EnygmaFactory constructor.
    function initiateEnygmaCreation(uint256 /*tag*/) external restricted {
        lastInvocationCount += 1;
        lastCaller = msg.sender;
    }
}

/**
 * @title F17_DvpTeleportVictim
 * @notice Stand-in for `DvpTeleport`. Its `emitCommitments` selector is
 *         intended to be mapped to `COIN_VAULT` — matching the live mapping
 *         at `hardhat/tasks/deploy/private-hub.ts:304`.
 */
contract F17_DvpTeleportVictim is RaylsAccessManaged {
    uint256 public lastInvocationCount;
    address public lastCaller;

    constructor(address authority_) {
        _initializeAuthority(authority_);
    }

    function emitCommitments(uint256 /*tag*/) external restricted {
        lastInvocationCount += 1;
        lastCaller = msg.sender;
    }
}
