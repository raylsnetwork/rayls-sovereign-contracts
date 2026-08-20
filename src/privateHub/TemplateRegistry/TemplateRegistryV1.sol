// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import '../../rayls-protocol-sdk/RaylsAppV1.sol';
import '../../rayls-protocol-sdk/Constants.sol';
import '../../rayls-protocol/TemplateRegistryReplica/TemplateRegistryReplicaV1.sol';
import '../AccessControl/RaylsAccessManaged.sol';
import './interfaces/ITemplateRegistry.sol';

/**
 * @title TemplateRegistryV1
 * @notice PNH-side source of truth for the bytecode-bound template whitelist.
 * @dev Two registration paths feed the same `(bytecodeHash, selector)` store:
 *      - `seedStandardTemplate` (auditor-only): bootstraps an audited Rayls standard's
 *        bytecode + selector pair in one step, skipping the propose step.
 *      - `propose` (open) + `approve` (auditor-only): anyone can submit a custom
 *        contract's `(bytecodeHash, signature)`; an auditor flips it to approved.
 *      `revoke` (auditor-only) clears an approval. All four state changes emit
 *      events and broadcast to every PN's replica via the Endpoint
 *      (`sendToResourceId(CHAIN_ID_ALL_PARTICIPANTS, ...)`).
 *
 *      Selectors are derived from the canonical signature string on registration
 *      via `bytes4(keccak256(bytes(signature)))` and stored alongside the signature.
 *      The signature is broadcast to each replica, where it is parsed to recover the
 *      function's parameter count — the programmability executor uses that count to
 *      locate the trailing `originSender` head word it stamps on owner-attested calls.
 */
