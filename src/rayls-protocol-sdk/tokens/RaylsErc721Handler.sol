// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RaylsApp} from "../RaylsApp.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
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
 * @title RaylsErc721Handler
 * @notice ERC721 base for Rayls NFT tokens. Adds cross-chain teleport (one-shot + atomic +
 *         public-chain), per-token lock/unlock used by atomic flows, and supply-tracking via
 *         an internal `_allTokens` array maintained from `_update`.
 * @dev Inherit and extend; mint/burn/submitTokenUpdate gated to the owner role; receive*
 *      and revert* surfaces gated to MESSAGE_EXECUTOR. ReentrancyGuard guards every
 *      external mutation.
 */
abstract contract RaylsErc721Handler is RaylsApp, ERC721, ERC721Holder, Initializable, ReentrancyGuard, RaylsAccessManaged, IRaylsTokenStandard {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    /// @notice Thrown when a teleport call receives a zero address or zero chain id.
    /// @param to Recipient address provided by the caller.
    /// @param chainId Destination chain id provided by the caller.
    error RaylsErc721Handler__ZeroValueArg(address to, uint256 chainId);

    /// @notice Thrown when a teleport target chain id equals the current chain.
    /// @param chainId Same-chain id supplied by caller.
    error RaylsErc721Handler__WrongFunctionForSameChainId(uint256 chainId);

    /// @notice Thrown when an operation references a token id not currently tracked by the handler.
    error RaylsErc721Handler__TokenDoesNotExist();

    /// @notice Thrown when a lock is requested for a token already locked.
    error RaylsErc721Handler__TokenAlreadyLocked();

    /// @notice Thrown when caller of teleport/teleportAtomic is not the token owner.
    /// @param caller Address that called the teleport.
    /// @param owner Actual owner of the token id.
    error RaylsErc721Handler__NotTokenOwner(address caller, address owner);

    /// @notice Thrown when `_unlock` is called with the zero address.
    error RaylsErc721Handler__ZeroToAddress();

    /// @notice Thrown when `_unlock` is called for a token id that isn't currently locked.
    error RaylsErc721Handler__NoFundsToUnlock();

    /// @notice Thrown when `unlock` (or its variants) cannot release the lock.
    error RaylsErc721Handler__UnlockFailed();

    /// @notice Thrown when a teleport is attempted before the token has been registered.
    error RaylsErc721Handler__TokenNotRegistered();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    /// @notice Emitted when an account locks an NFT into the contract pool.
    /// @param account Account whose token was locked.
    /// @param tokenId Token id locked.
    event TokenLocked(address indexed account, uint256 indexed tokenId);

    /// @notice Emitted when a previously locked NFT is released.
    /// @param account Account whose token was unlocked.
    /// @param tokenId Token id unlocked.
    event TokenUnlocked(address indexed account, uint256 indexed tokenId);

    /// @notice Emitted when this ERC721 token contract is created and initialized.
    /// @param tokenAddress Address of the newly created token contract.
    event RaylsErc721TokenCreated(address indexed tokenAddress);

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    /// @dev Base URI returned by `_baseURI()`. Settable at construction/initialize time.
    string private _uri;

    /// @notice Token name returned by `name()`. Mirrors ERC721 metadata.
    string public _tokenName;

    /// @notice Token symbol returned by `symbol()`. Mirrors ERC721 metadata.
    string public _tokenSymbol;

    /// @notice True when this token was deployed by a custom-token issuer (not the standard
    ///         template flow). Informational; affects PNH-side metadata extraction.
    bool isCustom;

    /// @notice Per-account, per-token lock ledger used by atomic teleport flows.
    mapping(address => mapping(uint256 => bool)) lockedTokens;

    /// @notice Per-token guard preventing duplicate cross-chain deploy instructions.
    mapping(uint256 => bool) alreadySentDeployInstructions;

    // Supply tracking
    /// @dev Existence flag per token id, maintained by `_update` to track minted state.
    mapping(uint256 => bool) private _exists;

    /// @dev Append-only/swap-pop list of all currently-existing token ids.
    uint256[] private _allTokens;

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Construct the handler with ERC721 metadata + trusted endpoint references.
     * @dev `_disableInitializers()` blocks the upgradeable `initialize` path on the
     *      implementation; the constructor flow is for non-upgradeable issuer-side deploys.
     * @param uri Base URI for token metadata.
     * @param name_ Token name.
     * @param symbol_ Token symbol.
     * @param _endpoint Trusted Rayls endpoint address.
     * @param _raylsNodeEndpoint Privacy-node endpoint; zero on PNH deploys.
     * @param _userGovernance UserGovernance binding; zero when unused.
     * @param _owner Owner that receives owner-gated selectors.
     * @param _isCustom True for custom-token issuer flow; false for the standard template path.
     */
    constructor(
        string memory uri,
        string memory name_,
        string memory symbol_,
        address _endpoint,
        address _raylsNodeEndpoint,
        address _userGovernance,
        address _owner,
        bool _isCustom
    )
        ERC721(name_, symbol_)
        RaylsApp(_endpoint, _raylsNodeEndpoint, _userGovernance)
    {
        _tokenName = name_;
        _tokenSymbol = symbol_;
        _uri = uri;
        isCustom = _isCustom;
        _registerAccessControl(_owner, address(0));
        _disableInitializers();
    }

    /**
     * @notice Canonical init entrypoint dispatched by RaylsContractFactoryV1 / RNContractFactoryV1.
     * @param userArgs ABI-encoded `(string uri, string name, string symbol)`.
     *                 Caller-supplied via the cross-chain init payload.
     * @param trusted  Trusted addresses + resourceId from {RaylsTrustedInit}, set by the
     *                 factory at deploy time. Caller cannot forge.
     */
    function initialize(bytes calldata userArgs, RaylsTrustedInit calldata trusted) public virtual initializer {
        (string memory uri, string memory name_, string memory symbol_) =
            abi.decode(userArgs, (string, string, string));

        // ERC721 initialization
        _tokenName = name_;
        _tokenSymbol = symbol_;
        _uri = uri;

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
        emit RaylsErc721TokenCreated(address(this));
    }

    /**
     * @notice Returns the token name. Overrides ERC721 to read from initializer-set storage.
     * @return Token name string.
     */
    /**
     * @notice Receiver-side teleport-deploy hint. See {RaylsErc20Handler.teleportDeployHint}.
     * @return factoryKey RAYLS_ERC721_KEY.
     * @return userArgs   ABI-encoded `(string uri, string name, string symbol)`.
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function teleportDeployHint()
        external
        view
        virtual
        returns (bytes32 factoryKey, bytes memory userArgs)
    {
        factoryKey = keccak256("RAYLS_ERC721");
        userArgs = abi.encode(_uri, _tokenName, _tokenSymbol);
    }

    function name() public view virtual override returns (string memory) {
        return _tokenName;
    }

    /**
     * @notice Returns the token symbol. Overrides ERC721 to read from initializer-set storage.
     * @return Token symbol string.
     */
    function symbol() public view virtual override returns (string memory) {
        return _tokenSymbol;
    }

    /**
     * @notice Returns the ERC standard tag identifying this token shape.
     * @return The `SharedObjects.ErcStandard.ERC721` enum value.
     */
    function GetERCStandard() public pure virtual override returns (SharedObjects.ErcStandard) {
        return SharedObjects.ErcStandard.ERC721;
    }

    /**
     * @notice Returns the base URI used by ERC721 metadata.
     * @dev Overrides OZ ERC721 to read from initializer-set storage.
     * @return Base URI string.
     */
    function _baseURI() internal view virtual override returns (string memory) {
        return _uri;
    }

    /**
     * @notice External accessor that returns the base URI for ERC721 metadata.
     * @dev Mirrors `RaylsErc721DvpHandler.baseUri` so the issuer-side token registry replica
     *      can read the Rayls-set base URI without resorting to per-token `tokenURI` calls
     *      (which require an existing token id) or non-standard fallbacks (`symbol()`).
     * @return Base URI string.
     */
    function baseUri() public view virtual returns (string memory) {
        return _baseURI();
    }

    /**
     * @notice Approve an operator only while this token is active on the local Privacy Node.
     * @param to Account approved to manage `tokenId`.
     * @param tokenId Token id whose approval is updated.
     */
    function approve(address to, uint256 tokenId) public virtual override whenPrivacyNodeActive {
        super.approve(to, tokenId);
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
     * @notice Transfer an NFT only while this token is active on the local Privacy Node.
     * @param from Current token owner.
     * @param to Recipient address.
     * @param tokenId Token id to transfer.
     */
    function transferFrom(address from, address to, uint256 tokenId) public virtual override whenPrivacyNodeActive {
        super.transferFrom(from, to, tokenId);
    }

    /**
     * @notice Safely transfer an NFT only while this token is active on the local Privacy Node.
     * @param from Current token owner.
     * @param to Recipient address.
     * @param tokenId Token id to transfer.
     * @param data Additional data forwarded to the receiver hook.
     */
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public virtual override whenPrivacyNodeActive {
        super.safeTransferFrom(from, to, tokenId, data);
    }

    /**
     * @notice Teleports an ERC721 token to a specified address on a destination chain
     * @dev Burns the token on the current chain and initiates cross-chain transfer to mint on destination
     * @param to The recipient address on the destination chain (cannot be zero address)
     * @param id The token ID to teleport
     * @param chainId The destination chain identifier (must be different from current chain)
     * @return bool Returns true if teleport initiation is successful
     * @custom:reverts RaylsErc721Handler__ZeroValueArg if to is zero address or chainId is 0
     * @custom:reverts RaylsErc721Handler__WrongFunctionForSameChainId if chainId equals current chain
     * @custom:security Token is burned immediately on source chain, minting occurs on destination upon message delivery
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function teleport(address to, uint256 id, uint256 chainId) public virtual nonReentrant whenHubActive returns (bool) {
        // Input validation
        if (to == address(0) || chainId == 0) {
            revert RaylsErc721Handler__ZeroValueArg(to, chainId);
        }
        if (chainId == endpoint.getChainId()) {
            revert RaylsErc721Handler__WrongFunctionForSameChainId(chainId);
        }
        address tokenOwner = _ownerOf(id);
        if (tokenOwner != msg.sender) revert RaylsErc721Handler__NotTokenOwner(msg.sender, tokenOwner);
        if (lockedTokens[msg.sender][id]) {
            revert RaylsErc721Handler__TokenAlreadyLocked();
        }

        // Execute teleport logic
        _burn(id);

        BridgedTransferMetadata memory metadata = BridgedTransferMetadata({
            assetType: RaylsBridgeableERC.ERC721,
            id: id,
            from: msg.sender,
            to: to,
            amount: 1,
            tokenAddress: address(this)
        });

        // Prepare cross-chain transfer
        _sendTeleport(
            chainId,
            abi.encodeWithSignature("receiveTeleport(address,uint256)", to, id),
            bytes(""),
            bytes(""),
            bytes(""),
            metadata
        );
        return true;
    }

    /**
     * @notice Teleports an ERC721 token atomically with rollback capability
     * @dev Burns token on source, mints to contract owner on destination, locks for recipient until unlocked
     * @param to The recipient address on the destination chain (cannot be zero address)
     * @param id The token ID to teleport
     * @param chainId The destination chain identifier (must be different from current chain)
     * @return bool Returns true if atomic teleport initiation is successful
     * @custom:reverts RaylsErc721Handler__ZeroValueArg if to is zero address or chainId is 0
     * @custom:reverts RaylsErc721Handler__WrongFunctionForSameChainId if chainId equals current chain
     * @custom:atomic If destination fails, tokens can be reverted back to sender through revertTeleportMint
     * @custom:locking Token is minted to contract owner and locked for recipient until manual unlock
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function teleportAtomic(address to, uint256 id, uint256 chainId) public virtual nonReentrant whenHubActive returns (bool) {
        // Input validation
        if (to == address(0) || chainId == 0) {
            revert RaylsErc721Handler__ZeroValueArg(to, chainId);
        }
        if (chainId == endpoint.getChainId()) {
            revert RaylsErc721Handler__WrongFunctionForSameChainId(chainId);
        }
        address tokenOwner = _ownerOf(id);
        if (tokenOwner != msg.sender) revert RaylsErc721Handler__NotTokenOwner(msg.sender, tokenOwner);
        if (lockedTokens[msg.sender][id]) {
            revert RaylsErc721Handler__TokenAlreadyLocked();
        }

        // Execute teleport logic
        _burn(id);

        BridgedTransferMetadata memory metadata = BridgedTransferMetadata({
            assetType: RaylsBridgeableERC.ERC721,
            id: id,
            from: msg.sender,
            to: to,
            amount: 1,
            tokenAddress: address(this)
        });

        // Prepare cross-chain transfer
        _sendTeleport(
            chainId,
            abi.encodeWithSignature("receiveTeleportAtomic(address,uint256)", to, id),
            abi.encodeWithSignature("unlock(address,uint256)", to, id),
            abi.encodeWithSignature("revertTeleportMint(address,uint256)", msg.sender, id),
            abi.encodeWithSignature("revertTeleportBurn(address,uint256)", to, id),
            metadata
        );
        return true;
    }

    /**
     * @notice Teleport an NFT from this private chain to a public destination chain via the
     *         privacy-node endpoint.
     * @dev Locks the caller's token locally (no burn — public-chain bridge mints a wrapper).
     *      Gated by `onlyRegisteredUsers`. Reverts if caller is not the token owner.
     * @param to Recipient address on the destination public chain.
     * @param id Token id to teleport.
     * @param destinationChainId Public-chain id (different from current chain).
     * @return Always true on success; reverts otherwise.
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function teleportToPublicChain(address to, uint256 id, uint256 destinationChainId)
        public
        virtual
        onlyRegisteredUsers
        nonReentrant
        whenPublicChainActive
        returns (bool)
    {
        address tokenOwner = _ownerOf(id);
        if (tokenOwner != msg.sender) revert RaylsErc721Handler__NotTokenOwner(msg.sender, tokenOwner);
        _lock(msg.sender, id);

        BridgedTransferMetadata memory transferMetadata = BridgedTransferMetadata({
            assetType: RaylsBridgeableERC.ERC721,
            id: id,
            from: msg.sender,
            to: to,
            tokenAddress: address(this),
            amount: 1
        });

        // Convert BridgedTransferMetadata to RaylsNodeBridgedTransferMetadata
        RaylsNodeBridgedTransferMetadata memory raylsNodeTransferMetadata = RaylsNodeBridgedTransferMetadata({
            assetType: RaylsNodeBridgeableERC.ERC721,
            id: transferMetadata.id,
            from: transferMetadata.from,
            to: transferMetadata.to,
            tokenAddress: transferMetadata.tokenAddress,
            amount: transferMetadata.amount
        });

        raylsNodeEndpoint.sendToAddress(
            destinationChainId,
            address(this),
            abi.encodeWithSignature("receiveTeleportFromPrivacyNode(address,uint256,address,uint256)", msg.sender, raylsNodeEndpoint.getChainId(), to, id),
            abi.encodeWithSignature("unlock(address,uint256)", msg.sender, id),
            raylsNodeTransferMetadata
        );

        return true;
    }

    /**
     * @notice Receive a one-shot teleport on the destination chain. Mints the token to `to`.
     * @dev Restricted to MESSAGE_EXECUTOR. Counterpart of `teleport`.
     * @param to Recipient.
     * @param id Token id minted on this chain.
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function receiveTeleport(address to, uint256 id) public virtual restricted nonReentrant whenHubActive {
        _safeMint(to, id);
    }

    /**
     * @notice Receive an atomic teleport on the destination chain.
     * @dev Restricted to MESSAGE_EXECUTOR. Mints to this contract and locks for `to`; the
     *      atomic protocol later either unlocks (success) or reverts (failure) the lock.
     * @param to Recipient (final).
     * @param id Token id.
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function receiveTeleportAtomic(address to, uint256 id) public virtual restricted nonReentrant whenHubActive {
        _safeMint(address(this), id);
        if (to != address(this)) {
            _lockInternal(to, id, false);
        }
    }

    /**
     * @notice Revert path: re-mint the token on the sender side after destination failure.
     * @dev Restricted to MESSAGE_EXECUTOR.
     * @param to Original sender (gets the NFT back).
     * @param id Token id.
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function revertTeleportMint(address to, uint256 id) public virtual restricted nonReentrant whenHubActive {
        _safeMint(to, id);
    }

    /**
     * @notice Revert path: burn the locked NFT on the receiver side after sender failure.
     * @dev Restricted to MESSAGE_EXECUTOR. Releases the lock then burns the token.
     * @param to Receiver whose lock is being unwound.
     * @param id Token id.
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function revertTeleportBurn(address to, uint256 id) public virtual restricted nonReentrant whenHubActive {
        _unlock(to, id);
        _burn(id);
    }

    /**
     * @notice Unlocks the locked funds and calls transfer
     * @dev Restricted to MESSAGE_EXECUTOR. If `to` is this contract, no transfer is issued.
     * @param to Address of a "to" account to unlock the funds to
     * @param id Id of the token to unlock
     * @return Always true on success; reverts otherwise.
     */
    function unlock(address to, uint256 id) external restricted nonReentrant whenHubActive returns (bool) {
        if (to != address(this)) {
            bool success = _unlock(to, id);
            if (!success) revert RaylsErc721Handler__UnlockFailed();
            _safeTransfer(address(this), to, id);
        }
        return true;
    }

    /**
     * @notice Lock an NFT from `from` into this contract's locked-token pool.
     * @dev Wraps `_lockInternal` with `transferToken=true`. Used by public-chain teleport.
     * @param from Account whose token is being locked.
     * @param tokenId Token id to lock.
     */
    function _lock(address from, uint256 tokenId) internal {
        _lockInternal(from, tokenId, true);
    }

    /**
     * @notice Internal lock primitive shared by `_lock` and atomic-receive.
     * @dev Reverts if token does not exist or is already locked. When `transferToken` is
     *      false, caller has already moved the NFT into this contract.
     * @param from Account whose token is being locked.
     * @param tokenId Token id to lock.
     * @param transferToken If true, transfer the NFT from `from` into this contract;
     *                      if false, only update the locked-token ledger.
     */
    function _lockInternal(address from, uint256 tokenId, bool transferToken) internal {
        if (!_exists[tokenId]) {
            revert RaylsErc721Handler__TokenDoesNotExist();
        }
        if (lockedTokens[from][tokenId]) {
            revert RaylsErc721Handler__TokenAlreadyLocked();
        }

        lockedTokens[from][tokenId] = true;
        emit TokenLocked(from, tokenId);

        if (transferToken) {
            _transfer(from, address(this), tokenId);
        }
    }

    /**
     * @notice Internal unlock primitive: clears the locked flag for an account/token pair.
     * @dev Reverts on zero `to` or when no lock is recorded. Caller is responsible for the
     *      actual token transfer.
     * @param to Account whose lock is being released.
     * @param id Token id to unlock.
     * @return Always true on success; reverts otherwise.
     */
    function _unlock(address to, uint256 id) internal returns (bool) {
        if (to == address(0)) revert RaylsErc721Handler__ZeroToAddress();
        if (!lockedTokens[to][id]) revert RaylsErc721Handler__NoFundsToUnlock();
        lockedTokens[to][id] = false;
        emit TokenUnlocked(to, id);
        return true;
    }

    /**
     * @notice Receive an NFT teleport from a public chain back into this private chain.
     * @dev Restricted to MESSAGE_EXECUTOR and non-reentrant. Releases the lock then transfers the NFT to `to`.
     * @param to Recipient.
     * @param id Token id.
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function receiveTeleportFromPublicChain(address to, uint256 id) public virtual restricted nonReentrant whenPublicChainActive {
        bool success = _unlock(to, id);
        if (!success) revert RaylsErc721Handler__UnlockFailed();
        if (to != address(this)) {
            _safeTransfer(address(this), to, id);
        }
    }

    /**
     * @notice Restores an NFT locked by a failed private→public cross-chain mint
     * @dev Called by the public chain handler when receiveTeleportFromPrivacyNode cannot be completed (e.g. invalid destination).
     *      Mirrors the logic of `unlock` but accepts calls from the public chain endpoint.
     * @param from Address whose locked NFT should be restored
     * @param id Token ID to restore
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function revertTeleportToPublicChain(address from, uint256 id) external virtual restricted nonReentrant whenPublicChainActive {
        if (from != address(this)) {
            bool success = _unlock(from, id);
            if (!success) revert RaylsErc721Handler__UnlockFailed();
            _safeTransfer(address(this), from, id);
        }
    }

    /**
     * @notice Read whether a given token id is currently locked for an account.
     * @param account Account whose lock state is queried.
     * @param id Token id.
     * @return True if the token is locked for `account`.
     */
    function isTokenLocked(address account, uint256 id) public view returns (bool) {
        return lockedTokens[account][id];
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
     * @dev No-op when `resourceId` is unset (token not yet activated).
     * @param updateType MINT or BURN classification.
     * @param tokenId Token id changed.
     */
    function _submitTokenUpdate(SharedObjects.BalanceUpdateType updateType, uint256 tokenId) internal {
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
                abi.encode(tokenId)
            )
        );
    }

    /**
     * @notice Submit a mint/burn update to the PNH TokenRegistry.
     * @dev Restricted to owner-gated callers.
     * @param updateType MINT or BURN classification.
     * @param tokenId Token id changed.
     */
    function submitTokenUpdate(SharedObjects.BalanceUpdateType updateType, uint256 tokenId) public virtual restricted {
        _submitTokenUpdate(updateType, tokenId);
    }

    /**
     * @notice Read the list of all currently-existing token ids.
     * @dev Maintained by `_update` on mint/burn. Private to the contract; subclass exposure
     *      is opt-in.
     * @return Array of every token id with `_exists[id] == true`.
     */
    function totalSupply() private view returns (uint256[] memory) {
        return _allTokens;
    }

    /**
     * @notice Mint a new NFT and submit a balance update to the PNH TokenRegistry.
     * @dev Restricted to owner-gated callers.
     * @param to Recipient of the new NFT.
     * @param id Token id to mint.
     */
    function mint(address to, uint256 id) public virtual restricted nonReentrant whenPrivacyNodeActive {
        _safeMint(to, id);
        _submitTokenUpdate(SharedObjects.BalanceUpdateType.MINT, id);
    }

    /**
     * @notice Burn an NFT and submit a balance update to the PNH TokenRegistry.
     * @dev Restricted to owner-gated callers.
     * @param id Token id to burn.
     */
    function burn(uint256 id) public virtual restricted nonReentrant whenPrivacyNodeActive {
        _burn(id);
        _submitTokenUpdate(SharedObjects.BalanceUpdateType.BURN, id);
    }

    /// @notice See RaylsErc20Handler.crossMint NatSpec — same owner-restriction model.
    error RaylsErc721Handler__NotTokenOwnerScoped(address originSender);

    /**
     * @notice Programmable mint, intended as a composed userBlob in an Enygma
     *         `crossTransfer`.
     * @dev RELAYER-gated direct caller + owner-restricted by attested origin. The
     *      ProgrammabilityExecutor appends the attested origin (sourced from `PNHTransfer.from`) as
     *      a trusted 20-byte calldata tail, read here via `_getMsgSenderOnReceiveMethod()`; this
     *      function verifies the origin holds contract-scoped `TOKEN_OWNER` on this token in the
     *      local AccessManager. Delegation: token owner calls
     *      `grantContractScopedRole(TOKEN_OWNER, delegate, address(this), 0)`.
     * @param to Recipient of the new NFT.
     * @param id Token id to mint.
     */
    function crossMint(address to, uint256 id) public virtual restricted nonReentrant {
        _requireOriginIsOwner(_getMsgSenderOnReceiveMethod());
        _safeMint(to, id);
        _submitTokenUpdate(SharedObjects.BalanceUpdateType.MINT, id);
    }

    /**
     * @notice Programmable burn, intended as a composed userBlob in an Enygma
     *         `crossTransfer`.
     * @dev See {crossMint} for the trust model.
     * @param id Token id to burn.
     */
    function crossBurn(uint256 id) public virtual restricted nonReentrant {
        _requireOriginIsOwner(_getMsgSenderOnReceiveMethod());
        _burn(id);
        _submitTokenUpdate(SharedObjects.BalanceUpdateType.BURN, id);
    }

    /// @dev Mirror of RaylsErc20Handler._requireOriginIsOwner; per-handler copy to avoid a shared
    ///      base churn. Looks up contract-scoped TOKEN_OWNER on this token via the AccessManager.
    function _requireOriginIsOwner(address originSender) internal view {
        address mgr = authority();
        if (originSender == address(0) || mgr == address(0)) {
            revert RaylsErc721Handler__NotTokenOwnerScoped(originSender);
        }
        // Use the built-in TOKEN_OWNER constant (= 2) rather than getRoleIdByName("TOKEN_OWNER"):
        // the name→id reverse map is not populated for built-in roles on the deployed AccessManager,
        // and every other AccessManager consumer references the role by this constant.
        (bool isMember, uint32 execDelay) =
            IRaylsAccessManager(mgr).hasContractScopedRole(TOKEN_OWNER, originSender, address(this));
        if (!isMember || execDelay != 0) {
            revert RaylsErc721Handler__NotTokenOwnerScoped(originSender);
        }
    }

    /**
     * @notice OZ ERC721 `_update` override that maintains the `_exists` + `_allTokens` index.
     * @dev On mint (previousOwner == 0): record existence + push to `_allTokens`. On burn
     *      (to == 0): clear existence + swap-pop the id out of `_allTokens`.
     * @param to New owner (zero on burn).
     * @param tokenId Token id being moved/minted/burned.
     * @param auth Caller authority (OZ ERC721 internal mechanic).
     * @return previousOwner Owner before the update (zero on mint).
     */
    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address) {
        address previousOwner = super._update(to, tokenId, auth);

        // Minting token
        if (previousOwner == address(0)) {
            if (!_exists[tokenId]) {
                _allTokens.push(tokenId);
                _exists[tokenId] = true;
            }
        }

        // Burning token
        if (to == address(0)) {
            _exists[tokenId] = false;
            // Remove the id from _allTokens array
            for (uint256 i = 0; i < _allTokens.length; i++) {
                if (_allTokens[i] == tokenId) {
                    _allTokens[i] = _allTokens[_allTokens.length - 1];
                    _allTokens.pop();
                    break;
                }
            }
        }

        return previousOwner;
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
