// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../../rayls-protocol/test-contracts/EnygmaTokenExample.sol";
import "../mocks/MockEndpointForSecurityTest.sol";
import {RaylsEnygmaHandler} from "../../../rayls-protocol-sdk/tokens/RaylsEnygmaHandler.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {Constants} from "../../../rayls-protocol-sdk/Constants.sol";
import {SharedObjects} from "../../../rayls-protocol-sdk/libraries/SharedObjects.sol";
import {MockRaylsAppTokenRegistry} from "../mocks/MockRaylsAppTokenRegistry.sol";

/**
 * @title MockEnygmaPNEvents
 * @notice Minimal mock that accepts all IEnygmaPNEvents calls without reverting.
 *         Records the number of `sendTransferPNH` and `revertMint` invocations so
 *         tests can assert the contract-level idempotency guards short-circuited
 *         duplicate calls.
 */
contract MockEnygmaPNEvents {
    uint256 public sendTransferPNHCount;
    uint256 public revertMintCount;
    uint256 public mintCount;
    uint256 public anyCount;

    /// @dev Catch-all: real selectors are routed here when no specific function matches.
    fallback() external {
        anyCount++;
        bytes4 sel;
        assembly {
            sel := calldataload(0)
        }
        // sendTransferPNH(((bytes32,uint256[],uint256[],address[],...))) — match by selector prefix
        // revertMint(bytes32,uint256,address,string)
        // mint(bytes32,address,uint256)
        // We can't easily compute selectors at runtime cheaply, so rely on the typed funcs below
        // when ABI matches; the fallback is just the safety net.
    }

    function sendTransferPNH(SharedObjects.PNHTransfer calldata) external {
        sendTransferPNHCount++;
    }

    function revertMint(bytes32, uint256, address, string calldata) external {
        revertMintCount++;
    }

    function mint(bytes32, address, uint256) external {
        mintCount++;
    }
}

/**
 * @title Unit Test: RaylsEnygmaHandler per-event idempotency (issue #75)
 * @notice Verifies that `crossMint`, `crossRevertMint`, and `crossTransferRevertBatch` each
 *         short-circuit on the SECOND call with the same `_referenceId`. The protocol-level
 *         guards are defense-in-depth against relayer crash-retry inflation.
 *
 * Test contract: PRE-FIX (story/75 head) these tests FAIL:
 *   - `testCrossMint_secondCallSameRefId_isNoOp` — current code mints twice
 *   - `testCrossTransferRevertBatch_secondCallSameRefId_isNoOp` — current code emits twice
 *   - `testCrossMint_refIdAlreadyReverted_isNoOp` — current code mints despite REVERTED status
 *   - `testCrossRevertMint_secondCallSameRefId_isNoOp` — COMPILE ERROR today (4-arg signature
 *     and REVERTED enum value don't exist yet); written against the target shape
 *   - `testReferenceIdStatus_REVERTED_isReadable` — COMPILE ERROR today (no REVERTED value)
 *
 * After Step 2 of the plan they PASS.
 */
