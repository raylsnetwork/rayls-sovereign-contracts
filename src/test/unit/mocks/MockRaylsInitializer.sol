// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IRaylsInitializer, RaylsTrustedInit} from "../../../rayls-protocol-sdk/IRaylsInitializer.sol";

/**
 * @title MockRaylsInitializer
 * @notice Test double for IRaylsInitializer. Records the arguments passed to `initialize`
 *         and optionally reverts to simulate a failing initializer.
 */
contract MockRaylsInitializer is IRaylsInitializer {

    bytes public lastUserArgs;
    address public lastEndpoint;
    address public lastRaylsNodeEndpoint;
    address public lastUserGovernance;
    address public lastOwner;
    bytes32 public lastResourceId;
    bool public initialized;

    bool public shouldRevert;
    string public revertReason;

    function setShouldRevert(bool _revert, string calldata _reason) external {
        shouldRevert = _revert;
        revertReason = _reason;
    }

    function initialize(bytes calldata userArgs, RaylsTrustedInit calldata trusted) external override {
        if (shouldRevert) revert(revertReason);
        lastUserArgs       = userArgs;
        lastEndpoint       = trusted.endpoint;
        lastRaylsNodeEndpoint = trusted.raylsNodeEndpoint;
        lastUserGovernance = trusted.userGovernance;
        lastOwner          = trusted.owner;
        lastResourceId     = trusted.resourceId;
        initialized        = true;
    }
}
