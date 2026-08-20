// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ReentrancyAttacker
 * @notice Malicious contract that attempts reentrancy attacks on send-protected functions
 */
contract ReentrancyAttacker {
    // Renamed from `target` to avoid shadowing ethers v6's BaseContract.target
    // field, which would silently mask this getter in off-chain TS bindings.
    address public attackTarget;
    uint256 public attackCount;

    constructor(address _target) {
        attackTarget = _target;
    }

    function attack() external {
        attackCount++;
        // Try to re-enter the vulnerable function
        (bool success, ) = attackTarget.call(
            abi.encodeWithSignature("protectedSendFunction()")
        );
        // If reentrancy works, this would succeed
        require(success, "Reentrancy blocked");
    }

    function initiateAttack() external {
        (bool success, ) = attackTarget.call(
            abi.encodeWithSignature("vulnerableFunction(address)", address(this))
        );
        require(success, "Initial call failed");
    }
}
