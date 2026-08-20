// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./RaylsMessage.sol";
import "./interfaces/IRaylsEndpoint.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title RaylsAppV1
 * @notice Upgradeable base SDK contract for Rayls infrastructure contracts that communicate through a local
 *         Rayls endpoint (e.g. ParticipantStorageV1, TokenRegistryV1, PNTokenRegistryV1, the replicas). These
 *         derived contracts assign their own `resourceId` directly in their initializers.
 * @dev Stores endpoint/resource ID wiring and cross-chain send helpers. Token-handler machinery
 *      (resource-id assignment, PN/hub/public-chain status guards) lives on the non-V1 `RaylsApp` base
 *      instead. Storage layout intentionally remains small (`endpoint` + `resourceId`) so derived contracts
 *      can append their own state without slot-collision risk.
 */
abstract contract RaylsAppV1 is Initializable {
    /// @notice Rayls endpoint this app dispatches outbound traffic through and is dispatched to on inbound delivery.
    IRaylsEndpoint public endpoint;

    /// @notice Resource ID identifying this contract across chains. Set by derived infra contracts in their initializer.
    bytes32 public resourceId;

    /**
     * @notice Initialize the RaylsAppV1 with its trusted endpoint reference.
     * @dev Marked `onlyInitializing` so derived contracts can compose this initializer
     *      inside their own `initializer`-gated initialize.
     * @param _endpoint Trusted Rayls endpoint address.
     */
    function initialize(address _endpoint) public virtual onlyInitializing {
        endpoint = IRaylsEndpoint(_endpoint);
    }

    /**
     * @notice Look up the implementation address registered against a resourceId.
     * @dev Thin pass-through to the bound endpoint's `getAddressByResourceId`.
     * @param _resourceId Resource ID to resolve.
     * @return Implementation address, or `address(0)` if no resource is registered.
     */
    function getAddressByResourceId(bytes32 _resourceId) external view returns (address) {
        return endpoint.getAddressByResourceId(_resourceId);
    }

    /**
     * @notice Send a single cross-chain message to a destination contract.
     * @dev Forwards to `endpoint.send`. Endpoint enforces caller-side authorization.
     * @param _dstChainId Destination chain id.
     * @param _destination Destination contract address on the destination chain.
     * @param _payload ABI-encoded payload to dispatch on the destination contract.
     */
    function _raylsSend(uint256 _dstChainId, address _destination, bytes memory _payload) internal virtual {
        endpoint.send(_dstChainId, _destination, _payload);
    }

    /**
     * @notice Send a single cross-chain message with attached transfer metadata.
     * @param _dstChainId Destination chain id.
     * @param _destination Destination contract address.
     * @param _payload ABI-encoded payload.
     * @param transferMetadata Bridged-transfer metadata travelling alongside the payload.
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
     * @notice Send a cross-chain message addressed by resourceId rather than concrete address.
     * @dev Endpoint resolves the resourceId to an implementation address on the destination
     *      chain at delivery time.
     * @param _dstChainId Destination chain id.
     * @param _resourceId Resource id of the destination contract.
     * @param _payload ABI-encoded payload.
     */
    function _raylsSendToResourceId(uint256 _dstChainId, bytes32 _resourceId, bytes memory _payload) internal virtual {
        endpoint.sendToResourceId(_dstChainId, _resourceId, _payload);
    }

    /**
     * @notice Send a cross-chain message addressed by resourceId, with full atomic-transfer
     *         metadata (lock data + revert payloads + transfer metadata).
     * @dev Used by atomic teleport / DvP flows where the receiver may need to revert the
     *      message back to the sender's chain on failure.
     * @param _dstChainId Destination chain id.
     * @param _resourceId Resource id of the destination contract.
     * @param _payload ABI-encoded payload.
     * @param _lockData Lock-state payload the destination uses for atomic ops.
     * @param _revertDataPayloadSender Revert payload dispatched on the sender chain on failure.
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

    // receiveMethod and onlyFromPrivateHub modifiers removed — replaced by
    // `restricted` modifier (Auth V3) and origin chain policies in AccessManager.

    /**
     * @notice Read the messageId from the trusted tail of an inbound receive-method call.
     * @dev Only meaningful inside an Endpoint-dispatched receive method; reads via
     *      `calldataload(calldatasize() - 84)`. Returns zero if calldata is too short.
     * @return _msgDataMessageId Globally-unique id of the inbound message.
     */
    function _getMessageIdOnReceiveMethod() internal pure virtual returns (bytes32 _msgDataMessageId) {
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
    function _getFromChainIdOnReceiveMethod() internal pure returns (uint256 _msgDataFromChainId) {
        if (msg.data.length >= 52) {
            assembly {
                _msgDataFromChainId := calldataload(sub(calldatasize(), 52))
            }
        }
    }

    /**
     * @notice Read the message-sender address from the trusted tail of a receive-method call.
     * @dev Falls back to `msg.sender` when calldata is too short to carry a tail-encoded
     *      sender. The fallback is safe-by-default because every receive-method on Rayls
     *      handlers is gated by `restricted` → MESSAGE_EXECUTOR (the relayer role): only an
     *      authorised dispatcher can ever reach this read. When the endpoint dispatches via
     *      its standard send path, it appends a 20-byte sender tail to calldata and this
     *      function reads from there; when an authorised caller invokes the receive
     *      function directly without appending the tail, attributing the message origin to
     *      `msg.sender` matches reality (the on-chain caller is the origin in that case).
     *
     *      Note: a stricter pattern would `require(msg.sender == address(endpoint))` and
     *      revert on missing tail. That's incorrect here — MESSAGE_EXECUTOR is held by the
     *      relayer (and similar dispatchers), not by the endpoint contract itself. The
     *      access-control gate already enforces the trust boundary; the tail is only an
     *      origin-encoding optimisation, not a security primitive.
     * @return _signer Address that dispatched the inbound message on its origin chain.
     */
    function _getMsgSenderOnReceiveMethod() internal view returns (address payable _signer) {
        _signer = payable(msg.sender);

        if (msg.data.length >= 20) {
            assembly {
                _signer := shr(96, calldataload(sub(calldatasize(), 20)))
            }
        }
    }
}
