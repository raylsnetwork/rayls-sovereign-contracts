// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import '../../rayls-protocol-sdk/RaylsAppV1.sol';
import '../../rayls-protocol-sdk/Constants.sol';
import '../../privateHub/AccessControl/RaylsAccessManaged.sol';
import '../../privateHub/TemplateRegistry/interfaces/ITemplateRegistry.sol';
import './libraries/SignatureParams.sol';

/**
 * @title TemplateRegistryReplicaV1
 * @notice PN-side read-only mirror of the PNH `TemplateRegistryV1`.
 * @dev Inbound `onTemplateApproved` / `onTemplateRevoked` calls are gated identically
 *      to `ParticipantStorageReplicaV1`: the `restricted` modifier (Endpoint-only via
 *      AccessManager wiring) plus an explicit check that
 *      `_getFromChainIdOnReceiveMethod() == endpoint.getPrivateHubId()`. Authenticity
 *      of the originating PNH message is guaranteed by the Endpoint's signature
 *      verification, so the replica only needs to enforce ordering on the same key —
 *      `_lastUpdatedAt[key]` carries the most recent `(approvedAt | revokedAt)` block
 *      number and stale events are dropped silently.
 *
 *      The `check(target, selector)` view is the single security gate consumed by the
 *      `ProgrammabilityExecutor`. One lookup: hash `(target.codehash, selector)`,
 *      read the stored `approved` flag.
 *
 *      Approvals and revocations are broadcast from the PNH `TemplateRegistryV1` and applied
 *      here via `onTemplateApproved` / `onTemplateRevoked`; the `ProgrammabilityExecutor`
 *      consults `check` on every dispatched blob. `checkWithParamCount` is retained for
 *      interface compatibility but is no longer on the dispatch hot path.
 */
