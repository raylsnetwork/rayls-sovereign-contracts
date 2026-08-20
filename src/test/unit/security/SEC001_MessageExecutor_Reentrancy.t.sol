// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RNMessageExecutorV1} from "../../../rayls-node/rayls-privacy-node/RNMessageExecutorV1.sol";
import {RNMessageLib} from "../../../rayls-node/rayls-privacy-node/RNMessageLib.sol";

/**
 * @title IReentrancyCallback
 * @notice Interface for the test contract to receive re-entry requests from malicious targets.
 */
interface IReentrancyCallback {
    function reentrantExecuteMessage(address target, bytes32 messageId) external;
    function reentrantExecuteMessageBatch(address target, bytes32 messageId) external;
}

/**
 * @title ReentrantTarget
 * @notice Malicious contract that re-enters executeMessage() via the endpoint (callback).
 *         The target calls back to the test contract (which IS the authorized endpoint),
 *         which then calls executeMessage() again. This simulates the real attack vector
 *         where a cross-chain message target routes re-entry through the endpoint.
 */
contract ReentrantTarget {
    address public callbackEndpoint;
    uint256 public callCount;
    bytes32 public reentrantMessageId;

    constructor(address _callbackEndpoint) {
        callbackEndpoint = _callbackEndpoint;
    }

    function setReentrantParams(bytes32 _messageId) external {
        reentrantMessageId = _messageId;
    }

    fallback() external {
        callCount++;
        if (callCount == 1) {
            // Re-enter via the endpoint (authorized caller)
            IReentrancyCallback(callbackEndpoint).reentrantExecuteMessage(
                address(this),
                reentrantMessageId
            );
        }
    }
}

/**
 * @title ReentrantBatchTarget
 * @notice Malicious contract that re-enters executeMessageBatch() via the endpoint.
 */
contract ReentrantBatchTarget {
    address public callbackEndpoint;
    uint256 public callCount;
    bytes32 public reentrantMessageId;

    constructor(address _callbackEndpoint) {
        callbackEndpoint = _callbackEndpoint;
    }

    function setReentrantParams(bytes32 _messageId) external {
        reentrantMessageId = _messageId;
    }

    fallback() external {
        callCount++;
        if (callCount == 1) {
            IReentrancyCallback(callbackEndpoint).reentrantExecuteMessageBatch(
                address(this),
                reentrantMessageId
            );
        }
    }
}

/**
 * @title BenignTarget
 * @notice Simple contract that just records calls, used for normal execution tests.
 */
contract BenignTarget {
    uint256 public callCount;

    fallback() external {
        callCount++;
    }
}

/**
 * @title SEC-001: Message Executor Reentrancy Test
 * @notice Tests that demonstrate reentrancy vulnerability in RNMessageExecutorV1.
 *
 * The attack vector: executeMessage() and executeMessageBatch() forward arbitrary
 * calldata to external contracts via .call(). A malicious target can re-enter
 * the executor with a different messageId, bypassing replay protection.
 *
 * TEST BEHAVIOR:
 * - "reproduces vulnerability" tests FAIL when vulnerability is present, PASS after fix
 * - "normal operation" tests should always PASS
 */
