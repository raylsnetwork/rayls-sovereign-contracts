// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;


import {RaylsAccessManaged} from "../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {IRaylsAccessManager} from "../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol";
import "../../rayls-protocol-sdk/tokens/RaylsErc20Handler.sol";
import "../../rayls-protocol-sdk/interfaces/IRaylsEndpoint.sol";
import {IRaylsInitializer, RaylsTrustedInit} from "../../rayls-protocol-sdk/IRaylsInitializer.sol";
import {SharedObjects} from "../../rayls-protocol-sdk/libraries/SharedObjects.sol";
import "../../rayls-protocol/Endpoint/EndpointV1.sol";


/**
 * @title CustomTokenExample
 * @notice Sample custom-token contract used by Rayls integration / e2e tests. Exposes a
 *         minimal Rayls ERC20 with an attestation UUID gate around `mint` and a fund-manager
 *         hook (`fundManagerFeeChainId` + `fundManagerAddr`).
 * @dev Demonstrates the custom-token issuer flow: constructor self-registers selectors with
 *      the AccessManager (owner-gated `setAttestationUuid` + `mint`), and the cross-chain
 *      `initialize(bytes,RaylsTrustedInit)` decodes a 5-tuple including the attestation
 *      uuid. NOT intended for production use.
 */
