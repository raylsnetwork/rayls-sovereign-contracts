// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol';
import '../../rayls-protocol-sdk/RaylsAppV1.sol';
import '../../rayls-protocol-sdk/Constants.sol';
import '../../privateHub/AccessControl/RaylsAccessManaged.sol';
import '../../rayls-protocol-sdk/libraries/SharedObjects.sol';
import '../TemplateRegistryReplica/interfaces/ITemplateRegistryReplica.sol';

/**
 * @title ProgrammabilityExecutorV1
 * @notice Standalone per-PN dispatcher for guardrailed cross-chain programmability.
 * @dev One instance per Privacy Node. The relayer submits every cross-chain programmable call to
 *      this contract's `executeProgramData(SharedObjects.EnygmaProgramData[],uint256,address)`. For
 *      each step `{resourceId, contractAddress, selector, args}` the executor:
 *        1. resolves the target from EXACTLY ONE of `resourceId` (via the PN's `EndpointV1` resource
 *           registry) or `contractAddress` (used directly),
 *        2. gates `(target.codehash, selector)` through the local `TemplateRegistryReplica`,
 *        3. for owner-attested selectors, dispatches `target.call(selector ‖ args ‖ originSender)`,
 *           appending the attested `originSender` as a trusted 20-byte calldata tail — the same
 *           origin-encoding the Rayls endpoint uses for cross-chain receive methods. The target
 *           reads it back via `_getMsgSenderOnReceiveMethod()`; settlement (`crossMintStandard`)
 *           gets NO tail (it carries no origin and its value is conservation-checked instead).
 *      The whole array runs in one EVM frame — any revert (gate failure, unknown resource,
 *      inner-call revert) unwinds every step earlier in the array. This is the atomicity
 *      primitive that lets a sender stamp `[mintStep, userStep]` and get "the transfer
 *      happened iff the downstream call succeeded."
 *
 *      Tokens (`RaylsEnygmaHandler`, `Rayls*`) and the `Dvp*` family are dispatch *targets*,
 *      not dispatchers — they expose their normal `restricted` external functions
 *      (`crossMint`, `burn`, swap settlement) and the executor reaches them via `target.call`.
 *      Because the executor address holds the RELAYER role on the AccessManager, those
 *      handlers' `restricted` modifiers admit the executor exactly as they admit the relayer
 *      key today; no per-token `onlyExecutor` modifier is required.
 *
 *      Authorization model: `executeProgramData` is `restricted` and the deploy script maps
 *      its selector to the RELAYER role. This composes with the CTS-driven
 *      `add-authorized-relayers` flow (multiple relayer keys for HA / rotation) without the
 *      executor needing redeploy.
 */
