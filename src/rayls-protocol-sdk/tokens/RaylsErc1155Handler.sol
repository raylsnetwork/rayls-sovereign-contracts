// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RaylsApp} from "../RaylsApp.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IRaylsNodeEndpoint} from "../../rayls-node/rayls-privacy-node/interfaces/IRaylsNodeEndpoint.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {RaylsAccessManaged} from '../../privateHub/AccessControl/RaylsAccessManaged.sol';
import {IRaylsAccessManager} from '../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol';
import {TOKEN_OWNER} from '../../privateHub/AccessControl/AccessManagerTypes.sol';
import "../interfaces/IRaylsEndpoint.sol";
import "../RaylsMessage.sol";
import "../libraries/SharedObjects.sol";
import "../libraries/Utils.sol";
import {IRaylsInitializer, RaylsTrustedInit} from "../IRaylsInitializer.sol";
import {IRaylsTokenStandard} from "../interfaces/IRaylsTokenStandard.sol";
import "../../rayls-node/rayls-privacy-node/RNMessageLib.sol";

/**
 * @title RaylsErc1155Handler
 * @notice ERC1155 base for Rayls multi-token contracts. Adds cross-chain teleport (one-shot
 *         + atomic + public-chain), per-account+per-id lock/unlock, and per-id supply
 *         tracking via internal `_totalSupply` + `_allTokens`.
 * @dev Inherit and extend; mint/burn/submitTokenUpdate gated to the owner role; receive
 *      and revert surfaces gated to MESSAGE_EXECUTOR. ReentrancyGuard guards every external
 *      mutation.
 */