contract CustomTokenExample is RaylsAccessManaged, RaylsErc20Handler {
    /// @notice Thrown when `mint` is called before any risk analysis attestation has been recorded.
    error CustomTokenExample__NoRiskAnalysisAttestation();

    /// @dev Local typed reference to the Rayls endpoint (full type, not just the interface).
    EndpointV1 private epoint;

    /// @notice Attestation uuid that gates mint operations. Mint reverts when zero.
    bytes32 public attestationUid;

    /// @notice Chain id of the fund manager that receives fee dispatches.
    uint256 public fundManagerFeeChainId;

    /// @notice Address of the fund manager on `fundManagerFeeChainId`.
    address public fundManagerAddr;

    /**
     * @notice Construct the custom token with metadata + fund-manager + endpoint references,
     *         and self-register owner-gated selectors with the AccessManager.
     * @dev Calls `RaylsErc20Handler` constructor with `_owner = msg.sender` and `isCustom = true`.
     * @param name Token name.
     * @param symbol Token symbol.
     * @param _fundManagerChainId Chain id of the fund manager.
     * @param _fundManagerAddr Fund manager address on `_fundManagerChainId`.
     * @param _endpointAddr Trusted Rayls endpoint address.
     * @param _raylsNodeEndpoint Privacy-node endpoint; zero on PNH deploys.
     * @param authority_ AccessManager address used for `restricted` gating + selector registration.
     */
    constructor(
        string memory name,
        string memory symbol,
        uint256 _fundManagerChainId,
        address _fundManagerAddr,
        address _endpointAddr,
        address _raylsNodeEndpoint,
        address authority_
    ) RaylsErc20Handler(name, symbol, _endpointAddr, _raylsNodeEndpoint, address(0), msg.sender, true) {
        epoint = EndpointV1(_endpointAddr);

        fundManagerFeeChainId = _fundManagerChainId;
        fundManagerAddr = _fundManagerAddr;

        // Set the authority unconditionally so direct-deploy callers can rely on `restricted`
        // immediately. Selector registration with the AccessManager is delegated to
        // `_registerAccessControl` (override below) which the parent constructor invokes
        // inside `RaylsErc20Handler(...)` via virtual dispatch — see the override for the
        // extended ownerSels list. Calling `selfRegisterManagedContract` a second time here
        // would revert with `RaylsAccessManagerV1__ContractAlreadyRegistered`.
        _setAuthority(authority_);
    }

    /**
     * @notice Read the bound endpoint's contract version.
     * @return Endpoint contract version.
     */
    function getVersion() public view returns (uint256) {
        return epoint.contractVersion();
    }

    /**
     * @notice Returns the token decimals — fixed at 6 for this example.
     * @return Always 6.
     */
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /**
     * @notice Canonical init entrypoint — overrides RaylsErc20Handler.initialize.
     * @param userArgs ABI-encoded `(string name, string symbol, uint256 fundManagerChainId,
     *                 address fundManagerAddr, bytes32 attestationUuid)`. Caller-supplied
     *                 via the cross-chain init payload.
     * @param trusted  Trusted addresses + resourceId from {RaylsTrustedInit}, set by the
     *                 factory at deploy time. Caller cannot forge.
     */
    function initialize(
        bytes calldata userArgs,
        RaylsTrustedInit calldata trusted
    ) public virtual override initializer {
        (
            string memory _name,
            string memory _symbol,
            uint256 _fundManagerChainId,
            address _fundManagerAddr,
            bytes32 _attestationUuid
        ) = abi.decode(userArgs, (string, string, uint256, address, bytes32));

        tokenName = _name;
        tokenSymbol = _symbol;
        attestationUid = _attestationUuid;
        fundManagerFeeChainId = _fundManagerChainId;
        fundManagerAddr = _fundManagerAddr;

        endpoint = IRaylsEndpoint(trusted.endpoint);
        resourceId = trusted.resourceId;
        // `trusted.raylsNodeEndpoint` and `trusted.userGovernance` are intentionally not
        // forwarded to parent fields: this is the custom-token issuer flow (`isCustom = true`),
        // which interacts with the trusted endpoint directly and does not consume the
        // privacy-node or UserGovernance bindings exposed by the standard template.

        address mgr = endpoint.authority();
        if (mgr != address(0)) {
            _setAuthority(mgr);
        }

        // Register the deployed contract with the AccessManager so MESSAGE_EXECUTOR-gated
        // selectors (receiveTeleport, receiveTeleportAtomic, revertTeleport*, unlock,
        // receiveResourceId, receiveTeleportFromPublicChain, revertTeleportToPublicChain)
        // are reachable on the factory-deployed instance. Without this, cross-chain auto-
        // deploy produces a token whose receive-side surface is admin-only by default,
        // and the relayer (which holds MESSAGE_EXECUTOR) cannot deliver inbound teleports.
        _registerAccessControl(trusted.owner, trusted.caller);
    }

    /**
     * @notice Encode the user-args bytes consumed by this token's `initialize` on the
     *         destination chain.
     * @dev Returns bare `abi.encode(name, symbol, fundManagerChainId, fundManagerAddr,
     *      attestationUid)` matching the override's decode shape.
     * @return ABI-encoded user-args bytes.
     */
    function _generateInitializerParams()
        internal
        view
        virtual
        returns (bytes memory)
    {
        return
            abi.encode(
                tokenName,
                tokenSymbol,
                fundManagerFeeChainId,
                fundManagerAddr,
                attestationUid
            );
    }

    /**
     * @notice Set the attestation uuid that gates mint operations.
     * @dev Restricted to the owner-gated role registered in the constructor.
     * @param _uuid New attestation uuid.
     */
    function setAttestationUuid(bytes32 _uuid) external restricted {
        attestationUid = _uuid;
    }

    /**
     * @notice Mint tokens, gated by a non-zero attestation uuid.
     * @dev Restricted to the owner-gated role. Reverts when no attestation has been set.
     *      Delegates to `super.mint` after the attestation gate so the parent's
     *      `_mint + _submitTokenUpdate` pair runs as a unit — without `super`, the override
     *      would bypass the cross-chain supply notification and the PNH TokenRegistry would
     *      drift away from on-chain reality.
     * @param to Recipient.
     * @param amount Amount to mint.
     */
    function mint(address to, uint256 amount) public override restricted {
        if (attestationUid == bytes32(0)) revert CustomTokenExample__NoRiskAnalysisAttestation();
        super.mint(to, amount);
    }

    /**
     * @notice Burn tokens from the caller.
     * @dev Public — standard ERC20Burnable convention: any holder may always burn their own
     *      tokens. Privileged burn-from-arbitrary-account is the parent's
     *      `RaylsErc20Handler.burn(address,uint256)`, which is owner-gated and registered in
     *      `_registerAccessControl` below; that path is the supply-contraction control
     *      point, not this self-burn. The local burn paths still notify the PNH
     *      TokenRegistry via `_submitTokenUpdate` so cross-chain supply tracking stays
     *      accurate — without it, holder-initiated burns silently drift the registry's
     *      view away from on-chain supply.
     * @param amount Amount to burn.
     */
    function burn(uint256 amount) public whenPrivacyNodeActive {
        _burn(_msgSender(), amount);
        _submitTokenUpdate(SharedObjects.BalanceUpdateType.BURN, amount);
    }

    /**
     * @notice Burn tokens from `account`, spending allowance from msg.sender.
     * @dev Public — standard ERC20Burnable convention: holder approves a spender, spender
     *      calls `burnFrom`. Same rationale as `burn(uint256)` — privileged burns are the
     *      parent's owner-gated `burn(address,uint256)`. Same supply-tracking note: the
     *      `_submitTokenUpdate` call keeps the PNH TokenRegistry in sync with on-chain
     *      supply.
     * @param account Account whose tokens are burned.
     * @param amount Amount to burn.
     */
    function burnFrom(address account, uint256 amount) public whenPrivacyNodeActive {
        _spendAllowance(account, _msgSender(), amount);
        _burn(account, amount);
        _submitTokenUpdate(SharedObjects.BalanceUpdateType.BURN, amount);
    }

    /**
     * @notice Receive an atomic teleport addressed by resourceId — mint to this contract,
     *         then lock for the resource's resolved address.
     * @dev Restricted. The protocol resolves `resourceId` via the endpoint and locks for
     *      that destination address.
     * @param resourceId Resource id of the destination contract.
     * @param value Amount.
     * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
     */
    function receiveTeleportAtomicToResourceId(bytes32 resourceId, uint256 value) public virtual restricted {
        address to = epoint.getAddressByResourceId(resourceId);
        _mint(address(this), value);
        if (to != address(this)) {
            _lock(to, value);
        }
    }

    /**
     * @notice Revert path: burn tokens at the resource-resolved destination after a failure.
     * @dev Restricted.
     * @param resourceId Resource id of the destination contract.
     * @param value Amount to burn.
     */
    function revertTeleportBurnToResourceId(bytes32 resourceId, uint256 value) public virtual restricted {
        address to = epoint.getAddressByResourceId(resourceId);
        _burn(to, value);
    }

    /**
     * @notice Unlock previously locked tokens addressed by resourceId, releasing them to
     *         the resolved destination.
     * @dev Restricted (MESSAGE_EXECUTOR / owner-gated per the AccessManager mapping).
     *      The analogous base-class `unlock` is also restricted; this function should match.
     *      If `to` is this contract, no transfer is issued.
     * @param resourceId Resource id of the destination contract.
     * @param amount Amount to unlock.
     * @return Always true on success; reverts otherwise.
     */
    function unlockToResourceId(bytes32 resourceId, uint256 amount) external virtual restricted returns (bool) {
        address to = epoint.getAddressByResourceId(resourceId);
        if (to != address(this)) {
            bool success = _unlock(to, amount);
            if (!success) revert RaylsErc20Handler__UnlockFailed();
            _transfer(address(this), to, amount);
            return true;
        }
        return true;
    }

    /**
     * @notice Override of {RaylsErc20Handler-_registerAccessControl} that extends the
     *         owner-gated selector set with `setAttestationUuid` (CustomTokenExample-specific).
     * @dev Single-call registration replaces the prior pattern of calling
     *      `selfRegisterManagedContract` once via the parent constructor and a second time
     *      from this contract's body — that double-call reverts with
     *      `RaylsAccessManagerV1__ContractAlreadyRegistered` when `endpoint.authority() != 0`.
     *      Re-uses the parent's MESSAGE_EXECUTOR mapping so cross-chain receive selectors
     *      stay reachable; appends `setAttestationUuid` so the token owner can rotate the
     *      attestation uuid post-deploy.
     * @param _owner Address that becomes owner of the owner-gated selectors.
     * @param caller The external deployer (factory's `msg.sender`); when non-zero and distinct
     *               from `_owner`, also granted TOKEN_OWNER scoped to this token. `address(0)`
     *               on the constructor path.
     */
    function _registerAccessControl(address _owner, address caller) internal virtual override {
        address mgr = address(endpoint) != address(0) ? endpoint.authority() : address(0);
        if (mgr == address(0)) return;

        _setAuthority(mgr);

        // Owner-gated selectors. The parent's `burn(address,uint256)` is the privileged
        // supply-contraction surface; the holder-side `burn(uint256)` and `burnFrom(...)`
        // are public per standard ERC20Burnable convention and intentionally NOT registered
        // here. Type-level lookups are compile-time verified — the named contract must still
        // expose the function with the expected signature, otherwise the build fails.
        // `mint` and `burn(address,uint256)` are looked up on `RaylsErc20Handler` to avoid
        // override-set ambiguity that breaks `.selector` access on a derived-class type-level
        // reference; selector value is identical.
        bytes4[] memory ownerSels = new bytes4[](4);
        ownerSels[0] = RaylsErc20Handler.mint.selector;
        ownerSels[1] = RaylsErc20Handler.burn.selector;
        ownerSels[2] = RaylsErc20Handler.submitTokenUpdate.selector;
        ownerSels[3] = CustomTokenExample.setAttestationUuid.selector;

        bytes4[] memory executorSels = new bytes4[](7);
        executorSels[0] = RaylsErc20Handler.receiveTeleport.selector;
        executorSels[1] = RaylsErc20Handler.receiveTeleportAtomic.selector;
        executorSels[2] = RaylsErc20Handler.revertTeleportMint.selector;
        executorSels[3] = RaylsErc20Handler.revertTeleportBurn.selector;
        executorSels[4] = RaylsErc20Handler.unlock.selector;
        executorSels[5] = RaylsErc20Handler.receiveTeleportFromPublicChain.selector;
        executorSels[6] = RaylsErc20Handler.revertTeleportToPublicChain.selector;

        IRaylsAccessManager.SelectorRoleMapping[] memory mappings = new IRaylsAccessManager.SelectorRoleMapping[](1);
        mappings[0] = IRaylsAccessManager.SelectorRoleMapping("MESSAGE_EXECUTOR", executorSels);

        IRaylsAccessManager(mgr).selfRegisterManagedContract(_owner, ownerSels, mappings);

        // Also grant TOKEN_OWNER to the deployer when it differs from the configured owner
        // (factory path where `owner` is factoryOwner but the deployer is a distinct caller).
        if (caller != address(0) && caller != _owner) {
            IRaylsAccessManager(mgr).grantSelfTokenOwner(caller);
        }
    }
}