contract ProgrammabilityExecutorV1 is
    Initializable,
    RaylsAppV1,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    RaylsAccessManaged
{
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a step's `resourceId` does not resolve to a deployed contract.
    /// @param index Position of the offending step in the array.
    /// @param resourceId The unresolved resource id.
    error ProgramData__UnknownResourceId(uint256 index, bytes32 resourceId);

    /// @notice Thrown when a step sets BOTH `resourceId` and `contractAddress`. The target must be
    ///         addressed by exactly one of them.
    /// @param index Position of the offending step in the array.
    error ProgramData__BothTargetsProvided(uint256 index);

    /// @notice Thrown when a step sets NEITHER `resourceId` nor `contractAddress`.
    /// @param index Position of the offending step in the array.
    error ProgramData__NoTargetProvided(uint256 index);

    /// @notice Thrown when `(target.codehash, selector)` does not match an approved template.
    /// @param index Position of the offending blob in the array.
    /// @param bytecodeHash Runtime `codehash` of the resolved target.
    /// @param selector The 4-byte selector that failed the gate.
    error ProgramData__UnapprovedTemplate(uint256 index, bytes32 bytecodeHash, bytes4 selector);

    /// @notice Thrown when the gate-approved inner `target.call` reverts.
    /// @param index Position of the offending blob in the array.
    /// @param resourceId The blob's resource id.
    /// @param selector The dispatched selector.
    /// @param ret Raw revert data bubbled up from the target.
    error ProgramData__Reverted(uint256 index, bytes32 resourceId, bytes4 selector, bytes ret);

    /// @notice Thrown when a configured dependency address is zero at initialization.
    error ProgrammabilityExecutorV1__ZeroAddress();

    /// @notice Thrown when a dispatch carries more than `MAX_BLOBS` blobs. A guardrail against a
    ///         pathologically large array exhausting block gas; well above any practical transfer.
    /// @param count The supplied blob count.
    error ProgramData__TooManyBlobs(uint256 count);

    /// @notice Thrown when the sum of `crossMintStandard` mint amounts in the blob array does
    ///         not equal the relayer-supplied `expectedMintTotal` (the value the PNH authorized
    ///         for this transfer). Guards against a tampered/mismatched settlement mint amount.
    /// @param expected The relayer-supplied expected total (this recipient's PNH-received value).
    /// @param actual The summed `_value` across all `crossMintStandard` blobs in the array.
    error ProgramData__MintTotalMismatch(uint256 expected, uint256 actual);

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Selector of `RaylsEnygmaHandler.crossMintStandard(address,uint256,bytes32)` — the
    ///         settlement mint blob whose `_value` is summed and conservation-checked against the
    ///         relayer-supplied `expectedMintTotal`. Declared as a constant (rather than imported)
    ///         so the executor stays decoupled from the token contract.
    bytes4 internal constant CROSS_MINT_STANDARD_SELECTOR =
        bytes4(keccak256('crossMintStandard(address,uint256,bytes32)'));

    /// @notice Upper bound on blobs per dispatch. A safety guardrail so a single oversized array
    ///         cannot consume all block gas; sized well above any realistic transfer fan-out.
    uint256 internal constant MAX_BLOBS = 256;

    /// @notice Local PN replica consulted as the single security gate per blob.
    ITemplateRegistryReplica public templateRegistryReplica;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted once per successfully dispatched blob.
    event ProgramDataExecuted(
        uint256 indexed index,
        bytes32 indexed resourceId,
        address target,
        bytes4  selector
    );

    /*//////////////////////////////////////////////////////////////
                            INITIALIZERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the executor with its trusted endpoint, replica, and authority.
     * @param _endpoint Trusted PN `EndpointV1` (provides `getAddressByResourceId`).
     * @param _templateRegistryReplica Local `TemplateRegistryReplicaV1` providing `check`.
     * @param authority_ AccessManager address used for `restricted` gating.
     */
    function initialize(
        address _endpoint,
        address _templateRegistryReplica,
        address authority_
    ) public initializer {
        if (_endpoint == address(0) || _templateRegistryReplica == address(0)) {
            revert ProgrammabilityExecutorV1__ZeroAddress();
        }
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        RaylsAppV1.initialize(_endpoint);
        templateRegistryReplica = ITemplateRegistryReplica(_templateRegistryReplica);
        _initializeAuthority(authority_);
    }

    /// @dev OZ UUPS upgrade authorization — selector-based gating via AccessManager.
    function _authorizeUpgrade(address /*newImplementation*/) internal view override {
        _checkCanCall(msg.sender, msg.sig);
    }

    /*//////////////////////////////////////////////////////////////
                            TARGET RESOLUTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Resolve a step's target to a contract address from EXACTLY ONE of its target fields.
     * @dev The step addresses its target by either `resourceId` (resolved via the receiver's
     *      endpoint resource registry) or a direct `contractAddress` — never both, never neither.
     *      Supplying both reverts `ProgramData__BothTargetsProvided`; supplying neither reverts
     *      `ProgramData__NoTargetProvided`. A `resourceId` that does not resolve to a deployed
     *      contract reverts `ProgramData__UnknownResourceId`. The `(target.codehash, selector)`
     *      gate runs downstream regardless of which field addressed the target, so a direct
     *      `contractAddress` pointing at unapproved bytecode is rejected exactly like a resourceId.
     * @param index Step index (for error context).
     * @param resourceId Resource id of the target (set this OR `contractAddress`).
     * @param contractAddress Direct target address (set this OR `resourceId`).
     * @return resolved The contract address to dispatch against.
     */
    function _resolveTarget(
        uint256 index,
        bytes32 resourceId,
        address contractAddress
    ) internal view returns (address resolved) {
        bool hasResourceId = resourceId != bytes32(0);
        bool hasAddress = contractAddress != address(0);

        if (hasResourceId && hasAddress) revert ProgramData__BothTargetsProvided(index);
        if (!hasResourceId && !hasAddress) revert ProgramData__NoTargetProvided(index);

        if (hasResourceId) {
            resolved = endpoint.getAddressByResourceId(resourceId);
            if (resolved == address(0)) revert ProgramData__UnknownResourceId(index, resourceId);
            return resolved;
        }
        return contractAddress;
    }

    /*//////////////////////////////////////////////////////////////
                            DISPATCH
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Dispatch an ordered array of gated program-data blobs in one atomic frame, attesting
     *         the originating EOA on the source chain and conserving the PNH-authorized mint value.
     * @dev RELAYER-gated via `restricted`. Each step is a `SharedObjects.EnygmaProgramData`
     *      `{resourceId, contractAddress, selector, args}`. For every step: resolve the target from
     *      EXACTLY ONE of `resourceId`/`contractAddress`, gate `(target.codehash, selector)` against
     *      the replica, then `target.call(selector ‖ args [‖ originSender])`. Any failure reverts the
     *      whole transaction, unwinding earlier steps (including a preceding mint) — that is the
     *      transfer-plus-call atomicity guarantee.
     *
     *      Origin attestation: every NON-settlement blob is dispatched with the attested
     *      `originSender` APPENDED as a trusted 20-byte calldata tail — `selector ‖ args ‖
     *      bytes20(originSender)`. This is the same origin-encoding the Rayls endpoint uses for
     *      cross-chain receive methods (see `MessageLib.executeMessage` / `RaylsApp`): the target
     *      reads it via `_getMsgSenderOnReceiveMethod()`, which reads the LAST 20 calldata bytes by
     *      absolute offset (`calldatasize() - 20`), independent of the target's ABI layout. The tail
     *      is forgery-proof because the executor controls the physical end of calldata: a caller's
     *      `args` can be any length, but the executor's `bytes20` is always the final word, so a
     *      caller cannot place a value after it. The userBlob's `args` therefore encode ONLY the
     *      target's leading parameters (no `originSender` slot). Owner-restricted flows (e.g. ERC20
     *      `crossMint(address,uint256)`) read the tail and perform the contract-scoped `TOKEN_OWNER`
     *      check in-body. Because the targets are `restricted` (executor/RELAYER-only), the tail-read
     *      is the trusted origin channel, not a security primitive on its own.
     *
     *      Conservation check: while walking the array, the `_value` of every `crossMintStandard`
     *      blob is summed. The settlement selector (`crossMintStandard`) is exempt from origin
     *      attestation — it carries no origin and is dispatched WITHOUT the tail, with its native
     *      args. After
     *      dispatch the total must equal `expectedMintTotal` — the value the relayer received for
     *      this transfer from the PNH batch (this recipient's `ToAmount`). A blob array that would
     *      mint more or less than the PNH authorized reverts atomically with
     *      `ProgramData__MintTotalMismatch`. The relayer supplies the authority; the blobs cannot
     *      mint a different amount than the PNH-received value they settle.
     *
     *      `originSender` is supplied by the relayer based on the cross-chain message's attested
     *      source-chain `from` (e.g. `PNHTransfer.from` for Enygma flows). The relayer faithfully
     *      forwarding this value is the same trust assumption as faithfully forwarding the message
     *      itself. It is per-call: every blob in one dispatch shares it, which is correct because
     *      the relayer splits the PNH batch to one dispatch per source sender (one recipient's
     *      blobs, one `from`) before calling this function.
     * @param steps Ordered program-data steps. An empty array is a no-op (requires
     *        `expectedMintTotal == 0`).
     * @param expectedMintTotal The PNH-authorized settlement-mint total for this dispatch.
     * @param originSender Attested EOA on the source chain that initiated this dispatch.
     */
    function executeProgramData(
        SharedObjects.EnygmaProgramData[] calldata steps,
        uint256 expectedMintTotal,
        address originSender
    )
        external
        virtual
        restricted
        nonReentrant
    {
        if (steps.length > MAX_BLOBS) revert ProgramData__TooManyBlobs(steps.length);

        uint256 mintedTotal = 0;

        for (uint256 i = 0; i < steps.length; i++) {
            bytes4 selector = steps[i].selector;
            bytes memory args = steps[i].args;

            address target = _resolveTarget(i, steps[i].resourceId, steps[i].contractAddress);

            if (!templateRegistryReplica.check(target, selector)) {
                revert ProgramData__UnapprovedTemplate(i, target.codehash, selector);
            }

            bytes memory callData;
            if (selector == CROSS_MINT_STANDARD_SELECTOR) {
                // Settlement blob: `crossMintStandard(address,uint256,bytes32)` carries no origin
                // (its mint amount is conservation-checked, not owner-gated). Decode-and-accumulate
                // and dispatch WITHOUT the origin tail — byte-identical to a plain native call.
                (, uint256 value, ) = abi.decode(args, (address, uint256, bytes32));
                mintedTotal += value;
                callData = bytes.concat(selector, args);
            } else {
                // Owner-attested path: append the attested origin as a trusted 20-byte calldata
                // tail. The target reads it via `_getMsgSenderOnReceiveMethod()` (absolute offset
                // `calldatasize() - 20`), so the read is independent of the target's ABI layout and
                // a caller cannot forge it — the executor controls the physical end of calldata.
                callData = bytes.concat(selector, args, bytes20(originSender));
            }

            (bool ok, bytes memory ret) = target.call(callData);
            if (!ok) revert ProgramData__Reverted(i, steps[i].resourceId, selector, ret);

            emit ProgramDataExecuted(i, steps[i].resourceId, target, selector);
        }

        if (mintedTotal != expectedMintTotal) {
            revert ProgramData__MintTotalMismatch(expectedMintTotal, mintedTotal);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the contract version.
    function contractVersion() external pure virtual returns (uint256) {
        return 1;
    }
}
