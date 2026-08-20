// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title ITemplateRegistryReplica
 * @notice Minimal read surface of the PN-side `TemplateRegistryReplicaV1` consumed by
 *         `ProgrammabilityExecutorV1`.
 * @dev Only the security gate is exposed here — the executor never writes to the replica.
 */
interface ITemplateRegistryReplica {
    /**
     * @notice The single security gate. One lookup: `(target.codehash, selector)`.
     * @param target Contract address whose runtime bytecode is being matched.
     * @param selector 4-byte function selector being matched.
     * @return True iff `(target.codehash, selector)` matches an approved template.
     */
    function check(address target, bytes4 selector) external view returns (bool);

    /**
     * @notice Gate check plus the approved signature's top-level parameter count, in one call.
     * @dev NOTE: `ProgrammabilityExecutorV1` no longer consumes `paramCount` — it appends the
     *      attested `originSender` as a trusted calldata tail (read by absolute offset) rather than
     *      stamping a parameter slot, so it gates via `check` alone. This overload is retained for
     *      compatibility and any other consumer that needs the signature arity. `paramCount` is only
     *      meaningful when `approved` is true; it is `0` for unknown/revoked keys.
     * @param target Contract address whose runtime bytecode is being matched.
     * @param selector 4-byte function selector being matched.
     * @return approved True iff `(target.codehash, selector)` matches an approved template.
     * @return paramCount Top-level parameter count of the approved signature (0 if not approved).
     */
    function checkWithParamCount(address target, bytes4 selector)
        external
        view
        returns (bool approved, uint256 paramCount);
}
