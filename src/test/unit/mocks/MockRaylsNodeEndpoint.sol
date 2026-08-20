// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RaylsNodeMessage, RaylsNodeBridgedTransferMetadata} from "../../../rayls-node/rayls-privacy-node/RNMessageLib.sol";
import {IRaylsNodeEndpoint} from "../../../rayls-node/rayls-privacy-node/interfaces/IRaylsNodeEndpoint.sol";

/**
 * @title MockRaylsNodeEndpoint
 * @notice Minimal mock implementing IRaylsNodeEndpoint for factory unit tests.
 *         Only getUserGovernanceAddress() and authority() are functional.
 */
contract MockRaylsNodeEndpoint is IRaylsNodeEndpoint {
    address private _userGovernance;
    address private _authority;

    constructor(address userGovernance_, address authority_) {
        _userGovernance = userGovernance_;
        _authority = authority_;
    }

    function getUserGovernanceAddress() external view override returns (address) {
        return _userGovernance;
    }

    function authority() external view override returns (address) {
        return _authority;
    }

    // ── Stubs ────────────────────────────────────────────────────────────────

    function send(uint256, address, bytes calldata) external pure override returns (bytes32) { return bytes32(0); }

    function sendToAddress(
        uint256,
        address,
        bytes calldata,
        bytes memory,
        RaylsNodeBridgedTransferMetadata memory
    ) external pure override returns (bytes32) { return bytes32(0); }

    function receivePayload(uint256, address, address, RaylsNodeMessage memory, bytes32) external override {}

    function getChainId() external pure override returns (uint256) { return 0; }

    function version() external pure override returns (string memory) { return "mock"; }
}
