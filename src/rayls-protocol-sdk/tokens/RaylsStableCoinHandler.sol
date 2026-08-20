// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RaylsErc20Handler} from "./RaylsErc20Handler.sol";
import {IRaylsAccessManager} from "../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol";
import {RaylsTrustedInit} from "../IRaylsInitializer.sol";
import {SharedObjects} from "../libraries/SharedObjects.sol";
import {FactoryKeys} from "../../rayls-protocol/RaylsContractFactory/FactoryKeys.sol";

/**
 * @title RaylsStableCoinHandler
 * @notice Rayls-native, Circle-style stablecoin. Extends {RaylsErc20Handler} with the FiatToken
 *         compliance surface — pause, blacklist, and a master-minter / controller minting model —
 *         while keeping the audited ERC20 + cross-chain teleport base unchanged.
 *
 * @dev WHY NOT CIRCLE'S FiatTokenV2 DIRECTLY: the Rayls factory CREATE2-deploys a finished runtime
 *      and then calls the fixed `IRaylsInitializer.initialize(bytes,RaylsTrustedInit)` selector on
 *      it. Circle's FiatToken is a proxy/delegatecall design with a different `initialize` selector,
 *      its own init-guard, and a storage layout that collides with this OZ-ERC20 base. So we port the
 *      *semantics*, not the bytecode. See ops-api openspec/changes/add-stablecoin-token-type.
 *
 *      ROLE MODEL (Circle-style — each compliance role self-gates on its own stored address, NOT via
 *      the AccessManager):
 *        - pauser: default `trusted.owner`. `pause`/`unpause` require `msg.sender == pauser`
 *          (`onlyPauser`). Reassigned by the token owner via `updatePauser`.
 *        - blacklister: default `trusted.owner`. `blacklist`/`unBlacklist` require
 *          `msg.sender == blacklister` (`onlyBlacklister`). Reassigned via `updateBlacklister`.
 *        - masterMinter: default `trusted.owner`. `configureMinter`/`removeMinter` require
 *          `msg.sender == masterMinter` (`onlyMasterMinter`). Reassigned via `updateMasterMinter`.
 *          Minters are NOT AccessManager roles — they are per-token allowance state (exactly like
 *          Circle), so `mintByMinter` is gated by an in-body allowance check.
 *        - the base owner-`restricted` `mint`/`burn` remain available to the owner. `mintByMinter` is
 *          the additive, allowance-capped path for delegated minters.
 *        - the three `update*` role-assignment setters ARE owner-gated via the AccessManager
 *          (TOKEN_OWNER), so the token owner controls who holds each compliance role.
 *
 *      STORAGE: appends new variables AFTER the base's storage. Never reorder; this contract is
 *      deployed via the factory's InitCodeStub (no proxy upgrade), but keeping append-only discipline
 *      matches the rest of the SDK and is safe if a proxy path is ever added.
 */
