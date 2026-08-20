// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IRaylsEndpoint} from "../../rayls-protocol-sdk/interfaces/IRaylsEndpoint.sol";
import {RaylsTrustedInit} from "../../rayls-protocol-sdk/IRaylsInitializer.sol";
import {AbstractContractFactoryV1} from "../../rayls-protocol/RaylsContractFactory/AbstractContractFactoryV1.sol";
import {IBaseContractFactory} from "../../rayls-protocol/RaylsContractFactory/interfaces/IBaseContractFactory.sol";
import {IRNContractFactoryV1} from "./interfaces/IRNContractFactoryV1.sol";
import {ITokenRegistry} from "../../rayls-protocol/TokenRegistry/interfaces/ITokenRegistry.sol";
import {IRaylsTokenStandard} from "../../rayls-protocol/TokenRegistry/modules/TokenCore/PNTokenCoreLib.sol";

/**
 * @title RNContractFactoryV1
 * @notice Privacy-node CREATE2 factory for Rayls handlers.
 * @dev Deploy logic, the open bytecode registry, and the typed deploy functions all live in
 *      {AbstractContractFactoryV1}. This subclass only specialises trusted-init.
 *
 *      `endpoint` MUST be the Rayls {EndpointV1} — the endpoint that owns the resource registry
 *      `getAddressByResourceId` resolves against, and the one every handler binds as its
 *      `IRaylsEndpoint`. Handlers resolve protocol contracts (e.g. `EnygmaPNEvents` via
 *      `RESOURCE_ID_ENYGMA_PN_EVENTS`) through it. Stamping the privacy-node endpoint here instead
 *      breaks every events-emitting path (`crossTransferRevertBatch`, `mint`, `crossRevertMint`,
 *      `sendTransferPNH`) because the privacy-node endpoint implements no `getAddressByResourceId`.
 *
 *      `raylsNodeEndpoint` MUST be the privacy node's {RNEndpointV1}: it is stamped into every
 *      handler's trusted-init, and a handler with a zero ("unbound") raylsNodeEndpoint cannot
 *      bridge to public chains — `teleportToPublicChain` reverts calling the zero address. The
 *      deploy wires it via {setRaylsNodeEndpoint} right after the endpoint repoint. The factory
 *      has no post-deploy side effects — `_afterDeploy` is the inherited no-op. Unlike the hub
 *      factory it deliberately does NOT auto-grant ENDPOINT_SENDER; PN instances are granted that
 *      role through the resource-registration path instead.
 */