abstract contract RaylsErc1155Handler is RaylsApp, ERC1155, ERC1155Holder, Initializable, ReentrancyGuard, RaylsAccessManaged, IRaylsTokenStandard {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    /// @notice Thrown when a teleport receives a zero address, zero amount, or zero chain id.
    /// @param to Recipient address provided by the caller.
    /// @param value Amount provided by the caller.
    /// @param chainId Destination chain id provided by the caller.
    error RaylsErc1155Handler__ZeroValueArg(address to, uint256 value, uint256 chainId);

    /// @notice Thrown when a teleport target chain id equals the current chain.
    /// @param chainId Same-chain id supplied by caller.
    error RaylsErc1155Handler__WrongFunctionForSameChainId(uint256 chainId);

    /// @notice Thrown when a lock is requested with a zero amount.
    error RaylsErc1155Handler__AmountMustBeGreaterThanZero();

    /// @notice Thrown when caller's balance is below the requested lock amount.
    error RaylsErc1155Handler__InsufficientBalanceToLock();

    /// @notice Thrown when `_unlock` is called with the zero address.
    error RaylsErc1155Handler__ZeroToAddress();

    /// @notice Thrown when the unlock request is zero or exceeds the locked amount.
    /// @param requested Amount requested to unlock.
    /// @param available Amount currently locked for the account.
    error RaylsErc1155Handler__InsufficientLockedAmount(uint256 requested, uint256 available);

    /// @notice Thrown when `unlock` (or its variants) cannot release the lock.
    error RaylsErc1155Handler__UnlockFailed();

    /// @notice Thrown when a teleport is attempted before the token has been registered.
    error RaylsErc1155Handler__TokenNotRegistered();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    /// @notice Emitted when an account locks tokens of a given id into the contract pool.
    /// @param account Account whose tokens were locked.
    /// @param tokenId Token id locked.
    /// @param amount Amount locked.
    event TokensLocked(address indexed account, uint256 indexed tokenId, uint256 amount);

    /// @notice Emitted when previously locked tokens of a given id are released.
    /// @param account Account whose tokens were unlocked.
    /// @param tokenId Token id unlocked.
    /// @param amount Amount unlocked.
    event TokensUnlocked(address indexed account, uint256 indexed tokenId, uint256 amount);

    /// @notice Emitted when this ERC1155 token contract is created and initialized.
    /// @param tokenAddress Address of the newly created token contract.
    event RaylsErc1155TokenCreated(address indexed tokenAddress);

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    /// @dev Base URI returned by `uri()`. Settable at construction/initialize time.
    string private _uri;

    /// @notice Token name. Custom field — ERC1155 has no canonical name.
    string public name;

    /// @notice True when this token was deployed by a custom-token issuer (not the standard
    ///         template flow). Informational; affects PNH-side metadata extraction.
    bool isCustom;

    /// @notice Per-account, per-token-id locked-balance ledger used by atomic teleport flows.
    mapping(address => mapping(uint256 => uint256)) lockedAmount;

    /// @notice Per-token-id guard preventing duplicate cross-chain deploy instructions.
    mapping(uint256 => bool) alreadySentDeployInstructions;

    // Supply tracking
    /// @dev Per-token-id total supply, maintained by `_update` on mint/burn.
    mapping(uint256 => uint256) private _totalSupply;

    /// @dev Existence flag per token id, maintained by `_update` to track minted-ever state.
    mapping(uint256 => bool) private _exists;

    /// @dev Append-only/swap-pop list of every token id with non-zero supply.
    uint256[] private _allTokens;

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Construct the handler with ERC1155 metadata + trusted endpoint references.
     * @dev `_disableInitializers()` blocks the upgradeable `initialize` path on the
     *      implementation; the constructor flow is for non-upgradeable issuer-side deploys.
     * @param _uriParam URI of the token metadata.
     * @param _name Token name (custom field; ERC1155 has no canonical name).
     * @param _endpoint Trusted Rayls endpoint address.
     * @param _raylsNodeEndpoint Privacy-node endpoint; zero on PNH deploys.
     * @param _userGovernance UserGovernance binding; zero when unused.
     * @param _owner Owner that receives owner-gated selectors.
     * @param _isCustom True for custom-token issuer flow; false for the standard template path.
     */
    constructor(
        string memory _uriParam,
        string memory _name,
        address _endpoint,
        address _raylsNodeEndpoint,
        address _userGovernance,
        address _owner,
        bool _isCustom)
        ERC1155(_uriParam)
        RaylsApp(_endpoint, _raylsNodeEndpoint, _userGovernance)
    {
        _uri = _uriParam;
        name = _name;
        isCustom = _isCustom;
        _registerAccessControl(_owner, address(0));
        _disableInitializers();
    }

    /**
     * @notice Canonical init entrypoint dispatched by RaylsContractFactoryV1 / RNContractFactoryV1.
     * @param userArgs ABI-encoded `(string uri, string name)`.
     *                 Caller-supplied via the cross-chain init payload.
     * @param trusted  Trusted addresses + resourceId from {RaylsTrustedInit}, set by the
     *                 factory at deploy time. Caller cannot forge.
     */
    function initialize(bytes calldata userArgs, RaylsTrustedInit calldata trusted) public virtual initializer {
        (string memory _uriParam, string memory _name) = abi.decode(userArgs, (string, string));

        // ERC1155 initialization
        _uri = _uriParam;
        name = _name;

        // RaylsApp initialization (trusted addresses from factory-injected struct)
        endpoint = IRaylsEndpoint(trusted.endpoint);
        // Bind the privacy-node endpoint when the factory stamped one. RNContractFactoryV1 now
        // injects the real RNEndpointV1 (non-zero) so teleportToPublicChain works; the null guard
        // stays for deploy paths that legitimately pass `address(0)` (see IRaylsInitializer.sol).
        if (trusted.raylsNodeEndpoint != address(0)) {
            raylsNodeEndpoint = IRaylsNodeEndpoint(trusted.raylsNodeEndpoint);
        }
        _initializeUserGovernance(trusted.userGovernance);
        resourceId = trusted.resourceId;

        _registerAccessControl(trusted.owner, trusted.caller);
        emit RaylsErc1155TokenCreated(address(this));
    }

    /**
     * @notice Returns the URI for a given token id. ERC1155 ignores per-id URI here and
     *         returns the contract-wide base URI.
     * @dev The `id` parameter is intentionally anonymous — every token id resolves to the
     *      same contract-wide base URI; per-id metadata is not modeled.
     * @return URI string.
     */
    /**
     * @notice Receiver-side teleport-deploy hint. See {RaylsErc20Handler.teleportDeployHint}.
     * @return factoryKey RAYLS_ERC1155_KEY.
     * @return userArgs   ABI-encoded `(string uri, string name)`.
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function teleportDeployHint()
        external
        view
        virtual
        returns (bytes32 factoryKey, bytes memory userArgs)
    {
        factoryKey = keccak256("RAYLS_ERC1155");
        userArgs = abi.encode(_uri, name);
    }

    function uri(uint256 /* id */ ) public view virtual override returns (string memory) {
        return _uri;
    }

    /**
     * @notice ERC165 interface support combining ERC1155 + ERC1155Holder.
     * @param interfaceId Interface id under inspection.
     * @return True if either base contract claims support.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC1155, ERC1155Holder) returns (bool) {
        return ERC1155.supportsInterface(interfaceId) || ERC1155Holder.supportsInterface(interfaceId);
    }

    /**
     * @notice Update the contract-wide ERC1155 base URI.
     * @dev Override of OZ ERC1155 internal hook; access control is the caller's concern.
     * @param newuri New URI string.
     */
    function _setURI(string memory newuri) internal virtual override {
        _uri = newuri;
    }

    /**
     * @notice Returns the ERC standard tag identifying this token shape.
     * @return The `SharedObjects.ErcStandard.ERC1155` enum value.
     */
    function GetERCStandard() public pure virtual override returns (SharedObjects.ErcStandard) {
        return SharedObjects.ErcStandard.ERC1155;
    }

    /**
     * @notice Approve or revoke an operator only while this token is active on the local Privacy Node.
     * @param operator Account whose operator approval is updated.
     * @param approved True to approve the operator; false to revoke.
     */
    function setApprovalForAll(address operator, bool approved) public virtual override whenPrivacyNodeActive {
        super.setApprovalForAll(operator, approved);
    }

    /**
     * @notice Safely transfer tokens only while this token is active on the local Privacy Node.
     * @param from Account whose tokens are transferred.
     * @param to Recipient address.
     * @param id Token id to transfer.
     * @param value Amount to transfer.
     * @param data Additional data forwarded to the receiver hook.
     */
    function safeTransferFrom(address from, address to, uint256 id, uint256 value, bytes memory data) public virtual override whenPrivacyNodeActive {
        super.safeTransferFrom(from, to, id, value, data);
    }

    /**
     * @notice Safely transfer token batches only while this token is active on the local Privacy Node.
     * @param from Account whose tokens are transferred.
     * @param to Recipient address.
     * @param ids Token ids to transfer.
     * @param values Amounts to transfer for each token id.
     * @param data Additional data forwarded to the receiver hook.
     */
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values,
        bytes memory data
    ) public virtual override whenPrivacyNodeActive {
        super.safeBatchTransferFrom(from, to, ids, values, data);
    }

    /**
     * @notice Teleports ERC1155 tokens to a specified address on a destination chain
     * @dev Burns tokens on the current chain and initiates cross-chain transfer to mint on destination
     * @param to The recipient address on the destination chain (cannot be zero address)
     * @param id The token ID to teleport
     * @param value The amount of tokens to teleport (must be > 0)
     * @param chainId The destination chain identifier (must be different from current chain)
     * @param data Additional data to pass with the transfer
     * @return bool Returns true if teleport initiation is successful
     * @custom:reverts RaylsErc1155Handler__ZeroValueArg if to is zero address, value is 0, or chainId is 0
     * @custom:reverts RaylsErc1155Handler__WrongFunctionForSameChainId if chainId equals current chain
     * @custom:security Tokens are burned immediately on source chain, minting occurs on destination upon message delivery
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function teleport(address to, uint256 id, uint256 value, uint256 chainId, bytes memory data)
        public
        virtual
        nonReentrant
        whenHubActive
        returns (bool)
    {
        // Input validation
        if (to == address(0) || value == 0 || chainId == 0) {
            revert RaylsErc1155Handler__ZeroValueArg(to, value, chainId);
        }
        if (chainId == endpoint.getChainId()) {
            revert RaylsErc1155Handler__WrongFunctionForSameChainId(chainId);
        }

        // Execute teleport logic
        _burn(msg.sender, id, value);

        BridgedTransferMetadata memory metadata = BridgedTransferMetadata({
            assetType: RaylsBridgeableERC.ERC1155,
            id: id,
            from: msg.sender,
            to: to,
            amount: value,
            tokenAddress: address(this)
        });

        // Prepare cross-chain transfer
        _sendTeleport(
            chainId,
            abi.encodeWithSignature("receiveTeleport(address,uint256,uint256,bytes)", to, id, value, data),
            bytes(""),
            bytes(""),
            bytes(""),
            metadata
        );
        return true;
    }

    /**
     * @notice Teleports ERC1155 tokens atomically with rollback capability
     * @dev Burns tokens on source, mints to contract owner on destination, locks for recipient until unlocked
     * @param to The recipient address on the destination chain (cannot be zero address)
     * @param id The token ID to teleport
     * @param value The amount of tokens to teleport (must be > 0)
     * @param chainId The destination chain identifier (must be different from current chain)
     * @param data Additional data to pass with the transfer
     * @return bool Returns true if atomic teleport initiation is successful
     * @custom:reverts RaylsErc1155Handler__ZeroValueArg if to is zero address, value is 0, or chainId is 0
     * @custom:reverts RaylsErc1155Handler__WrongFunctionForSameChainId if chainId equals current chain
     * @custom:atomic If destination fails, tokens can be reverted back to sender through revertTeleportMint
     * @custom:locking Tokens are minted to contract owner and locked for recipient until manual unlock
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function teleportAtomic(address to, uint256 id, uint256 value, uint256 chainId, bytes memory data)
        public
        virtual
        nonReentrant
        whenHubActive
        returns (bool)
    {
        // Input validation
        if (to == address(0) || value == 0 || chainId == 0) {
            revert RaylsErc1155Handler__ZeroValueArg(to, value, chainId);
        }
        if (chainId == endpoint.getChainId()) {
            revert RaylsErc1155Handler__WrongFunctionForSameChainId(chainId);
        }

        // Execute teleport logic
        _burn(msg.sender, id, value);

        BridgedTransferMetadata memory metadata = BridgedTransferMetadata({
            assetType: RaylsBridgeableERC.ERC1155,
            id: id,
            from: msg.sender,
            to: to,
            amount: value,
            tokenAddress: address(this)
        });

        // Prepare cross-chain transfer
        _sendTeleport(
            chainId,
            abi.encodeWithSignature("receiveTeleportAtomic(address,uint256,uint256,bytes)", to, id, value, data),
            abi.encodeWithSignature("unlock(address,uint256,uint256,bytes)", to, id, value, data),
            abi.encodeWithSignature("revertTeleportMint(address,uint256,uint256,bytes)", msg.sender, id, value, data),
            abi.encodeWithSignature("revertTeleportBurn(address,uint256,uint256)", to, id, value),
            metadata
        );
        return true;
    }

    /**
     * @notice Teleport tokens from this private chain to a public destination chain via the
     *         privacy-node endpoint.
     * @dev Locks the caller's tokens locally (no burn — public-chain bridge mints a wrapper).
     *      Gated by `onlyRegisteredUsers`.
     * @param to Recipient address on the destination public chain.
     * @param id Token id to teleport.
     * @param value Amount to teleport.
     * @param destinationChainId Public-chain id.
     * @param data Additional data to pass with the transfer.
     * @return Always true on success; reverts otherwise.
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function teleportToPublicChain(address to, uint256 id, uint256 value, uint256 destinationChainId, bytes memory data)
        public
        virtual
        onlyRegisteredUsers
        nonReentrant
        whenPublicChainActive
        returns (bool)
    {
        _lock(msg.sender, id, value);

        BridgedTransferMetadata memory transferMetadata = BridgedTransferMetadata({
            assetType: RaylsBridgeableERC.ERC1155,
            id: id,
            from: msg.sender,
            to: to,
            tokenAddress: address(this),
            amount: value
        });

        // Convert BridgedTransferMetadata to RaylsNodeBridgedTransferMetadata
        RaylsNodeBridgedTransferMetadata memory raylsNodeTransferMetadata = RaylsNodeBridgedTransferMetadata({
            assetType: RaylsNodeBridgeableERC.ERC1155,
            id: transferMetadata.id,
            from: transferMetadata.from,
            to: transferMetadata.to,
            tokenAddress: transferMetadata.tokenAddress,
            amount: transferMetadata.amount
        });

        raylsNodeEndpoint.sendToAddress(
            destinationChainId,
            address(this),
            abi.encodeWithSignature("receiveTeleportFromPrivacyNode(address,uint256,address,uint256,uint256,bytes)", msg.sender, raylsNodeEndpoint.getChainId(), to, id, value, data),
            abi.encodeWithSignature("unlock(address,uint256,uint256)", msg.sender, id, value),
            raylsNodeTransferMetadata
        );

        return true;
    }

    /**
     * @notice Receive a one-shot teleport on the destination chain. Mints to `to`.
     * @dev Restricted to MESSAGE_EXECUTOR.
     * @param to Recipient.
     * @param id Token id.
     * @param value Amount to mint.
     * @param data Additional data forwarded to ERC1155 hooks.
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function receiveTeleport(address to, uint256 id, uint256 value, bytes memory data) public virtual restricted nonReentrant whenHubActive {
        _mint(to, id, value, data);
    }

    /**
     * @notice Receive an atomic teleport on the destination chain.
     * @dev Restricted to MESSAGE_EXECUTOR. Mints to this contract and locks for `to`; the
     *      atomic protocol later either unlocks (success) or reverts (failure).
     * @param to Recipient (final).
     * @param id Token id.
     * @param value Amount.
     * @param data Additional data forwarded to ERC1155 hooks.
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function receiveTeleportAtomic(address to, uint256 id, uint256 value, bytes memory data) public virtual restricted nonReentrant whenHubActive {
        _mint(address(this), id, value, data);
        if (to != address(this)) {
            _lockInternal(to, id, value, false);
        }
    }

    /**
     * @notice Revert path: re-mint tokens on the sender side after destination failure.
     * @dev Restricted to MESSAGE_EXECUTOR.
     * @param to Original sender (gets the tokens back).
     * @param id Token id.
     * @param value Amount.
     * @param data Additional data forwarded to ERC1155 hooks.
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function revertTeleportMint(address to, uint256 id, uint256 value, bytes memory data)
        public
        virtual
        restricted
        nonReentrant
        whenHubActive
    {
        _mint(to, id, value, data);
    }

    /**
     * @notice Revert path: burn the locked tokens on the receiver side after sender failure.
     * @dev Restricted to MESSAGE_EXECUTOR. Releases the lock then burns from this contract.
     * @param to Receiver whose lock is being unwound.
     * @param id Token id.
     * @param value Amount.
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function revertTeleportBurn(address to, uint256 id, uint256 value) public virtual restricted nonReentrant whenHubActive {
        _unlock(to, id, value);
        _burn(address(this), id, value);
    }

    /**
     * @notice Unlocks the locked funds and calls transfer
     * @dev Restricted to MESSAGE_EXECUTOR. If `to` is this contract, no transfer is issued.
     * @param to Address of a "to" account to unlock the funds to
     * @param id Token id to unlock.
     * @param amount Amount of tokens to unlock
     * @param data Additional data forwarded to the transfer hooks.
     * @return Always true on success; reverts otherwise.
     */
    function unlock(address to, uint256 id, uint256 amount, bytes memory data) external restricted nonReentrant whenHubActive returns (bool) {
        if (to != address(this)) {
            bool success = _unlock(to, id, amount);
            if (!success) revert RaylsErc1155Handler__UnlockFailed();
            _safeTransferFrom(address(this), to, id, amount, data);
        }
        return true;
    }

    /**
     * @notice Lock tokens of a given id from `from` into this contract's locked-balance pool.
     * @dev Wraps `_lockInternal` with `transferTokens=true`. Used by public-chain teleport.
     * @param from Account whose tokens are being locked.
     * @param id Token id.
     * @param amount Amount to lock.
     */
    function _lock(address from, uint256 id, uint256 amount) internal {
        _lockInternal(from, id, amount, true);
    }

    /**
     * @notice Internal lock primitive shared by `_lock` and atomic-receive.
     * @dev Reverts on zero amount; reverts on insufficient balance only when `transferTokens`
     *      is true. When transfer is needed, uses the internal OZ transfer primitive so the
     *      public `safeTransferFrom` lifecycle guard is not re-entered by public-chain lock flows.
     *      When `transferTokens` is false, caller has already moved tokens into this contract.
     * @param from Account whose tokens are being locked.
     * @param id Token id.
     * @param amount Amount to lock.
     * @param transferTokens If true, transfer the tokens from `from` into this contract;
     *                       if false, only update the locked-balance ledger.
     */
    function _lockInternal(address from, uint256 id, uint256 amount, bool transferTokens) internal {
        if (amount == 0) {
            revert RaylsErc1155Handler__AmountMustBeGreaterThanZero();
        }

        if (transferTokens && balanceOf(from, id) < amount) {
            revert RaylsErc1155Handler__InsufficientBalanceToLock();
        }

        lockedAmount[from][id] += amount;
        emit TokensLocked(from, id, amount);

        if (transferTokens) {
            _safeTransferFrom(from, address(this), id, amount, "");
        }
    }

    /**
     * @notice Internal unlock primitive: decrements the locked-balance ledger.
     * @dev Reverts on zero `to`, zero amount, or amount exceeding currently locked balance.
     *      Caller is responsible for the actual token transfer.
     * @param to Account whose lock is being released.
     * @param id Token id.
     * @param amount Amount to unlock.
     * @return Always true on success; reverts otherwise.
     */
    function _unlock(address to, uint256 id, uint256 amount) internal returns (bool) {
        if (to == address(0)) revert RaylsErc1155Handler__ZeroToAddress();
        uint256 amountToUnlock = lockedAmount[to][id];
        if (amount == 0 || amount > amountToUnlock) {
            revert RaylsErc1155Handler__InsufficientLockedAmount(amount, amountToUnlock);
        }
        lockedAmount[to][id] -= amount;
        emit TokensUnlocked(to, id, amount);
        return true;
    }

    /**
     * @notice Receive a teleport from a public chain back into this private chain.
     * @dev Restricted to MESSAGE_EXECUTOR and non-reentrant. Releases the lock then transfers to `to`.
     * @param to Recipient.
     * @param id Token id.
     * @param amount Amount.
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function receiveTeleportFromPublicChain(address to, uint256 id, uint256 amount) public virtual restricted nonReentrant whenPublicChainActive {
        bool success = _unlock(to, id, amount);
        if (!success) revert RaylsErc1155Handler__UnlockFailed();
        if (to != address(this)) {
            _safeTransferFrom(address(this), to, id, amount, "");
        }
    }

    /**
     * @notice Restores tokens locked by a failed private→public cross-chain mint
     * @dev Called by the public chain handler when receiveTeleportFromPrivacyNode cannot be completed (e.g. invalid destination).
     *      Mirrors the logic of `unlock` but accepts calls from the public chain endpoint.
     * @param from Address whose locked tokens should be restored
     * @param id Token ID to restore
     * @param amount Amount to restore
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function revertTeleportToPublicChain(address from, uint256 id, uint256 amount) external virtual restricted nonReentrant whenPublicChainActive {
        if (from != address(this)) {
            bool success = _unlock(from, id, amount);
            if (!success) revert RaylsErc1155Handler__UnlockFailed();
            _safeTransferFrom(address(this), from, id, amount, "");
        }
    }

    /**
     * @notice Read the locked-balance ledger entry for an account/id pair.
     * @param account Account to query.
     * @param id Token id.
     * @return Currently locked amount.
     */
    function getLockedAmount(address account, uint256 id) public view returns (uint256) {
        return lockedAmount[account][id];
    }

    /**
     * @notice Internal cross-chain dispatch helper for teleport flows.
     * @dev Reverts if `resourceId` is unset (token not yet registered).
     * @param chainId Destination chain id.
     * @param _payload ABI-encoded payload to dispatch on the destination handler.
     * @param _lockDataPayload Lock-state payload (atomic flow).
     * @param _revertDataPayloadSender Revert payload to dispatch on the sender chain on failure.
     * @param _revertDataPayloadReceiver Revert payload to dispatch on the receiver chain on failure.
     * @param metadata Bridged-transfer metadata.
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function sendTeleport(
        uint256 chainId,
        bytes memory _payload,
        bytes memory _lockDataPayload,
        bytes memory _revertDataPayloadSender,
        bytes memory _revertDataPayloadReceiver,
        BridgedTransferMetadata memory metadata
    ) internal whenHubActive {
        _sendTeleport(
            chainId,
            _payload,
            _lockDataPayload,
            _revertDataPayloadSender,
            _revertDataPayloadReceiver,
            metadata
        );
    }

    /// @notice Dispatches a previously validated teleport payload to the configured resource id.
    /// @dev Callers must run `_requireHubActive()` before invoking this helper.
    function _sendTeleport(
        uint256 chainId,
        bytes memory _payload,
        bytes memory _lockDataPayload,
        bytes memory _revertDataPayloadSender,
        bytes memory _revertDataPayloadReceiver,
        BridgedTransferMetadata memory metadata
    ) private {
        _raylsSendToResourceId(
            chainId,
            resourceId,
            _payload,
            _lockDataPayload,
            _revertDataPayloadSender,
            _revertDataPayloadReceiver,
            metadata
        );
    }

    /**
     * @notice Internal helper that dispatches a balance-update message to the PNH TokenRegistry.
     * @dev No-op when `resourceId` is unset (token not yet activated). Encodes per-id
     *      `(id, amount)` payload in `ERC1155Supply` form.
     * @param updateType MINT or BURN classification.
     * @param id Token id changed.
     * @param amount Amount changed.
     */
    function _submitTokenUpdate(SharedObjects.BalanceUpdateType updateType, uint256 id, uint256 amount) internal {
        // No-op unless the token is PNH-registered (endpoint resolves this resourceId to `this`).
        // A user-deployed token (deployXAsUser) sets resourceId locally but is never endpoint-bound,
        // lacks ENDPOINT_SENDER, and must not report balances to the PNH TokenRegistry — see the
        // detailed note on RaylsErc20Handler._submitTokenUpdate.
        if (resourceId == bytes32(0) || endpoint.getAddressByResourceId(resourceId) != address(this)) {
            return;
        }

        _raylsSend(
            endpoint.getPrivateHubId(),
            endpoint.getPrivateHubAddress("TokenRegistry"),
            abi.encodeWithSignature(
                "updateTokenBalance(uint256,bytes32,uint8,bytes)",
                endpoint.getChainId(),
                resourceId,
                updateType,
                abi.encode(SharedObjects.ERC1155Supply({id: id, amount: amount}))
            )
        );
    }

    /**
     * @notice Submit a mint/burn update to the PNH TokenRegistry.
     * @dev Restricted to owner-gated callers.
     * @param updateType MINT or BURN classification.
     * @param id Token id changed.
     * @param amount Amount changed.
     */
    function submitTokenUpdate(SharedObjects.BalanceUpdateType updateType, uint256 id, uint256 amount)
        public
        virtual
        restricted
    {
        _submitTokenUpdate(updateType, id, amount);
    }

    /**
     * @notice Read the per-id total supply snapshot for every existing token id.
     * @dev Maintained by `_update`. Private to the contract; subclass exposure is opt-in.
     * @return Array of `{id, amount}` entries — one per id with non-zero supply.
     */
    function totalSupply() private view returns (SharedObjects.ERC1155Supply[] memory) {
        SharedObjects.ERC1155Supply[] memory supplies = new SharedObjects.ERC1155Supply[](_allTokens.length);
        for (uint256 i = 0; i < _allTokens.length; i++) {
            supplies[i] = SharedObjects.ERC1155Supply({id: _allTokens[i], amount: _totalSupply[_allTokens[i]]});
        }
        return supplies;
    }

    /**
     * @notice Mint new tokens of a given id and submit a balance update to the PNH TokenRegistry.
     * @dev Restricted to owner-gated callers.
     * @param to Recipient of the new tokens.
     * @param id Token id.
     * @param value Amount to mint.
     * @param data Additional data forwarded to ERC1155 hooks.
     */
    function mint(address to, uint256 id, uint256 value, bytes memory data) public virtual restricted nonReentrant whenPrivacyNodeActive {
        _mint(to, id, value, data);
        _submitTokenUpdate(SharedObjects.BalanceUpdateType.MINT, id, value);
    }

    /**
     * @notice Burn tokens of a given id and submit a balance update to the PNH TokenRegistry.
     * @dev Restricted to owner-gated callers.
     * @param from Account whose tokens are burned.
     * @param id Token id.
     * @param value Amount to burn.
     */
    function burn(address from, uint256 id, uint256 value) public virtual restricted nonReentrant whenPrivacyNodeActive {
        _burn(from, id, value);
        _submitTokenUpdate(SharedObjects.BalanceUpdateType.BURN, id, value);
    }

    /// @notice See RaylsErc20Handler.crossMint NatSpec — same owner-restriction model.
    error RaylsErc1155Handler__NotTokenOwnerScoped(address originSender);

    /**
     * @notice Programmable mint, intended as a composed userBlob in an Enygma
     *         `crossTransfer`.
     * @dev RELAYER-gated direct caller + owner-restricted by attested origin. The
     *      ProgrammabilityExecutor appends the attested origin (sourced from `PNHTransfer.from`) as
     *      a trusted 20-byte calldata tail, read here via `_getMsgSenderOnReceiveMethod()`; this
     *      function verifies the origin holds contract-scoped `TOKEN_OWNER` on this token in the
     *      local AccessManager. The tail is read by absolute calldata offset (`calldatasize() - 20`),
     *      so it is correct even though this signature carries a dynamic `bytes data` parameter.
     *      Delegation: token owner calls
     *      `grantContractScopedRole(TOKEN_OWNER, delegate, address(this), 0)`.
     * @param to Recipient of the new tokens.
     * @param id Token id.
     * @param value Amount to mint.
     * @param data Additional data forwarded to ERC1155 hooks.
     */
    function crossMint(address to, uint256 id, uint256 value, bytes memory data)
        public virtual restricted nonReentrant
    {
        _requireOriginIsOwner(_getMsgSenderOnReceiveMethod());
        _mint(to, id, value, data);
        _submitTokenUpdate(SharedObjects.BalanceUpdateType.MINT, id, value);
    }

    /**
     * @notice Programmable burn, intended as a composed userBlob in an Enygma
     *         `crossTransfer`.
     * @dev See {crossMint} for the trust model.
     * @param from Account whose tokens are burned.
     * @param id Token id.
     * @param value Amount to burn.
     */
    function crossBurn(address from, uint256 id, uint256 value)
        public virtual restricted nonReentrant
    {
        _requireOriginIsOwner(_getMsgSenderOnReceiveMethod());
        _burn(from, id, value);
        _submitTokenUpdate(SharedObjects.BalanceUpdateType.BURN, id, value);
    }

    /// @dev Mirror of RaylsErc20Handler._requireOriginIsOwner; per-handler copy to avoid a shared
    ///      base churn. Looks up contract-scoped TOKEN_OWNER on this token via the AccessManager.
    function _requireOriginIsOwner(address originSender) internal view {
        address mgr = authority();
        if (originSender == address(0) || mgr == address(0)) {
            revert RaylsErc1155Handler__NotTokenOwnerScoped(originSender);
        }
        // Use the built-in TOKEN_OWNER constant (= 2) rather than getRoleIdByName("TOKEN_OWNER"):
        // the name→id reverse map is not populated for built-in roles on the deployed AccessManager,
        // and every other AccessManager consumer references the role by this constant.
        (bool isMember, uint32 execDelay) =
            IRaylsAccessManager(mgr).hasContractScopedRole(TOKEN_OWNER, originSender, address(this));
        if (!isMember || execDelay != 0) {
            revert RaylsErc1155Handler__NotTokenOwnerScoped(originSender);
        }
    }

    /**
     * @notice OZ ERC1155 `_update` override that maintains per-id supply + `_allTokens`.
     * @dev On mint (from == 0): increment `_totalSupply[id]`, record existence, push id.
     *      On burn (to == 0): decrement; when supply reaches zero, clear existence and
     *      swap-pop the id out of `_allTokens`.
     * @param from Sender (zero on mint).
     * @param to Recipient (zero on burn).
     * @param ids Token ids being moved/minted/burned.
     * @param amounts Amounts paired with `ids`.
     */
    function _update(address from, address to, uint256[] memory ids, uint256[] memory amounts)
        internal
        virtual
        override
    {
        super._update(from, to, ids, amounts);

        // Minting tokens
        if (from == address(0)) {
            for (uint256 i = 0; i < ids.length; ++i) {
                uint256 id = ids[i];
                uint256 amount = amounts[i];

                _totalSupply[id] += amount;
                if (!_exists[id]) {
                    _allTokens.push(id);
                    _exists[id] = true;
                }
            }
        }

        // Burning tokens
        if (to == address(0)) {
            for (uint256 i = 0; i < ids.length; ++i) {
                uint256 id = ids[i];
                uint256 amount = amounts[i];

                _totalSupply[id] -= amount;
                if (_totalSupply[id] == 0) {
                    _exists[id] = false;
                    // Remove the id from _allTokens array
                    for (uint256 j = 0; j < _allTokens.length; j++) {
                        if (_allTokens[j] == id) {
                            _allTokens[j] = _allTokens[_allTokens.length - 1];
                            _allTokens.pop();
                            break;
                        }
                    }
                }
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                    ACCESS CONTROL REGISTRATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Register this token with the local AccessManager via `selfRegisterManagedContract`.
     * @dev Wires owner-gated selectors to `_owner`, MESSAGE_EXECUTOR-gated selectors to the
     *      relayer's executor role, and RELAYER-gated programmable userBlob entries (crossMint/
     *      crossBurn) so the ProgrammabilityExecutor can target.call them. No-op when no
     *      AccessManager is bound.
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
        ownerSels[2] = this.submitTokenUpdate.selector;

        bytes4[] memory executorSels = new bytes4[](7);
        executorSels[0] = this.receiveTeleport.selector;
        executorSels[1] = this.receiveTeleportAtomic.selector;
        executorSels[2] = this.revertTeleportMint.selector;
        executorSels[3] = this.revertTeleportBurn.selector;
        executorSels[4] = this.unlock.selector;
        executorSels[5] = this.receiveTeleportFromPublicChain.selector;
        executorSels[6] = this.revertTeleportToPublicChain.selector;

        // Programmable userBlob entries — RELAYER-gated so the ProgrammabilityExecutor (which
        // holds RELAYER) can target.call them when a composed Enygma transfer carries a crossMint/
        // crossBurn blob against this token's own resourceId.
        bytes4[] memory relayerSels = new bytes4[](2);
        relayerSels[0] = this.crossMint.selector;
        relayerSels[1] = this.crossBurn.selector;

        IRaylsAccessManager.SelectorRoleMapping[] memory mappings = new IRaylsAccessManager.SelectorRoleMapping[](2);
        mappings[0] = IRaylsAccessManager.SelectorRoleMapping("MESSAGE_EXECUTOR", executorSels);
        mappings[1] = IRaylsAccessManager.SelectorRoleMapping("RELAYER", relayerSels);

        IRaylsAccessManager(mgr).selfRegisterManagedContract(_owner, ownerSels, mappings);

        // Also grant TOKEN_OWNER to the deployer when it differs from the configured owner
        // (factory path where `owner` is factoryOwner but the deployer is a distinct caller).
        if (caller != address(0) && caller != _owner) {
            IRaylsAccessManager(mgr).grantSelfTokenOwner(caller);
        }
    }
}
