// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title InitCodeStub
 * @notice Builds the CREATE2 init-code that wraps a fixed runtime as a "no-arg constructor"
 *         deploy. Replaces hand-rolled hex literals previously inlined in both factories.
 *
 * @dev WHAT THIS STUB DOES:
 *
 *      When you call CREATE / CREATE2, the EVM executes the bytes you give it as a
 *      *constructor* and then deploys whatever the constructor RETURNs. The Solidity
 *      compiler usually emits a constructor that may run user code (state setup,
 *      `constructor(args)`), then RETURNs the runtime. Here we want the reverse: we
 *      already have a finished runtime and want to deploy it unchanged. So this stub is
 *      a hand-written "no-op constructor": it sets Solidity's free memory pointer,
 *      refuses any ETH sent to the deploy, then `CODECOPY`s the runtime bytes that we
 *      append right after the stub itself, and `RETURN`s them. Net effect: deployed
 *      code = the input runtime, byte-for-byte.
 *
 *      CONCEPTUAL SOLIDITY EQUIVALENT (illustrative, NOT compiled — included to help
 *      readers who don't speak EVM)
 *
 *          contract _InitCodeWrapper {
 *              constructor() {
 *                  require(msg.value == 0);              // matches CALLVALUE/ISZERO/JUMPI/REVERT
 *                  // The runtime bytes are appended after this constructor in code memory.
 *                  // The next two lines are what the tail does in assembly:
 *                  bytes memory runtime =
 *                      <slice of own code starting at stubLen, length runtime.length>;
 *                  assembly { return(add(runtime, 0x20), mload(runtime)) }
 *              }
 *          }
 *
 *      Real Solidity cannot read its own code that way, which is why the stub is
 *      hand-written EVM (CODECOPY does what the slice expression conceptually represents).
 *
 *      MECHANICS
 *
 *      The stub is a tiny EVM program that simply CODECOPYs the trailing runtime bytes into
 *      memory and RETURNs them as the deployed code. The only path-dependent values are
 *      (a) the length push opcode (PUSH1 vs PUSH2) and (b) the CODECOPY source offset which
 *      must equal the stub length (31 vs 32 bytes).
 *
 *      Stub disassembly (constant header, identical for both paths):
 *
 *        // free memory pointer setup: mstore(0x40, 0x80)
 *        PUSH1 0x80
 *        PUSH1 0x40
 *        MSTORE
 *        // revert if msg.value != 0  (this stub is a non-payable constructor)
 *        CALLVALUE
 *        DUP1
 *        ISZERO
 *        PUSH2 0x0010      // jump dest = 0x10 (16)
 *        JUMPI
 *        PUSH1 0x00
 *        DUP1
 *        REVERT
 *        JUMPDEST          // 0x10
 *        POP               // discard the duplicated CALLVALUE
 *                          // ── 18 B so far ──
 *
 *      Tail (path-dependent length push + fixed copy/return sequence):
 *
 *        PUSH1 <runtimeLen>     |  PUSH2 <runtimeLen>      // PUSH1 path | PUSH2 path
 *        DUP1                                              // duplicate length for RETURN
 *        PUSH2 <stubLen>                                   // 0x001F (31) | 0x0020 (32)
 *        PUSH1 0x00
 *        CODECOPY                                          // copy runtime into memory at 0
 *        PUSH1 0x00
 *        RETURN
 *        INVALID                                           // padding
 *
 *      Total stub length:
 *        - PUSH1 path (runtime <= 255 B): 18 + 2 + 11 = 31 B
 *        - PUSH2 path (runtime  > 255 B): 18 + 3 + 11 = 32 B
 */
library InitCodeStub {
    /// @notice Thrown when the runtime exceeds the PUSH2 length the stub can encode (`uint16` max).
    /// @dev EIP-170 caps deployed contracts at 24,576 bytes — well below this — but the
    ///      explicit guard documents the invariant and prevents silent truncation if the
    ///      EIP-170 limit is ever raised or bypassed.
    /// @param length The offending runtime length.
    error InitCodeStub__RuntimeTooLarge(uint256 length);

    /// @dev Maximum runtime length encodable by the PUSH2 path.
    uint256 private constant MAX_RUNTIME_LEN = type(uint16).max; // 65,535 bytes

    /// @dev 18-byte constant header. See disassembly in NatSpec above.
    bytes private constant HEADER = hex"608060405234801561001057600080fd5b50";

    /// @dev Length-push opcodes. The factory picks PUSH1 or PUSH2 based on runtime length.
    bytes1 private constant OP_PUSH1 = 0x60;
    bytes1 private constant OP_PUSH2 = 0x61;

    /// @dev Tail used after a 1-byte length push (stub length = 31 = 0x001F).
    ///      Decodes as: DUP1 PUSH2 0x001F PUSH1 0x00 CODECOPY PUSH1 0x00 RETURN INVALID.
    bytes11 private constant TAIL_PUSH1_PATH = 0x8061001f6000396000f3fe;

    /// @dev Tail used after a 2-byte length push (stub length = 32 = 0x0020).
    ///      Decodes as: DUP1 PUSH2 0x0020 PUSH1 0x00 CODECOPY PUSH1 0x00 RETURN INVALID.
    bytes11 private constant TAIL_PUSH2_PATH = 0x806100206000396000f3fe;

    /**
     * @notice Wrap a runtime in init-code that returns it from a no-arg constructor.
     * @param runtime The deployed-contract runtime bytes.
     * @return initCode Runnable init code: stub ‖ runtime.
     */
    function wrapRuntime(bytes calldata runtime) internal pure returns (bytes memory initCode) {
        if (runtime.length > MAX_RUNTIME_LEN) revert InitCodeStub__RuntimeTooLarge(runtime.length);
        if (runtime.length <= 255) {
            return abi.encodePacked(
                HEADER,
                OP_PUSH1,
                bytes1(uint8(runtime.length)),
                TAIL_PUSH1_PATH,
                runtime
            );
        }
        return abi.encodePacked(
            HEADER,
            OP_PUSH2,
            bytes2(uint16(runtime.length)),
            TAIL_PUSH2_PATH,
            runtime
        );
    }

    /**
     * @notice Memory-input variant — same shape as `wrapRuntime` but takes `bytes memory`
     *         so test harnesses and on-chain callers that only have memory bytes can use it.
     * @param runtime The deployed-contract runtime bytes.
     * @return initCode Runnable init code: stub then runtime.
     */
    function wrapRuntimeMemory(bytes memory runtime) internal pure returns (bytes memory initCode) {
        if (runtime.length > MAX_RUNTIME_LEN) revert InitCodeStub__RuntimeTooLarge(runtime.length);
        if (runtime.length <= 255) {
            return abi.encodePacked(
                HEADER,
                OP_PUSH1,
                bytes1(uint8(runtime.length)),
                TAIL_PUSH1_PATH,
                runtime
            );
        }
        return abi.encodePacked(
            HEADER,
            OP_PUSH2,
            bytes2(uint16(runtime.length)),
            TAIL_PUSH2_PATH,
            runtime
        );
    }
}
