// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RaylsApp} from '../RaylsApp.sol';
import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';

import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import '../interfaces/IRaylsEndpoint.sol';
import '../RaylsMessage.sol';

import '../libraries/SharedObjects.sol';
import '../libraries/Utils.sol';
import '../Constants.sol';
import '../contracts/EnygmaPNHEvents.sol';

import {IEnygmaPNEvents} from '../interfaces/IEnygmaPNEvents.sol';
import {IPNCommunicator} from '../interfaces/IPNCommunicator.sol';
import {IRaylsAccessManager} from '../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol';
import {TOKEN_OWNER} from '../../privateHub/AccessControl/AccessManagerTypes.sol';
import {RaylsAccessManaged} from '../../privateHub/AccessControl/RaylsAccessManaged.sol';
import {IRaylsInitializer, RaylsTrustedInit} from '../IRaylsInitializer.sol';
import {IRaylsTokenStandard} from '../interfaces/IRaylsTokenStandard.sol';

/**
 * @title RaylsEnygmaHandler
 * @notice ERC20 base for Enygma tokens — Rayls' privacy-preserving fungible flavor with
 *         zero-knowledge DvP (Delivery vs Payment). Adds cross-chain transfer with reference
 *         ids, Dvp deposit/withdraw + ERC721/1155 swap orchestration, and PN communicator
 *         notifications.
 * @dev Inherits ERC20 + Initializable + ReentrancyGuard + RaylsAccessManaged. Cross-chain
 *      events are emitted via `IEnygmaPNEvents` (resolved by resourceId at call time);
 *      Dvp swap status is propagated via `IPNCommunicator`. Owner-gated selectors:
 *      mint, burn, setSwapValidityTime. RELAYER-gated selectors: crossRevertMint, crossMint,
 *      crossTransferRevertBatch, supplyUpdateRevert, receiveWithdrawFromDvp,
 *      notifySenderWithPNCommunicator, notifySenderAndReceiverWithPNCommunicator,
 *      dvpSwapCompleted. MESSAGE_EXECUTOR-gated selectors: crossTransferCheck.
 */