contract SEC001_MessageExecutor_ReentrancyTest is Test, IReentrancyCallback {

    RNMessageExecutorV1 public executorImpl;
    RNMessageExecutorV1 public executor;
    address public owner;

    uint256 constant SRC_CHAIN_ID = 1000;
    address constant SENDER = address(0xBEEF);

    function setUp() public {
        owner = address(this);

        // Deploy RaylsAccessManagerV1 via proxy
        RaylsAccessManagerV1 mgrImpl = new RaylsAccessManagerV1();
        bytes memory mgrInit = abi.encodeCall(RaylsAccessManagerV1.initialize, (owner));
        RaylsAccessManagerV1 manager = RaylsAccessManagerV1(address(new ERC1967Proxy(address(mgrImpl), mgrInit)));

        // Deploy executor behind UUPS proxy
        executorImpl = new RNMessageExecutorV1();
        bytes memory initData = abi.encodeWithSelector(
            RNMessageExecutorV1.initialize.selector,
            address(manager)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(executorImpl), initData);
        executor = RNMessageExecutorV1(address(proxy));

        // Set THIS TEST CONTRACT as the authorized endpoint.
        // This is critical: the test contract acts as the endpoint so that
        // re-entrant calls routed through it satisfy the onlyEndpoint modifier.
        executor.setAuthorizedEndpoint(address(this));
    }

    // =========================================================================
    // IReentrancyCallback implementation
    // The malicious target calls these to route re-entry through the "endpoint"
    // =========================================================================

    function reentrantExecuteMessage(address target, bytes32 messageId) external override {
        executor.executeMessage(
            target,
            hex"deadbeef",
            messageId,
            SRC_CHAIN_ID,
            SENDER
        );
    }

    function reentrantExecuteMessageBatch(address target, bytes32 messageId) external override {
        RNMessageLib.Message[] memory msgs = new RNMessageLib.Message[](1);
        msgs[0] = RNMessageLib.Message({
            to: target,
            data: hex"cafebabe"
        });
        executor.executeMessageBatch(
            msgs,
            messageId,
            SRC_CHAIN_ID,
            SENDER
        );
    }

    // =========================================================================
    // Normal operation tests (should always pass)
    // =========================================================================

    function test_SEC001_normal_executeMessage_works() public {
        BenignTarget target = new BenignTarget();
        bytes32 messageId = keccak256("msg1");

        executor.executeMessage(
            address(target),
            abi.encodeWithSignature("fallback()"),
            messageId,
            SRC_CHAIN_ID,
            SENDER
        );

        assertEq(target.callCount(), 1, "Target should have been called once");
        assertTrue(executor.executed(messageId), "Message should be marked as executed");
    }

    function test_SEC001_replay_protection_blocks_same_messageId() public {
        BenignTarget target = new BenignTarget();
        bytes32 messageId = keccak256("msg1");

        executor.executeMessage(
            address(target),
            abi.encodeWithSignature("fallback()"),
            messageId,
            SRC_CHAIN_ID,
            SENDER
        );

        // Replay with same messageId should revert
        vm.expectRevert(
            abi.encodeWithSelector(
                RNMessageExecutorV1.RNMessageExecutorV1__MessageIdAlreadyExecuted.selector,
                messageId
            )
        );
        executor.executeMessage(
            address(target),
            abi.encodeWithSignature("fallback()"),
            messageId,
            SRC_CHAIN_ID,
            SENDER
        );
    }

    // =========================================================================
    // Reentrancy vulnerability tests
    // =========================================================================

    /**
     * @notice Demonstrates reentrancy on executeMessage().
     *
     * Attack flow:
     * 1. Test (acting as endpoint) calls executeMessage(target, data, msgId1, ...)
     * 2. Executor marks msgId1 as executed, then calls target.call(data)
     * 3. Target fallback calls back to test contract via IReentrancyCallback
     * 4. Test contract (endpoint) calls executeMessage(target, data, msgId2, ...)
     * 5. Executor checks msgId2 - not yet executed, so replay check passes
     * 6. Both messages execute = double execution in single tx
     *
     * BEFORE FIX: Re-entrant call succeeds (inner message executed). Test FAILS.
     * AFTER FIX:  Re-entrant call reverts with reentrancy error. Test PASSES.
     */
    function test_SEC001_executeMessage_reentrancy_is_blocked() public {
        // Target calls back to this test contract (the "endpoint") for re-entry
        ReentrantTarget target = new ReentrantTarget(address(this));

        bytes32 outerMessageId = keccak256("outer-msg");
        bytes32 innerMessageId = keccak256("inner-msg");

        target.setReentrantParams(innerMessageId);

        // Execute the outer message. The target will attempt re-entry via callback.
        // Without guard: both messages execute (inner succeeds with different messageId)
        // With guard: inner call reverts -> target reverts -> outer .call() fails -> outer reverts
        bool outerSucceeded = true;
        try executor.executeMessage(
            address(target),
            hex"",
            outerMessageId,
            SRC_CHAIN_ID,
            SENDER
        ) {
            outerSucceeded = true;
        } catch {
            outerSucceeded = false;
        }

        if (outerSucceeded) {
            // Outer succeeded: check that re-entry was blocked
            assertEq(
                target.callCount(), 1,
                "VULNERABILITY: Re-entrant executeMessage succeeded! callCount should be 1 not 2"
            );
            assertFalse(
                executor.executed(innerMessageId),
                "VULNERABILITY: Inner message was executed via reentrancy"
            );
        }

        // Regardless of outer outcome, inner must never have been executed
        assertFalse(
            executor.executed(innerMessageId),
            "Inner messageId should never be executed - reentrancy must be blocked"
        );
    }

    /**
     * @notice Demonstrates reentrancy on executeMessageBatch().
     *
     * BEFORE FIX: Re-entrant batch call succeeds. Test FAILS.
     * AFTER FIX:  Re-entrant call reverts. Test PASSES.
     */
    function test_SEC001_executeMessageBatch_reentrancy_is_blocked() public {
        ReentrantBatchTarget target = new ReentrantBatchTarget(address(this));

        bytes32 outerMessageId = keccak256("outer-batch");
        bytes32 innerMessageId = keccak256("inner-batch");

        target.setReentrantParams(innerMessageId);

        RNMessageLib.Message[] memory msgs = new RNMessageLib.Message[](1);
        msgs[0] = RNMessageLib.Message({
            to: address(target),
            data: hex""
        });

        bool outerSucceeded = true;
        try executor.executeMessageBatch(
            msgs,
            outerMessageId,
            SRC_CHAIN_ID,
            SENDER
        ) {
            outerSucceeded = true;
        } catch {
            outerSucceeded = false;
        }

        if (outerSucceeded) {
            assertEq(
                target.callCount(), 1,
                "VULNERABILITY: Re-entrant executeMessageBatch succeeded"
            );
            assertFalse(
                executor.executed(innerMessageId),
                "VULNERABILITY: Inner batch was executed via reentrancy"
            );
        }

        assertFalse(
            executor.executed(innerMessageId),
            "Inner messageId should never be executed - reentrancy must be blocked"
        );
    }
}