contract TemplateRegistryV1 is
    Initializable,
    RaylsAppV1,
    ITemplateRegistry,
    UUPSUpgradeable,
    RaylsAccessManaged
{
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when `bytecodeHash` is zero — a zero hash matches `address.codehash`
    ///         for any address with no code, which would silently whitelist EOAs.
    error TemplateRegistryV1__EmptyBytecodeHash();

    /// @notice Thrown when an empty signature string is supplied.
    error TemplateRegistryV1__EmptySignature();

    /// @notice Thrown when `seedStandardTemplate` / `propose` would overwrite an
    ///         already-stored template at the same key.
    error TemplateRegistryV1__AlreadyRegistered(bytes32 key);

    /// @notice Thrown when `approve(key)` is called on a key that has no proposal recorded.
    error TemplateRegistryV1__NotProposed(bytes32 key);

    /// @notice Thrown when `approve(key)` is called on a key that is already approved.
    error TemplateRegistryV1__AlreadyApproved(bytes32 key);

    /// @notice Thrown when `revoke(key)` is called on a key that is not currently approved.
    error TemplateRegistryV1__NotApproved(bytes32 key);

    /// @notice Thrown when `reseedStandardTemplate` targets a key that exists but was
    ///         deliberately revoked. Re-seeding is for the post-upgrade re-register flow
    ///         (a new implementation has a new codehash → new key); silently un-revoking
    ///         bytecode an auditor pulled would bypass that decision. Re-approve via
    ///         `propose` + `approve` if the revoke is meant to be reversed.
    error TemplateRegistryV1__RevokedTemplate(bytes32 key);

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Template store keyed by `keccak256(abi.encode(bytecodeHash, selector))`.
    mapping(bytes32 => Template) private _templates;

    /*//////////////////////////////////////////////////////////////
                            INITIALIZERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the registry with its trusted endpoint + AccessManager authority.
     * @param _endpoint Trusted Rayls endpoint address.
     * @param authority_ AccessManager address used for `restricted` gating.
     */
    function initialize(address _endpoint, address authority_) public initializer {
        __UUPSUpgradeable_init();
        RaylsAppV1.initialize(_endpoint);
        resourceId = Constants.RESOURCE_ID_TEMPLATE_REGISTRY;
        _initializeAuthority(authority_);
    }

    /// @dev OZ UUPS upgrade authorization — selector-based gating via AccessManager.
    function _authorizeUpgrade(address /*newImplementation*/) internal view override {
        _checkCanCall(msg.sender, msg.sig);
    }

    /*//////////////////////////////////////////////////////////////
                        STANDARD-TEMPLATE SEEDING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice One-shot seeding of an audited standard's `(bytecodeHash, signature)` pair.
     * @dev Auditor-only. Skips the propose step because the auditor is registering
     *      canonical Rayls bytecode they already trust. Reverts if the key already
     *      exists — re-seeding the same standard is an operator error, not a normal flow.
     * @param bytecodeHash Runtime `extcodehash` of the audited contract.
     * @param signature Canonical function signature, e.g. "mint(address,uint256,bytes32)".
     */
    function seedStandardTemplate(bytes32 bytecodeHash, string calldata signature)
        external
        virtual
        restricted
    {
        if (bytecodeHash == bytes32(0)) revert TemplateRegistryV1__EmptyBytecodeHash();
        if (bytes(signature).length == 0) revert TemplateRegistryV1__EmptySignature();

        (bytes4 selector, bytes32 key) = _deriveKey(bytecodeHash, signature);

        if (_templates[key].bytecodeHash != bytes32(0)) {
            revert TemplateRegistryV1__AlreadyRegistered(key);
        }

        uint64 approvedAt = uint64(block.number);
        _templates[key] = Template({
            bytecodeHash:   bytecodeHash,
            signature:      signature,
            selector:       selector,
            approvedAtBlock: approvedAt,
            approved:       true
        });

        emit TemplateApproved(key, bytecodeHash, signature, selector, approvedAt);
        _broadcastApproved(bytecodeHash, signature, approvedAt);
    }

    /**
     * @notice Re-seed an audited standard's `(bytecodeHash, signature)` pair after a UUPS
     *         upgrade changes the contract's runtime codehash.
     * @dev Auditor-only. Intended to be called from the UUPS upgrade runbook BEFORE/AT
     *      activation of the new implementation, so the settlement-mint and revert re-credit
     *      paths (`executeProgramData`) keep clearing the codehash gate. Re-broadcasts the
     *      approval to every PN replica via the existing `_broadcastApproved` fan-out (so the
     *      replica path is unchanged) and additionally emits `StandardTemplateReseeded` for
     *      off-chain audit of the re-seed event distinct from a first-time seed.
     *
     *      Idempotency is intentionally asymmetric to the key's prior state:
     *        - absent key          → first-time write (the post-upgrade new-codehash path);
     *        - approved key        → no-op: returns early without re-writing, re-emitting, or
     *                                re-broadcasting (unlike `seedStandardTemplate`, which reverts),
     *                                so a re-run of the runbook step is a safe and cheap no-op that
     *                                does not spam every PN replica with a redundant approval;
     *        - proposed-only key   → overwrites in place (approves it). `propose` is open to anyone, so an
     *                                external actor pre-empting the runbook with a matching `propose` must
     *                                not be able to make the reseed revert; it is distinguished from a
     *                                revoke by `approvedAtBlock == 0`.
     *        - revoked key         → reverts `TemplateRegistryV1__RevokedTemplate`. A revoke is a
     *                                deliberate auditor decision to pull bytecode; re-seeding must not
     *                                silently un-revoke it. Use `propose` + `approve` to reverse a revoke.
     * @param bytecodeHash New runtime `extcodehash` of the audited contract.
     * @param signature Canonical function signature, e.g. "crossMintStandard(address,uint256,bytes32)".
     */
    function reseedStandardTemplate(bytes32 bytecodeHash, string calldata signature)
        external
        virtual
        restricted
    {
        if (bytecodeHash == bytes32(0)) revert TemplateRegistryV1__EmptyBytecodeHash();
        if (bytes(signature).length == 0) revert TemplateRegistryV1__EmptySignature();

        (bytes4 selector, bytes32 key) = _deriveKey(bytecodeHash, signature);

        // A key that was once approved and then revoked must not be silently un-revoked by a reseed.
        // `revoke` stamps `approvedAtBlock = block.number (> 0)`, whereas a key that was merely
        // `propose`d but never approved keeps `approvedAtBlock == 0`. Gate on `approvedAtBlock > 0` so
        // only genuinely-revoked keys revert: a proposed-but-never-approved key (which anyone can
        // create, since `propose` is open) is overwritten in place rather than reverting with a
        // misleading `RevokedTemplate`. (A first-time seed has bytecodeHash == 0 and is allowed.)
        Template storage existing = _templates[key];
        if (existing.bytecodeHash != bytes32(0) && !existing.approved && existing.approvedAtBlock > 0) {
            revert TemplateRegistryV1__RevokedTemplate(key);
        }

        // No-op short-circuit: the key already holds this exact, currently-approved template.
        // `key` pins (bytecodeHash, selector), so an approved match means the stored signature is
        // already this one — a re-run of the runbook step. Skip the redundant 5-slot struct write
        // AND, more importantly, the redundant `_broadcastApproved` fan-out to every PN replica.
        // (Only `approvedAtBlock` would have changed, and it carries no semantic meaning for an approval.)
        if (existing.approved) {
            return;
        }

        uint64 approvedAt = uint64(block.number);
        _templates[key] = Template({
            bytecodeHash:   bytecodeHash,
            signature:      signature,
            selector:       selector,
            approvedAtBlock: approvedAt,
            approved:       true
        });

        emit TemplateApproved(key, bytecodeHash, signature, selector, approvedAt);
        // `StandardTemplateReseeded` omits `signature` (carried by the co-emitted
        // `TemplateApproved`); off-chain consumers correlate the two by `key` to recover it.
        emit StandardTemplateReseeded(key, bytecodeHash, selector, approvedAt);
        _broadcastApproved(bytecodeHash, signature, approvedAt);
    }

    /*//////////////////////////////////////////////////////////////
                            CUSTOM-TEMPLATE FLOW
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Propose a custom `(bytecodeHash, signature)` for auditor review.
     * @dev Open to any caller. Records the template with `approved == false`; an
     *      auditor flips `approved` via `approve(key)`. Reverts if the key already
     *      exists — re-proposing is an explicit no-op the proposer should avoid.
     * @param bytecodeHash Runtime `extcodehash` of the custom contract.
     * @param signature Canonical function signature.
     * @return key Derived template key, equal to `keccak256(abi.encode(bytecodeHash, selector))`.
     */
    function propose(bytes32 bytecodeHash, string calldata signature)
        external
        virtual
        returns (bytes32 key)
    {
        if (bytecodeHash == bytes32(0)) revert TemplateRegistryV1__EmptyBytecodeHash();
        if (bytes(signature).length == 0) revert TemplateRegistryV1__EmptySignature();

        bytes4 selector;
        (selector, key) = _deriveKey(bytecodeHash, signature);

        if (_templates[key].bytecodeHash != bytes32(0)) {
            revert TemplateRegistryV1__AlreadyRegistered(key);
        }

        _templates[key] = Template({
            bytecodeHash:   bytecodeHash,
            signature:      signature,
            selector:       selector,
            approvedAtBlock: 0,
            approved:       false
        });

        emit TemplateProposed(key, bytecodeHash, signature, selector, msg.sender);
    }

    /**
     * @notice Approve a previously-proposed custom template.
     * @dev Auditor-only. Stamps `approvedAtBlock = block.number` so the replica can
     *      apply staleness ordering across repeated approve/revoke cycles on the
     *      same key.
     * @param key Template key returned by `propose`.
     */
    function approve(bytes32 key) external virtual restricted {
        Template storage t = _templates[key];
        if (t.bytecodeHash == bytes32(0)) revert TemplateRegistryV1__NotProposed(key);
        if (t.approved) revert TemplateRegistryV1__AlreadyApproved(key);

        uint64 approvedAt = uint64(block.number);
        t.approved        = true;
        t.approvedAtBlock = approvedAt;

        emit TemplateApproved(key, t.bytecodeHash, t.signature, t.selector, approvedAt);
        _broadcastApproved(t.bytecodeHash, t.signature, approvedAt);
    }

    /**
     * @notice Revoke an approved template.
     * @dev Auditor-only. Clears `approved` and stamps a fresh `approvedAtBlock` (used by
     *      the replica purely as a monotonic ordering token — the replica drops the
     *      revoke event if its stored `lastUpdatedAt` is newer). Leaves the
     *      signature and bytecodeHash in storage so a future re-approval against
     *      the same key keeps its history.
     * @param key Template key to revoke.
     */
    function revoke(bytes32 key) external virtual restricted {
        Template storage t = _templates[key];
        if (!t.approved) revert TemplateRegistryV1__NotApproved(key);

        uint64 revokedAt = uint64(block.number);
        t.approved        = false;
        t.approvedAtBlock = revokedAt;

        emit TemplateRevoked(key, t.bytecodeHash, t.selector, revokedAt);
        _broadcastRevoked(t.bytecodeHash, t.selector, revokedAt);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Read a template by key.
    function getTemplate(bytes32 key) external view returns (Template memory) {
        return _templates[key];
    }

    /// @notice Compute the storage key for a `(bytecodeHash, selector)` pair.
    function getKey(bytes32 bytecodeHash, bytes4 selector) external pure returns (bytes32) {
        return keccak256(abi.encode(bytecodeHash, selector));
    }

    /// @dev Derive a template's `(selector, key)` from its bytecode hash and canonical
    ///      signature. Shared by `seedStandardTemplate`, `reseedStandardTemplate`, and
    ///      `propose` so the selector/key derivation stays identical across all three.
    function _deriveKey(bytes32 bytecodeHash, string calldata signature)
        internal
        pure
        returns (bytes4 selector, bytes32 key)
    {
        selector = bytes4(keccak256(bytes(signature)));
        key      = keccak256(abi.encode(bytecodeHash, selector));
    }

    /// @notice Returns the contract version.
    /// @dev Bumped to 2 when `reseedStandardTemplate` was added, so downstream consumers
    ///      (relayer / governance tooling / monitoring) can detect the new capability.
    function contractVersion() external pure virtual override returns (uint256) {
        return 2;
    }

    /*//////////////////////////////////////////////////////////////
                        CROSS-CHAIN BROADCAST
    //////////////////////////////////////////////////////////////*/

    /// @dev Fan-out approval to every PN's replica via the existing Endpoint
    ///      `sendToResourceId(CHAIN_ID_ALL_PARTICIPANTS, ...)` primitive — the
    ///      same shape `TokenFreezeManagerV1.broadcastFrozenToken` uses. The
    ///      dest-relayer's `MessageDispatched` listener routes the message to
    ///      every PN's `receivePayload`, which dispatches into
    ///      `TemplateRegistryReplicaV1.onTemplateApproved`.
    ///      Declared `internal` (not `private`) so a future UUPS implementation
    ///      (`TemplateRegistryV2`, ...) can reuse this security-sensitive fan-out
    ///      without re-implementing it.
    function _broadcastApproved(
        bytes32 bytecodeHash,
        string memory signature,
        uint64  approvedAt
    ) internal virtual {
        BridgedTransferMetadata memory emptyMetadata;
        endpoint.sendToResourceId(
            Constants.CHAIN_ID_ALL_PARTICIPANTS,
            Constants.RESOURCE_ID_TEMPLATE_REGISTRY,
            abi.encodeWithSelector(
                TemplateRegistryReplicaV1.onTemplateApproved.selector,
                bytecodeHash,
                signature,
                approvedAt
            ),
            bytes(''),
            bytes(''),
            bytes(''),
            emptyMetadata
        );
    }

    /// @dev Fan-out revocation to every PN's replica. Carries only the
    ///      selector (no signature) — the replica already stored the signature
    ///      on the matching approval, and the on-chain staleness guard uses
    ///      `revokedAt` regardless.
    ///      Declared `internal` (not `private`) so a future UUPS implementation can
    ///      reuse this security-sensitive fan-out without re-implementing it.
    function _broadcastRevoked(
        bytes32 bytecodeHash,
        bytes4  selector,
        uint64  revokedAt
    ) internal virtual {
        BridgedTransferMetadata memory emptyMetadata;
        endpoint.sendToResourceId(
            Constants.CHAIN_ID_ALL_PARTICIPANTS,
            Constants.RESOURCE_ID_TEMPLATE_REGISTRY,
            abi.encodeWithSelector(
                TemplateRegistryReplicaV1.onTemplateRevoked.selector,
                bytecodeHash,
                selector,
                revokedAt
            ),
            bytes(''),
            bytes(''),
            bytes(''),
            emptyMetadata
        );
    }
}
