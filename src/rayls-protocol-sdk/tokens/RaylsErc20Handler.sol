// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "../RaylsMessage.sol";
import "../interfaces/IRaylsEndpoint.sol";
import "../libraries/SharedObjects.sol";
import "../libraries/Utils.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {RaylsAccessManaged} from '../../privateHub/AccessControl/RaylsAccessManaged.sol';
import {IRaylsAccessManager} from '../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol';
import {TOKEN_OWNER} from '../../privateHub/AccessControl/AccessManagerTypes.sol';
import {IUserGovernance} from "../../rayls-node/rayls-privacy-node/interfaces/IUserGovernanceV1.sol";
import {IRaylsNodeEndpoint} from "../../rayls-node/rayls-privacy-node/interfaces/IRaylsNodeEndpoint.sol";
import {RaylsApp} from "../RaylsApp.sol";
import {IRaylsInitializer, RaylsTrustedInit} from "../IRaylsInitializer.sol";
import {IRaylsTokenStandard} from "../interfaces/IRaylsTokenStandard.sol";
import {FactoryKeys} from "../../rayls-protocol/RaylsContractFactory/FactoryKeys.sol";
import "../../rayls-node/rayls-privacy-node/RNMessageLib.sol";

/**
 * @title RaylsErc20Handler
 * @notice ERC20 base for Rayls tokens. Adds cross-chain teleport (one-shot + atomic +
 *         third-party + public-chain), mint/burn balance reporting to the PNH TokenRegistry,
 *         and a lock/unlock primitive used by atomic flows.
 * @dev Inherit and extend; mint, burn, and submitTokenUpdate are owner-gated; the receive*
 *      and revert* surfaces are gated to the MESSAGE_EXECUTOR role and registered with the
 *      AccessManager during construction/initialize via `_registerAccessControl`.
 */
