// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAbstractCoinVault} from "../../../rayls-protocol/interfaces/IAbstractCoinVault.sol";

/**
 * @title MockReentrantDvpTeleport
 * @notice Malicious DvpTeleport that re-enters the vault during emitCommitments callback.
 * @dev Used to test reentrancy-no-eth vulnerability (Slither medium #9-30).
 *
 * ATTACK VECTOR:
 *   When a CoinVault calls DvpTeleport.emitCommitments() as part of deposit/transfer,
 *   this mock re-enters the vault by calling deposit() again. Without ReentrancyGuard,
 *   the re-entrant deposit succeeds mid-transaction, corrupting merkle tree state
 *   (extra commitments inserted) and breaking the vault's integrity invariants.
 *
 * CONSEQUENCES OF REENTRANCY:
 *   - Merkle tree gets additional leaves inserted during an incomplete transaction
 *   - Commitment ordering guarantees are violated
 *   - In withdraw scenarios, nullifiers may not be set when re-entering, enabling double-spend
 *   - Event ordering is disrupted (inner call events emitted before outer call completes)
 */
contract MockReentrantDvpTeleport {
    address public targetVault;
    bool public reentrancyAttempted;
    bool public reentrancySucceeded;
    bool private _armed; // only re-enter when armed

    function setTarget(address _vault) external {
        targetVault = _vault;
    }

    function arm() external {
        _armed = true;
    }

    function disarm() external {
        _armed = false;
    }

    /// @notice Called by vault during deposit/transfer. Re-enters vault.deposit() if armed.
    function emitCommitments(address, uint256, uint256, uint256[] calldata) external {
        if (targetVault != address(0) && _armed && !reentrancyAttempted) {
            reentrancyAttempted = true;

            // Build deposit params: [tokenId=999, publicKey=67890]
            uint256[] memory params = new uint256[](2);
            params[0] = 999;
            params[1] = 67890;

            // Attempt to re-enter the vault's deposit function
            try IAbstractCoinVault(targetVault).deposit(params) {
                // Re-entry SUCCEEDED - vulnerability confirmed!
                // This means the vault accepted a second deposit mid-transaction,
                // inserting extra commitments into the merkle tree during an
                // incomplete outer operation.
                reentrancySucceeded = true;
            } catch {
                // Re-entry BLOCKED - fix is working (nonReentrant)
                reentrancySucceeded = false;
            }
        }
    }

    /// @notice Called by vault during nullification. Does not re-enter.
    function emitNullifiers(address, uint256, uint256[] calldata) external {}

}