contract TemplateRegistryReplicaV1 is
    Initializable,
    RaylsAppV1,
    UUPSUpgradeable,
    RaylsAccessManaged
{
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a state-changing call did not originate from PNH.
    /// @param fromChainId Chain id reported by `_getFromChainIdOnReceiveMethod()`.
    /// @param hubId Configured private hub id reported by the endpoint.
    error TemplateRegistryReplicaV1__NotFromPrivateHub(uint256 fromChainId, uint256 hubId);

    /// @notice Thrown when `onTemplateApproved` is invoked with a zero bytecode hash —
    ///         see `TemplateRegistryV1`'s equivalent check for the rationale.
    error TemplateRegistryReplicaV1__EmptyBytecodeHash();

    /// @notice Thrown when `onTemplateApproved` is invoked with an empty signature.
    error TemplateRegistryReplicaV1__EmptySignature();

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Template store, identical key shape to PNH.
    mapping(bytes32 => ITemplateRegistry.Template) private _templates;

    /// @notice Per-key monotonic ordering token (`approvedAt` or `revokedAt`). Used to
    ///         drop stale events on the same key — events on different keys are
    ///         independent.
    mapping(bytes32 => uint64) private _lastUpdatedAt;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event TemplateMirrored(
        bytes32 indexed key,
        bytes32 bytecodeHash,
        bytes4  selector,
        uint64  approvedAt
    );

    event TemplateRevocationMirrored(
        bytes32 indexed key,
        bytes32 bytecodeHash,
        bytes4  selector,
        uint64  revokedAt
    );

    /*//////////////////////////////////////////////////////////////
                            INITIALIZERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the replica with its trusted endpoint + AccessManager authority.
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
                        INBOUND CROSS-CHAIN MESSAGES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Mirror an approval recorded on PNH.
     * @dev Endpoint-only via `restricted` + explicit hub-id check. Re-derives the
     *      selector from the signature locally rather than trusting a selector arg
     *      from the sender (eliminates a class of "valid signature, mismatched
     *      selector" mistakes). Stale events (`approvedAt <= _lastUpdatedAt[key]`)
     *      are dropped silently — replays and out-of-order delivery on the same key
     *      become no-ops.
     */
    function onTemplateApproved(
        bytes32 bytecodeHash,
        string  calldata signature,
        uint64  approvedAt
    ) external virtual restricted {
        _assertFromPrivateHub();

        if (bytecodeHash == bytes32(0)) revert TemplateRegistryReplicaV1__EmptyBytecodeHash();
        if (bytes(signature).length == 0) revert TemplateRegistryReplicaV1__EmptySignature();

        bytes4  selector = bytes4(keccak256(bytes(signature)));
        bytes32 key      = keccak256(abi.encode(bytecodeHash, selector));

        if (approvedAt <= _lastUpdatedAt[key]) return;

        _templates[key] = ITemplateRegistry.Template({
            bytecodeHash:   bytecodeHash,
            signature:      signature,
            selector:       selector,
            approvedAtBlock: approvedAt,
            approved:       true
        });
        _lastUpdatedAt[key] = approvedAt;

        emit TemplateMirrored(key, bytecodeHash, selector, approvedAt);
    }

    /**
     * @notice Mirror a revocation recorded on PNH.
     * @dev Endpoint-only via `restricted` + hub-id check. Revocations carry only the
     *      selector (no signature) because the registry already has the signature
     *      from the original approval. Stale events are dropped silently.
     */
    function onTemplateRevoked(
        bytes32 bytecodeHash,
        bytes4  selector,
        uint64  revokedAt
    ) external virtual restricted {
        _assertFromPrivateHub();

        bytes32 key = keccak256(abi.encode(bytecodeHash, selector));
        if (revokedAt <= _lastUpdatedAt[key]) return;

        // Preserve the stored signature so explorers can still resolve the key history.
        _templates[key].approved        = false;
        _templates[key].approvedAtBlock = revokedAt;
        _lastUpdatedAt[key]             = revokedAt;

        emit TemplateRevocationMirrored(key, bytecodeHash, selector, revokedAt);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The single security gate consumed by `ProgrammableExecutor`.
     * @dev One lookup: hash `(target.codehash, selector)`, return `approved`.
     *      Returns `false` for unknown keys and for revoked templates.
     * @param target Contract address whose runtime bytecode is being matched.
     * @param selector 4-byte function selector being matched.
     * @return True iff `(target.codehash, selector)` matches an approved template.
     */
    function check(address target, bytes4 selector) external view virtual returns (bool) {
        bytes32 key = keccak256(abi.encode(target.codehash, selector));
        return _templates[key].approved;
    }

    /**
     * @notice Gate check plus the approved signature's top-level parameter count, in one lookup.
     * @dev Consumed by `ProgrammabilityExecutorV1` to locate the trailing `originSender` head word
     *      when dispatching an owner-attested call. The count is parsed on-read from the stored
     *      canonical signature; signatures are short and the parse is cheap relative to a
     *      cross-chain settlement tx. Returns `(false, 0)` for unknown or revoked keys.
     * @param target Contract address whose runtime bytecode is being matched.
     * @param selector 4-byte function selector being matched.
     * @return approved True iff `(target.codehash, selector)` matches an approved template.
     * @return paramCount Top-level parameter count of the approved signature (0 if not approved).
     */
    function checkWithParamCount(address target, bytes4 selector)
        external
        view
        virtual
        returns (bool approved, uint256 paramCount)
    {
        bytes32 key = keccak256(abi.encode(target.codehash, selector));
        ITemplateRegistry.Template storage t = _templates[key];
        if (!t.approved) return (false, 0);
        return (true, SignatureParams.paramCount(t.signature));
    }

    /// @notice Read a mirrored template by key.
    function getTemplate(bytes32 key) external view returns (ITemplateRegistry.Template memory) {
        return _templates[key];
    }

    /// @notice Read the last-applied ordering token for a key.
    function getLastUpdatedAt(bytes32 key) external view returns (uint64) {
        return _lastUpdatedAt[key];
    }

    /// @notice Compute the storage key for a `(bytecodeHash, selector)` pair.
    function getKey(bytes32 bytecodeHash, bytes4 selector) external pure returns (bytes32) {
        return keccak256(abi.encode(bytecodeHash, selector));
    }

    /// @notice Returns the contract version.
    function contractVersion() external pure virtual returns (uint256) {
        return 1;
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Reverts unless the inbound cross-chain message originated from PNH.
    ///      `_getFromChainIdOnReceiveMethod()` is appended to calldata by the
    ///      Endpoint's MessageLib on receive; `getPrivateHubId()` is the
    ///      endpoint-configured hub id.
    function _assertFromPrivateHub() internal view {
        uint256 fromChainId = _getFromChainIdOnReceiveMethod();
        uint256 hubId       = endpoint.getPrivateHubId();
        if (fromChainId != hubId) {
            revert TemplateRegistryReplicaV1__NotFromPrivateHub(fromChainId, hubId);
        }
    }
}