abstract contract RaylsErc20Handler is RaylsApp, ERC20, Initializable, RaylsAccessManaged, IRaylsTokenStandard {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    /// @notice Thrown when a teleport receives a zero address, zero amount, or zero chain id.
    /// @param receiver Recipient address provided by the caller.
    /// @param value Amount provided by the caller.
    /// @param destCahinId Destination chain id provided by the caller (typo retained for ABI stability).
    error RaylsErc20Handler__ZeroValueArg(address receiver, uint256 value, uint256 destCahinId);

    /// @notice Thrown when teleport target chain id equals current chain.
    /// @param chainId Same-chain id supplied by caller.
    error RaylsErc20Handler__WrongFunctionForSameChainId(uint256 chainId);

    /// @notice Thrown when a third-party teleport `from` address is zero or equals msg.sender.
    /// @param from Invalid `from` argument.
    error RaylsErc20Handler__WrongAddress(address from);

    /// @notice Thrown when lock requested with zero amount.
    error RaylsErc20Handler__AmountMustBeGreaterThanZero();

    /// @notice Thrown when caller's balance is below the requested lock amount.
    error RaylsErc20Handler__InsufficientBalanceToLock();

    /// @notice Thrown when `_unlock` is called with the zero address as the target.
    error RaylsErc20Handler__ZeroToAddress();

    /// @notice Thrown when an unlock request exceeds the locked balance, or asks for zero.
    /// @param requested Amount caller asked to unlock.
    /// @param locked Amount actually locked for the account.
    error RaylsErc20Handler__InsufficientLockedAmount(uint256 requested, uint256 locked);

    /// @notice Thrown when the post-unlock invariant fails (e.g. internal accounting bug).
    error RaylsErc20Handler__UnlockFailed();

    /// @notice Thrown when teleport-side dispatch is called before the token has been activated.
    error RaylsErc20Handler__TokenNotRegistered();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    /// @notice Emitted when an account's tokens move into the contract's locked pool.
    /// @param account Account whose tokens were locked.
    /// @param amount Amount locked.
    event TokensLocked(address indexed account, uint256 amount);

    /// @notice Emitted when previously locked tokens are released back to an account.
    /// @param account Account whose tokens were unlocked.
    /// @param amount Amount unlocked.
    event TokensUnlocked(address indexed account, uint256 amount);

    /// @notice Emitted when this ERC20 token contract is created and initialized.
    /// @param tokenAddress Address of the newly created token contract.
    event RaylsErc20TokenCreated(address indexed tokenAddress);

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    /// @notice Name returned by `name()`. Mirrors ERC20 metadata; settable by initialize.
    string tokenName;

    /// @notice Symbol returned by `symbol()`. Mirrors ERC20 metadata; settable by initialize.
    string tokenSymbol;

    /// @notice True when this token was deployed by a custom-token issuer (not the standard
    ///         template flow). Informational; affects PNH-side metadata extraction.
    bool isCustom;

    /// @notice Decimals returned by `decimals()`. Mirrors ERC20 metadata.
    uint8 internalDecimals;

    /// @dev ERC20 token identifier for cross-chain transfers (0 for standard ERC20 fungible tokens).
    uint8 internal _erc20Identifier = 0;

    /// @notice Per-account locked-balance ledger used by atomic teleport flows.
    mapping(address => uint256) lockedAmount;

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Construct the handler with ERC20 metadata + trusted endpoint references.
     * @dev `_disableInitializers()` blocks the upgradeable `initialize` path on the
     *      implementation; the constructor flow is for non-upgradeable deploys (issuer chain).
     * @param _name Token name.
     * @param _symbol Token symbol.
     * @param _endpoint Trusted Rayls endpoint address.
     * @param _raylsNodeEndpoint Privacy-node endpoint; zero on PNH deploys.
     * @param _userGovernance UserGovernance binding; zero when unused.
     * @param _owner Owner that receives owner-gated selectors (mint/burn/submitTokenUpdate).
     * @param _isCustom True for custom-token issuer flow; false for the standard template path.
     */
    constructor(string memory _name, string memory _symbol, address _endpoint, address _raylsNodeEndpoint, address _userGovernance, address _owner, bool _isCustom)
        ERC20(_name, _symbol)
        RaylsApp(_endpoint, _raylsNodeEndpoint, _userGovernance)
    {
        tokenName = _name;
        tokenSymbol = _symbol;
        isCustom = _isCustom;
        // Constructor-deployed instances default to the conventional ERC20 decimals. The
        // authoritative per-token value is set by {initialize} on the FACTORY/upgradeable path;
        // setting it here keeps `decimals()` sane for non-`initialize` deploys (and avoids an
        // uninitialized-state read on the constructor flow).
        internalDecimals = 18;
        _registerAccessControl(_owner, address(0));
        _disableInitializers();
    }

    /**
     * @notice Canonical init entrypoint dispatched by RaylsContractFactoryV1 / RNContractFactoryV1.
     * @param userArgs ABI-encoded `(string name, string symbol, uint8 decimals)`.
     *                 Caller-supplied via the cross-chain init payload.
     * @param trusted  Trusted addresses + resourceId from {RaylsTrustedInit}, set by the
     *                 factory at deploy time. Caller cannot forge.
     */
    function initialize(bytes calldata userArgs, RaylsTrustedInit calldata trusted) public virtual initializer {
        (string memory _name, string memory _symbol, uint8 _decimals) =
            abi.decode(userArgs, (string, string, uint8));

        // ERC20 initialization
        tokenName = _name;
        tokenSymbol = _symbol;

        // RaylsApp initialization (trusted addresses from factory-injected struct)
        endpoint = IRaylsEndpoint(trusted.endpoint);
        // Mirror the constructor's null guard — a factory not yet wired to an RN endpoint
        // passes `address(0)` for raylsNodeEndpoint, leaving the handler "unbound"
        // (teleportToPublicChain unavailable). See IRaylsInitializer.sol.
        if (trusted.raylsNodeEndpoint != address(0)) {
            raylsNodeEndpoint = IRaylsNodeEndpoint(trusted.raylsNodeEndpoint);
        }
        _initializeUserGovernance(trusted.userGovernance);
        resourceId = trusted.resourceId;

        internalDecimals = _decimals;
        _registerAccessControl(trusted.owner, trusted.caller);
        emit RaylsErc20TokenCreated(address(this));
    }

    /**
     * @notice Receiver-side teleport-deploy hint. Returns the factory key and ABI-encoded init
     *         user-args that an off-chain orchestrator (relayer) must use to materialise the
     *         matching instance on a destination PN whose endpoint has no record of this token's
     *         resourceId yet. Pairs with {RNContractFactoryV1.deployFromTeleport}.
     * @dev The owner that should be passed to `deployFromTeleport` is independently sourced from
     *      this instance's `AccessManager` (the TOKEN_OWNER scoped to `address(this)` — typically
     *      the address that called `deployErc20AsUser`). Splitting "what to deploy" from "who owns
     *      it" keeps each read responsibility local to the contract that owns it.
     * @return factoryKey Seeded bytecode key (e.g. RAYLS_ERC20_KEY).
     * @return userArgs   ABI-encoded `(string name, string symbol, uint8 decimals)` matching what
     *                    {initialize} consumes.
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function teleportDeployHint()
        external
        view
        virtual
        returns (bytes32 factoryKey, bytes memory userArgs)
    {
        factoryKey = FactoryKeys.RAYLS_ERC20_KEY;
        userArgs = abi.encode(tokenName, tokenSymbol, internalDecimals);
    }

    /**
     * @notice Returns the token name. Overrides ERC20 to read from initializer-set storage.
     * @return Token name string.
     */
    function name() public view override returns (string memory) {
        return tokenName;
    }

    /**
     * @notice Returns the ERC standard tag identifying this token shape.
     * @return The `SharedObjects.ErcStandard.ERC20` enum value.
     */
    function GetERCStandard() public pure virtual override returns (SharedObjects.ErcStandard) {
        return SharedObjects.ErcStandard.ERC20;
    }

    /**
     * @notice Submit a mint/burn balance update to the PNH TokenRegistry.
     * @dev Restricted to owner-gated callers. Wraps `_submitTokenUpdate`.
     * @param updateType MINT or BURN classification.
     * @param amount Amount changed (positive value; direction implied by `updateType`).
     */
    function submitTokenUpdate(SharedObjects.BalanceUpdateType updateType, uint256 amount) public virtual restricted {
        _submitTokenUpdate(updateType, amount);
    }

    /**
     * @notice Internal helper that dispatches a balance-update message to the PNH TokenRegistry.
     * @dev No-op when the token is not PNH-registered. Two cases collapse to "skip": (1) `resourceId`
     *      unset, and (2) `resourceId` set locally but never bound on the endpoint — the latter is a
     *      user-deployed token (`RNContractFactory.deployXAsUser`) whose `initialize` set `resourceId`
     *      but never ran the PNH-activation path (`receiveResourceId` → `_registerResourceId`), so it
     *      lacks `ENDPOINT_SENDER` and is not a hub-tracked token. Such a token must not (and cannot)
     *      report balances to the PNH TokenRegistry; emitting would revert `endpoint.send` for lack of
     *      the role. Registration is detected by the endpoint resolving this resourceId to `this`.
     * @param updateType MINT or BURN classification.
     * @param amount Amount changed.
     */
    function _submitTokenUpdate(SharedObjects.BalanceUpdateType updateType, uint256 amount) internal {
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
                abi.encode(amount)
            )
        );
    }

    /**
     * @notice Returns the token symbol. Overrides ERC20 to read from initializer-set storage.
     * @return Token symbol string.
     */
    function symbol() public view override returns (string memory) {
        return tokenSymbol;
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
     * @notice Teleports ERC20 tokens from this chain to a specified destination chain
     * @dev Burns tokens on the source chain and initiates cross-chain transfer to mint on destination
     * @param to The recipient address on the destination chain
     * @param value The amount of tokens to teleport (must be > 0)
     * @param chainId The destination chain identifier (must be different from current chain)
     * @return bool Returns true if teleport initiation is successful
     * @custom:reverts RaylsErc20Handler__ZeroValueArg if to is zero address, value is 0, or chainId is 0
     * @custom:reverts RaylsErc20Handler__WrongFunctionForSameChainId if chainId equals current chain
     * @custom:security Tokens are burned immediately on source chain, minting occurs on destination upon message delivery
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function teleport(address to, uint256 value, uint256 chainId) public virtual whenHubActive returns (bool) {
        // Input validation
        if (to == address(0) || value == 0 || chainId == 0) {
            revert RaylsErc20Handler__ZeroValueArg(to, value, chainId);
        }
        if (chainId == endpoint.getChainId()) {
            revert RaylsErc20Handler__WrongFunctionForSameChainId(chainId);
        }

        // Execute teleport logic
        address spender = _msgSender();
        _burn(spender, value);

        BridgedTransferMetadata memory transferMetadata = BridgedTransferMetadata({
            assetType: RaylsBridgeableERC.ERC20,
            id: _erc20Identifier,
            from: spender,
            tokenAddress: address(this),
            to: to,
            amount: value
        });

        // Prepare cross-chain transfer
        _sendTeleport(
            chainId,
            abi.encodeWithSignature("receiveTeleport(address,uint256)", to, value),
            bytes(""),
            bytes(""),
            bytes(""),
            transferMetadata
        );
        return true;
    }

    /**
     * @notice Teleports ERC20 tokens on behalf of another account (third-party transfer)
     * @dev Similar to transferFrom, burns tokens from 'from' account and mints on destination chain
     * @param from The token owner address (must have given approval to msg.sender)
     * @param to The recipient address on the destination chain
     * @param value The amount of tokens to teleport (must be > 0)
     * @param chainId The destination chain identifier (must be different from current chain)
     * @return bool Returns true if teleport initiation is successful
     * @custom:reverts RaylsErc20Handler__ZeroValueArg if to is zero address, value is 0, or chainId is 0
     * @custom:reverts RaylsErc20Handler__WrongFunctionForSameChainId if chainId equals current chain
     * @custom:security Requires prior approval from 'from' account, prevents self-teleporting (use teleport() instead)
     * @custom:approval msg.sender must have sufficient allowance from 'from' account
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function teleportFrom(address from, address to, uint256 value, uint256 chainId) public virtual whenHubActive returns (bool) {
        // Input validation
        if (from == address(0) || from == msg.sender) {
            revert RaylsErc20Handler__WrongAddress(from);
        }
        if (to == address(0) || value == 0 || chainId == 0) {
            revert RaylsErc20Handler__ZeroValueArg(to, value, chainId);
        }
        if (chainId == endpoint.getChainId()) {
            revert RaylsErc20Handler__WrongFunctionForSameChainId(chainId);
        }

        // Execute teleport logic
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        _burn(from, value);

        BridgedTransferMetadata memory transferMetadata = BridgedTransferMetadata({
            assetType: RaylsBridgeableERC.ERC20,
            id: 0,
            from: from,
            to: to,
            amount: value,
            tokenAddress: address(this)
        });

        // Prepare cross-chain transfer
        _sendTeleport(
            chainId,
            abi.encodeWithSignature("receiveTeleport(address,uint256)", to, value),
            bytes(""),
            bytes(""),
            bytes(""),
            transferMetadata
        );

        return true;
    }

    /**
     * @notice Atomically teleports ERC20 tokens with revert capability if destination fails
     * @dev Burns tokens on source chain and initiates atomic cross-chain transfer with unlock/revert mechanisms
     * @param to The recipient address on the destination chain
     * @param value The amount of tokens to teleport atomically (must be > 0)
     * @param destinationChainId The destination chain identifier (must be different from current chain)
     * @return bool Returns true if atomic teleport initiation is successful
     * @custom:reverts RaylsErc20Handler__ZeroValueArg if to is zero address, value is 0, or destinationChainId is 0
     * @custom:reverts RaylsErc20Handler__WrongFunctionForSameChainId if destinationChainId equals current chain
     * @custom:security Uses atomic mechanism - tokens are locked on destination until confirmed, with revert capability
     * @custom:atomic If destination fails, tokens can be reverted back to sender through revertTeleportMint
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function teleportAtomic(address to, uint256 value, uint256 destinationChainId) public virtual whenHubActive returns (bool) {
        // Input validation
        if (to == address(0) || value == 0 || destinationChainId == 0) {
            revert RaylsErc20Handler__ZeroValueArg(to, value, destinationChainId);
        }
        if (destinationChainId == endpoint.getChainId()) {
            revert RaylsErc20Handler__WrongFunctionForSameChainId(destinationChainId);
        }

        // Execute teleport logic
        _burn(msg.sender, value);

        BridgedTransferMetadata memory transferMetadata = BridgedTransferMetadata({
            assetType: RaylsBridgeableERC.ERC20,
            id: 0,
            from: msg.sender,
            to: to,
            tokenAddress: address(this),
            amount: value
        });

        // Prepare cross-chain transfer
        _sendTeleport(
            destinationChainId,
            abi.encodeWithSignature("receiveTeleportAtomic(address,uint256)", to, value),
            abi.encodeWithSignature("unlock(address,uint256)", to, value),
            abi.encodeWithSignature("revertTeleportMint(address,uint256)", msg.sender, value),
            abi.encodeWithSignature("revertTeleportBurn(address,uint256)", to, value),
            transferMetadata
        );
        return true;
    }

    /**
     * @notice Atomically teleports ERC20 tokens on behalf of another account with revert capability
     * @dev Third-party atomic teleport with approval check, tokens locked on destination until confirmed
     * @param from The token owner address (must NOT be msg.sender, must have given approval)
     * @param to The recipient address on the destination chain
     * @param value The amount of tokens to teleport atomically (must be > 0)
     * @param destinationChainId The destination chain identifier (must be different from current chain)
     * @return bool Returns true if atomic teleport initiation is successful
     * @custom:reverts RaylsErc20Handler__WrongAddress if from is zero address or equals msg.sender
     * @custom:reverts RaylsErc20Handler__ZeroValueArg if to is zero address, value is 0, or destinationChainId is 0
     * @custom:reverts RaylsErc20Handler__WrongFunctionForSameChainId if destinationChainId equals current chain
     * @custom:security Enforces third-party usage only - prevents self-teleporting (use teleportAtomic() instead)
     * @custom:approval msg.sender must have sufficient allowance from 'from' account
     * @custom:atomic If destination fails, tokens can be reverted back to 'from' account through revertTeleportMint
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function teleportAtomicFrom(address from, address to, uint256 value, uint256 destinationChainId)
        public
        virtual
        whenHubActive
        returns (bool)
    {
        // Input validation
        if (from == address(0) || from == msg.sender) {
            revert RaylsErc20Handler__WrongAddress(from);
        }
        if (to == address(0) || value == 0 || destinationChainId == 0) {
            revert RaylsErc20Handler__ZeroValueArg(to, value, destinationChainId);
        }
        if (destinationChainId == endpoint.getChainId()) {
            revert RaylsErc20Handler__WrongFunctionForSameChainId(destinationChainId);
        }

        // Execute teleport logic
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        _burn(from, value);

        BridgedTransferMetadata memory transferMetadata = BridgedTransferMetadata({
            assetType: RaylsBridgeableERC.ERC20,
            id: 0,
            from: from,
            to: to,
            amount: value,
            tokenAddress: address(this)
        });

        // Prepare cross-chain transfer
        _sendTeleport(
            destinationChainId,
            abi.encodeWithSignature("receiveTeleportAtomic(address,uint256)", to, value),
            abi.encodeWithSignature("unlock(address,uint256)", to, value),
            abi.encodeWithSignature("revertTeleportMint(address,uint256)", from, value),
            abi.encodeWithSignature("revertTeleportBurn(address,uint256)", to, value),
            transferMetadata
        );
        return true;
    }

    /**
     * @notice Teleport tokens from this private chain to a public destination chain via the
     *         privacy-node endpoint.
     * @dev Locks the caller's tokens locally (no burn — public-chain bridge mints a wrapper);
     *      gated by `onlyRegisteredUsers` so only governance-approved senders can initiate.
     *      Destination side eventually calls `revertTeleportToPublicChain` if delivery fails.
     * @param to Recipient address on the destination public chain.
     * @param value Amount to teleport (must be > 0).
     * @param destinationChainId Public-chain id (different from current chain).
     * @return Always true on success; reverts otherwise.
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function teleportToPublicChain(address to, uint256 value, uint256 destinationChainId)
    public
    virtual
    onlyRegisteredUsers
    whenPublicChainActive
    returns (bool) {
        _lock(msg.sender, value);

        // Convert BridgedTransferMetadata to RaylsNodeBridgedTransferMetadata
        RaylsNodeBridgedTransferMetadata memory raylsNodeTransferMetadata = RaylsNodeBridgedTransferMetadata({
            assetType: RaylsNodeBridgeableERC.ERC20,
            id: 0,
            from: msg.sender,
            to: to,
            tokenAddress: address(this),
            amount: value
        });

        raylsNodeEndpoint.sendToAddress(
            destinationChainId,
            address(this),
            abi.encodeWithSignature("receiveTeleportFromPrivacyNode(address,uint256,address,uint256)", msg.sender, raylsNodeEndpoint.getChainId(), to, value),
            abi.encodeWithSignature("unlock(address,uint256)", msg.sender, value),
            raylsNodeTransferMetadata
        );

        return true;
    }

    /**
     * @notice Receive a one-shot teleport on the destination chain. Mints `value` to `to`.
     * @dev Restricted to MESSAGE_EXECUTOR. Counterpart of `teleport` / `teleportFrom`.
     * @param to Recipient.
     * @param value Amount to mint.
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function receiveTeleport(address to, uint256 value) public virtual restricted whenHubActive {
        _mint(to, value);
    }

    /**
     * @notice Receive a teleport from a public chain back into this private chain.
     * @dev Restricted to MESSAGE_EXECUTOR. Releases locked tokens back to `to`; if `to`
     *      is this contract, the tokens stay locked (caller-side concern).
     * @param to Recipient.
     * @param value Amount to release.
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function receiveTeleportFromPublicChain(address to, uint256 value) public virtual restricted whenPublicChainActive {
        bool success = _unlock(to, value);
        if (!success) revert RaylsErc20Handler__UnlockFailed();
        if (to != address(this)) {
            _transfer(address(this), to, value);
        }
    }

    /**
     * @notice Restores tokens locked by a failed private→public cross-chain mint
     * @dev Called by the public chain handler when receiveTeleportFromPrivacyNode cannot be completed (e.g. invalid destination).
     *      Mirrors the logic of `unlock` but accepts calls from the public chain endpoint.
     * @param from Address whose locked tokens should be restored
     * @param amount Amount to restore
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function revertTeleportToPublicChain(address from, uint256 amount) external virtual restricted whenPublicChainActive {
        if (from != address(this)) {
            bool success = _unlock(from, amount);
            if (!success) revert RaylsErc20Handler__UnlockFailed();
            _transfer(address(this), from, amount);
        }
    }

    /**
     * @notice Receive an atomic teleport on the destination chain.
     * @dev Restricted to MESSAGE_EXECUTOR. Mints to this contract and locks for `to`; the
     *      atomic protocol later either unlocks (success) or reverts (failure) the lock.
     * @param to Recipient (final).
     * @param value Amount.
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function receiveTeleportAtomic(address to, uint256 value) public virtual restricted whenHubActive {
        _mint(address(this), value);
        if (to != address(this)) {
            _lockInternal(to, value, false);
        }
    }

    /**
     * @notice Revert path: re-mint tokens on the sender side after destination failure.
     * @dev Restricted to MESSAGE_EXECUTOR. Counterpart of `revertTeleportBurn` on the receiver.
     * @param to Original sender (gets the tokens back).
     * @param value Amount.
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function revertTeleportMint(address to, uint256 value) public virtual restricted whenHubActive {
        _mint(to, value);
    }

    /**
     * @notice Revert path: burn the locked tokens on the receiver side after sender failure.
     * @dev Restricted to MESSAGE_EXECUTOR. Releases the lock then burns from this contract.
     * @param to Receiver whose lock is being unwound.
     * @param value Amount.
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function revertTeleportBurn(address to, uint256 value) public virtual restricted whenHubActive {
        _unlock(to, value);
        _burn(address(this), value);
    }

    /**
     * @notice Unlocks the locked funds and calls transfer
     * @dev Restricted to MESSAGE_EXECUTOR. If `to` is this contract, no transfer is issued.
     * @param to Address of a "to" account to unlock the funds to
     * @param amount Amount of tokens to unlock
     * @return Always true on success; reverts otherwise.
     */
    function unlock(address to, uint256 amount) external restricted whenHubActive returns (bool) {
        if (to != address(this)) {
            bool success = _unlock(to, amount);
            if (!success) revert RaylsErc20Handler__UnlockFailed();
            _transfer(address(this), to, amount);
            return true;
        }
        return true;
    }

    /**
     * @notice Lock tokens from `from` into this contract's locked-balance pool.
     * @dev Wraps `_lockInternal` with `transferTokens=true`. Used by public-chain teleport.
     * @param from Account whose tokens are being locked.
     * @param amount Amount to lock (must be > 0).
     */
    function _lock(address from, uint256 amount) internal {
        _lockInternal(from, amount, true);
    }

    /**
     * @notice Internal lock primitive shared by `_lock` and atomic-receive.
     * @dev Reverts on zero amount; reverts on insufficient balance only when `transferTokens`
     *      is true. When `transferTokens` is false, the caller has already moved the tokens
     *      into this contract (atomic-receive path).
     * @param from Account whose tokens are being locked.
     * @param amount Amount to lock.
     * @param transferTokens If true, transfer `amount` from `from` into this contract;
     *                       if false, only update the locked-balance ledger.
     */
    function _lockInternal(address from, uint256 amount, bool transferTokens) internal {
        if (amount == 0) {
            revert RaylsErc20Handler__AmountMustBeGreaterThanZero();
        }

        if (transferTokens && balanceOf(from) < amount) {
            revert RaylsErc20Handler__InsufficientBalanceToLock();
        }

        lockedAmount[from] += amount;
        emit TokensLocked(from, amount);

        if (transferTokens) {
            _transfer(from, address(this), amount);
        }
    }

    /**
     * @notice Internal unlock primitive: decrements the locked-balance ledger.
     * @dev Reverts on zero `to`, zero `amount`, or amount exceeding currently locked balance.
     *      Caller is responsible for the actual token transfer (this only updates state +
     *      emits the event).
     * @param to Account whose lock is being released.
     * @param amount Amount to unlock.
     * @return Always true on success; reverts otherwise.
     */
    function _unlock(address to, uint256 amount) internal returns (bool) {
        if (to == address(0)) revert RaylsErc20Handler__ZeroToAddress();

        uint256 amountToUnlock = lockedAmount[to];
        if (amount == 0 || amount > amountToUnlock) {
            revert RaylsErc20Handler__InsufficientLockedAmount(amount, amountToUnlock);
        }

        lockedAmount[to] -= amount;
        emit TokensUnlocked(to, amount);

        return true;
    }

    /**
     * @notice Read the locked-balance ledger entry for an account.
     * @param account Account to query.
     * @return Currently locked amount for `account`.
     */
    function getLockedAmount(address account) public view returns (uint256) {
        return lockedAmount[account];
    }

    /**
     * @notice Internal cross-chain dispatch helper for teleport flows.
     * @dev Reverts if `resourceId` is unset (token not yet registered). Forwards to
     *      `_raylsSendToResourceId` with the supplied lock + revert + metadata payloads.
     * @param chainId Destination chain id.
     * @param _payload ABI-encoded payload to dispatch on the destination handler.
     * @param _lockDataPayload Lock-state payload (atomic flow).
     * @param _revertDataPayloadSender Revert payload to dispatch on the sender chain on failure.
     * @param _revertDataPayloadReceiver Revert payload to dispatch on the receiver chain on failure.
     * @param transferMetadata Bridged-transfer metadata.
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function sendTeleport(
        uint256 chainId,
        bytes memory _payload,
        bytes memory _lockDataPayload,
        bytes memory _revertDataPayloadSender,
        bytes memory _revertDataPayloadReceiver,
        BridgedTransferMetadata memory transferMetadata
    ) internal whenHubActive {
        _sendTeleport(
            chainId,
            _payload,
            _lockDataPayload,
            _revertDataPayloadSender,
            _revertDataPayloadReceiver,
            transferMetadata
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
        BridgedTransferMetadata memory transferMetadata
    ) private {
        _raylsSendToResourceId(
            chainId,
            resourceId,
            _payload,
            _lockDataPayload,
            _revertDataPayloadSender,
            _revertDataPayloadReceiver,
            transferMetadata
        );
    }

    /**
     * @notice Mint new tokens and submit a balance update to the PNH TokenRegistry.
     * @dev Restricted to owner-gated callers.
     * @param to Recipient of newly minted tokens.
     * @param value Amount to mint.
     */
    function mint(address to, uint256 value) public virtual restricted whenPrivacyNodeActive {
        _mint(to, value);
        _submitTokenUpdate(SharedObjects.BalanceUpdateType.MINT, value);
    }

    /**
     * @notice Burn tokens and submit a balance update to the PNH TokenRegistry.
     * @dev Restricted to owner-gated callers.
     * @param from Account whose tokens are being burned.
     * @param value Amount to burn.
     */
    function burn(address from, uint256 value) public virtual restricted whenPrivacyNodeActive {
        _burn(from, value);
        _submitTokenUpdate(SharedObjects.BalanceUpdateType.BURN, value);
    }

    /// @notice Programmability mint was invoked with an originSender that does not hold
    ///         TOKEN_OWNER scoped to this token. The owner-restriction enforces that only
    ///         the registered token owner (or delegates the owner has explicitly granted) can
    ///         compose a `crossMint(X)` userBlob in an Enygma transfer.
    /// @param originSender The attested source-chain EOA that was forwarded by the executor.
    error RaylsErc20Handler__NotTokenOwnerScoped(address originSender);

    /**
     * @notice Programmable mint, intended as a composed userBlob in an Enygma
     *         `crossTransfer`.
     * @dev    RELAYER-gated direct caller (only the ProgrammabilityExecutor can invoke), AND
     *         owner-restricted by origin: the executor appends the attested origin
     *         (sourced from `PNHTransfer.from` — the EOA that initiated the Enygma transfer on
     *         the origin chain) as a trusted 20-byte calldata tail; this function reads it via
     *         `_getMsgSenderOnReceiveMethod()` and verifies that the attested origin holds
     *         `TOKEN_OWNER` scoped to this token in the local AccessManager.
     *
     *         Delegation works through the existing contract-scoping API: the token's owner
     *         (initially the deployer) can `grantContractScopedRole(TOKEN_OWNER, delegate, X, 0)`
     *         to extend mint-via-programmability authority. Revocation is symmetric.
     *
     *         Trust chain: relayer faithfully forwards `originSender` from the source-chain
     *         message into the 3-arg `executeProgramData(blobs, expectedMintTotal, originSender)`
     *         entry point; the executor appends it as a trusted calldata tail read by absolute
     *         offset (`calldatasize() - 20`), so the read is independent of the target's ABI
     *         layout — correct even for selectors with dynamic args. Safe because the function is
     *         `restricted` (executor/RELAYER-only) and the executor controls the tail.
     * @param to Recipient of the new tokens.
     * @param value Amount to mint.
     */
    function crossMint(address to, uint256 value) public virtual restricted {
        _requireOriginIsOwner(_getMsgSenderOnReceiveMethod());
        _mint(to, value);
        _submitTokenUpdate(SharedObjects.BalanceUpdateType.MINT, value);
    }

    /**
     * @notice Programmable burn, intended as a composed userBlob in an Enygma
     *         `crossTransfer`.
     * @dev See {crossMint} for the trust model. Same owner-restriction applies: only an
     *      attested origin holding contract-scoped `TOKEN_OWNER` may compose a `crossBurn` userBlob.
     * @param from Account whose tokens are being burned.
     * @param value Amount to burn.
     */
    function crossBurn(address from, uint256 value) public virtual restricted {
        _requireOriginIsOwner(_getMsgSenderOnReceiveMethod());
        _burn(from, value);
        _submitTokenUpdate(SharedObjects.BalanceUpdateType.BURN, value);
    }

    /// @dev Owner-restriction check for the programmability path. Looks up contract-scoped
    ///      TOKEN_OWNER membership of `originSender` on this token via the local AccessManager.
    ///      Reverts with {RaylsErc20Handler__NotTokenOwnerScoped} on miss. Requires a non-zero
    ///      origin (rejects unattested calls).
    function _requireOriginIsOwner(address originSender) internal view {
        address mgr = authority();
        if (originSender == address(0) || mgr == address(0)) {
            revert RaylsErc20Handler__NotTokenOwnerScoped(originSender);
        }
        // Use the built-in TOKEN_OWNER constant (= 2) rather than getRoleIdByName("TOKEN_OWNER"):
        // the name→id reverse map is not populated for built-in roles on the deployed AccessManager,
        // and every other AccessManager consumer references the role by this constant.
        (bool isMember, uint32 execDelay) =
            IRaylsAccessManager(mgr).hasContractScopedRole(TOKEN_OWNER, originSender, address(this));
        if (!isMember || execDelay != 0) {
            revert RaylsErc20Handler__NotTokenOwnerScoped(originSender);
        }
    }

    /**
     * @notice Returns the token decimals. Overrides ERC20 to read from initializer-set storage.
     * @return Decimals as configured at construction/initialize time.
     */
    function decimals() public view virtual override returns (uint8) {
        return internalDecimals;
    }

    /*//////////////////////////////////////////////////////////////
                    ACCESS CONTROL REGISTRATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Register this token with the local AccessManager via `selfRegisterManagedContract`.
     * @dev Wires owner-gated selectors (mint/burn/submitTokenUpdate) to `_owner`,
     *      MESSAGE_EXECUTOR-gated selectors (receiveTeleport, revertTeleport*, unlock, ...) to
     *      the relayer's executor role, and RELAYER-gated programmable userBlob entries
     *      (crossMint/crossBurn) so the ProgrammabilityExecutor can target.call them. No-op when
     *      no AccessManager is bound (constructor flow on chains without Auth V3).
     * @param _owner Address that becomes owner of the owner-gated selectors.
     * @param caller The external deployer (factory's `msg.sender`); when non-zero and distinct
     *               from `_owner`, also granted TOKEN_OWNER scoped to this token. `address(0)`
     *               on the constructor path.
     */
    function _registerAccessControl(address _owner, address caller) internal virtual {
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
