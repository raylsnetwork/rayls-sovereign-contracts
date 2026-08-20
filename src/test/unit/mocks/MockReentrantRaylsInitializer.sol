// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IRaylsInitializer, RaylsTrustedInit} from "../../../rayls-protocol-sdk/IRaylsInitializer.sol";
import {IRNContractFactoryV1} from "../../../rayls-node/rayls-privacy-node/interfaces/IRNContractFactoryV1.sol";

/**
 * @title MockReentrantRaylsInitializer
 * @notice Test double that re-enters the factory (msg.sender) during `initialize`.
 *         Used to verify that RNContractFactoryV1's nonReentrant modifier catches
 *         re-entrant calls originating from within the deployed handler's initializer.
 */
contract MockReentrantRaylsInitializer is IRaylsInitializer {
    function initialize(bytes calldata userArgs, RaylsTrustedInit calldata trusted) external override {
        // msg.sender here is the factory (it performed the low-level call).
        // Attempting to call deploy() back into the factory must be blocked by nonReentrant.
        bytes memory dummyBytecode = new bytes(1);
        IRNContractFactoryV1(msg.sender).deploy(dummyBytecode, userArgs, trusted.resourceId);
    }
}
