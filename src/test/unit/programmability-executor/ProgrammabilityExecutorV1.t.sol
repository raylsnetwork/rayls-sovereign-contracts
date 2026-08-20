// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RaylsAccessManagerV1}      from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged}        from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {ProgrammabilityExecutorV1} from "../../../rayls-protocol/ProgrammabilityExecutor/ProgrammabilityExecutorV1.sol";
import {SharedObjects}             from "../../../rayls-protocol-sdk/libraries/SharedObjects.sol";

/// @dev Endpoint stub: resolves resourceId → address from a settable map. The executor
///      only calls `getAddressByResourceId` on the endpoint.
contract _StubEndpoint {
    mapping(bytes32 => address) public addrs;
    function set(bytes32 rid, address a) external { addrs[rid] = a; }
    function getAddressByResourceId(bytes32 rid) external view returns (address) { return addrs[rid]; }
}

/// @dev Replica stub: approves `(codehash, selector)` pairs the test explicitly allows. The
///      executor gates via `check` only (the origin is conveyed by a trusted calldata tail, so no
///      parameter count is needed). `checkWithParamCount` is retained to satisfy the interface.
contract _StubReplica {
    mapping(bytes32 => bool) public approved;

    function approve(address target, bytes4 selector) external {
        approved[keccak256(abi.encode(target.codehash, selector))] = true;
    }

    function check(address target, bytes4 selector) external view returns (bool) {
        return approved[keccak256(abi.encode(target.codehash, selector))];
    }

    function checkWithParamCount(address target, bytes4 selector)
        external
        view
        returns (bool, uint256)
    {
        return (approved[keccak256(abi.encode(target.codehash, selector))], 0);
    }
}

/// @dev Reads the attested origin the executor appends as the trusted last 20 calldata bytes,
///      mirroring `RaylsApp._getMsgSenderOnReceiveMethod` for these standalone test targets.
function _originFromTail() pure returns (address tailOrigin) {
    assembly {
        tailOrigin := shr(96, calldataload(sub(calldatasize(), 20)))
    }
}

/// @dev Dispatch target for non-mint program steps. Neither function declares an origin parameter;
///      they read the executor-appended origin tail. `record` stores its value and the origin
///      it saw; `boom` always reverts.
contract _Target {
    uint256 public last;
    uint256 public callCount;
    address public seenOrigin;
    error Boom();

    function record(uint256 v) external {
        last = v;
        callCount++;
        seenOrigin = _originFromTail();
    }
    function boom() external pure { revert Boom(); }
}

/// @dev Mint target exposing the real `crossMintStandard(address,uint256,bytes32)` selector so
///      the executor's conservation accounting (which keys off that selector) is exercised.
///      Records the cumulative minted amount so tests can assert the dispatch happened.
contract _MintTarget {
    uint256 public minted;
    function crossMintStandard(address, uint256 value, bytes32) external { minted += value; }
}

/// @dev A second target with the same ABI but *different runtime bytecode* (extra state),
///      so its `extcodehash` differs from `_Target` — needed to test that approving one
///      bytecode does not implicitly approve another.
contract _OtherTarget {
    uint256 public last;
    uint256 public callCount;
    uint256 private _pad;

    function record(uint256 v) external { last = v; callCount++; _pad = v + 1; }
}

/// @dev Owner-attested target mirroring `crossMint(address,uint256)`. Records the origin it read
///      from the trusted tail, so a test can assert the executor — not the caller — controls it.
///      `owner` is the only address allowed to mint.
contract _AttestedMint {
    address public immutable owner;
    address public seenOrigin;
    uint256 public minted;
    error NotOwner(address who);

    constructor(address _owner) { owner = _owner; }

    function crossMint(address, uint256 value) external {
        address origin = _originFromTail();
        seenOrigin = origin;
        if (origin != owner) revert NotOwner(origin);
        minted += value;
    }
}