contract RaylsEnygmaHandlerIdempotencyTest is Test {
    EnygmaTokenExample public token;
    MockEndpointForSecurityTest public mockEndpoint;
    MockEnygmaPNEvents public mockPNEvents;
    RaylsAccessManagerV1 public manager;

    address public owner;
    address public relayer;
    address public recipient;
    address public attacker;

    uint64 public relayerRoleId;

    uint256 constant CHAIN_ID = 12345;
    uint256 constant PRIVATE_HUB_ID = 99999;
    uint256 constant OTHER_CHAIN_ID = 67890; // for crossTransferRevertBatch (must != endpoint chainId)
    uint256 constant MINT_AMOUNT = 100 ether;
    bytes32 constant REF_ID_A = keccak256("ref-A");
    bytes32 constant REF_ID_B = keccak256("ref-B");

    function setUp() public {
        owner = address(this);
        relayer = makeAddr("relayer");
        recipient = makeAddr("recipient");
        attacker = makeAddr("attacker");

        // Deploy AccessManager via proxy
        RaylsAccessManagerV1 impl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(
            address(impl), abi.encodeCall(RaylsAccessManagerV1.initialize, (owner))
        )));

        // Register roles and grant RELAYER to our relayer EOA
        relayerRoleId = manager.registerRole("RELAYER");
        manager.registerRole("MESSAGE_EXECUTOR");
        manager.grantRole(relayerRoleId, relayer, 0);

        // Deploy endpoint with authority wired BEFORE token construction — the token's
        // `_registerAccessControl` (called from the parent constructor) reads
        // `endpoint.authority()` to wire RELAYER-gated selectors to the manager.
        mockEndpoint = new MockEndpointForSecurityTest(CHAIN_ID, PRIVATE_HUB_ID);
        mockEndpoint.setTrustedExecutor(owner);
        mockEndpoint.setAuthority(address(manager));

        // Register PN-events mock at the well-known resource id so crossRevertMint and
        // crossTransferRevertBatch don't revert on the events call.
        mockPNEvents = new MockEnygmaPNEvents();
        mockEndpoint.registerResourceId(
            Constants.RESOURCE_ID_ENYGMA_PN_EVENTS,
            address(mockPNEvents)
        );

        // Register the PN token registry so `_requireHubActive` can resolve it, then
        // activate the token by assigning a non-zero resourceId (as the registry).
        MockRaylsAppTokenRegistry registry = new MockRaylsAppTokenRegistry();
        mockEndpoint.registerResourceId(Constants.RESOURCE_ID_TOKEN_REGISTRY, address(registry));

        token = new EnygmaTokenExample("TestEnygma", "TENYG", address(mockEndpoint));

        vm.prank(address(registry));
        token.setResourceId(bytes32(uint256(1)));
    }

    // =========================================================================
    // crossMint idempotency (Fix 2)
    // =========================================================================

    /// @notice Second `crossMintStandard` with the same `_referenceId` MUST be a silent no-op.
    /// @dev PRE-FIX: current code mints twice (200 ether). POST-FIX: 100 ether.
    function testCrossMintStandard_secondCallSameRefId_isNoOp() public {
        vm.prank(relayer);
        token.crossMintStandard(recipient, MINT_AMOUNT, REF_ID_A);

        // First call should have minted exactly MINT_AMOUNT.
        assertEq(token.totalSupply(), MINT_AMOUNT, "first crossMintStandard should mint exactly once");
        assertEq(token.balanceOf(recipient), MINT_AMOUNT, "recipient should hold the mint");

        // Second call with the SAME referenceId — must short-circuit (no second mint).
        vm.prank(relayer);
        token.crossMintStandard(recipient, MINT_AMOUNT, REF_ID_A);

        assertEq(
            token.totalSupply(),
            MINT_AMOUNT,
            "duplicate referenceId must not double-mint (inflation)"
        );
        assertEq(
            token.balanceOf(recipient),
            MINT_AMOUNT,
            "recipient balance must not double-mint (inflation)"
        );
    }

    /// @notice A fresh `_referenceId` after a prior call must still mint normally.
    function testCrossMintStandard_newRefId_mintsNormally() public {
        vm.startPrank(relayer);
        token.crossMintStandard(recipient, MINT_AMOUNT, REF_ID_A);
        token.crossMintStandard(recipient, MINT_AMOUNT, REF_ID_B);
        vm.stopPrank();

        assertEq(token.totalSupply(), MINT_AMOUNT * 2, "distinct referenceIds must mint independently");
        assertEq(token.balanceOf(recipient), MINT_AMOUNT * 2, "recipient should hold both mints");
    }

    /// @notice `referenceIdsStatus` is set to RECEIVED after a successful crossMintStandard.
    function testCrossMintStandard_setsReferenceIdStatusReceived() public {
        vm.prank(relayer);
        token.crossMintStandard(recipient, MINT_AMOUNT, REF_ID_A);

        assertEq(
            token.referenceIdStatusUint(REF_ID_A),
            uint256(RaylsEnygmaHandler.ReferenceIdStatus.RECEIVED),
            "first crossMintStandard should record RECEIVED on the referenceId"
        );
    }

    // =========================================================================
    // crossTransferRevertBatch idempotency (Fix 3)
    // =========================================================================

    /// @notice Second `crossTransferRevertBatch` with the same `_referenceId` MUST be a no-op
    ///         (no second PN-events emission, no double accounting).
    /// @dev PRE-FIX: PN events `sendTransferPNH` fires twice. POST-FIX: once.
    function testCrossTransferRevertBatch_secondCallSameRefId_isNoOp() public {
        vm.prank(relayer);
        token.crossTransferRevertBatch(
            recipient,
            recipient,
            MINT_AMOUNT,
            OTHER_CHAIN_ID,
            REF_ID_A
        );

        assertEq(
            mockPNEvents.sendTransferPNHCount(),
            1,
            "first revertBatch should fire sendTransferPNH once"
        );

        vm.prank(relayer);
        token.crossTransferRevertBatch(
            recipient,
            recipient,
            MINT_AMOUNT,
            OTHER_CHAIN_ID,
            REF_ID_A
        );

        assertEq(
            mockPNEvents.sendTransferPNHCount(),
            1,
            "duplicate referenceId must not double-emit (inflation on revert path)"
        );
    }

    // =========================================================================
    // crossRevertMint idempotency + ABI shape (Fix 4)
    // =========================================================================

    /// @notice Second `crossRevertMint` with the same `_referenceId` MUST be a no-op.
    /// @dev Pre-Step-2 this test fails to COMPILE — `crossRevertMint` still has the 3-arg
    ///      signature. Written against the target 4-arg shape so it compiles after Step 2.
    function testCrossRevertMint_secondCallSameRefId_isNoOp() public {
        vm.prank(relayer);
        token.crossRevertMint(recipient, MINT_AMOUNT, "reason", REF_ID_A);

        assertEq(
            token.totalSupply(),
            MINT_AMOUNT,
            "first crossRevertMint should mint exactly once"
        );
        assertEq(
            mockPNEvents.revertMintCount(),
            1,
            "first crossRevertMint should fire revertMint once"
        );

        vm.prank(relayer);
        token.crossRevertMint(recipient, MINT_AMOUNT, "reason", REF_ID_A);

        assertEq(
            token.totalSupply(),
            MINT_AMOUNT,
            "duplicate referenceId must not double-revert-mint (inflation on revert)"
        );
        assertEq(
            mockPNEvents.revertMintCount(),
            1,
            "duplicate referenceId must not double-emit revertMint"
        );
    }

    /// @notice After `crossRevertMint`, status MUST be REVERTED (new enum value from Fix 4).
    /// @dev Pre-Step-2: COMPILE ERROR (no REVERTED enum value). Locks the enum shape.
    function testReferenceIdStatus_REVERTED_isReadable() public {
        vm.prank(relayer);
        token.crossRevertMint(recipient, MINT_AMOUNT, "reason", REF_ID_A);

        assertEq(
            token.referenceIdStatusUint(REF_ID_A),
            uint256(RaylsEnygmaHandler.ReferenceIdStatus.REVERTED),
            "crossRevertMint should mark the referenceId as REVERTED"
        );
    }

    // =========================================================================
    // Terminal-status cross-protection (Fixes 2 + 4 together)
    // =========================================================================

    /// @notice A referenceId already in REVERTED state must not accept a fresh crossMint.
    /// @dev Defense-in-depth: protects against an out-of-order delivery where a revert is
    ///      observed first and then a stale forward arrives.
    function testCrossMintStandard_refIdAlreadyReverted_isNoOp() public {
        // Revert first under REF_ID_A.
        vm.prank(relayer);
        token.crossRevertMint(recipient, MINT_AMOUNT, "reason", REF_ID_A);

        uint256 supplyAfterRevert = token.totalSupply();

        // Now attempt crossMintStandard with the SAME referenceId — must short-circuit.
        vm.prank(relayer);
        token.crossMintStandard(recipient, MINT_AMOUNT, REF_ID_A);

        assertEq(
            token.totalSupply(),
            supplyAfterRevert,
            "crossMintStandard on an already-REVERTED referenceId must be a no-op"
        );
    }

    /// @notice A referenceId already in RECEIVED state must not accept a fresh crossRevertMint.
    /// @dev Mirror of `testCrossMint_refIdAlreadyReverted_isNoOp` — defense-in-depth against a
    ///      misrouted forward (sets RECEIVED) followed by a revert that would otherwise re-mint
    ///      the same value (PR #247 round-18 review, Low #1).
    function testCrossRevertMint_refIdAlreadyReceived_isNoOp() public {
        // Forward first under REF_ID_A — sets status to RECEIVED.
        vm.prank(relayer);
        token.crossMintStandard(recipient, MINT_AMOUNT, REF_ID_A);

        uint256 supplyAfterMint = token.totalSupply();
        uint256 revertMintCountBefore = mockPNEvents.revertMintCount();

        assertEq(
            token.referenceIdStatusUint(REF_ID_A),
            uint256(RaylsEnygmaHandler.ReferenceIdStatus.RECEIVED),
            "precondition: crossMint should have marked RECEIVED"
        );

        // Now attempt crossRevertMint with the SAME referenceId — must short-circuit.
        vm.prank(relayer);
        token.crossRevertMint(recipient, MINT_AMOUNT, "reason", REF_ID_A);

        assertEq(
            token.totalSupply(),
            supplyAfterMint,
            "crossRevertMint on an already-RECEIVED referenceId must not re-mint"
        );
        assertEq(
            mockPNEvents.revertMintCount(),
            revertMintCountBefore,
            "crossRevertMint on an already-RECEIVED referenceId must not emit revertMint"
        );
        assertEq(
            token.referenceIdStatusUint(REF_ID_A),
            uint256(RaylsEnygmaHandler.ReferenceIdStatus.RECEIVED),
            "terminal status RECEIVED must not be overwritten by a late revert"
        );
    }

    // =========================================================================
    // Programmable userBlob crossMint / crossBurn (no referenceId, no guard)
    // =========================================================================
    //
    // These are the gate-approved userBlob entries a composed crossTransfer may
    // target on the token's own resourceId. Unlike crossMintStandard they carry NO referenceId
    // and NO idempotency guard: each dispatch mints/burns unconditionally. Repeated calls must
    // therefore accumulate (the opposite of the settlement path's short-circuit).
    //
    // The origin is conveyed the way the ProgrammabilityExecutor conveys it: appended as a trusted
    // 20-byte calldata tail (read by `_getMsgSenderOnReceiveMethod`). These helpers append that
    // tail so a direct call faithfully exercises the owner-restriction. `expectRevert: true`
    // bubbles the inner revert for negative cases.

    function _crossMintWithOrigin(address to, uint256 value, address origin) internal {
        (bool ok, bytes memory ret) = address(token).call(
            bytes.concat(abi.encodeWithSelector(RaylsEnygmaHandler.crossMint.selector, to, value), bytes20(origin))
        );
        if (!ok) assembly { revert(add(ret, 32), mload(ret)) }
    }

    function _crossBurnWithOrigin(address from, uint256 value, address origin) internal {
        (bool ok, bytes memory ret) = address(token).call(
            bytes.concat(abi.encodeWithSelector(RaylsEnygmaHandler.crossBurn.selector, from, value), bytes20(origin))
        );
        if (!ok) assembly { revert(add(ret, 32), mload(ret)) }
    }

    /// @notice userBlob `crossMint` mints on every call — no referenceId, no short-circuit.
    function testCrossMint_userBlob_mintsEveryCall() public {
        vm.startPrank(relayer);
        // Appended origin tail = owner (this contract), the TOKEN_OWNER scoped to `token` per the
        // constructor-mode self-registration. Required by the in-body owner-restriction.
        _crossMintWithOrigin(recipient, MINT_AMOUNT, owner);
        _crossMintWithOrigin(recipient, MINT_AMOUNT, owner);
        vm.stopPrank();

        assertEq(token.totalSupply(), MINT_AMOUNT * 2, "userBlob crossMint must mint on every call (no guard)");
        assertEq(token.balanceOf(recipient), MINT_AMOUNT * 2, "recipient should hold both mints");
        // NB: this harness never activates the token (resourceId == 0), so the
        // `if (resourceId != 0)` PN-events emission is intentionally skipped here. The
        // activated-token event path is covered by the e2e programmability test.
    }

    /// @notice userBlob `crossMint` is RELAYER-gated — a non-relayer caller is rejected.
    function testCrossMint_userBlob_revertsForNonRelayer() public {
        vm.prank(attacker);
        vm.expectRevert();
        // origin value irrelevant — RELAYER gate rejects before the in-body owner check.
        _crossMintWithOrigin(recipient, MINT_AMOUNT, owner);
    }

    /// @notice userBlob `crossMint` rejects a zero amount.
    function testCrossMint_userBlob_revertsOnZeroAmount() public {
        vm.prank(relayer);
        vm.expectRevert(RaylsEnygmaHandler.RaylsEnygmaHandler__ZeroAmount.selector);
        _crossMintWithOrigin(recipient, 0, owner);
    }

    /// @notice userBlob `crossBurn` burns on every call — no referenceId, no short-circuit.
    function testCrossBurn_userBlob_burnsEveryCall() public {
        // Seed a balance to burn from via the settlement path.
        vm.prank(relayer);
        token.crossMintStandard(recipient, MINT_AMOUNT * 3, REF_ID_A);

        vm.startPrank(relayer);
        _crossBurnWithOrigin(recipient, MINT_AMOUNT, owner);
        _crossBurnWithOrigin(recipient, MINT_AMOUNT, owner);
        vm.stopPrank();

        assertEq(token.totalSupply(), MINT_AMOUNT, "two burns of MINT_AMOUNT must reduce supply by 2x (no guard)");
        assertEq(token.balanceOf(recipient), MINT_AMOUNT, "recipient should be debited both burns");
        // NB: resourceId == 0 in this harness, so the PN-events burn emission is skipped here
        // (same as crossMint above). Activated-token emission is covered by the e2e test.
    }

    /// @notice userBlob `crossBurn` is RELAYER-gated — a non-relayer caller is rejected.
    function testCrossBurn_userBlob_revertsForNonRelayer() public {
        vm.prank(relayer);
        token.crossMintStandard(recipient, MINT_AMOUNT, REF_ID_A);

        vm.prank(attacker);
        vm.expectRevert();
        _crossBurnWithOrigin(recipient, MINT_AMOUNT, owner);
    }

    /// @notice userBlob `crossBurn` rejects a zero amount.
    function testCrossBurn_userBlob_revertsOnZeroAmount() public {
        vm.prank(relayer);
        vm.expectRevert(RaylsEnygmaHandler.RaylsEnygmaHandler__ZeroAmount.selector);
        _crossBurnWithOrigin(recipient, 0, owner);
    }
}