abstract contract RaylsEnygmaHandler is RaylsApp, ERC20, Initializable, ReentrancyGuard, RaylsAccessManaged, IRaylsTokenStandard {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    /// @notice Thrown when a cross-transfer entry has zero recipient, zero amount, or zero chain id.
    /// @param receiver Recipient address.
    /// @param value Amount.
    /// @param destChainId Destination chain id.
    error RaylsEnygmaHandler__ZeroValueArg(address receiver, uint256 value, uint256 destChainId);

    /// @notice Thrown when destination chain id equals current chain.
    /// @param chainId Same-chain id supplied by caller.
    error RaylsEnygmaHandler__WrongFunctionForSameChainId(uint256 chainId);

    /// @notice Thrown when a `from` address is invalid (zero or not a permitted source).
    /// @param from Invalid `from`.
    error RaylsEnygmaHandler__WrongAddress(address from);

    /// @notice Thrown when an address argument is the zero address but a non-zero value was required.
    /// @param addr Zero address argument.
    error RaylsEnygmaHandler__ZeroAddress(address addr);

    /// @notice Thrown when batch arrays have mismatching lengths.
    error RaylsEnygmaHandler__ArrayLengthMismatch();

    /// @notice Thrown when a batch operation receives an empty input array.
    error RaylsEnygmaHandler__EmptyArray();
    error RaylsEnygmaHandler__TooManyUniqueChainIds(uint256 count);

    /// @notice Thrown when access manager authority has not been set.
    error RaylsEnygmaHandler__AuthorityNotSet();

    /// @notice Thrown when a relayer-gated selector is called by a non-relayer.
    /// @param caller Calling address.
    error RaylsEnygmaHandler__NotRelayer(address caller);

    /// @notice Thrown when a mint or burn is requested with zero amount.
    error RaylsEnygmaHandler__ZeroAmount();

    /// @notice Thrown when init is called with decimals > MAX_DECIMALS (uint256-overflow guard).
    /// @param decimals Provided decimals value.
    error RaylsEnygmaHandler__InvalidDecimals(uint8 decimals);

    /// @notice Thrown when a callable target resolves to an EOA / unrelated address (no code).
    /// @param target Resolved address that has no contract code.
    error RaylsEnygmaHandler__CallableTargetNotContract(address target);

    /// @notice Thrown when a callable invocation reverts AND the inner revert returned no data.
    ///         When inner revert data IS available, the assembly bubble-up rethrows that
    ///         instead of this typed error so callers see the underlying reason.
    /// @param target Address whose call reverted.
    error RaylsEnygmaHandler__CallableExecutionFailed(address target);

    /// @notice Thrown when an Enygma DvP swap validity time falls outside
    ///         `[ENYGMA_DVP_SWAP_MIN_VALIDITY_TIME + 1, ENYGMA_DVP_SWAP_MAX_VALIDITY_TIME - 1]`.
    /// @param provided Caller-supplied validity time.
    /// @param min Minimum allowed validity time (exclusive).
    /// @param max Maximum allowed validity time (exclusive).
    error RaylsEnygmaHandler__SwapValidityOutOfRange(uint64 provided, uint64 min, uint64 max);

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/
    /// @notice Maximum number of decimals allowed. uint256 max ≈ 1.158e77, so 10^77 fits but 10^78 overflows.
    uint8 private constant MAX_DECIMALS = 77;

    /// @notice Selector of `crossMintStandard(address,uint256,bytes32)` — the settlement-mint blob
    ///         stamped first in every recipient's program-data array. Declared as a constant so
    ///         `_buildProgramData` avoids a STATICCALL-per-call `this.crossMintStandard.selector`,
    ///         and matches `ProgrammabilityExecutorV1.CROSS_MINT_STANDARD_SELECTOR`.
    bytes4 private constant CROSS_MINT_STANDARD_SELECTOR =
        bytes4(keccak256('crossMintStandard(address,uint256,bytes32)'));

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    /// @notice Number of decimals for the token
    uint8 tokenDecimals;
    /// @notice Mapping to track the status of reference IDs for cross-chain transfers
    mapping(bytes32 => uint256) referenceIdsStatus;
    /// @notice Name of the token
    string tokenName;
    /// @notice Symbol of the token
    string tokenSymbol;
    /// @notice Flag indicating if this is a custom token implementation
    bool isCustom;
    /// @notice Nonce for the cross-chain transfers
    uint256 nonce;

    /// @notice Validity time for Enygma DvP swaps in seconds.
    uint64 public swapValidityTime;

    /**
     * @dev Enum representing the possible statuses of a reference ID in cross-chain transfers
     */
    enum ReferenceIdStatus {
        NOSTATUS, /// @notice No status assigned
        SENT, /// @notice Transfer has been sent
        RECEIVED, /// @notice Transfer has been received
        DEPOSITED, /// @notice Tokens have been deposited to Dvp
        WITHDRAW_ASKED, /// @notice Withdrawal has been requested
        WITHDRAW_RECEIVED, /// @notice Withdrawal has been received
        REVERTED /// @notice Transfer has been reverted on the source side (per-event terminal status)
    }

    /// @notice Emitted when a cross-transfer reference ID is generated
    event crossTransferReferenceId(bytes32 _referenceId);
    /// @notice Emitted when a transaction reference ID is generated
    event transactionReferenceId(bytes32 _referenceId);
    /// @notice Emitted when this Enygma token contract is created and initialized
    /// @param tokenAddress The address of the newly created token contract
    event RaylsEnygmaErc20TokenCreated(address indexed tokenAddress);

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Construct the handler with ERC20 metadata + trusted endpoint reference.
     * @dev `_disableInitializers()` blocks the upgradeable initialize path on the implementation.
     *      Reverts with `RaylsEnygmaHandler__InvalidDecimals` if `_decimals > MAX_DECIMALS`.
     * @param _name Name of the token.
     * @param _symbol Symbol of the token.
     * @param _endpoint Trusted Rayls endpoint address.
     * @param _owner Address that receives owner-gated selectors.
     * @param _decimals Number of decimals for the token (<= MAX_DECIMALS).
     * @param _isCustom True for custom-token issuer flow; false for the standard template path.
     */
    constructor(
        string memory _name,
        string memory _symbol,
        address _endpoint,
        address _owner,
        uint8 _decimals,
        bool _isCustom
    ) ERC20(_name, _symbol) RaylsApp(_endpoint, address(0), address(0)) {
        if (_decimals > MAX_DECIMALS) revert RaylsEnygmaHandler__InvalidDecimals(_decimals);
        tokenName = _name;
        tokenSymbol = _symbol;
        tokenDecimals = _decimals;
        isCustom = _isCustom;
        swapValidityTime = Utils.ENYGMA_DVP_SWAP_DEFAULT_VALIDITY_TIME;
        _registerAccessControl(_owner, address(0));
        _disableInitializers();
    }

    /**
     * @notice Canonical init entrypoint dispatched by RaylsContractFactoryV1.
     * @param userArgs ABI-encoded `(string name, string symbol, uint8 decimals)`.
     *                 Caller-supplied via the cross-chain init payload.
     * @param trusted  Trusted addresses + resourceId from {RaylsTrustedInit}, set by the
     *                 factory at deploy time. Caller cannot forge.
     */
    function initialize(bytes calldata userArgs, RaylsTrustedInit calldata trusted) public initializer {
        (string memory _name, string memory _symbol, uint8 _decimals) =
            abi.decode(userArgs, (string, string, uint8));
        if (_decimals > MAX_DECIMALS) revert RaylsEnygmaHandler__InvalidDecimals(_decimals);

        tokenName = _name;
        tokenSymbol = _symbol;
        tokenDecimals = _decimals;

        endpoint = IRaylsEndpoint(trusted.endpoint);
        resourceId = trusted.resourceId;
        _registerAccessControl(trusted.owner, trusted.caller);
        emit RaylsEnygmaErc20TokenCreated(address(this));
    }

    /**
     * @notice Set the validity time applied to subsequent Enygma DvP swaps.
     * @dev Restricted to owner-gated callers. Reverts when `_validityTime` is outside
     *      `[ENYGMA_DVP_SWAP_MIN_VALIDITY_TIME, ENYGMA_DVP_SWAP_MAX_VALIDITY_TIME]`.
     * @param _validityTime Validity time in seconds.
     */
    function setSwapValidityTime(uint64 _validityTime) public virtual restricted {
        if (
            _validityTime <= Utils.ENYGMA_DVP_SWAP_MIN_VALIDITY_TIME ||
            _validityTime >= Utils.ENYGMA_DVP_SWAP_MAX_VALIDITY_TIME
        ) {
            revert RaylsEnygmaHandler__SwapValidityOutOfRange(
                _validityTime,
                Utils.ENYGMA_DVP_SWAP_MIN_VALIDITY_TIME,
                Utils.ENYGMA_DVP_SWAP_MAX_VALIDITY_TIME
            );
        }
        swapValidityTime = _validityTime;
    }

    /**
     * @notice Transfer tokens only while this token is active on the local Privacy Node.
     * @param to Recipient address.
     * @param value Amount to transfer.
     * @return True if the transfer succeeds.
     */
    function transfer(address to, uint256 value) public virtual override whenPrivacyNodeActive returns (bool) {
        return super.transfer(to, value);
    }

    /**
     * @notice Approve token allowance only while this token is active on the local Privacy Node.
     * @param spender Account allowed to spend the caller's tokens.
     * @param value Allowance amount to set.
     * @return True if the approval succeeds.
     */
    function approve(address spender, uint256 value) public virtual override whenPrivacyNodeActive returns (bool) {
        return super.approve(spender, value);
    }

    /**
     * @notice Transfer tokens from another account only while this token is active on the local Privacy Node.
     * @param from Account whose tokens are transferred.
     * @param to Recipient address.
     * @param value Amount to transfer.
     * @return True if the transfer succeeds.
     */
    function transferFrom(address from, address to, uint256 value) public virtual override whenPrivacyNodeActive returns (bool) {
        return super.transferFrom(from, to, value);
    }

    /**
     * @notice Mint Enygma tokens and emit a corresponding `mint` event on the PN events contract.
     * @dev Restricted to owner-gated callers. Reverts on zero amount. Emits the cross-chain
     *      mint notification only when this token has been activated (`resourceId != 0`).
     * @param _to Recipient of the new tokens.
     * @param _value Amount in base units (wei). Must be > 0.
     */
    function mint(address _to, uint256 _value) public virtual restricted whenPrivacyNodeActive {
        if (_value == 0) revert RaylsEnygmaHandler__ZeroAmount();

        _mint(_to, _value);

        if (resourceId != bytes32(0)) {
            IEnygmaPNEvents(getEnygmaEventsAdress()).mint(resourceId, _to, _value);
        }
    }

    /**
     * @notice Re-mint tokens on the sender side after a failed cross-transfer; emits a revert
     *         notification on the PN events contract.
     * @dev Restricted to RELAYER. Counterpart to `_crossTransferFrom` failure path. Silent
     *      no-op when `_referenceId` has already been processed as REVERTED — defense-in-depth
     *      against relayer crash-retry double-mint inflation (issue #75).
     * @param _to Recipient (original sender of the failed cross-transfer).
     * @param _value Amount to re-mint.
     * @param _reason Human-readable revert reason for off-chain consumers.
     * @param _referenceId Reference id of the original cross-transfer; identifies the unique
     *                     event so duplicate calls (e.g., after a relayer restart) become no-ops.
     */
    function crossRevertMint(
        address _to,
        uint256 _value,
        string memory _reason,
        bytes32 _referenceId
    ) public virtual restricted {
        // Mirror the dual-check in `crossMint`: block both REVERTED (normal duplicate revert
        // path) and RECEIVED (defense-in-depth — a misrouted forward landing first must not
        // be followed by a revert that would re-mint the same value).
        uint256 prevStatus = referenceIdsStatus[_referenceId];
        if (prevStatus == uint256(ReferenceIdStatus.REVERTED) || prevStatus == uint256(ReferenceIdStatus.RECEIVED)) {
            return;
        }
        _requireHubActive();
       
        referenceIdsStatus[_referenceId] = uint256(ReferenceIdStatus.REVERTED);
        _mint(_to, _value);
        IEnygmaPNEvents(getEnygmaEventsAdress()).revertMint(resourceId, _value, _to, _reason);
    }

    /**
     * @notice Settlement mint for the auto-built mint blob of a cross-chain transfer.
     * @dev This is the selector stamped into every transfer's leading mint blob by
     *      `_buildProgramData`. It is idempotent on `_referenceId` (issue #75) because it
     *      settles a retryable cross-chain transfer: a relayer crash-retry or an out-of-order
     *      forward landing must not double-credit. NOT for use as a userBlob — composed program
     *      steps should use the unguarded `crossMint`/`crossBurn` variants instead.
     * @param _to Address to mint tokens to
     * @param _value Amount of tokens to mint
     * @param _referenceId Reference ID for the cross-chain transfer
     */
    function crossMintStandard(
        address _to,
        uint256 _value,
        bytes32 _referenceId
    ) public virtual restricted nonReentrant {
        // Validate the settlement inputs before consuming the referenceId: a zero amount or
        // zero recipient must not record RECEIVED, which would permanently block any retry
        // for this referenceId without ever delivering tokens. `_mint` reverts on a zero `_to`,
        // but the explicit guard makes the failure mode unambiguous and matches `crossMint`.
        if (_value == 0) revert RaylsEnygmaHandler__ZeroAmount();
        if (_to == address(0)) revert RaylsEnygmaHandler__ZeroAddress(_to);

        // Idempotency guard (issue #75): silent no-op when this referenceId has already
        // been processed. RECEIVED blocks legitimate retries after a relayer crash;
        // REVERTED blocks an out-of-order forward landing after the revert has been
        // observed (terminal-status protection).
        uint256 prevStatus = referenceIdsStatus[_referenceId];
        if (prevStatus == uint256(ReferenceIdStatus.RECEIVED) || prevStatus == uint256(ReferenceIdStatus.REVERTED)) {
            return;
        }

        _requireHubActive();
        
        referenceIdsStatus[_referenceId] = uint256(ReferenceIdStatus.RECEIVED);

        _mint(_to, _value);
    }

    /**
     * @notice Programmable mint, intended as a composed userBlob in `crossTransfer`.
     * @dev RELAYER-gated and seedable as a standard template so a userBlob can target this token's
     *      own resourceId with this selector. Unlike `crossMintStandard` it carries NO referenceId
     *      and NO idempotency guard: a userBlob is an explicit program step, not a retryable
     *      settlement, so it mints unconditionally on every dispatch. Emits the PN mint event when
     *      this token has been activated (`resourceId != 0`).
     *
     *      Owner-restricted by attested origin: the `ProgrammabilityExecutor` appends the attested
     *      source-chain sender (`PNHTransfer.from`) as a trusted 20-byte calldata tail, read here
     *      via `_getMsgSenderOnReceiveMethod()`. This function verifies that origin holds
     *      contract-scoped `TOKEN_OWNER` on this token. Safe because the function is `restricted`
     *      (only the executor/RELAYER can reach it) and the executor controls the tail.
     * @param _to Account to mint to.
     * @param _value Amount in base units (wei). Must be > 0.
     */
    /// @notice Origin-restriction check for Enygma's programmability path.
    error RaylsEnygmaHandler__NotTokenOwnerScoped(address originSender);

    function crossMint(address _to, uint256 _value) public virtual restricted nonReentrant {
        if (_value == 0) revert RaylsEnygmaHandler__ZeroAmount();
        _requireOriginIsOwner(_getMsgSenderOnReceiveMethod());

        _mint(_to, _value);

        if (resourceId != bytes32(0)) {
            IEnygmaPNEvents(getEnygmaEventsAdress()).mint(resourceId, _to, _value);
        }
    }

    /**
     * @notice Programmable burn, intended as a composed userBlob in `crossTransfer`.
     * @dev RELAYER-gated direct caller + owner-restricted by attested origin. The
     *      `ProgrammabilityExecutor` appends the attested origin (sourced from `PNHTransfer.from`)
     *      as a trusted 20-byte calldata tail, read here via `_getMsgSenderOnReceiveMethod()`; this
     *      function verifies that origin holds contract-scoped `TOKEN_OWNER` on this Enygma token.
     *      Carries NO referenceId and NO idempotency guard — it burns unconditionally on every
     *      dispatch. Emits the PN burn event when this token has been activated.
     * @param _from Account whose tokens are burned.
     * @param _value Amount in base units (wei). Must be > 0.
     */
    function crossBurn(address _from, uint256 _value) public virtual restricted nonReentrant {
        if (_value == 0) revert RaylsEnygmaHandler__ZeroAmount();
        _requireOriginIsOwner(_getMsgSenderOnReceiveMethod());

        _burn(_from, _value);

        if (resourceId != bytes32(0)) {
            IEnygmaPNEvents(getEnygmaEventsAdress()).burn(resourceId, _from, _value);
        }
    }

    /// @dev Mirror of RaylsErc20Handler._requireOriginIsOwner.
    function _requireOriginIsOwner(address originSender) internal view {
        address mgr = authority();
        if (originSender == address(0) || mgr == address(0)) {
            revert RaylsEnygmaHandler__NotTokenOwnerScoped(originSender);
        }
        // Use the built-in TOKEN_OWNER constant (= 2) rather than getRoleIdByName("TOKEN_OWNER"):
        // the name→id reverse map is not populated for built-in roles on the deployed AccessManager,
        // and every other AccessManager consumer references the role by this constant.
        (bool isMember, uint32 execDelay) =
            IRaylsAccessManager(mgr).hasContractScopedRole(TOKEN_OWNER, originSender, address(this));
        if (!isMember || execDelay != 0) {
            revert RaylsEnygmaHandler__NotTokenOwnerScoped(originSender);
        }
    }

    /**
     * @notice Resolve the Enygma PN events contract address via the endpoint's resource registry.
     * @return Address of the contract bound to `RESOURCE_ID_ENYGMA_PN_EVENTS`, or zero if unbound.
     */
    function getEnygmaEventsAdress() internal virtual returns (address) {
        return endpoint.getAddressByResourceId(Constants.RESOURCE_ID_ENYGMA_PN_EVENTS);
    }

    /**
     * @notice Single-recipient convenience wrapper around {crossTransfer}.
     * @dev Wraps args in length-1 arrays. `_userProgramData` is this single recipient's blob array
     *      (`[]` for a plain transfer); see {crossTransfer} for the blob format and origin rules.
     * @param _to Address to transfer tokens to
     * @param _value Amount of tokens to transfer
     * @param _toChainId Destination chain ID
     * @param _userProgramData This recipient's typed programmability steps (`[]` for a plain transfer).
     * @return bytes32 Reference ID of the transfer
     */
    function linearCrossTransfer(
        address _to,
        uint256 _value,
        uint256 _toChainId,
        SharedObjects.EnygmaProgramData[] memory _userProgramData
    ) public virtual returns (bytes32) {
        address[] memory toArray = new address[](1);
        uint256[] memory valueArray = new uint256[](1);
        uint256[] memory toChainIdArray = new uint256[](1);

        toArray[0] = _to;
        valueArray[0] = _value;
        toChainIdArray[0] = _toChainId;

        SharedObjects.EnygmaProgramData[][] memory userSteps = new SharedObjects.EnygmaProgramData[][](1);
        userSteps[0] = _userProgramData;
        return _crossTransferFrom(msg.sender, toArray, valueArray, toChainIdArray, userSteps);
    }

    /**
     * @notice Single-recipient convenience wrapper around {crossTransferFrom} (allowance-based).
     * @dev Wraps args in length-1 arrays, spends allowance from `_from`. `_userProgramData` is this
     *      single recipient's blob array (`[]` for a plain transfer); see {crossTransfer} for the
     *      blob format and origin rules.
     * @param _from Address to transfer tokens from (requires allowance)
     * @param _to Address to transfer tokens to
     * @param _value Amount of tokens to transfer
     * @param _toChainId Destination chain ID
     * @param _userProgramData This recipient's typed programmability steps (`[]` for a plain transfer).
     * @return bytes32 Reference ID of the transfer
     */
    function linearCrossTransferFrom(
        address _from,
        address _to,
        uint256 _value,
        uint256 _toChainId,
        SharedObjects.EnygmaProgramData[] memory _userProgramData
    ) public virtual returns (bytes32) {
        address[] memory toArray = new address[](1);
        uint256[] memory valueArray = new uint256[](1);
        uint256[] memory toChainIdArray = new uint256[](1);

        toArray[0] = _to;
        valueArray[0] = _value;
        toChainIdArray[0] = _toChainId;

        _spendAllowance(_from, msg.sender, _value);

        SharedObjects.EnygmaProgramData[][] memory userSteps = new SharedObjects.EnygmaProgramData[][](1);
        userSteps[0] = _userProgramData;
        return _crossTransferFrom(_from, toArray, valueArray, toChainIdArray, userSteps);
    }

    /**
     * @notice Initiates a cross-chain transfer of tokens, optionally composing each recipient's
     *         settlement mint with caller-supplied programmability blobs executed atomically on
     *         the receiver.
     * @dev For each recipient `i`, the handler prepends the auto-built mint blob to
     *      `_userProgramData[i]`, producing `[mintBlob, userStep_0, ...]`. The whole array is
     *      stamped on the source event and run under one `executeProgramData` tx on the receiver —
     *      mint and user calls all succeed or all revert. Each user step is independently gated by
     *      the template registry on the receiver. Pass an empty inner array (`[]`) per recipient
     *      for a plain transfer with no programmability.
     *
     *      Owner-attested steps (targets that verify the attested origin, e.g.
     *      `crossMint(address,uint256)`) encode `args` with ONLY the target's leading parameters —
     *      no origin slot. The receiver's `ProgrammabilityExecutor` appends the attested origin
     *      (`PNHTransfer.from`) as a trusted 20-byte calldata tail, which the target reads via
     *      `_getMsgSenderOnReceiveMethod()`. The tail is forgery-proof because the executor controls
     *      the physical end of calldata.
     * @param _to Array of recipient addresses on destination chains.
     * @param _value Array of token amounts to transfer.
     * @param _toChainId Array of destination chain IDs.
     * @param _userProgramData Per-recipient typed programmability steps (parallel to `_to`).
     * @return bytes32 Reference ID of the cross-chain transfer.
     */
    function crossTransfer(
        address[] memory _to,
        uint256[] memory _value,
        uint256[] memory _toChainId,
        SharedObjects.EnygmaProgramData[][] memory _userProgramData
    ) public virtual returns (bytes32) {
        return _crossTransferFrom(msg.sender, _to, _value, _toChainId, _userProgramData);
    }

    /**
     * @notice Emit a revert-transfer notification on the PN events contract for a previously
     *         dispatched cross-transfer.
     * @dev Restricted to RELAYER. Reverts if `_toChainId` equals current chain.
     * @param _from Original sender of the failed transfer.
     * @param _to Original recipient.
     * @param _value Amount.
     * @param _toChainId Destination chain id of the original transfer.
     * @param _referenceId Reference id of the original transfer.
     */
    function crossTransferRevertBatch(
        address _from,
        address _to,
        uint256 _value,
        uint256 _toChainId,
        bytes32 _referenceId
    ) public virtual restricted {
        // Idempotency guard (issue #75): silent no-op on duplicate revert calls so a
        // relayer crash-retry on the revert path can't double-emit and inflate.
        if (referenceIdsStatus[_referenceId] == uint256(ReferenceIdStatus.REVERTED)) {
            return;
        }
        // Placed after the idempotency early-return: an already-REVERTED referenceId must still
        // no-op even while the hub is inactive, but a fresh revert-batch is blocked (and left
        // retryable, no status recorded) when the token is not hub-active. Mirrors the
        // `_requireHubActive` guard on the ERC20/721/1155 receive-side settlement functions.
        _requireHubActive();
        // Marking REVERTED before the `require` is intentional: the require failure reverts
        // the whole transaction, so the status write is rolled back atomically — keeping
        // the assignment paired with the no-op check above (Effects before Interactions).
        referenceIdsStatus[_referenceId] = uint256(ReferenceIdStatus.REVERTED);

        require(
            _toChainId != endpoint.getChainId(),
            'Use another function to transfer to same ChainId'
        );

        address[] memory toArray = new address[](1);
        uint256[] memory valueArray = new uint256[](1);
        uint256[] memory toChainIdArray = new uint256[](1);

        toArray[0] = _to;
        valueArray[0] = _value;
        toChainIdArray[0] = _toChainId;

        // Revert-batch carries the mint step too, so the receiver re-mints the reversed
        // value via the same gated executeProgramData path.
        SharedObjects.EnygmaProgramData[][] memory revertProgramData = _buildProgramData(
            toArray,
            valueArray,
            _referenceId,
            new SharedObjects.EnygmaProgramData[][](1)
        );

        SharedObjects.PNHTransfer memory pnhTransfer = SharedObjects.PNHTransfer(
            resourceId,
            valueArray,
            toChainIdArray,
            toArray,
            _from,
            _referenceId,
            revertProgramData
        );
        IEnygmaPNEvents(getEnygmaEventsAdress()).sendTransferPNH(pnhTransfer);
    }

    /**
     * @notice Reverse a supply-update operation: burn tokens that were previously minted, or
     *         mint tokens that were previously burned.
     * @dev Restricted to RELAYER. The action is the inverse of the operation indicated by `_isMint`.
     * @param _amount Amount to reverse.
     * @param _recipient Address whose balance is adjusted.
     * @param _isMint True if the previous op was a mint (this call burns); false if a burn (this call mints).
     */
    function supplyUpdateRevert(uint256 _amount, address _recipient, bool _isMint) public virtual restricted whenHubActive {
        // Revert operation is the opposite of the actual operation that was performed
        if (_isMint) {
            // Burning the tokens that were minted before
            _burn(_recipient, _amount);
        } else {
            // Minting the tokens that were burned before
            _mint(_recipient, _amount);
        }
    }

    /**
     * @dev Internal function to handle cross-chain transfers from a specific address
     * @param _from Address to transfer tokens from
     * @param _to Array of recipient addresses
     * @param _value Array of token amounts
     * @param _toChainId Array of destination chain IDs
     * @return bytes32 Reference ID of the transfer
     */
    function _crossTransferFrom(
        address _from,
        address[] memory _to,
        uint256[] memory _value,
        uint256[] memory _toChainId,
        SharedObjects.EnygmaProgramData[][] memory _userProgramData
    ) private whenHubActive returns (bytes32) {
        // Input validation for _from address
        if (_from == address(0)) {
            revert RaylsEnygmaHandler__WrongAddress(_from);
        }

        // Array length validation: every per-recipient array must be parallel to `_to`,
        // including `_userProgramData` (one blob array per recipient).
        if (
            _to.length != _value.length ||
            _to.length != _toChainId.length ||
            _to.length != _userProgramData.length
        ) {
            revert RaylsEnygmaHandler__ArrayLengthMismatch();
        }
        if (_to.length == 0) {
            revert RaylsEnygmaHandler__EmptyArray();
        }

        // Validate each recipient address, value, and destination chain ID
        for (uint256 i = 0; i < _to.length; i++) {
            if (_to[i] == address(0) || _value[i] == 0 || _toChainId[i] == 0) {
                revert RaylsEnygmaHandler__ZeroValueArg(_to[i], _value[i], _toChainId[i]);
            }
            if (_toChainId[i] == endpoint.getChainId()) {
                revert RaylsEnygmaHandler__WrongFunctionForSameChainId(_toChainId[i]);
            }
        }

        uint256[5] memory uniqueChainIds;
        uint256 uniqueChainIdsCount = 0;

        for (uint256 i = 0; i < _toChainId.length; i++) {
            bool isUniqueChainId = true;
            for (uint256 j = 0; j < uniqueChainIdsCount; j++) {
                if (uniqueChainIds[j] == _toChainId[i]) {
                    isUniqueChainId = false;
                    break;
                }
            }
            if (isUniqueChainId) {
                if (uniqueChainIdsCount >= 5) {
                    revert RaylsEnygmaHandler__TooManyUniqueChainIds(uniqueChainIdsCount + 1);
                }
                uniqueChainIds[uniqueChainIdsCount] = _toChainId[i];
                uniqueChainIdsCount++;
            }
        }

        uint256 totalToSend = 0;
        for (uint256 i = 0; i < _to.length; i++) {
            totalToSend = totalToSend + _value[i];
        }

        _burn(_from, totalToSend);

        bytes32 _referenceId = MessageLib.computeEnygmaReferenceId(
            endpoint.getChainId(),
            _from,
            _toChainId,
            _to,
            abi.encode(block.number, nonce)
        );
        referenceIdsStatus[_referenceId] = uint256(ReferenceIdStatus.SENT);
        nonce++;

        // Build the per-recipient program-data array: each recipient gets a mint step
        // prepended to any caller-supplied user steps. The receiver's ProgrammabilityExecutor
        // dispatches the array atomically; the mint step targets this token's `crossMintStandard`.
        SharedObjects.EnygmaProgramData[][] memory programData =
            _buildProgramData(_to, _value, _referenceId, _userProgramData);

        SharedObjects.PNHTransfer memory pnhTransfer = SharedObjects.PNHTransfer(
            resourceId,
            _value,
            _toChainId,
            _to,
            _from,
            _referenceId,
            programData
        );
        IEnygmaPNEvents(getEnygmaEventsAdress()).sendTransferPNH(pnhTransfer);

        emit transactionReferenceId(_referenceId);

        emit crossTransferReferenceId(_referenceId);

        return _referenceId;
    }

    /**
     * @dev Build the per-recipient program-data array stamped on the source event.
     *      For each recipient `i`, the result is `[mintStep_i, userStep_i_0, ...]` where
     *      `mintStep_i = EnygmaProgramData(resourceId, address(0), crossMintStandard.selector,
     *      abi.encode(to_i, value_i, referenceId))`. The mint step is always first so a composed
     *      transfer mints before any downstream call; it targets this token by `resourceId`.
     * @param _to Recipient addresses.
     * @param _value Per-recipient amounts.
     * @param _referenceId Reference id shared by every mint step in this transfer.
     * @param _userProgramData Per-recipient caller-supplied steps (may be empty per recipient).
     * @return programData The composed per-recipient step arrays.
     */
    function _buildProgramData(
        address[] memory _to,
        uint256[] memory _value,
        bytes32 _referenceId,
        SharedObjects.EnygmaProgramData[][] memory _userProgramData
    ) private view returns (SharedObjects.EnygmaProgramData[][] memory programData) {
        // Callers must supply one user-step bucket per recipient; enforce the invariant rather
        // than silently substituting an empty bucket on mismatch (which would mask a caller bug).
        if (_userProgramData.length != _to.length) revert RaylsEnygmaHandler__ArrayLengthMismatch();
        programData = new SharedObjects.EnygmaProgramData[][](_to.length);

        for (uint256 i = 0; i < _to.length; i++) {
            SharedObjects.EnygmaProgramData memory mintStep = SharedObjects.EnygmaProgramData({
                resourceId: resourceId,
                contractAddress: address(0),
                selector: CROSS_MINT_STANDARD_SELECTOR,
                args: abi.encode(_to[i], _value[i], _referenceId)
            });

            SharedObjects.EnygmaProgramData[] memory userSteps = _userProgramData[i];

            SharedObjects.EnygmaProgramData[] memory recipientSteps =
                new SharedObjects.EnygmaProgramData[](userSteps.length + 1);
            recipientSteps[0] = mintStep;
            for (uint256 j = 0; j < userSteps.length; j++) {
                recipientSteps[j + 1] = userSteps[j];
            }
            programData[i] = recipientSteps;
        }
    }

    /**
     * @notice Initiates a cross-chain transfer from a specific address (requires allowance),
     *         optionally composing each recipient's settlement mint with caller-supplied
     *         programmability blobs. See {crossTransfer} for the blob format and origin-attestation
     *         rules; pass an empty inner array (`[]`) per recipient for a plain transfer.
     * @param _from Address to transfer tokens from
     * @param _to Array of recipient addresses
     * @param _value Array of token amounts
     * @param _toChainId Array of destination chain IDs
     * @param _userProgramData Per-recipient typed programmability steps (parallel to `_to`).
     * @return bytes32 Reference ID of the transfer
     */
    function crossTransferFrom(
        address _from,
        address[] memory _to,
        uint256[] memory _value,
        uint256[] memory _toChainId,
        SharedObjects.EnygmaProgramData[][] memory _userProgramData
    ) public virtual returns (bytes32) {
        if (_userProgramData.length != _to.length) {
            revert RaylsEnygmaHandler__ArrayLengthMismatch();
        }

        address spender = msg.sender;

        for (uint256 i = 0; i < _to.length; ++i) {
            _spendAllowance(_from, spender, _value[i]);
        }

        return _crossTransferFrom(_from, _to, _value, _toChainId, _userProgramData);
    }

    /**
     * @notice Burn Enygma tokens and emit a corresponding `burn` event on the PN events contract.
     * @dev Restricted to owner-gated callers. Reverts on zero amount. Emits the cross-chain
     *      burn notification only when this token has been activated (`resourceId != 0`).
     * @param from Account whose tokens are burned.
     * @param value Amount in base units (wei). Must be > 0.
     */
    function burn(address from, uint256 value) public virtual restricted whenPrivacyNodeActive {
        if (value == 0) revert RaylsEnygmaHandler__ZeroAmount();

        _burn(from, value);

        if (resourceId != bytes32(0)) {
            IEnygmaPNEvents(getEnygmaEventsAdress()).burn(resourceId, from, value);
        }
    }

    /**
     * @notice Returns the token name. Overrides ERC20 to read from initializer-set storage.
     * @return Token name string.
     */
    function name() public view virtual override returns (string memory) {
        return tokenName;
    }

    /**
     * @notice Returns the token symbol. Overrides ERC20 to read from initializer-set storage.
     * @return Token symbol string.
     */
    function symbol() public view virtual override returns (string memory) {
        return tokenSymbol;
    }

    /**
     * @notice Returns the token decimals. Overrides ERC20 to read from initializer-set storage.
     * @return Decimals.
     */
    function decimals() public view virtual override returns (uint8) {
        return tokenDecimals;
    }

    /**
     * @notice Returns the ERC standard tag identifying this token shape.
     * @return The `SharedObjects.ErcStandard.Enygma` enum value.
     */
    function GetERCStandard() public pure virtual override returns (SharedObjects.ErcStandard) {
        return SharedObjects.ErcStandard.Enygma;
    }

    /**
     * @notice Empty hook used by destination relayer to confirm token deployment on its PN.
     * @dev Restricted to MESSAGE_EXECUTOR. Subclasses may override to add post-deploy logic.
     */
    function crossTransferCheck() public virtual restricted {}

    /**
     * @notice Read the raw uint status code stored against a reference id.
     * @param _referenceID Reference id under inspection.
     * @return Raw uint value (mirrors `ReferenceIdStatus` enum).
     */
    function referenceIdStatusUint(bytes32 _referenceID) public view virtual returns (uint256) {
        return referenceIdsStatus[_referenceID];
    }

    /**
     * @notice Read the typed `ReferenceIdStatus` for a reference id.
     * @param _referenceID Reference id under inspection.
     * @return Typed status enum value.
     */
    function referenceIdStatus(
        bytes32 _referenceID
    ) public view virtual returns (ReferenceIdStatus) {
        return ReferenceIdStatus(referenceIdsStatus[_referenceID]);
    }

    /**
     * @notice Deposit tokens into Dvp by burning the caller's balance and emitting a deposit
     *         event for off-chain DvP processing.
     * @dev Zero-value deposits are intentionally allowed because some swap use cases require
     *      one side of the trade to deposit 0 (e.g. gifting an NFT without payment).
     * @param amount Amount to deposit in base units.
     * @return Reference id assigned to the deposit.
     */
    function depositToDvp(uint256 amount) public virtual whenHubActive returns (bytes32) {
        _burn(_msgSender(), amount);

        uint256[] memory empty;
        address[] memory emptyAddress;

        bytes32 referenceId = MessageLib.computeEnygmaReferenceId(
            endpoint.getChainId(),
            msg.sender,
            empty,
            emptyAddress,
            abi.encode(block.number, amount, 'DEPOSIT')
        );
        referenceIdsStatus[referenceId] = uint256(ReferenceIdStatus.DEPOSITED);

        IEnygmaPNEvents(getEnygmaEventsAdress()).depositToDvp(
            resourceId,
            amount,
            _msgSender(),
            referenceId
        );

        emit transactionReferenceId(referenceId);
        return referenceId;
    }

    /**
     * @notice Receive tokens released from a Dvp withdrawal: mark the reference id as
     *         `WITHDRAW_RECEIVED` and mint to `_to`.
     * @dev Restricted to RELAYER. Counterpart to `callWithdrawFromDvp`.
     * @param _to Recipient.
     * @param _value Amount minted.
     * @param _referenceId Reference id of the original withdrawal request.
     */
    function receiveWithdrawFromDvp(
        address _to,
        uint256 _value,
        bytes32 _referenceId
    ) public virtual restricted whenHubActive {
        referenceIdsStatus[_referenceId] = uint256(ReferenceIdStatus.WITHDRAW_RECEIVED);
        _mint(_to, _value);
    }

    /**
     * @notice Initiate a withdrawal from Dvp by emitting a withdraw event for off-chain processing.
     * @dev Reverts on zero amount. No on-chain balance check is performed here; the actual
     *      mint happens in `receiveWithdrawFromDvp` after the DvP off-chain verification.
     * @param amount Amount to withdraw in base units. Must be > 0.
     * @return Reference id assigned to the withdrawal request.
     */
    function callWithdrawFromDvp(uint256 amount) public virtual whenHubActive returns (bytes32) {
        if (amount == 0) revert RaylsEnygmaHandler__ZeroAmount();

        uint256[] memory empty;
        address[] memory emptyAddress;

        bytes32 referenceId = MessageLib.computeEnygmaReferenceId(
            endpoint.getChainId(),
            msg.sender,
            empty,
            emptyAddress,
            abi.encode(block.number, amount, 'WITHDRAW')
        );
        referenceIdsStatus[referenceId] = uint256(ReferenceIdStatus.WITHDRAW_ASKED);

        IEnygmaPNEvents(getEnygmaEventsAdress()).withdrawFromDvp(
            resourceId,
            amount,
            _msgSender(),
            referenceId
        );

        emit transactionReferenceId(referenceId);
        return referenceId;
    }

    /**
     * @notice Swap Enygma tokens for an ERC721 token through Dvp.
     * @dev Emits the swap request and notifies the sender/receiver PN communicators.
     * @param _nftId ID of the NFT to receive
     * @param _nftResourceId Resource ID of the NFT contract
     * @param _enygmaAmount Amount of Enygma tokens to swap
     * @param _destChainId Destination chain ID
     * @param _sharedId Shared ID for the swap operation
     * @param _validityTime Optional swap validity time in seconds; zero uses the default.
     */
    function swapWithDvpForERC721(
        uint256 _nftId,
        bytes32 _nftResourceId,
        uint256 _enygmaAmount,
        uint256 _destChainId,
        bytes32 _sharedId,
        uint64 _validityTime
    ) public virtual whenHubActive {
        if (_validityTime > 0) {
            if (
                _validityTime <= Utils.ENYGMA_DVP_SWAP_MIN_VALIDITY_TIME ||
                _validityTime >= Utils.ENYGMA_DVP_SWAP_MAX_VALIDITY_TIME
            ) {
                revert RaylsEnygmaHandler__SwapValidityOutOfRange(
                    _validityTime,
                    Utils.ENYGMA_DVP_SWAP_MIN_VALIDITY_TIME,
                    Utils.ENYGMA_DVP_SWAP_MAX_VALIDITY_TIME
                );
            }
        } else {
            _validityTime = Utils.ENYGMA_DVP_SWAP_DEFAULT_VALIDITY_TIME;
        }

        IEnygmaPNEvents(getEnygmaEventsAdress()).swapWithDvpForERC721(
            resourceId,
            _nftId,
            _nftResourceId,
            _enygmaAmount,
            _msgSender(),
            _destChainId,
            _sharedId,
            _validityTime
        );

        _notifySenderAndReceiverWithPNCommunicator(
            _sharedId,
            _destChainId,
            SharedObjects.DvpCommunicatiorStatus.SwapEnygmaFor721Sent,
            SharedObjects.DvpCommunicatiorStatus.SwapEnygmaFor721Received,
            '',
            ''
        );
    }

    /**
     * @notice Swap Enygma tokens for an ERC1155 token through Dvp.
     * @dev Emits the swap request and notifies the sender/receiver PN communicators.
     * @param _nftId ID of the NFT to receive
     * @param _nftAmountOrOne Amount of NFT tokens to receive
     * @param _nftResourceId Resource ID of the NFT contract
     * @param _enygmaAmount Amount of Enygma tokens to swap
     * @param _destChainId Destination chain ID
     * @param _sharedId Shared ID for the swap operation
     * @param _validityTime Optional swap validity time in seconds; zero uses the default.
     */
    function swapWithDvpForERC1155(
        uint256 _nftId,
        uint256 _nftAmountOrOne,
        bytes32 _nftResourceId,
        uint256 _enygmaAmount,
        uint256 _destChainId,
        bytes32 _sharedId,
        uint64 _validityTime
    ) public virtual whenHubActive {
        if (_validityTime > 0) {
            if (
                _validityTime <= Utils.ENYGMA_DVP_SWAP_MIN_VALIDITY_TIME ||
                _validityTime >= Utils.ENYGMA_DVP_SWAP_MAX_VALIDITY_TIME
            ) {
                revert RaylsEnygmaHandler__SwapValidityOutOfRange(
                    _validityTime,
                    Utils.ENYGMA_DVP_SWAP_MIN_VALIDITY_TIME,
                    Utils.ENYGMA_DVP_SWAP_MAX_VALIDITY_TIME
                );
            }
        } else {
            _validityTime = Utils.ENYGMA_DVP_SWAP_DEFAULT_VALIDITY_TIME;
        }

        IEnygmaPNEvents(getEnygmaEventsAdress()).swapWithDvpForERC1155(
            resourceId,
            _nftId,
            _nftResourceId,
            _nftAmountOrOne,
            _enygmaAmount,
            _msgSender(),
            _destChainId,
            _sharedId,
            _validityTime
        );

        _notifySenderAndReceiverWithPNCommunicator(
            _sharedId,
            _destChainId,
            SharedObjects.DvpCommunicatiorStatus.SwapEnygmaFor1155Sent,
            SharedObjects.DvpCommunicatiorStatus.SwapEnygmaFor1155Received,
            '',
            ''
        );
    }

    /**
     * @notice Cancel a Dvp ERC721 swap initiated by this caller.
     * @dev Caller must hold a non-zero Enygma balance. Emits a cancel event on the PN
     *      events contract.
     * @param _sharedId Shared id of the swap to cancel.
     * @param _toChainId Destination chain id of the original swap.
     * @param _nftId Token id of the NFT side of the swap.
     * @param _nftResourceId Resource id of the NFT contract.
     * @param _enygmaAmount Enygma amount of the original swap.
     */
    function cancelERC721Swap(
        bytes32 _sharedId,
        uint256 _toChainId,
        uint256 _nftId,
        bytes32 _nftResourceId,
        uint256 _enygmaAmount
    ) public virtual whenHubActive {
        require(balanceOf(msg.sender) > 0, 'Caller has no token balance');
        IEnygmaPNEvents(getEnygmaEventsAdress()).cancelSwap(_sharedId, _toChainId, resourceId, _enygmaAmount, 0, SharedObjects.ErcStandard.Enygma, _nftResourceId, 1, _nftId, SharedObjects.ErcStandard.DvpERC721);
    }

    /**
     * @notice Cancel a Dvp ERC1155 swap initiated by this caller.
     * @dev Caller must hold a non-zero Enygma balance.
     * @param _sharedId Shared id of the swap to cancel.
     * @param _toChainId Destination chain id of the original swap.
     * @param _nftId Token id of the ERC1155 side.
     * @param _nftAmountOrOne Amount of the ERC1155 token in the original swap.
     * @param _nftResourceId Resource id of the ERC1155 contract.
     * @param _enygmaAmount Enygma amount of the original swap.
     */
    function cancelERC1155Swap(
        bytes32 _sharedId,
        uint256 _toChainId,
        uint256 _nftId,
        uint256 _nftAmountOrOne,
        bytes32 _nftResourceId,
        uint256 _enygmaAmount
    ) public virtual whenHubActive {
        require(balanceOf(msg.sender) > 0, 'Caller has no token balance');
        IEnygmaPNEvents(getEnygmaEventsAdress()).cancelSwap(_sharedId, _toChainId, resourceId, _enygmaAmount, 0, SharedObjects.ErcStandard.Enygma, _nftResourceId, _nftAmountOrOne, _nftId, SharedObjects.ErcStandard.DvpERC1155);
    }

    /**
     * @dev Returns the address of the PN communicator contract
     * @return address Address of the PN communicator contract
     */
    function getPNCommunicatorAddress() public view virtual returns (address) {
        return endpoint.getAddressByResourceId(Constants.RESOURCE_ID_PN_COMMUNICATOR);
    }

    /**
     * @notice Internal helper that posts a Dvp status update to the local PN communicator.
     * @param _sharedId Shared id correlating the operation.
     * @param _status Status code to record.
     * @param _message Free-form message attached to the status update.
     */
    function _notifySenderWithPNCommunicator(
        bytes32 _sharedId,
        SharedObjects.DvpCommunicatiorStatus _status,
        string memory _message
    ) internal {
        IPNCommunicator(getPNCommunicatorAddress()).addSharedInfo(
            _sharedId,
            uint256(_status),
            uint256(SharedObjects.CommunicatiorContexts.Dvp),
            _message
        );
    }

    /**
     * @notice External form of `_notifySenderWithPNCommunicator`.
     * @dev Restricted to RELAYER.
     * @param _sharedId Shared id correlating the operation.
     * @param _status Status code to record.
     * @param _message Free-form message attached to the status update.
     */
    function notifySenderWithPNCommunicator(
        bytes32 _sharedId,
        SharedObjects.DvpCommunicatiorStatus _status,
        string memory _message
    ) public virtual restricted {
        _notifySenderWithPNCommunicator(_sharedId, _status, _message);
    }

    /**
     * @notice Internal helper that updates the local PN communicator AND dispatches a
     *         cross-chain status update to the destination PN communicator.
     * @param _sharedId Shared id correlating the operation.
     * @param _destChainId Destination chain id receiving the status update.
     * @param _statusToSender Status code to record locally for the sender.
     * @param _statusToReceiver Status code to dispatch to the receiver.
     * @param _messageToSender Free-form message for the sender side.
     * @param _messageToReceiver Free-form message for the receiver side.
     */
    function _notifySenderAndReceiverWithPNCommunicator(
        bytes32 _sharedId,
        uint256 _destChainId,
        SharedObjects.DvpCommunicatiorStatus _statusToSender,
        SharedObjects.DvpCommunicatiorStatus _statusToReceiver,
        string memory _messageToSender,
        string memory _messageToReceiver
    ) internal {
        IPNCommunicator(getPNCommunicatorAddress()).addSharedInfo(
            _sharedId,
            uint256(_statusToSender),
            uint256(SharedObjects.CommunicatiorContexts.Dvp),
            _messageToSender
        );

        _raylsSendToResourceId(
            _destChainId,
            Constants.RESOURCE_ID_PN_COMMUNICATOR,
            abi.encodeWithSignature(
                'addSharedInfo(bytes32,uint256,uint256,string)',
                _sharedId,
                uint256(_statusToReceiver),
                uint256(SharedObjects.CommunicatiorContexts.Dvp),
                _messageToReceiver
            )
        );
    }

    /**
     * @notice External form of `_notifySenderAndReceiverWithPNCommunicator`.
     * @dev Restricted to RELAYER.
     * @param _sharedId Shared id correlating the operation.
     * @param _destChainId Destination chain id receiving the status update.
     * @param _statusToSender Status code to record locally for the sender.
     * @param _statusToReceiver Status code to dispatch to the receiver.
     * @param _messageToSender Free-form message for the sender side.
     * @param _messageToReceiver Free-form message for the receiver side.
     */
    function notifySenderAndReceiverWithPNCommunicator(
        bytes32 _sharedId,
        uint256 _destChainId,
        SharedObjects.DvpCommunicatiorStatus _statusToSender,
        SharedObjects.DvpCommunicatiorStatus _statusToReceiver,
        string memory _messageToSender,
        string memory _messageToReceiver
    ) public virtual restricted {
        _notifySenderAndReceiverWithPNCommunicator(_sharedId, _destChainId, _statusToSender, _statusToReceiver, _messageToSender, _messageToReceiver);
    }

    /**
     * @notice Handle completion of a Dvp swap by posting a "ready for withdraw" status to
     *         the local PN communicator.
     * @dev Restricted to RELAYER. The first parameter (`_destinationChainId`) is intentionally
     *      anonymous — reserved for future routing logic but currently unused; retained in
     *      the signature to keep the cross-chain ABI stable for callers.
     * @param _sharedId Shared id correlating the swap operation.
     */
    function dvpSwapCompleted(uint256 /* _destinationChainId */, bytes32 _sharedId) public virtual restricted whenHubActive {
        IPNCommunicator(getPNCommunicatorAddress()).addSharedInfo(
            _sharedId,
            uint256(SharedObjects.DvpCommunicatiorStatus.SwapDoneReadyForWithdraw),
            uint256(SharedObjects.CommunicatiorContexts.Dvp),
            ''
        );
    }

    /*//////////////////////////////////////////////////////////////
                    ACCESS CONTROL REGISTRATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Register this token with the local AccessManager via `selfRegisterManagedContract`.
     * @dev Called from both the constructor (direct deployment) and `initialize` (proxy deployment).
     *      Wires owner-gated selectors (mint/burn/setSwapValidityTime), RELAYER-gated selectors
     *      (cross-chain settlement mint/transfer/dvp + notifications + programmable crossMint/
     *      crossBurn userBlob entries), and MESSAGE_EXECUTOR-gated selectors
     *      (receiveResourceId, crossTransferCheck). No-op when no AccessManager is bound.
     * @param _owner Address that becomes owner of the owner-gated selectors.
     * @param caller The external deployer (factory's `msg.sender`); when non-zero and distinct
     *               from `_owner`, also granted TOKEN_OWNER scoped to this token. `address(0)`
     *               on the constructor path.
     */
    function _registerAccessControl(address _owner, address caller) internal {
        address mgr = address(endpoint) != address(0) ? endpoint.authority() : address(0);
        if (mgr == address(0)) return;

        _setAuthority(mgr);

        bytes4[] memory ownerSels = new bytes4[](3);
        ownerSels[0] = this.mint.selector;
        ownerSels[1] = this.burn.selector;
        ownerSels[2] = this.setSwapValidityTime.selector;

        bytes4[] memory relayerSels = new bytes4[](10);
        relayerSels[0] = this.crossRevertMint.selector;
        relayerSels[1] = this.crossMintStandard.selector;
        relayerSels[2] = this.crossTransferRevertBatch.selector;
        relayerSels[3] = this.supplyUpdateRevert.selector;
        relayerSels[4] = this.receiveWithdrawFromDvp.selector;
        relayerSels[5] = this.notifySenderWithPNCommunicator.selector;
        relayerSels[6] = this.notifySenderAndReceiverWithPNCommunicator.selector;
        relayerSels[7] = this.dvpSwapCompleted.selector;
        // Programmable userBlob entries — RELAYER-gated so the ProgrammabilityExecutor (which
        // holds RELAYER) can target.call them when a composed transfer carries a crossMint/
        // crossBurn blob against this token's own resourceId.
        relayerSels[8] = this.crossMint.selector;
        relayerSels[9] = this.crossBurn.selector;

        bytes4[] memory executorSels = new bytes4[](1);
        executorSels[0] = this.crossTransferCheck.selector;

        IRaylsAccessManager.SelectorRoleMapping[] memory mappings = new IRaylsAccessManager.SelectorRoleMapping[](2);
        mappings[0] = IRaylsAccessManager.SelectorRoleMapping("RELAYER", relayerSels);
        mappings[1] = IRaylsAccessManager.SelectorRoleMapping("MESSAGE_EXECUTOR", executorSels);

        IRaylsAccessManager(mgr).selfRegisterManagedContract(_owner, ownerSels, mappings);

        // Also grant TOKEN_OWNER to the deployer when it differs from the configured owner
        // (factory path where `owner` is factoryOwner but the deployer is a distinct caller).
        if (caller != address(0) && caller != _owner) {
            IRaylsAccessManager(mgr).grantSelfTokenOwner(caller);
        }
    }

}
