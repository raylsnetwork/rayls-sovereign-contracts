// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Merkle} from "../../../rayls-protocol/Enygma/Enygma-DVP/Merkle.sol";

/**
 * @title MerkleHarness
 * @dev Exposes internal Merkle functions for testing that they work when called
 *      from an inheriting contract (the production pattern).
 */
contract MerkleHarness is Merkle {
    function exposed_initializeMerkle(uint256 _treeDepth, uint256 _vaultId, address _poseidon) public {
        initializeMerkle(_treeDepth, _vaultId, _poseidon);
    }

    function exposed_lock(uint256 _treeNumber, uint256 _nullifierId) public returns (bool) {
        return lock(_treeNumber, _nullifierId);
    }

    function exposed_unlock(uint256 _treeNumber, uint256 _nullifierId) public returns (bool) {
        return unlock(_treeNumber, _nullifierId);
    }

    function exposed_setNullifier(uint256 _treeNumber, uint256 _nullifierId) public {
        setNullifier(_treeNumber, _nullifierId);
    }

    function exposed_insertLeaves(uint256[] memory _leafHashes) public {
        insertLeaves(_leafHashes);
    }

    function exposed_newTree() public {
        newTree();
    }
}

/**
 * @title Security Test: Merkle Access Control
 * @notice Tests that state-mutating Merkle functions are internal (not externally callable).
 *
 * VULNERABILITY (before fix):
 * - Anyone could call lock/unlock/setNullifier/insertLeaves/newTree/initializeMerkle
 * - An attacker could corrupt the Merkle tree, preventing legitimate withdrawals
 * - An attacker could double-spend by manipulating nullifiers
 *
 * EXPECTED BEHAVIOR (after fix):
 * - State-mutating functions are internal, only callable by inheriting contracts
 * - External callers cannot access these functions at all (compile-time guarantee)
 * - The MerkleHarness demonstrates that inheriting contracts can still use them
 */
contract MerkleAccessControlTest is Test {
    MerkleHarness public harness;

    function setUp() public {
        harness = new MerkleHarness();
    }

    // ========== Verify internal functions still work via inheriting contract ==========

    function test_internalFunctions_workViaHarness() public {
        // lock should work via harness
        bool locked = harness.exposed_lock(0, 123);
        assertTrue(locked, "lock should return true");

        // unlock should work via harness
        bool unlocked = harness.exposed_unlock(0, 123);
        assertTrue(unlocked, "unlock should return true");

        // setNullifier should work via harness
        harness.exposed_setNullifier(0, 456);
        assertTrue(harness.isValidNullifier(0, 456), "nullifier should be set");
    }

    // ========== Verify external callers CANNOT call these functions ==========
    // Since the functions are now internal, they don't appear in the ABI.
    // We verify this by attempting raw low-level calls and confirming they revert.

    function test_lock_notExternallyCallable() public {
        // Try calling lock(0, 123) directly on the Merkle contract via raw call
        // This should fail because lock is internal
        (bool success, ) = address(harness).call(
            abi.encodeWithSignature("lock(uint256,uint256)", 0, 123)
        );
        assertFalse(success, "lock should not be externally callable");
    }

    function test_unlock_notExternallyCallable() public {
        (bool success, ) = address(harness).call(
            abi.encodeWithSignature("unlock(uint256,uint256)", 0, 123)
        );
        assertFalse(success, "unlock should not be externally callable");
    }

    function test_setNullifier_notExternallyCallable() public {
        (bool success, ) = address(harness).call(
            abi.encodeWithSignature("setNullifier(uint256,uint256)", 0, 123)
        );
        assertFalse(success, "setNullifier should not be externally callable");
    }

    function test_insertLeaves_notExternallyCallable() public {
        uint256[] memory leaves = new uint256[](1);
        leaves[0] = 42;
        (bool success, ) = address(harness).call(
            abi.encodeWithSignature("insertLeaves(uint256[])", leaves)
        );
        assertFalse(success, "insertLeaves should not be externally callable");
    }

    function test_newTree_notExternallyCallable() public {
        (bool success, ) = address(harness).call(
            abi.encodeWithSignature("newTree()")
        );
        assertFalse(success, "newTree should not be externally callable");
    }

    function test_initializeMerkle_notExternallyCallable() public {
        (bool success, ) = address(harness).call(
            abi.encodeWithSignature("initializeMerkle(uint256,uint256,address)", 10, 1, address(0))
        );
        assertFalse(success, "initializeMerkle should not be externally callable");
    }
}
