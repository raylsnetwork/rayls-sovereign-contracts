// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./Constants.sol";
import "./interfaces/IRaylsEndpoint.sol";
import "./RaylsMessage.sol";
import {IRaylsAppV1TokenRegistry} from "./interfaces/IRaylsAppV1TokenRegistry.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./libraries/MessageLib.sol";
import {IRaylsNodeEndpoint} from "../rayls-node/rayls-privacy-node/interfaces/IRaylsNodeEndpoint.sol";
import {IUserGovernance} from "../rayls-node/rayls-privacy-node/interfaces/IUserGovernanceV1.sol";

/**
 * @title RaylsApp
 * @notice Base class for cross-chain Rayls applications. Provides the primitives every
 *         Rayls-deployed contract needs: a typed endpoint reference, batched + targeted
 *         send helpers, resource-ID registration, and trusted-tail readers used by the
 *         Endpoint when delivering cross-chain messages back into this contract.
 * @dev Inherit and call `_raylsSend*` to dispatch outbound messages; override receive
 *      methods to consume inbound ones. Trusted addresses (endpoint, raylsNodeEndpoint,
 *      raylsNodeUserGovernance) come either from the constructor or from the factory's
 *      typed `RaylsTrustedInit` payload at initialize time.
 */
abstract contract RaylsApp {
    /// @notice Thrown when `_registerResourceId` runs before the token has been activated.
    error RaylsApp__ResourceNotApproved();

    /// @notice Thrown when no PN TokenRegistry is registered at RESOURCE_ID_TOKEN_REGISTRY.
    error RaylsApp__TokenRegistryNotConfigured();

    /// @notice Thrown when `setResourceId` is called by anyone other than the PN TokenRegistry.
    /// @param caller Calling address.
    /// @param tokenRegistry Expected PN TokenRegistry address.
    error RaylsApp__UnauthorizedTokenRegistry(address caller, address tokenRegistry);

    /// @notice Thrown when the token is not authorized at the local Privacy Node.
    /// @param tokenAddress Address of this token contract.
    /// @param privacyNodeStatus Current Privacy Node status.
    error RaylsApp__PrivacyNodeNotActive(address tokenAddress, uint8 privacyNodeStatus);

    /// @notice Thrown when the token is frozen at the local Privacy Node.
    /// @param tokenAddress Address of this token contract.
    error RaylsApp__PrivacyNodeFrozen(address tokenAddress);

    /// @notice Thrown when the token is not active for private-hub operations.
    /// @param tokenAddress Address of this token contract.
    /// @param privacyNodeStatus Current Privacy Node status.
    /// @param hubStatus Current hub status.
    error RaylsApp__HubNotActive(address tokenAddress, uint8 privacyNodeStatus, uint8 hubStatus);

    /// @notice Thrown when the token is not active for public-chain operations.
    /// @param tokenAddress Address of this token contract.
    /// @param privacyNodeStatus Current Privacy Node status.
    /// @param publicChainStatus Current public-chain status.
    error RaylsApp__PublicChainNotActive(address tokenAddress, uint8 privacyNodeStatus, uint8 publicChainStatus);

    /// @notice Thrown when `onlyRegisteredUsers` denies a caller that has not been approved
    ///         by the bound UserGovernance.
    /// @param caller Calling address.
    error RaylsApp__UserNotRegistered(address caller);

    /// @dev Mirrors TokenStructs.PrivacyNodeStatus.AUTHORIZED without importing registry structs into the SDK.
    uint8 internal constant _PRIVACY_NODE_STATUS_AUTHORIZED = 2;

    /// @dev Mirrors TokenStructs.PrivacyNodeStatus.FROZEN without importing registry structs into the SDK.
    uint8 internal constant _PRIVACY_NODE_STATUS_FROZEN = 4;

    /// @notice Rayls endpoint this app dispatches outbound traffic through and is dispatched
    ///         to on inbound delivery.
    IRaylsEndpoint internal endpoint;

    /// @notice Privacy-node endpoint reference. `address(0)` for protocol-side deploys
    ///         where no PN endpoint is bound.
    IRaylsNodeEndpoint internal raylsNodeEndpoint;

    /// @notice Optional UserGovernance reference used by `onlyRegisteredUsers`. Zero
    ///         when the deploy has no governance binding.
    IUserGovernance public raylsNodeUserGovernance;

    /// @notice Resource ID assigned by the PNH TokenRegistry. Zero until activation.
    bytes32 public resourceId;

    /// @notice Emitted when a token registration is submitted to the TokenRegistry on the Private Network Hub.
    /// @param tokenAddress The address of the token contract submitted for registration.
    event TokenRegistrationSubmitted(address indexed tokenAddress);

    /**
     * @notice Initialize the RaylsApp with trusted endpoint references.
     * @dev `address(0)` for `_raylsNodeEndpoint` or `_userGovernance` skips that binding.
     * @param _endpoint Trusted Rayls endpoint address. Required (non-zero).
     * @param _raylsNodeEndpoint Privacy-node endpoint address; zero on PNH deploys.
     * @param _userGovernance UserGovernance contract address; zero when not used.
     */
    constructor(address _endpoint, address _raylsNodeEndpoint, address _userGovernance) {
        endpoint = IRaylsEndpoint(_endpoint);
        if (_raylsNodeEndpoint != address(0)) {
            raylsNodeEndpoint = IRaylsNodeEndpoint(_raylsNodeEndpoint);
        }
        if (_userGovernance != address(0)) {
            raylsNodeUserGovernance = IUserGovernance(_userGovernance);
        }
    }

    /**
     * @notice Look up the implementation address registered against a resourceId.
     * @dev Thin pass-through to the bound endpoint's `getAddressByResourceId`.
     * @param _resourceId Resource ID to resolve.
     * @return Implementation address, or `address(0)` if no resource is registered.
     */
    function getAddressByResourceId(
        bytes32 _resourceId
    ) external view returns (address) {
        return endpoint.getAddressByResourceId(_resourceId);
    }

    /**
     * @notice Send a single cross-chain message to a destination contract.
     * @dev Forwards to `endpoint.send`. Caller-side authorization (`ENDPOINT_SENDER`) is
     *      enforced by the endpoint, not here.
     * @param _dstChainId Destination chain id.
     * @param _destination Destination contract address on the destination chain.
     * @param _payload ABI-encoded payload to dispatch on the destination contract.
     */
    function _raylsSend(
        uint256 _dstChainId,
        address _destination,
        bytes memory _payload
    ) internal virtual {
        endpoint.send(_dstChainId, _destination, _payload);
    }

    /**
     * @notice Send a single cross-chain message with attached transfer metadata.
     * @dev Same shape as the no-metadata variant; metadata travels alongside the payload
     *      for downstream consumers (DvP, audit, governance hooks).
     * @param _dstChainId Destination chain id.
     * @param _destination Destination contract address.
     * @param _payload ABI-encoded payload.
     * @param transferMetadata Bridged-transfer metadata (asset type, sender, receiver, etc.).
     */
    function _raylsSend(
        uint256 _dstChainId,
        address _destination,
        bytes memory _payload,
        BridgedTransferMetadata memory transferMetadata
    ) internal virtual {
        endpoint.send(_dstChainId, _destination, _payload, transferMetadata);
    }

    /**
     * @notice Send a batch of cross-chain messages in a single dispatch.
     * @dev Each entry carries its own destination + payload. Forwards to `endpoint.sendBatch`.
     * @param _destinationPayloadRequests Batch of `(dstChainId, destination, payload)` requests.
     */
    function _raylsSendBatch(
        DestinationPayloadRequest[] calldata _destinationPayloadRequests
    ) internal virtual {
        endpoint.sendBatch(_destinationPayloadRequests);
    }

    /**
     * @notice Send a cross-chain message addressed by resourceId rather than concrete address.
     * @dev Endpoint resolves the resourceId to an implementation address on the destination
     *      chain at delivery time.
     * @param _dstChainId Destination chain id.
     * @param _resourceId Resource id of the destination contract.
     * @param _payload ABI-encoded payload.
     */
    function _raylsSendToResourceId(
        uint256 _dstChainId,
        bytes32 _resourceId,
        bytes memory _payload
    ) internal virtual {
        endpoint.sendToResourceId(
            _dstChainId,
            _resourceId,
            _payload
        );
    }

    /**
     * @notice Send a batch of resource-ID-addressed messages.
     * @param _resourceIdPayloadRequests Batch of `(dstChainId, resourceId, payload)` requests.
     */
    function _raylsSendBatchToResourceId(
        ResourceIdPayloadRequest[] memory _resourceIdPayloadRequests
    ) internal virtual {
        endpoint.sendBatchToResourceId(
            _resourceIdPayloadRequests
        );
    }

    /**
     * @notice Send a cross-chain message addressed by resourceId, with full atomic-transfer
     *         metadata (lock data + revert payloads + transfer metadata).
     * @dev Used by atomic teleport / DvP flows where the receiver may need to revert the
     *      message back to the sender's chain on failure. Forwards to the rich
     *      `endpoint.sendToResourceId` overload.
     * @param _dstChainId Destination chain id.
     * @param _resourceId Resource id of the destination contract.
     * @param _payload ABI-encoded payload.
     * @param _lockData Lock-state payload the destination uses for atomic ops.
     * @param _revertDataPayloadSender Revert-back payload to dispatch on the sender chain
     *                                  if the destination rejects the message.
     * @param _revertDataPayloadReceiver Revert payload dispatched on the receiver chain.
     * @param transferMetadata Bridged-transfer metadata.
     */
    function _raylsSendToResourceId(
        uint256 _dstChainId,
        bytes32 _resourceId,
        bytes memory _payload,
        bytes memory _lockData,
        bytes memory _revertDataPayloadSender,
        bytes memory _revertDataPayloadReceiver,
        BridgedTransferMetadata memory transferMetadata
    ) internal virtual {
        endpoint.sendToResourceId(
            _dstChainId,
            _resourceId,
            _payload,
            _lockData,
            _revertDataPayloadSender,
            _revertDataPayloadReceiver,
            transferMetadata
        );
    }

    /**
     * @notice Send a batch of resource-ID-addressed messages with full atomic metadata.
     * @param _resourceIdPayloadRequests Batch of complete payload requests including lock
     *                                    + revert + metadata fields.
     */
    function _raylsSendBatchToResourceId(
        ResourceIdCompletePayloadRequest[] memory _resourceIdPayloadRequests
    ) internal virtual {
        endpoint.sendBatchToResourceId(
            _resourceIdPayloadRequests
        );
    }

    /**
     * @notice Self-register this contract under its assigned `resourceId` on the endpoint.
     * @dev Reverts if `resourceId` is unset (token has not been activated by PNH).
     */
    function _registerResourceId() internal virtual {
        if (resourceId == bytes32(0)) revert RaylsApp__ResourceNotApproved();
        endpoint.registerResourceId(resourceId, address(this));
    }

    /**
     * @notice Set the resourceId on this contract. Callable only by the PN TokenRegistry.
     * @dev TokenRegistry address is resolved at call time from RESOURCE_ID_TOKEN_REGISTRY
     *      on the local endpoint — no per-token wiring needed.
     * @param _resourceId Resource id assigned by the PNH TokenRegistry.
     */
    function setResourceId(bytes32 _resourceId) external virtual {
        address tokenRegistry = _getTokenRegistry();
        if (msg.sender != tokenRegistry) {
            revert RaylsApp__UnauthorizedTokenRegistry(msg.sender, tokenRegistry);
        }
        resourceId = _resourceId;
    }

    /**
     * @notice Resolve the PN TokenRegistry facade from the endpoint's resource mapping.
     * @dev Reverts when RESOURCE_ID_TOKEN_REGISTRY has not been registered on this PN.
     * @return tokenRegistry Address currently registered for RESOURCE_ID_TOKEN_REGISTRY.
     */
    function _getTokenRegistry() internal view returns (address tokenRegistry) {
        tokenRegistry = endpoint.getAddressByResourceId(Constants.RESOURCE_ID_TOKEN_REGISTRY);
        if (tokenRegistry == address(0)) {
            revert RaylsApp__TokenRegistryNotConfigured();
        }
    }

    /**
     * @notice Require this app to be authorized at the local Privacy Node layer.
     * @dev Intended for token handlers before operations that require local PN approval.
     */
    function _requirePrivacyNodeActive() internal view virtual {
        IRaylsAppV1TokenRegistry tokenRegistry = IRaylsAppV1TokenRegistry(_getTokenRegistry());
        uint8 privacyNodeStatus = tokenRegistry.getPrivacyNodeStatus(address(this));
        if (privacyNodeStatus != _PRIVACY_NODE_STATUS_AUTHORIZED) {
            revert RaylsApp__PrivacyNodeNotActive(address(this), privacyNodeStatus);
        }
    }

    /**
     * @notice Require this app to be active for private-hub operations.
     * @dev PN freezes are surfaced separately from non-authorized hub state so callers
     *      can distinguish global local freezes from hub approval/freeze failures.
     */
    function _requireHubActive() internal view virtual {
        if (resourceId == bytes32(0)) revert RaylsApp__ResourceNotApproved();
        IRaylsAppV1TokenRegistry tokenRegistry = IRaylsAppV1TokenRegistry(_getTokenRegistry());
        if (tokenRegistry.isTokenActiveForHub(address(this))) {
            return;
        }
        uint8 privacyNodeStatus = tokenRegistry.getPrivacyNodeStatus(address(this));
        if (privacyNodeStatus == _PRIVACY_NODE_STATUS_FROZEN) {
            revert RaylsApp__PrivacyNodeFrozen(address(this));
        }
        revert RaylsApp__HubNotActive(address(this), privacyNodeStatus, tokenRegistry.getHubStatus(address(this)));
    }

    /**
     * @notice Require this app to be active for public-chain operations.
     * @dev PN freezes are surfaced separately from non-deployed public-chain state so callers
     *      can distinguish global local freezes from public-chain deployment/freeze failures.
     */
    function _requirePublicChainActive() internal view virtual {
        IRaylsAppV1TokenRegistry tokenRegistry = IRaylsAppV1TokenRegistry(_getTokenRegistry());
        if (tokenRegistry.isTokenActiveForPublicChain(address(this))) {
            return;
        }
        uint8 privacyNodeStatus = tokenRegistry.getPrivacyNodeStatus(address(this));
        if (privacyNodeStatus == _PRIVACY_NODE_STATUS_FROZEN) {
            revert RaylsApp__PrivacyNodeFrozen(address(this));
        }
        revert RaylsApp__PublicChainNotActive(
            address(this), privacyNodeStatus, tokenRegistry.getPublicChainStatus(address(this))
        );
    }

    /**
     * @notice Read the messageId from the trusted tail of an inbound receive-method call.
     * @dev Only meaningful inside an Endpoint-dispatched receive method; reads via
     *      `calldataload(calldatasize() - 84)`. Returns zero if calldata is too short.
     * @return _msgDataMessageId Globally-unique id of the inbound message.
     */
    function _getMessageIdOnReceiveMethod()
        internal
        pure
        returns (bytes32 _msgDataMessageId)
    {
        if (msg.data.length >= 84) {
            assembly {
                _msgDataMessageId := calldataload(sub(calldatasize(), 84))
            }
        }
    }

    /**
     * @notice Read the originating chain id from the trusted tail of a receive-method call.
     * @dev Reads via `calldataload(calldatasize() - 52)`. Returns zero if calldata too short.
     * @return _msgDataFromChainId Chain id that dispatched the inbound message.
     */
    function _getFromChainIdOnReceiveMethod()
        internal
        pure
        returns (uint256 _msgDataFromChainId)
    {
        if (msg.data.length >= 52) {
            assembly {
                _msgDataFromChainId := calldataload(sub(calldatasize(), 52))
            }
        }
    }

    /**
     * @notice Read the message-sender address from the trusted tail of a receive-method call.
     * @dev Falls back to `msg.sender` when calldata is too short to carry a tail-encoded
     *      sender. The fallback is **safe-by-default** because every receive-method on Rayls
     *      handlers is gated by `restricted` → MESSAGE_EXECUTOR (the relayer role): only an
     *      authorised dispatcher can ever reach this read. When the endpoint dispatches via
     *      its standard send path, it appends a 20-byte sender tail to calldata and this
     *      function reads from there; when an authorised caller invokes the receive
     *      function directly without appending the tail, attributing the message origin to
     *      `msg.sender` matches reality (the on-chain caller IS the origin in that case).
     *
     *      Note: a stricter pattern would `require(msg.sender == address(endpoint))` and
     *      revert on missing tail. That's incorrect here — MESSAGE_EXECUTOR is held by the
     *      relayer (and similar dispatchers), not by the endpoint contract itself. The
     *      access-control gate already enforces the trust boundary; the tail is only an
     *      origin-encoding optimisation, not a security primitive.
     * @return _signer Address that dispatched the inbound message on its origin chain.
     */
    function _getMsgSenderOnReceiveMethod()
        internal
        view
        returns (address payable _signer)
    {
        _signer = payable(msg.sender);

        if (msg.data.length >= 20) {
            assembly {
                _signer := shr(96, calldataload(sub(calldatasize(), 20)))
            }
        }
    }

    /**
     * @notice Update the bound endpoint reference.
     * @dev No access control here — gating is the inheritor's responsibility.
     * @param _endpoint New endpoint address.
     */
    function _updateEndpoint(address _endpoint) internal virtual {
        endpoint = IRaylsEndpoint(_endpoint);
    }

    /**
     * @notice Read the bound endpoint address.
     * @return Endpoint contract address.
     */
    function getEndpointAddress() public view virtual returns (address) {
        return address(endpoint);
    }

    /**
     * @notice Wire UserGovernance from a trusted address supplied at initialize time.
     * @dev Replaces the prior calldata-offset reader. Handlers pass `trusted.userGovernance`
     *      from the typed `RaylsTrustedInit` struct injected by the contract factory.
     * @param userGovernance Trusted UserGovernance address. `address(0)` is a valid no-op.
     */
    function _initializeUserGovernance(address userGovernance) internal {
        if (userGovernance != address(0)) {
            raylsNodeUserGovernance = IUserGovernance(userGovernance);
        }
    }

    /**
     * @notice Restrict a function to UserGovernance-approved callers.
     * @dev When `raylsNodeUserGovernance` is unset (zero), the modifier is a no-op so
     *      handlers without a governance binding remain callable. When set, the caller
     *      address must be approved by `checkUserIsApprovedByPrivateAddress`.
     */
    modifier onlyRegisteredUsers() {
        if (address(raylsNodeUserGovernance) != address(0)) {
            if (!raylsNodeUserGovernance.checkUserIsApprovedByPrivateAddress(msg.sender)) {
                revert RaylsApp__UserNotRegistered(msg.sender);
            }
        }
        _;
    }

    /**
     * @notice Gate a function on this app being authorized at the local Privacy Node layer.
     * @dev Declarative wrapper around {_requirePrivacyNodeActive}.
     */
    modifier whenPrivacyNodeActive() {
        _requirePrivacyNodeActive();
        _;
    }

    /**
     * @notice Gate a function on this app being active for private-hub operations.
     * @dev Declarative wrapper around {_requireHubActive}.
     */
    modifier whenHubActive() {
        _requireHubActive();
        _;
    }

    /**
     * @notice Gate a function on this app being active for public-chain operations.
     * @dev Declarative wrapper around {_requirePublicChainActive}.
     */
    modifier whenPublicChainActive() {
        _requirePublicChainActive();
        _;
    }
}
