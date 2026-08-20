// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RNMessageExecutorV1} from "../../../rayls-node/rayls-privacy-node/RNMessageExecutorV1.sol";
import {RNEndpointV1} from "../../../rayls-node/rayls-privacy-node/RNEndpointV1.sol";
import {
    RaylsNodeMessage,
    RaylsNodeMessageMetadata,
    RaylsNodeNewResourceMetadata,
    RaylsNodeBridgedTransferMetadata
} from "../../../rayls-node/rayls-privacy-node/RNMessageLib.sol";

/**
 * @title Replay Protection - Executor as Single Source of Truth
 * @notice Asserts that cross-chain message replay protection is anchored in
 *         RNMessageExecutorV1.executed and that this guard is sufficient across
 *         the full set of relevant scenarios, including endpoint rotation.
 *
 * PROPERTIES UNDER TEST:
 *   test_A1 - after a successful receivePayload, executor.executed(messageId) is set.
 *   test_A2 - a second delivery of the same messageId via the same endpoint reverts.
 *   test_A3 - a replay attempt with a different destination address but the same
 *             messageId is blocked.
 *   test_A4 - executor.executed survives endpoint rotation: a new endpoint pointed
 *             at the same executor cannot replay messageIds the executor has seen.
 */

/// @dev Benign target for executeMessage calls.
contract BenignTarget {
    uint256 public callCount;
    fallback() external { callCount++; }
}

