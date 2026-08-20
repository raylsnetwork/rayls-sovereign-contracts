// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title ITemplateRegistry
 * @notice External surface of the PNH-side Template Registry.
 * @dev The registry whitelists `(bytecodeHash, selector)` pairs that the per-PN
 *      `ProgrammableExecutor` is allowed to dispatch. Templates are keyed by
 *      `keccak256(abi.encode(bytecodeHash, selector))`. Approvals (and revocations)
 *      are broadcast to every PN's `TemplateRegistryReplicaV1` via the Endpoint.
 */
interface ITemplateRegistry {
    struct Template {
        bytes32 bytecodeHash;
        string  signature;
        bytes4  selector;
        /// @dev Block number of the last approve/seed/revoke, used as a monotonic ordering
        ///      token: the replica drops an event older than what it stored. Named `...Block`
        ///      (not `...At`) to make clear it is a block number, not a unix timestamp.
        uint64  approvedAtBlock;
        bool    approved;
    }

    /// @notice Emitted when an external caller proposes a custom template (pre-approval).
    event TemplateProposed(
        bytes32 indexed key,
        bytes32 bytecodeHash,
        string  signature,
        bytes4  selector,
        address proposer
    );

    /// @notice Emitted when a template is approved — via `approve(...)` after a proposal,
    ///         via `seedStandardTemplate(...)` for a first-time audited-standard seed, or
    ///         via `reseedStandardTemplate(...)` when re-seeding after a UUPS upgrade
    ///         (the latter co-emits `StandardTemplateReseeded`).
    event TemplateApproved(
        bytes32 indexed key,
        bytes32 bytecodeHash,
        string  signature,
        bytes4  selector,
        uint64  approvedAt
    );

    /// @notice Emitted when an audited standard's template is re-seeded after a UUPS upgrade
    ///         changes its runtime codehash. Accompanies the `TemplateApproved` event so the
    ///         re-seed (idempotent overwrite) is distinguishable off-chain from a first-time seed.
    event StandardTemplateReseeded(
        bytes32 indexed key,
        bytes32 bytecodeHash,
        bytes4  selector,
        uint64  approvedAt
    );

    /// @notice Emitted when an approved template is revoked.
    event TemplateRevoked(
        bytes32 indexed key,
        bytes32 bytecodeHash,
        bytes4  selector,
        uint64  revokedAt
    );

    function seedStandardTemplate(bytes32 bytecodeHash, string calldata signature) external;
    function reseedStandardTemplate(bytes32 bytecodeHash, string calldata signature) external;
    function propose(bytes32 bytecodeHash, string calldata signature) external returns (bytes32 key);
    function approve(bytes32 key) external;
    function revoke(bytes32 key) external;

    function getTemplate(bytes32 key) external view returns (Template memory);
    function getKey(bytes32 bytecodeHash, bytes4 selector) external pure returns (bytes32);

    /// @notice Returns the contract version, so callers holding only an `ITemplateRegistry`
    ///         reference can query it without an explicit cast to `TemplateRegistryV1`.
    function contractVersion() external pure returns (uint256);
}
