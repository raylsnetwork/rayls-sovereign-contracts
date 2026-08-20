// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {InitCodeStub} from "../../../../rayls-protocol-sdk/libraries/InitCodeStub.sol";

/// @notice Behavior contract for `InitCodeStub.wrapRuntime` / `wrapRuntimeMemory`.
///         The library replaced hand-rolled hex literals previously inlined in
///         RNContractFactoryV1 / RaylsContractFactoryV1. These tests pin the exact
///         byte sequence the stub must emit, so a future refactor can't silently
///         break the per-path boundary documented in InitCodeStub.sol.
contract InitCodeStubTest is Test {
    // ─────────────────────────────────────────────────────────────────
    //  Header constant — identical for PUSH1 and PUSH2 paths
    //  60 80 PUSH1 0x80
    //  60 40 PUSH1 0x40
    //  52    MSTORE
    //  34    CALLVALUE
    //  80    DUP1
    //  15    ISZERO
    //  61 00 10 PUSH2 0x0010
    //  57    JUMPI
    //  60 00 PUSH1 0x00
    //  80    DUP1
    //  FD    REVERT
    //  5B    JUMPDEST
    //  50    POP
    // ─────────────────────────────────────────────────────────────────
    bytes18 internal constant EXPECTED_HEADER = 0x608060405234801561001057600080fd5b50;

    // PUSH1-path tail (DUP1 PUSH2 0x001F PUSH1 0x00 CODECOPY PUSH1 0x00 RETURN INVALID).
    bytes11 internal constant EXPECTED_TAIL_PUSH1 = 0x8061001f6000396000f3fe;

    // PUSH2-path tail (DUP1 PUSH2 0x0020 PUSH1 0x00 CODECOPY PUSH1 0x00 RETURN INVALID).
    bytes11 internal constant EXPECTED_TAIL_PUSH2 = 0x806100206000396000f3fe;

    /// Helper to call the calldata variant from a test (calldata-only library functions
    /// can't be invoked with memory args directly).
    function _wrap(bytes calldata runtime) external pure returns (bytes memory) {
        return InitCodeStub.wrapRuntime(runtime);
    }

    // ─────────────────────────────────────────────────────────────────
    //  PUSH1 path — runtime length <= 255 → 31-byte stub
    // ─────────────────────────────────────────────────────────────────

    function test_when_runtimeIsOneByte_then_stubIsExactPush1Layout() public view {
        bytes memory runtime = hex"00";
        bytes memory got = this._wrap(runtime);

        assertEq(got.length, 31 + runtime.length, "stub+runtime length mismatch (PUSH1 path, 1 B)");
        _assertHeaderAt(got, 0);
        assertEq(got[18], bytes1(0x60), "byte 18 must be PUSH1 (0x60)");
        assertEq(got[19], bytes1(uint8(runtime.length)), "byte 19 must encode runtime length");
        _assertTailPush1At(got, 20);
        _assertRuntimeAt(got, 31, runtime);
    }

    function test_when_runtimeIsAtSmallPathBoundary_then_stubIsExactPush1Layout() public view {
        bytes memory runtime = _seqRuntime(255);
        bytes memory got = this._wrap(runtime);

        assertEq(got.length, 31 + 255, "stub+runtime length mismatch at PUSH1 boundary");
        _assertHeaderAt(got, 0);
        assertEq(got[18], bytes1(0x60), "byte 18 must be PUSH1 (0x60)");
        assertEq(got[19], bytes1(uint8(255)), "byte 19 must encode runtime length 255");
        _assertTailPush1At(got, 20);
        _assertRuntimeAt(got, 31, runtime);
    }

    // ─────────────────────────────────────────────────────────────────
    //  PUSH2 path — runtime length > 255 → 32-byte stub
    // ─────────────────────────────────────────────────────────────────

    function test_when_runtimeIsAtLargePathBoundary_then_stubIsExactPush2Layout() public view {
        bytes memory runtime = _seqRuntime(256);
        bytes memory got = this._wrap(runtime);

        assertEq(got.length, 32 + 256, "stub+runtime length mismatch at PUSH2 boundary");
        _assertHeaderAt(got, 0);
        assertEq(got[18], bytes1(0x61), "byte 18 must be PUSH2 (0x61)");
        assertEq(got[19], bytes1(0x01), "byte 19 must be high byte of length 256 (0x0100)");
        assertEq(got[20], bytes1(0x00), "byte 20 must be low byte of length 256 (0x0100)");
        _assertTailPush2At(got, 21);
        _assertRuntimeAt(got, 32, runtime);
    }

    function test_when_runtimeIs1024Bytes_then_stubIsExactPush2Layout() public view {
        bytes memory runtime = _seqRuntime(1024);
        bytes memory got = this._wrap(runtime);

        assertEq(got.length, 32 + 1024, "stub+runtime length mismatch at 1024 B");
        _assertHeaderAt(got, 0);
        assertEq(got[18], bytes1(0x61), "PUSH2 expected");
        assertEq(got[19], bytes1(0x04), "high byte of 1024 (0x0400)");
        assertEq(got[20], bytes1(0x00), "low byte of 1024 (0x0400)");
        _assertTailPush2At(got, 21);
        _assertRuntimeAt(got, 32, runtime);
    }

    // ─────────────────────────────────────────────────────────────────
    //  Memory-input variant must produce identical bytes to calldata variant
    // ─────────────────────────────────────────────────────────────────

    function test_when_memoryAndCalldataVariantsAgree_thenBytesAreIdentical() public view {
        bytes memory runtime = _seqRuntime(60);
        bytes memory fromCalldata = this._wrap(runtime);
        bytes memory fromMemory = InitCodeStub.wrapRuntimeMemory(runtime);
        assertEq(fromCalldata, fromMemory, "memory and calldata variants must produce identical bytes");
    }

    // ─────────────────────────────────────────────────────────────────
    //  End-to-end CREATE — wrap + deploy + assert deployed runtime equals input
    // ─────────────────────────────────────────────────────────────────

    function test_when_wrappedAndDeployed_then_runtimeOnChainEqualsInput() public {
        bytes memory runtime = _seqRuntime(60);
        bytes memory initCode = InitCodeStub.wrapRuntimeMemory(runtime);

        address deployed;
        assembly {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        assertTrue(deployed != address(0), "CREATE returned zero - stub bytecode is malformed");
        assertEq(deployed.code, runtime, "deployed runtime != input runtime");
    }

    function test_when_wrappedAndDeployedAtPush2Boundary_then_runtimeOnChainEqualsInput() public {
        bytes memory runtime = _seqRuntime(300);
        bytes memory initCode = InitCodeStub.wrapRuntimeMemory(runtime);

        address deployed;
        assembly {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        assertTrue(deployed != address(0), "CREATE returned zero at PUSH2 boundary");
        assertEq(deployed.code, runtime, "deployed runtime != input runtime at PUSH2 boundary");
    }

    // ─────────────────────────────────────────────────────────────────
    //  Internal helpers
    // ─────────────────────────────────────────────────────────────────

    function _assertHeaderAt(bytes memory data, uint256 offset) internal pure {
        for (uint256 i = 0; i < 18; i++) {
            assertEq(data[offset + i], EXPECTED_HEADER[i], "header byte mismatch");
        }
    }

    function _assertTailPush1At(bytes memory data, uint256 offset) internal pure {
        for (uint256 i = 0; i < 11; i++) {
            assertEq(data[offset + i], EXPECTED_TAIL_PUSH1[i], "PUSH1 tail byte mismatch");
        }
    }

    function _assertTailPush2At(bytes memory data, uint256 offset) internal pure {
        for (uint256 i = 0; i < 11; i++) {
            assertEq(data[offset + i], EXPECTED_TAIL_PUSH2[i], "PUSH2 tail byte mismatch");
        }
    }

    function _assertRuntimeAt(bytes memory data, uint256 offset, bytes memory runtime) internal pure {
        for (uint256 i = 0; i < runtime.length; i++) {
            assertEq(data[offset + i], runtime[i], "runtime byte mismatch in init-code suffix");
        }
    }

    /// Build a runtime of `length` bytes that starts with two STOPs (so any post-deploy
    /// init-call halts cleanly) followed by a unique pattern. Mirrors
    /// `FactoryStubLib.buildSentinelRuntime` so the two helpers are interchangeable.
    function _seqRuntime(uint256 length) internal pure returns (bytes memory out) {
        out = new bytes(length);
        if (length >= 1) out[0] = 0x00;
        if (length >= 2) out[1] = 0x00;
        for (uint256 i = 2; i < length; i++) {
            out[i] = bytes1(uint8(((i - 1) & 0xff)));
        }
    }
}