/// @dev Owner-attested target with a DYNAMIC parameter, mirroring ERC1155
///      `crossMint(address,uint256,uint256,bytes)`. Exercises that the trusted-tail read lands on
///      the appended origin by absolute calldata offset, regardless of the dynamic `bytes` layout.
contract _AttestedMintDynamic {
    address public immutable owner;
    address public seenOrigin;
    uint256 public minted;
    bytes public seenData;
    error NotOwner(address who);

    constructor(address _owner) { owner = _owner; }

    function crossMint(address, uint256, uint256 value, bytes calldata data)
        external
    {
        address origin = _originFromTail();
        seenOrigin = origin;
        seenData = data;
        if (origin != owner) revert NotOwner(origin);
        minted += value;
    }
}

contract ProgrammabilityExecutorV1_Test is Test {
    address admin = address(this);
    address relayer = makeAddr("relayer");
    address relayer2 = makeAddr("relayer2");
    address stranger = makeAddr("stranger");

    RaylsAccessManagerV1      manager;
    ProgrammabilityExecutorV1 executor;
    _StubEndpoint             endpointStub;
    _StubReplica              replicaStub;
    _Target                   targetA;
    _Target                   targetB;
    _OtherTarget              targetC; // distinct bytecode from targetA/targetB

    uint64 RELAYER_ID;

    bytes32 constant RID_A = keccak256("resource.A");
    bytes32 constant RID_B = keccak256("resource.B");
    bytes32 constant RID_C = keccak256("resource.C");
    bytes32 constant RID_UNKNOWN = keccak256("resource.unknown");

    bytes4 immutable SEL_RECORD = _Target.record.selector;
    bytes4 immutable SEL_BOOM   = _Target.boom.selector;

    function setUp() public {
        // ── AccessManager via UUPS proxy ────────────────────────────────────
        RaylsAccessManagerV1 mImpl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(
            address(new ERC1967Proxy(address(mImpl), abi.encodeCall(RaylsAccessManagerV1.initialize, (admin))))
        );
        manager.grantRole(manager.ADMIN(), address(manager), 0);
        RELAYER_ID = manager.registerRole("RELAYER");

        // ── dependencies ────────────────────────────────────────────────────
        endpointStub = new _StubEndpoint();
        replicaStub  = new _StubReplica();
        targetA      = new _Target();
        targetB      = new _Target();
        targetC      = new _OtherTarget();

        endpointStub.set(RID_A, address(targetA));
        endpointStub.set(RID_B, address(targetB));
        endpointStub.set(RID_C, address(targetC));

        // ── executor via UUPS proxy ─────────────────────────────────────────
        ProgrammabilityExecutorV1 eImpl = new ProgrammabilityExecutorV1();
        executor = ProgrammabilityExecutorV1(
            address(new ERC1967Proxy(
                address(eImpl),
                abi.encodeCall(
                    ProgrammabilityExecutorV1.initialize,
                    (address(endpointStub), address(replicaStub), address(manager))
                )
            ))
        );

        // Map executeProgramData to RELAYER and grant RELAYER to two relayer keys.
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = bytes4(keccak256("executeProgramData((bytes32,address,bytes4,bytes)[],uint256,address)"));
        uint64[] memory roles = new uint64[](1);
        roles[0] = RELAYER_ID;
        manager.addFunctionAllowedRoles(address(executor), sels, roles);
        manager.grantRole(RELAYER_ID, relayer, 0);
        manager.grantRole(RELAYER_ID, relayer2, 0);
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    /// @dev A program-data step targeting by resourceId.
    function _step(bytes32 rid, bytes4 selector, bytes memory args)
        internal
        pure
        returns (SharedObjects.EnygmaProgramData memory)
    {
        return SharedObjects.EnygmaProgramData({
            resourceId: rid,
            contractAddress: address(0),
            selector: selector,
            args: args
        });
    }

    /// @dev A program-data step targeting by direct contract address.
    function _stepByAddress(address target, bytes4 selector, bytes memory args)
        internal
        pure
        returns (SharedObjects.EnygmaProgramData memory)
    {
        return SharedObjects.EnygmaProgramData({
            resourceId: bytes32(0),
            contractAddress: target,
            selector: selector,
            args: args
        });
    }

    /// @dev Single-element step array.
    function _one(SharedObjects.EnygmaProgramData memory s)
        internal
        pure
        returns (SharedObjects.EnygmaProgramData[] memory arr)
    {
        arr = new SharedObjects.EnygmaProgramData[](1);
        arr[0] = s;
    }

    /// @dev `record(uint256)` step — args encode only the leading param; the executor appends the
    ///      attested origin as a trusted tail (no placeholder slot).
    function _recordStep(bytes32 rid, uint256 v) internal view returns (SharedObjects.EnygmaProgramData memory) {
        return _step(rid, SEL_RECORD, abi.encode(v));
    }

    /// @dev Approve a `record` target. The executor gates via `check` only (no param count).
    function _approveRecord(address target) internal {
        replicaStub.approve(target, SEL_RECORD);
    }

    // ── happy paths ─────────────────────────────────────────────────────────────

    function test_singleStep_dispatches() public {
        _approveRecord(address(targetA));
        vm.prank(relayer);
        executor.executeProgramData(_one(_recordStep(RID_A, 7)), 0, relayer);

        assertEq(targetA.last(), 7);
        assertEq(targetA.callCount(), 1);
    }

    function test_multiStep_dispatchesAllInOrder() public {
        _approveRecord(address(targetA));
        _approveRecord(address(targetB));
        SharedObjects.EnygmaProgramData[] memory steps = new SharedObjects.EnygmaProgramData[](2);
        steps[0] = _recordStep(RID_A, 11);
        steps[1] = _recordStep(RID_B, 22);

        vm.prank(relayer);
        executor.executeProgramData(steps, 0, relayer);

        assertEq(targetA.last(), 11);
        assertEq(targetB.last(), 22);
    }

    function test_emptyArray_isNoop() public {
        SharedObjects.EnygmaProgramData[] memory steps = new SharedObjects.EnygmaProgramData[](0);
        vm.prank(relayer);
        executor.executeProgramData(steps, 0, relayer); // must not revert
        assertEq(targetA.callCount(), 0);
    }

    function test_secondRelayerKey_accepted() public {
        _approveRecord(address(targetA));
        vm.prank(relayer2);
        executor.executeProgramData(_one(_recordStep(RID_A, 5)), 0, relayer);
        assertEq(targetA.last(), 5);
    }

    // ── atomicity ─────────────────────────────────────────────────────────────

    function test_midArrayRevert_unwindsPriorStep() public {
        // step 0 (targetA.record) is approved and would succeed; step 1 (targetB.boom)
        // is approved by the gate but reverts on the inner call. The whole tx must revert,
        // so targetA's state change is rolled back.
        _approveRecord(address(targetA));
        replicaStub.approve(address(targetB), SEL_BOOM);

        SharedObjects.EnygmaProgramData[] memory steps = new SharedObjects.EnygmaProgramData[](2);
        steps[0] = _recordStep(RID_A, 99);
        // boom() takes no args; the executor appends the origin tail, then the inner call reverts
        // Boom() — exercising mid-array unwind.
        steps[1] = _step(RID_B, SEL_BOOM, "");

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ProgrammabilityExecutorV1.ProgramData__Reverted.selector,
                uint256(1),
                RID_B,
                SEL_BOOM,
                abi.encodeWithSelector(_Target.Boom.selector)
            )
        );
        executor.executeProgramData(steps, 0, relayer);

        assertEq(targetA.last(), 0, "prior step must be unwound");
        assertEq(targetA.callCount(), 0);
    }

    // ── gate / resolution failures ───────────────────────────────────────────────

    function test_unapprovedSelector_reverts() public {
        // gate not approved for (targetA, record)
        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ProgrammabilityExecutorV1.ProgramData__UnapprovedTemplate.selector,
                uint256(0),
                address(targetA).codehash,
                SEL_RECORD
            )
        );
        executor.executeProgramData(_one(_recordStep(RID_A, 1)), 0, relayer);
    }

    function test_unapprovedAfterValidMint_revertsWhole() public {
        // step 0 approved+valid (targetA), step 1 targets targetC whose *bytecode* is not
        // approved → whole tx reverts, step 0 unwound. targetC has a distinct codehash from
        // targetA, so approving targetA's bytecode does not cover it.
        _approveRecord(address(targetA));
        SharedObjects.EnygmaProgramData[] memory steps = new SharedObjects.EnygmaProgramData[](2);
        steps[0] = _recordStep(RID_A, 42);
        steps[1] = _recordStep(RID_C, 43); // targetC bytecode not approved

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ProgrammabilityExecutorV1.ProgramData__UnapprovedTemplate.selector,
                uint256(1),
                address(targetC).codehash,
                SEL_RECORD
            )
        );
        executor.executeProgramData(steps, 0, relayer);

        assertEq(targetA.last(), 0, "valid mint must not land when a later step is rejected");
    }

    function test_sameBytecodeSharesTemplate() public {
        // Approving targetA's (codehash, selector) also covers targetB, since they share
        // runtime bytecode. This is the bytecode-binding property the design relies on.
        _approveRecord(address(targetA));
        vm.prank(relayer);
        executor.executeProgramData(_one(_recordStep(RID_B, 8)), 0, relayer); // targetB never explicitly approved
        assertEq(targetB.last(), 8);
    }

    function test_unknownResourceId_reverts() public {
        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ProgrammabilityExecutorV1.ProgramData__UnknownResourceId.selector,
                uint256(0),
                RID_UNKNOWN
            )
        );
        executor.executeProgramData(_one(_recordStep(RID_UNKNOWN, 1)), 0, relayer);
    }

    // ── target resolution: resourceId XOR contractAddress ──────────────────────────
    // A step addresses its target by EXACTLY ONE of resourceId / contractAddress. The same
    // template gate runs regardless of which field resolved the target.

    function test_addressTarget_dispatches() public {
        // Target by direct contract address (not bound on the endpoint). Still gated.
        _approveRecord(address(targetA));
        vm.prank(relayer);
        executor.executeProgramData(
            _one(_stepByAddress(address(targetA), SEL_RECORD, abi.encode(uint256(99)))),
            0,
            relayer
        );

        assertEq(targetA.last(), 99);
        assertEq(targetA.callCount(), 1);
    }

    function test_addressTarget_stillGatedByTemplate() public {
        // No approve() — an address target with unapproved (codehash, selector) must still revert.
        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ProgrammabilityExecutorV1.ProgramData__UnapprovedTemplate.selector,
                uint256(0),
                address(targetA).codehash,
                SEL_RECORD
            )
        );
        executor.executeProgramData(
            _one(_stepByAddress(address(targetA), SEL_RECORD, abi.encode(uint256(1)))),
            0,
            relayer
        );
    }

    function test_bothTargetsProvided_reverts() public {
        // A step that sets BOTH resourceId and contractAddress is rejected.
        SharedObjects.EnygmaProgramData memory s = SharedObjects.EnygmaProgramData({
            resourceId: RID_A,
            contractAddress: address(targetA),
            selector: SEL_RECORD,
            args: abi.encode(uint256(1))
        });
        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(ProgrammabilityExecutorV1.ProgramData__BothTargetsProvided.selector, uint256(0))
        );
        executor.executeProgramData(_one(s), 0, relayer);
    }

    function test_noTargetProvided_reverts() public {
        // A step that sets NEITHER resourceId nor contractAddress is rejected.
        SharedObjects.EnygmaProgramData memory s = SharedObjects.EnygmaProgramData({
            resourceId: bytes32(0),
            contractAddress: address(0),
            selector: SEL_RECORD,
            args: abi.encode(uint256(1))
        });
        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(ProgrammabilityExecutorV1.ProgramData__NoTargetProvided.selector, uint256(0))
        );
        executor.executeProgramData(_one(s), 0, relayer);
    }

    // ── access control ───────────────────────────────────────────────────────────

    function test_nonRelayer_rejected() public {
        _approveRecord(address(targetA));
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, stranger)
        );
        executor.executeProgramData(_one(_recordStep(RID_A, 1)), 0, relayer);
    }

    // ── mint conservation (expectedMintTotal) ─────────────────────────────────────

    bytes4 constant SEL_CROSS_MINT_STANDARD = bytes4(keccak256("crossMintStandard(address,uint256,bytes32)"));

    /// @dev Build a crossMintStandard settlement step: args = abi.encode(to, value, referenceId).
    function _mintStep(bytes32 rid, address to, uint256 value, bytes32 refId)
        internal
        pure
        returns (SharedObjects.EnygmaProgramData memory)
    {
        return _step(rid, SEL_CROSS_MINT_STANDARD, abi.encode(to, value, refId));
    }

    /// @notice A settlement mint whose value equals the relayer-supplied expected total passes.
    function test_mintTotal_matches_passes() public {
        _MintTarget mintTarget = new _MintTarget();
        endpointStub.set(RID_A, address(mintTarget));
        replicaStub.approve(address(mintTarget), SEL_CROSS_MINT_STANDARD);

        vm.prank(relayer);
        executor.executeProgramData(_one(_mintStep(RID_A, address(0xBEEF), 100, keccak256("ref"))), 100, relayer);
        assertEq(mintTarget.minted(), 100, "mint should have dispatched");
    }

    /// @notice Summing several settlement mints against the expected total passes.
    function test_mintTotal_sumOfSteps_matches_passes() public {
        _MintTarget mintTarget = new _MintTarget();
        endpointStub.set(RID_A, address(mintTarget));
        replicaStub.approve(address(mintTarget), SEL_CROSS_MINT_STANDARD);

        SharedObjects.EnygmaProgramData[] memory steps = new SharedObjects.EnygmaProgramData[](2);
        steps[0] = _mintStep(RID_A, address(0xBEEF), 70, keccak256("ref1"));
        steps[1] = _mintStep(RID_A, address(0xBEEF), 30, keccak256("ref2"));

        vm.prank(relayer);
        executor.executeProgramData(steps, 100, relayer);
        assertEq(mintTarget.minted(), 100, "both mints should have dispatched");
    }

    /// @notice Minting MORE than the PNH-authorized total reverts atomically (no mint sticks).
    function test_mintTotal_overMint_reverts() public {
        _MintTarget mintTarget = new _MintTarget();
        endpointStub.set(RID_A, address(mintTarget));
        replicaStub.approve(address(mintTarget), SEL_CROSS_MINT_STANDARD);

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(ProgrammabilityExecutorV1.ProgramData__MintTotalMismatch.selector, uint256(100), uint256(150))
        );
        executor.executeProgramData(_one(_mintStep(RID_A, address(0xBEEF), 150, keccak256("ref"))), 100, relayer);
        assertEq(mintTarget.minted(), 0, "over-mint must be unwound");
    }

    /// @notice Minting LESS than the PNH-authorized total reverts.
    function test_mintTotal_underMint_reverts() public {
        _MintTarget mintTarget = new _MintTarget();
        endpointStub.set(RID_A, address(mintTarget));
        replicaStub.approve(address(mintTarget), SEL_CROSS_MINT_STANDARD);

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(ProgrammabilityExecutorV1.ProgramData__MintTotalMismatch.selector, uint256(100), uint256(80))
        );
        executor.executeProgramData(_one(_mintStep(RID_A, address(0xBEEF), 80, keccak256("ref"))), 100, relayer);
    }

    /// @notice A non-mint step array (no crossMintStandard) requires expectedMintTotal == 0.
    function test_mintTotal_nonMintSteps_requireZeroExpected() public {
        _approveRecord(address(targetA));
        // Passing a non-zero expected total when nothing mints must revert.
        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(ProgrammabilityExecutorV1.ProgramData__MintTotalMismatch.selector, uint256(5), uint256(0))
        );
        executor.executeProgramData(_one(_recordStep(RID_A, 1)), 5, relayer);
    }

    /// @notice A composed [mintStep, userStep] only counts the mint toward the conservation total;
    ///         the userStep (a non-mint call) does not affect the expected total.
    function test_mintTotal_composedWithUserStep_countsOnlyMint() public {
        _MintTarget mintTarget = new _MintTarget();
        endpointStub.set(RID_A, address(mintTarget));
        replicaStub.approve(address(mintTarget), SEL_CROSS_MINT_STANDARD);
        _approveRecord(address(targetB));

        SharedObjects.EnygmaProgramData[] memory steps = new SharedObjects.EnygmaProgramData[](2);
        steps[0] = _mintStep(RID_A, address(0xBEEF), 100, keccak256("ref"));
        steps[1] = _recordStep(RID_B, 42); // userStep — not a mint, must not count

        vm.prank(relayer);
        executor.executeProgramData(steps, 100, relayer);
        assertEq(mintTarget.minted(), 100, "mint dispatched");
        assertEq(targetB.last(), 42, "userStep dispatched");
    }

    // ── origin attestation ─────────────────────────────────────────────────────────
    // The executor APPENDS the attested `originSender` as a trusted 20-byte calldata tail on each
    // non-mint step. The target reads it by absolute offset (`calldatasize()-20`), independent of
    // its ABI layout. The userBlob `args` encode ONLY the target's leading params. These tests pin
    // down the forgery defense and the happy paths for both static and dynamic arg layouts.

    bytes4 constant SEL_ATTESTED_MINT = bytes4(keccak256("crossMint(address,uint256)"));
    bytes4 constant SEL_ATTESTED_MINT_DYN =
        bytes4(keccak256("crossMint(address,uint256,uint256,bytes)"));

    address tokenOwner = makeAddr("tokenOwner");

    /// @notice Happy path: the executor appends the attested owner as the tail; the target reads it,
    ///         the in-body owner check passes and the mint lands.
    function test_attested_happyPath_executorWritesOrigin() public {
        _AttestedMint mt = new _AttestedMint(tokenOwner);
        endpointStub.set(RID_A, address(mt));
        replicaStub.approve(address(mt), SEL_ATTESTED_MINT);

        // args = (to, value) — leading params only; the executor appends the origin tail.
        bytes memory args = abi.encode(address(0xBEEF), uint256(500));

        vm.prank(relayer);
        executor.executeProgramData(_one(_step(RID_A, SEL_ATTESTED_MINT, args)), 0, tokenOwner);

        assertEq(mt.seenOrigin(), tokenOwner, "target must read the executor-attested origin");
        assertEq(mt.minted(), 500, "mint should land for the real owner");
    }

    /// @notice THE FORGERY DEFENSE. An attacker (attested origin = attacker) crafts args that try to
    ///         smuggle a known TOKEN_OWNER. Because the target reads the origin from the executor's
    ///         appended tail (absolute offset), any value the attacker puts in `args` is IGNORED —
    ///         the tail always wins and the owner check sees the real (attacker) origin → revert.
    function test_attested_forgedOriginInArgs_ignored_tailWins() public {
        _AttestedMint mt = new _AttestedMint(tokenOwner);
        endpointStub.set(RID_A, address(mt));
        replicaStub.approve(address(mt), SEL_ATTESTED_MINT);

        address attacker = makeAddr("attacker");
        // Attacker appends an extra word holding the real owner, hoping the target decodes it. The
        // target ignores `args` for the origin and reads the appended tail (= attacker) instead, so
        // the owner check fails with NotOwner(attacker) — bubbled by the executor as ProgramData__Reverted.
        bytes memory args = abi.encode(address(0xBEEF), uint256(500), tokenOwner);

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ProgrammabilityExecutorV1.ProgramData__Reverted.selector,
                uint256(0), RID_A, SEL_ATTESTED_MINT,
                abi.encodeWithSelector(_AttestedMint.NotOwner.selector, attacker)
            )
        );
        executor.executeProgramData(_one(_step(RID_A, SEL_ATTESTED_MINT, args)), 0, attacker);

        assertEq(mt.minted(), 0, "no mint may land on a forged origin");
    }

    /// @notice Even a widened `args` (many extra trailing words) cannot forge the origin: the
    ///         executor appends its tail AFTER all of `args`, so the last 20 bytes are always the
    ///         attested origin. The target reads the attested (attacker) origin → revert.
    function test_attested_widenedArgsForgery_ignored_tailWins() public {
        _AttestedMint mt = new _AttestedMint(tokenOwner);
        endpointStub.set(RID_A, address(mt));
        replicaStub.approve(address(mt), SEL_ATTESTED_MINT);

        address attacker = makeAddr("attacker");
        bytes memory args = abi.encode(address(0xBEEF), uint256(500), tokenOwner, uint256(0xDEAD));

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ProgrammabilityExecutorV1.ProgramData__Reverted.selector,
                uint256(0), RID_A, SEL_ATTESTED_MINT,
                abi.encodeWithSelector(_AttestedMint.NotOwner.selector, attacker)
            )
        );
        executor.executeProgramData(_one(_step(RID_A, SEL_ATTESTED_MINT, args)), 0, attacker);

        assertEq(mt.minted(), 0, "widened-args forgery must not land");
    }

    /// @notice Dynamic-arg happy path: a `bytes` parameter is present, but the tail read uses an
    ///         absolute calldata offset, so it lands on the appended origin regardless of layout.
    function test_attested_dynamicArgs_executorWritesOrigin() public {
        _AttestedMintDynamic mt = new _AttestedMintDynamic(tokenOwner);
        endpointStub.set(RID_A, address(mt));
        replicaStub.approve(address(mt), SEL_ATTESTED_MINT_DYN);

        bytes memory payload = hex"c0ffee";
        // (to, id, value, data) — leading params only; executor appends the origin tail.
        bytes memory args = abi.encode(address(0xBEEF), uint256(7), uint256(900), payload);

        vm.prank(relayer);
        executor.executeProgramData(_one(_step(RID_A, SEL_ATTESTED_MINT_DYN, args)), 0, tokenOwner);

        assertEq(mt.seenOrigin(), tokenOwner, "dynamic-layout origin must be the attested owner");
        assertEq(mt.minted(), 900);
        assertEq(mt.seenData(), payload, "dynamic bytes payload preserved");
    }

    /// @notice Dynamic-arg forgery: a forged owner smuggled in `args` is ignored — the tail (the
    ///         attested attacker) wins even with a well-formed dynamic `bytes` in the payload.
    function test_attested_dynamicArgs_forgery_ignored_tailWins() public {
        _AttestedMintDynamic mt = new _AttestedMintDynamic(tokenOwner);
        endpointStub.set(RID_A, address(mt));
        replicaStub.approve(address(mt), SEL_ATTESTED_MINT_DYN);

        address attacker = makeAddr("attacker");
        // Extra trailing word holding the real owner — ignored; the appended tail is the origin.
        bytes memory args = abi.encode(address(0xBEEF), uint256(7), uint256(900), hex"c0ffee", tokenOwner);

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ProgrammabilityExecutorV1.ProgramData__Reverted.selector,
                uint256(0), RID_A, SEL_ATTESTED_MINT_DYN,
                abi.encodeWithSelector(_AttestedMintDynamic.NotOwner.selector, attacker)
            )
        );
        executor.executeProgramData(_one(_step(RID_A, SEL_ATTESTED_MINT_DYN, args)), 0, attacker);
    }

    /// @notice The mint step (crossMintStandard) is NOT on the attested path: it is invoked WITHOUT
    ///         the origin tail (native args only) and counts toward the conservation total. Asserts
    ///         the dispatch is unaffected by whatever origin the relayer supplied.
    function test_attested_mintStepUnaffectedByOrigin() public {
        _MintTarget mintTarget = new _MintTarget();
        endpointStub.set(RID_A, address(mintTarget));
        replicaStub.approve(address(mintTarget), SEL_CROSS_MINT_STANDARD);

        vm.prank(relayer);
        executor.executeProgramData(_one(_mintStep(RID_A, address(0xBEEF), 100, keccak256("ref"))), 100, makeAddr("anyone"));
        assertEq(mintTarget.minted(), 100, "mint step dispatched with native args");
    }

    /// @notice Composed [mintStep, attestedUserStep]: the mint settles (no tail) and the attested
    ///         user call reads the executor-appended origin from its tail.
    function test_attested_composedMintPlusUserStep() public {
        _MintTarget mintTarget = new _MintTarget();
        _AttestedMint mt = new _AttestedMint(tokenOwner);
        endpointStub.set(RID_A, address(mintTarget));
        endpointStub.set(RID_B, address(mt));
        replicaStub.approve(address(mintTarget), SEL_CROSS_MINT_STANDARD);
        replicaStub.approve(address(mt), SEL_ATTESTED_MINT);

        SharedObjects.EnygmaProgramData[] memory steps = new SharedObjects.EnygmaProgramData[](2);
        steps[0] = _mintStep(RID_A, address(0xBEEF), 100, keccak256("ref"));
        steps[1] = _step(RID_B, SEL_ATTESTED_MINT, abi.encode(address(0xBEEF), uint256(50)));

        vm.prank(relayer);
        executor.executeProgramData(steps, 100, tokenOwner);

        assertEq(mintTarget.minted(), 100, "settlement mint landed");
        assertEq(mt.seenOrigin(), tokenOwner, "attested user step read executor-appended origin");
        assertEq(mt.minted(), 50);
    }
}
