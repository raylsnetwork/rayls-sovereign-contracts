// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ReceiveReentrancyAttacker
 * @notice Malicious contract that attempts reentrancy attacks on receive-protected functions
 */
contract ReceiveReentrancyAttacker {
    // Renamed from `target` to avoid shadowing ethers v6's BaseContract.target
    // field, which would silently mask this getter in off-chain TS bindings.
    address public attackTarget;
    uint256 public attackCount;

    constructor(address _target) {
        attackTarget = _target;
    }

    function attack() external {
        attackCount++;
        (bool success, ) = attackTarget.call(
            abi.encodeWithSignature("protectedReceiveFunction()")
        );
        require(success, "Reentrancy blocked");
    }

    function initiateAttack() external {
        (bool success, ) = attackTarget.call(
            abi.encodeWithSignature("vulnerableReceiveFunction(address)", address(this))
        );
        require(success, "Initial call failed");
    }
}