contract RaylsStableCoinHandler is RaylsErc20Handler {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    /// @notice Thrown when a transfer/mint/burn is attempted while the token is paused.
    error RaylsStableCoin__Paused();

    /// @notice Thrown when `account` is blacklisted and tries to send or receive.
    /// @param account The blacklisted address.
    error RaylsStableCoin__Blacklisted(address account);

    /// @notice Thrown when a minting account's per-account allowance is below the requested amount.
    /// @param minter The minter whose allowance is insufficient.
    /// @param allowance The minter's current allowance.
    /// @param requested The amount requested.
    error RaylsStableCoin__MintAllowanceExceeded(address minter, uint256 allowance, uint256 requested);

    /// @notice Thrown when a non-minter calls a minter-only path.
    /// @param caller The address that is not an authorized minter.
    error RaylsStableCoin__NotMinter(address caller);

    /// @notice Thrown when a caller other than the current `pauser` calls a pauser-only path.
    /// @param caller The unauthorized caller.
    error RaylsStableCoin__NotPauser(address caller);

    /// @notice Thrown when a caller other than the current `blacklister` calls a blacklister-only path.
    /// @param caller The unauthorized caller.
    error RaylsStableCoin__NotBlacklister(address caller);

    /// @notice Thrown when a caller other than the current `masterMinter` calls a masterMinter-only path.
    /// @param caller The unauthorized caller.
    error RaylsStableCoin__NotMasterMinter(address caller);

    /// @notice Thrown when a zero address is supplied where a non-zero one is required.
    error RaylsStableCoin__ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    /// @notice Emitted when this stablecoin contract is created and initialized. The Blockscout
    ///         RaylsTokenDiscovery fetcher keys on this topic to classify the token as
    ///         "Rayls-StableCoin"; ops-api maps that to ErcStandard 7 / "RAYLS_STABLECOIN".
    /// @param tokenAddress Address of the newly created token contract.
    event RaylsStableCoinTokenCreated(address indexed tokenAddress);

    /// @notice Emitted when the token is paused.
    /// @param account The pauser that paused the token.
    event Paused(address indexed account);

    /// @notice Emitted when the token is unpaused.
    /// @param account The pauser that unpaused the token.
    event Unpaused(address indexed account);

    /// @notice Emitted when an account is added to the blacklist.
    /// @param account The blacklisted account.
    event Blacklisted(address indexed account);

    /// @notice Emitted when an account is removed from the blacklist.
    /// @param account The un-blacklisted account.
    event UnBlacklisted(address indexed account);

    /// @notice Emitted when a minter's allowance is configured.
    /// @param minter The minter address.
    /// @param minterAllowedAmount The allowance granted.
    event MinterConfigured(address indexed minter, uint256 minterAllowedAmount);

    /// @notice Emitted when a minter is removed.
    /// @param oldMinter The removed minter.
    event MinterRemoved(address indexed oldMinter);

    /// @notice Emitted when the `pauser` role address is changed.
    /// @param newPauser The new pauser.
    event PauserChanged(address indexed newPauser);

    /// @notice Emitted when the `blacklister` role address is changed.
    /// @param newBlacklister The new blacklister.
    event BlacklisterChanged(address indexed newBlacklister);

    /// @notice Emitted when the `masterMinter` role address is changed.
    /// @param newMasterMinter The new masterMinter.
    event MasterMinterChanged(address indexed newMasterMinter);

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    /// @notice The account allowed to `configureMinter`/`removeMinter` (Circle-style enforcement:
    ///         gated by `msg.sender == masterMinter`, NOT by the AccessManager). Defaults to the deploy
    ///         owner; changeable by the token owner via {updateMasterMinter}.
    address public masterMinter;

    /// @notice The account allowed to `pause`/`unpause` (gated by `msg.sender == pauser`). Defaults to
    ///         the deploy owner; changeable by the token owner via {updatePauser}.
    address public pauser;

    /// @notice The account allowed to `blacklist`/`unBlacklist` (gated by `msg.sender == blacklister`).
    ///         Defaults to the deploy owner; changeable by the token owner via {updateBlacklister}.
    address public blacklister;

    /// @notice True while transfers/mint/burn are paused.
    bool public paused;

    /// @notice Blacklist membership; a blacklisted account cannot send or receive.
    mapping(address => bool) public isBlacklisted;

    /// @notice Authorized minters (delegated, allowance-capped minting).
    mapping(address => bool) public isMinter;

    /// @notice Remaining mint allowance per minter.
    mapping(address => uint256) public minterAllowance;

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Circle-style: the compliance role functions self-gate on the stored role address, NOT on
    ///      the AccessManager. The token owner assigns the roles via the owner-gated `update*` setters.

    /// @notice Restricts to the current `pauser`.
    modifier onlyPauser() {
        if (msg.sender != pauser) revert RaylsStableCoin__NotPauser(msg.sender);
        _;
    }

    /// @notice Restricts to the current `blacklister`.
    modifier onlyBlacklister() {
        if (msg.sender != blacklister) revert RaylsStableCoin__NotBlacklister(msg.sender);
        _;
    }

    /// @notice Restricts to the current `masterMinter`.
    modifier onlyMasterMinter() {
        if (msg.sender != masterMinter) revert RaylsStableCoin__NotMasterMinter(msg.sender);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        string memory _name,
        string memory _symbol,
        address _endpoint,
        address _raylsNodeEndpoint,
        address _userGovernance
    ) RaylsErc20Handler(_name, _symbol, _endpoint, _raylsNodeEndpoint, _userGovernance, msg.sender, false) {
        // Constructor (non-factory) path: default the compliance roles to the deployer, mirroring what
        // {initialize} does for the factory path. The factory path overrides these in initialize().
        masterMinter = msg.sender;
        pauser = msg.sender;
        blacklister = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                                INITIALIZE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Canonical factory init. Decodes the same `(name, symbol, decimals)` tuple as the ERC20
     *         handler, runs base initialization, then defaults the compliance roles to the owner and
     *         registers the new restricted selectors with the AccessManager.
     * @dev This override carries NO `initializer` modifier: it delegates to `super.initialize`, whose
     *      `initializer` modifier is the single re-entry guard for the whole init call. Adding a second
     *      `initializer` here would nest two top-level guards and revert (`InvalidInitialization`).
     * @param userArgs ABI-encoded `(string name, string symbol, uint8 decimals)`.
     * @param trusted  Factory-injected trusted addresses (owner, endpoint, …); never user-forgeable.
     */
    function initialize(bytes calldata userArgs, RaylsTrustedInit calldata trusted) public override {
        // super.initialize runs the base init (and the one-shot AccessManager registration via our
        // overridden _registerAccessControl, which already includes the stablecoin selectors).
        super.initialize(userArgs, trusted);

        masterMinter = trusted.owner;
        pauser = trusted.owner;
        blacklister = trusted.owner;

        emit RaylsStableCoinTokenCreated(address(this));
    }

    /**
     * @notice Receiver-side teleport-deploy hint. Returns the stablecoin factory key so a teleported
     *         instance materializes as a stablecoin (not a plain ERC20) on the destination PN.
     * @return factoryKey `FactoryKeys.RAYLS_STABLECOIN_KEY` (== keccak256("RAYLS_STABLECOIN")).
     * @return userArgs   ABI-encoded `(name, symbol, decimals)` matching {initialize}.
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function teleportDeployHint()
        external
        view
        override
        returns (bytes32 factoryKey, bytes memory userArgs)
    {
        factoryKey = FactoryKeys.RAYLS_STABLECOIN_KEY;
        userArgs = abi.encode(name(), symbol(), decimals());
    }

    /*//////////////////////////////////////////////////////////////
                                 PAUSE
    //////////////////////////////////////////////////////////////*/

    /// @notice Pause all transfers, mints, and burns. Restricted to the `pauser`.
    function pause() external onlyPauser {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Resume transfers. Restricted to the `pauser`.
    function unpause() external onlyPauser {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Reassign the `pauser` role. Owner-gated (AccessManager TOKEN_OWNER).
    /// @param newPauser New pauser (must be non-zero).
    function updatePauser(address newPauser) external restricted {
        if (newPauser == address(0)) revert RaylsStableCoin__ZeroAddress();
        pauser = newPauser;
        emit PauserChanged(newPauser);
    }

    /*//////////////////////////////////////////////////////////////
                               BLACKLIST
    //////////////////////////////////////////////////////////////*/

    /// @notice Add `account` to the blacklist (blocks send/receive). Restricted to the `blacklister`.
    /// @param account Address to blacklist.
    function blacklist(address account) external onlyBlacklister {
        if (account == address(0)) revert RaylsStableCoin__ZeroAddress();
        isBlacklisted[account] = true;
        emit Blacklisted(account);
    }

    /// @notice Remove `account` from the blacklist. Restricted to the `blacklister`.
    /// @param account Address to un-blacklist.
    function unBlacklist(address account) external onlyBlacklister {
        if (account == address(0)) revert RaylsStableCoin__ZeroAddress();
        isBlacklisted[account] = false;
        emit UnBlacklisted(account);
    }

    /// @notice Reassign the `blacklister` role. Owner-gated (AccessManager TOKEN_OWNER).
    /// @param newBlacklister New blacklister (must be non-zero).
    function updateBlacklister(address newBlacklister) external restricted {
        if (newBlacklister == address(0)) revert RaylsStableCoin__ZeroAddress();
        blacklister = newBlacklister;
        emit BlacklisterChanged(newBlacklister);
    }

    /*//////////////////////////////////////////////////////////////
                          MASTER-MINTER / MINTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Authorize `minter` to mint up to `minterAllowedAmount`. Restricted to the `masterMinter`.
    /// @param minter Minter to configure.
    /// @param minterAllowedAmount Allowance to grant.
    function configureMinter(address minter, uint256 minterAllowedAmount) external onlyMasterMinter {
        if (minter == address(0)) revert RaylsStableCoin__ZeroAddress();
        isMinter[minter] = true;
        minterAllowance[minter] = minterAllowedAmount;
        emit MinterConfigured(minter, minterAllowedAmount);
    }

    /// @notice Revoke `minter`'s minting authority and zero its allowance. Restricted to the `masterMinter`.
    /// @param minter Minter to remove.
    function removeMinter(address minter) external onlyMasterMinter {
        if (minter == address(0)) revert RaylsStableCoin__ZeroAddress();
        isMinter[minter] = false;
        minterAllowance[minter] = 0;
        emit MinterRemoved(minter);
    }

    /// @notice Reassign the `masterMinter` role. Owner-gated (AccessManager TOKEN_OWNER).
    /// @param newMasterMinter New masterMinter (must be non-zero).
    function updateMasterMinter(address newMasterMinter) external restricted {
        if (newMasterMinter == address(0)) revert RaylsStableCoin__ZeroAddress();
        masterMinter = newMasterMinter;
        emit MasterMinterChanged(newMasterMinter);
    }

    /**
     * @notice Mint as a configured minter, capped by the caller's remaining allowance. Decrements the
     *         allowance and reports the balance update to the PNH TokenRegistry like the base `mint`.
     * @dev NOT `restricted`: minter authority is per-token allowance state, not an AccessManager role.
     *      The owner-gated base `mint` remains available for the owner.
     * @param to Recipient of the new tokens.
     * @param value Amount to mint (must be within the caller's allowance).
     */
    function mintByMinter(address to, uint256 value) external returns (bool) {
        if (!isMinter[msg.sender]) revert RaylsStableCoin__NotMinter(msg.sender);
        // Guard the minting caller against the blacklist. `_update` skips the `from` blacklist check on
        // mints (from == address(0)), so a sanctioned-but-still-configured minter would otherwise keep
        // inflating supply. Mirrors Circle's FiatToken, which gates `mint` with `notBlacklisted(msg.sender)`.
        if (isBlacklisted[msg.sender]) revert RaylsStableCoin__Blacklisted(msg.sender);
        uint256 allowed = minterAllowance[msg.sender];
        if (value > allowed) revert RaylsStableCoin__MintAllowanceExceeded(msg.sender, allowed, value);

        minterAllowance[msg.sender] = allowed - value;
        _mint(to, value);
        _submitTokenUpdate(SharedObjects.BalanceUpdateType.MINT, value);
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                          COMPLIANCE ENFORCEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice OZ ERC20 v5 transfer hook. Enforces pause + blacklist on every balance change,
     *         including mints (`from == 0`) and burns (`to == 0`).
     * @dev Mint checks `to`; burn checks `from`; transfer checks both. Pausing blocks all paths.
     *      Check ordering matches Circle's FiatToken, whose transfer/mint modifiers run
     *      `whenNotPaused` BEFORE `notBlacklisted(...)`: pause is evaluated first, so a paused token
     *      surfaces `RaylsStableCoin__Paused` even if a party is also blacklisted.
     */
    function _update(address from, address to, uint256 value) internal virtual override {
        if (paused) revert RaylsStableCoin__Paused();
        if (from != address(0) && isBlacklisted[from]) revert RaylsStableCoin__Blacklisted(from);
        if (to != address(0) && isBlacklisted[to]) revert RaylsStableCoin__Blacklisted(to);
        super._update(from, to, value);
    }

    /*//////////////////////////////////////////////////////////////
                          ACCESS-CONTROL REGISTRATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Override the base AccessManager registration to add the stablecoin OWNER-gated selectors
     *         alongside the ERC20 ones, in the SINGLE one-shot `selfRegisterManagedContract` call.
     * @dev The stablecoin owner-gated selectors are the ROLE-ASSIGNMENT setters
     *      (updatePauser/updateBlacklister/updateMasterMinter) — NOT the compliance functions
     *      themselves. Circle-style, pause/blacklist/configureMinter self-gate on their stored role
     *      address (`onlyPauser`/`onlyBlacklister`/`onlyMasterMinter`), so they are deliberately NOT
     *      registered with the AccessManager. `selfRegisterManagedContract` is one-shot per contract, so
     *      we replace the whole registration here, building a 6-entry owner-selector array
     *      (3 ERC20 + 3 role-update setters) plus the same MESSAGE_EXECUTOR / RELAYER mappings the base
     *      wires. Kept in sync with {RaylsErc20Handler-_registerAccessControl}; if the base's
     *      executor/relayer sets change, mirror them here. No-op when no AccessManager is bound
     *      (constructor-only path).
     * @param _owner Address that becomes owner of the owner-gated selectors.
     * @param caller External deployer; granted TOKEN_OWNER when non-zero and distinct from `_owner`.
     */
    function _registerAccessControl(address _owner, address caller) internal virtual override {
        address mgr = address(endpoint) != address(0) ? endpoint.authority() : address(0);
        if (mgr == address(0)) return;

        _setAuthority(mgr);

        bytes4[] memory ownerSels = new bytes4[](6);
        ownerSels[0] = this.mint.selector;
        ownerSels[1] = this.burn.selector;
        ownerSels[2] = this.submitTokenUpdate.selector;
        ownerSels[3] = this.updatePauser.selector;
        ownerSels[4] = this.updateBlacklister.selector;
        ownerSels[5] = this.updateMasterMinter.selector;

        bytes4[] memory executorSels = new bytes4[](7);
        executorSels[0] = this.receiveTeleport.selector;
        executorSels[1] = this.receiveTeleportAtomic.selector;
        executorSels[2] = this.revertTeleportMint.selector;
        executorSels[3] = this.revertTeleportBurn.selector;
        executorSels[4] = this.unlock.selector;
        executorSels[5] = this.receiveTeleportFromPublicChain.selector;
        executorSels[6] = this.revertTeleportToPublicChain.selector;

        bytes4[] memory relayerSels = new bytes4[](2);
        relayerSels[0] = this.crossMint.selector;
        relayerSels[1] = this.crossBurn.selector;

        IRaylsAccessManager.SelectorRoleMapping[] memory mappings = new IRaylsAccessManager.SelectorRoleMapping[](2);
        mappings[0] = IRaylsAccessManager.SelectorRoleMapping("MESSAGE_EXECUTOR", executorSels);
        mappings[1] = IRaylsAccessManager.SelectorRoleMapping("RELAYER", relayerSels);

        IRaylsAccessManager(mgr).selfRegisterManagedContract(_owner, ownerSels, mappings);

        if (caller != address(0) && caller != _owner) {
            IRaylsAccessManager(mgr).grantSelfTokenOwner(caller);
        }
    }
}