contract RNContractFactoryV1 is AbstractContractFactoryV1, IRNContractFactoryV1 {
    /// @notice Privacy-node RN endpoint (RNEndpointV1) injected into every handler's trusted-init.
    /// @dev Occupies the first derived-contract slot guarded by the base storage gap, mirroring
    ///      {RaylsContractFactoryV1.raylsNodeEndpoint}.
    address public raylsNodeEndpoint;

    /// @notice PN TokenRegistry facade the factory records receiver-side teleport mirrors in.
    /// @dev Set via {setTokenRegistry} after the registry is deployed (it is deployed after this
    ///      factory, so it cannot be an init arg). Zero until set; {_registerExternalToken} reverts
    ///      with {FactoryV1__TokenRegistryNotSet} if a token mirror must be recorded while this is
    ///      still zero. Trailing slot — appended after `raylsNodeEndpoint` to preserve the UUPS
    ///      storage layout.
    ITokenRegistry public tokenRegistry;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the privacy-node factory.
     * @param _endpoint Rayls {EndpointV1} address — owns the resource registry; bound as every
     *                  handler's `IRaylsEndpoint` (non-zero).
     * @param _raylsNodeEndpoint Privacy-node {RNEndpointV1} address stamped into every deployed
     *                  handler's `raylsNodeEndpoint` so `teleportToPublicChain` can dispatch (non-zero).
     * @param _owner Factory owner injected into trusted-init (non-zero).
     * @param authority_ AccessManager address used for `restricted` gating.
     */
    function initialize(address _endpoint, address _raylsNodeEndpoint, address _owner, address authority_)
        public
        initializer
    {
        if (_raylsNodeEndpoint == address(0)) revert FactoryV1__ZeroAddress();
        __AbstractFactory_init(_endpoint, _owner, authority_);
        raylsNodeEndpoint = _raylsNodeEndpoint;
    }

    /// @inheritdoc IRNContractFactoryV1
    function setRaylsNodeEndpoint(address newEndpoint) external override restricted {
        if (newEndpoint == address(0)) revert FactoryV1__ZeroAddress();
        emit RaylsNodeEndpointUpdated(raylsNodeEndpoint, newEndpoint);
        raylsNodeEndpoint = newEndpoint;
    }

    /// @inheritdoc IRNContractFactoryV1
    function getRaylsNodeEndpoint() external view override returns (address) {
        return raylsNodeEndpoint;
    }

    /// @inheritdoc IRNContractFactoryV1
    function setTokenRegistry(address _tokenRegistry) external override restricted {
        if (_tokenRegistry == address(0)) revert FactoryV1__ZeroAddress();
        emit TokenRegistrySet(address(tokenRegistry), _tokenRegistry);
        tokenRegistry = ITokenRegistry(_tokenRegistry);
    }

    /// @inheritdoc AbstractContractFactoryV1
    /// @dev Owner-source rule: if a per-call override is set (via the user-facing deploy entry
    ///      points below), use it; otherwise default to `factoryOwner` (the existing semantics
    ///      for governance/relayer-driven deploys).
    function _buildTrustedInit(bytes32 resourceId)
        internal
        view
        override
        returns (RaylsTrustedInit memory)
    {
        address override_ = _pendingOwnerOverride;
        return RaylsTrustedInit({
            endpoint: endpoint,
            raylsNodeEndpoint: raylsNodeEndpoint,
            userGovernance: IRaylsEndpoint(endpoint).getUserGovernanceAddress(),
            owner: override_ != address(0) ? override_ : factoryOwner,
            resourceId: resourceId,
            // When an owner override is active (deployFromTeleport / deployErc*AsUser), the EOA in
            // `owner` is the sole intended TOKEN_OWNER and the actual msg.sender is a transparent
            // intermediary — the EOA itself for the *AsUser wrappers, or the PN TokenCoreV1 for
            // deployFromTeleport. Zeroing `caller` here prevents the handler's _registerAccessControl
            // from granting TOKEN_OWNER (mint/burn/submitTokenUpdate) to that intermediary; the relay
            // contract has no legitimate need for token authority on instances it merely activates.
            //
            // With no override (governance/relayer-driven typed deploys), `owner` is factoryOwner and
            // the distinct relayer caller SHOULD also hold TOKEN_OWNER, so keep msg.sender. It is
            // preserved across the internal _deployContract -> _buildTrustedInit calls (no external
            // hop), so it is the original factory caller — never user-forged.
            caller: override_ != address(0) ? address(0) : msg.sender
        });
    }

    /*//////////////////////////////////////////////////////////////
                    USER-FACING DEPLOY ENTRY POINTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Generic owner-as-caller wrapper around the typed deploy functions.
    /// @dev Sets {_pendingOwnerOverride} to `msg.sender`, dispatches the wrapped deploy, then
    ///      clears the override. The override is read by {_buildTrustedInit}, so the deployed
    ///      instance's TOKEN_OWNER becomes the EOA that called this function — *not* `factoryOwner`.
    ///
    ///      The wrapped call uses a direct internal helper rather than the public typed entry
    ///      points because the latter are `restricted`. Callers do not need RELAYER / factory-admin
    ///      to invoke these user-facing wrappers; the trust model is "you own what you deploy."
    ///
    ///      Reentrancy: the underlying `_deployRegistered` path is itself wrapped by the public
    ///      typed entry points' `nonReentrant`; these wrappers reuse that guard transitively.
    ///      Concretely, no recursion into another deploy can occur between set and clear of
    ///      `_pendingOwnerOverride`.

    /// @notice User-deploy ERC20 with the caller as TOKEN_OWNER.
    /// @dev Issuer-side deploy: the `resourceId` is unknown at this point — it is assigned later by
    ///      the PNH TokenRegistry (via {RaylsAppV1.setResourceId}) once the token is approved, so the
    ///      instance is deployed with `bytes32(0)` ("not yet activated"). Bytecode source is the
    ///      seeded `RAYLS_ERC20_KEY` template (codehash matches the programmability gate).
    function deployErc20AsUser(string calldata name, string calldata symbol, uint8 decimals)
        external
        virtual
        nonReentrant
        returns (address deployed)
    {
        _pendingOwnerOverride = msg.sender;
        deployed = _deployRegistered(RAYLS_ERC20_KEY, abi.encode(name, symbol, decimals), bytes32(0));
        _pendingOwnerOverride = address(0);
    }

    /// @notice User-deploy ERC721 with the caller as TOKEN_OWNER.
    /// @dev Issuer-side deploy; `resourceId` is assigned later by the PNH TokenRegistry, so the
    ///      instance is deployed with `bytes32(0)`.
    function deployErc721AsUser(string calldata uri, string calldata name, string calldata symbol)
        external
        virtual
        nonReentrant
        returns (address deployed)
    {
        _pendingOwnerOverride = msg.sender;
        deployed = _deployRegistered(RAYLS_ERC721_KEY, abi.encode(uri, name, symbol), bytes32(0));
        _pendingOwnerOverride = address(0);
    }

    /// @notice User-deploy ERC1155 with the caller as TOKEN_OWNER.
    /// @dev Issuer-side deploy; `resourceId` is assigned later by the PNH TokenRegistry, so the
    ///      instance is deployed with `bytes32(0)`.
    function deployErc1155AsUser(string calldata uri, string calldata name)
        external
        virtual
        nonReentrant
        returns (address deployed)
    {
        _pendingOwnerOverride = msg.sender;
        deployed = _deployRegistered(RAYLS_ERC1155_KEY, abi.encode(uri, name), bytes32(0));
        _pendingOwnerOverride = address(0);
    }

    /// @notice User-deploy Enygma with the caller as TOKEN_OWNER.
    /// @dev Issuer-side deploy; `resourceId` is assigned later by the PNH TokenRegistry, so the
    ///      instance is deployed with `bytes32(0)`.
    function deployEnygmaAsUser(string calldata name, string calldata symbol, uint8 decimals)
        external
        virtual
        nonReentrant
        returns (address deployed)
    {
        _pendingOwnerOverride = msg.sender;
        deployed = _deployRegistered(RAYLS_ENYGMA_KEY, abi.encode(name, symbol, decimals), bytes32(0));
        _pendingOwnerOverride = address(0);
    }

    /// @notice Generic user-deploy of any *seeded* factory key with the caller as TOKEN_OWNER.
    /// @dev Issuer-side deploy; `resourceId` is assigned later by the PNH TokenRegistry, so the
    ///      instance is deployed with `bytes32(0)`.
    function deployRegisteredAsUser(bytes32 key, bytes calldata userArgs)
        external
        virtual
        nonReentrant
        returns (address deployed)
    {
        _pendingOwnerOverride = msg.sender;
        deployed = _deployRegistered(key, userArgs, bytes32(0));
        _pendingOwnerOverride = address(0);
    }

    /// @notice User-deploy a stablecoin with the caller as TOKEN_OWNER.
    /// @dev Same args as the ERC20 wrapper — `RaylsStableCoinHandler.initialize` decodes the same
    ///      `(name, symbol, decimals)` tuple. The owner override matters more here than for the
    ///      other standards: the handler seeds `masterMinter`, `pauser` and `blacklister` from
    ///      `trusted.owner`, so without it every stablecoin's compliance roles land on
    ///      `factoryOwner` and the deploying user cannot pause their own token.
    function deployStableCoinAsUser(string calldata name, string calldata symbol, uint8 decimals)
        external
        virtual
        nonReentrant
        returns (address deployed)
    {
        _pendingOwnerOverride = msg.sender;
        deployed = _deployRegistered(RAYLS_STABLECOIN_KEY, abi.encode(name, symbol, decimals), bytes32(0));
        _pendingOwnerOverride = address(0);
    }

    /// @notice Receiver-side teleport-driven deploy. Invoked when a teleport arrives on this PN
    ///         for a `resourceId` that's not yet bound on the endpoint. The caller (a RELAYER,
    ///         typically the message executor for the inbound teleport message) supplies the
    ///         attested `ownerEOA` from the source-chain message — that EOA becomes TOKEN_OWNER
    ///         of the receiver-side instance, matching the source-chain owner of the same
    ///         `resourceId`. Restricted to RELAYER so untrusted callers cannot fabricate owners.
    /// @param resourceId Resource id that the deployed instance will be bound to.
    /// @param factoryKey  Seeded factory key (e.g. `RAYLS_ERC20_KEY`). Only seeded keys are
    ///                    accepted, enforced by `_deployRegistered`'s "bytecode-not-registered"
    ///                    revert if `factoryKey` has no entry.
    /// @param ownerEOA    Attested source-chain owner that becomes TOKEN_OWNER on the receiver.
    /// @param userArgs    ABI-encoded init args for the standard's `initialize`.
    function deployFromTeleport(bytes32 resourceId, bytes32 factoryKey, address ownerEOA, bytes calldata userArgs)
        external
        virtual
        restricted
        nonReentrant
        returns (address deployed)
    {
        _pendingOwnerOverride = ownerEOA;
        deployed = _deployRegistered(factoryKey, userArgs, resourceId);
        _pendingOwnerOverride = address(0);
    }

    /// @inheritdoc AbstractContractFactoryV1
    /// @dev Receiver-side auto-deploy used by the {ResourceManager}. Deploys the seeded
    ///      standard with factory-owner semantics (no owner override) and records the mirror in the
    ///      PN TokenRegistry. Kept separate from {deployRegistered} so issuer-side user/governance
    ///      deploys are never auto-registered as hub tokens.
    function deployRegisteredExternal(bytes32 key, bytes calldata userArgs, bytes32 resourceId)
        external
        override(AbstractContractFactoryV1, IBaseContractFactory)
        restricted
        nonReentrant
        returns (address deployed)
    {
        deployed = _deployRegistered(key, userArgs, resourceId);
        if (_isRaylsToken(deployed)) {
            _registerExternalToken(resourceId, deployed);
        }
    }

    /// @inheritdoc AbstractContractFactoryV1
    /// @dev BYTECODE-mode receiver-side auto-deploy used by the {ResourceManager} for custom/legacy
    ///      standards. Deploys the caller-supplied bytecode and records the mirror only if the
    ///      deployed instance is a classifiable Rayls token standard — a custom contract that does
    ///      not implement {IRaylsTokenStandard-GetERCStandard} is deployed but left unregistered.
    function deployExternal(bytes calldata bytecode, bytes calldata userArgs, bytes32 resourceId)
        external
        override(AbstractContractFactoryV1, IBaseContractFactory)
        restricted
        nonReentrant
        returns (address deployed)
    {
        if (bytecode.length == 0) revert FactoryV1__EmptyBytecode();
        deployed = _deployContract(bytecode, userArgs, resourceId);
        emit ContractDeployed(deployed, resourceId);
        if (_isRaylsToken(deployed)) {
            _registerExternalToken(resourceId, deployed);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Record the receiver-side mirror in the PN TokenRegistry.
    /// @dev Callers gate this on {_isRaylsToken}, so reaching here means the instance IS a Rayls
    ///      token that must be recorded as a hub mirror. An unwired registry at that point is a
    ///      misconfiguration and reverts (fail-loud) — silently skipping would leave a token mirror
    ///      unregistered and break its hub authorization. {registerHubToken} is idempotent, so
    ///      teleport retries are safe.
    /// @param resourceId Resource id the deployed instance is bound to.
    /// @param deployed Address of the freshly deployed instance.
    function _registerExternalToken(bytes32 resourceId, address deployed) internal {
        if (address(tokenRegistry) == address(0)) revert FactoryV1__TokenRegistryNotSet();
        tokenRegistry.registerHubToken(resourceId, deployed);
    }

    /// @notice True iff `token` implements {IRaylsTokenStandard-GetERCStandard} — i.e. it is a Rayls
    ///         token standard the PN TokenRegistry can classify. Gates the registry recording so a
    ///         custom contract that is not a Rayls standard is deployed but left unregistered.
    /// @param token Address of the deployed contract to probe.
    /// @return supported Whether the contract responds to `GetERCStandard()`.
    function _isRaylsToken(address token) internal view returns (bool supported) {
        try IRaylsTokenStandard(token).GetERCStandard() returns (uint8) {
            return true;
        } catch {
            return false;
        }
    }
}