contract ReplayProtection_ExecutorSingleSourceOfTruth is Test {
    RaylsAccessManagerV1 public manager;
    RNEndpointV1 public endpoint;
    RNMessageExecutorV1 public executor;

    address public owner;

    uint256 constant CURRENT_CHAIN = 1001;
    uint256 constant PUBLIC_CHAIN  = 2002;
    uint256 constant DEST_CHAIN    = 3003;

    function setUp() public {
        owner = address(this);

        // ---- Auth manager ----
        // Test contract is the ADMIN on the manager → admin bypasses all selector
        // role mappings, so we can call `restricted` functions directly.
        RaylsAccessManagerV1 mgrImpl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(
            address(mgrImpl), abi.encodeCall(RaylsAccessManagerV1.initialize, (owner))
        )));
        manager.registerRole("MESSAGE_EXECUTOR");
        manager.registerRole("RELAYER");

        // ---- RNEndpoint + RNExecutor ----
        RNEndpointV1 epImpl = new RNEndpointV1();
        endpoint = RNEndpointV1(address(new ERC1967Proxy(
            address(epImpl),
            abi.encodeWithSelector(RNEndpointV1.initialize.selector, CURRENT_CHAIN, PUBLIC_CHAIN, address(manager))
        )));

        RNMessageExecutorV1 exImpl = new RNMessageExecutorV1();
        executor = RNMessageExecutorV1(address(new ERC1967Proxy(
            address(exImpl),
            abi.encodeWithSelector(RNMessageExecutorV1.initialize.selector, address(manager))
        )));
        executor.setAuthorizedEndpoint(address(endpoint));

        // configureContracts requires non-zero addresses for all deps even when this
        // test only exercises the executor path. Stub the rest with a placeholder.
        address dummy = address(0xDEAD);
        endpoint.configureContracts(address(executor), dummy, dummy, dummy);
    }

    /// @notice Baseline: a successful receivePayload is recorded in the single source of
    ///         truth (RNMessageExecutorV1.executed). Endpoint has no replay state.
    function test_A1_executorIsTheSingleSourceOfTruth() public {
        BenignTarget target = new BenignTarget();
        bytes32 messageId = keccak256("A1-msg");
        // Non-empty arbitrary payload; routes to BenignTarget.fallback() (no selector match).
        RaylsNodeMessage memory m = _nodeMsg(hex"deadbeef");

        endpoint.receivePayload(DEST_CHAIN, address(0xCAFE), address(target), m, messageId);

        assertTrue(executor.executed(messageId), "RNMessageExecutor.executed must be set");
    }

    /// @notice Replay from the SAME endpoint is blocked by the executor-layer guard.
    function test_A2_replayThroughSameEndpointBlockedByExecutor() public {
        BenignTarget target = new BenignTarget();
        bytes32 messageId = keccak256("A2-msg");
        // Non-empty arbitrary payload; routes to BenignTarget.fallback() (no selector match).
        RaylsNodeMessage memory m = _nodeMsg(hex"deadbeef");

        endpoint.receivePayload(DEST_CHAIN, address(0xCAFE), address(target), m, messageId);
        assertEq(target.callCount(), 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                RNMessageExecutorV1.RNMessageExecutorV1__MessageIdAlreadyExecuted.selector,
                messageId
            )
        );
        endpoint.receivePayload(DEST_CHAIN, address(0xCAFE), address(target), m, messageId);
        assertEq(target.callCount(), 1, "No double execution");
    }

    /// @notice Replay is still blocked when the payload target is swapped to a
    ///         different contract address with the same messageId.
    /// @dev An attacker who could influence `_dstAddress` must not be able to bypass
    ///      replay protection by changing the destination alone.
    function test_A3_replayBlockedEvenWithDifferentDestinationAddress() public {
        BenignTarget target1 = new BenignTarget();
        BenignTarget target2 = new BenignTarget();
        bytes32 messageId = keccak256("A3-msg");
        // Non-empty arbitrary payload; routes to BenignTarget.fallback() (no selector match).
        RaylsNodeMessage memory m = _nodeMsg(hex"deadbeef");

        endpoint.receivePayload(DEST_CHAIN, address(0xCAFE), address(target1), m, messageId);
        assertEq(target1.callCount(), 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                RNMessageExecutorV1.RNMessageExecutorV1__MessageIdAlreadyExecuted.selector,
                messageId
            )
        );
        endpoint.receivePayload(DEST_CHAIN, address(0xCAFE), address(target2), m, messageId);
        assertEq(target2.callCount(), 0, "replay must not be possible by redirecting to a different target");
    }

    /// @notice Replay is blocked after an endpoint rotation: a new endpoint pointed
    ///         at the same executor cannot replay messageIds the executor has seen.
    function test_A4_executorBlocksReplayAcrossEndpointRotation() public {
        BenignTarget target = new BenignTarget();
        bytes32 messageId = keccak256("A4-msg");
        // Non-empty arbitrary payload; routes to BenignTarget.fallback() (no selector match).
        RaylsNodeMessage memory m = _nodeMsg(hex"deadbeef");

        endpoint.receivePayload(DEST_CHAIN, address(0xCAFE), address(target), m, messageId);
        assertEq(target.callCount(), 1);

        // Admin rotates: deploy new endpoint, point executor at it.
        RNEndpointV1 newEpImpl = new RNEndpointV1();
        RNEndpointV1 newEndpoint = RNEndpointV1(address(new ERC1967Proxy(
            address(newEpImpl),
            abi.encodeWithSelector(RNEndpointV1.initialize.selector, CURRENT_CHAIN, PUBLIC_CHAIN, address(manager))
        )));
        address dummy = address(0xDEAD);
        newEndpoint.configureContracts(address(executor), dummy, dummy, dummy);
        executor.setAuthorizedEndpoint(address(newEndpoint));

        // Executor remembers the old messageId across the endpoint swap.
        assertTrue(executor.executed(messageId), "executor remembers the old messageId across rotation");

        // Replay via the NEW endpoint is blocked by the executor-layer guard.
        vm.expectRevert(
            abi.encodeWithSelector(
                RNMessageExecutorV1.RNMessageExecutorV1__MessageIdAlreadyExecuted.selector,
                messageId
            )
        );
        newEndpoint.receivePayload(DEST_CHAIN, address(0xCAFE), address(target), m, messageId);
        assertEq(target.callCount(), 1, "executor.executed blocks cross-rotation replay");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _nodeMsg(bytes memory payload) internal pure returns (RaylsNodeMessage memory) {
        RaylsNodeNewResourceMetadata memory emptyRes;
        RaylsNodeBridgedTransferMetadata memory emptyBridge;
        return RaylsNodeMessage({
            messageMetadata: RaylsNodeMessageMetadata({
                nonce: 1,
                newResourceMetadata: emptyRes,
                transferMetadata: emptyBridge,
                revertPayloadData: bytes("")
            }),
            payload: payload
        });
    }
}
