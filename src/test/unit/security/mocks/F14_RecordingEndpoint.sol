// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BridgedTransferMetadata} from "../../../../rayls-protocol-sdk/RaylsMessage.sol";

/**
 * @title F14_RecordingEndpoint
 * @notice Mock endpoint that records `sendToResourceId` calls so the F14 test
 *         can observe whether `_raylsSendToResourceId` fires from the module.
 */
contract F14_RecordingEndpoint {
    struct Broadcast {
        uint256 dstChainId;
        bytes32 resourceId;
        bytes payload;
        address sender;
    }

    Broadcast[] internal _broadcasts;

    uint256 public chainId;
    uint256 public privateHubId;
    address private _authority;

    mapping(bytes32 => address) public resourceIdToAddress;

    constructor(uint256 _chainId, uint256 _privateHubId) {
        chainId = _chainId;
        privateHubId = _privateHubId;
    }

    function setAuthority(address authority_) external {
        _authority = authority_;
    }

    function authority() external view returns (address) {
        return _authority;
    }

    function getChainId() external view returns (uint256) {
        return chainId;
    }

    function getPrivateHubId() external view returns (uint256) {
        return privateHubId;
    }

    function registerResourceId(bytes32 resourceId, address tokenAddress) external {
        resourceIdToAddress[resourceId] = tokenAddress;
    }

    function getAddressByResourceId(bytes32 resourceId) external view returns (address) {
        return resourceIdToAddress[resourceId];
    }

    // ── Recording overload used by ParticipantCoreV1.broadcastCurrentParticipants ──
    function sendToResourceId(
        uint256 _dstChainId,
        bytes32 _resourceId,
        bytes calldata _payload,
        bytes calldata,
        bytes calldata,
        bytes calldata,
        BridgedTransferMetadata memory
    ) external payable returns (bytes32) {
        _broadcasts.push(Broadcast({
            dstChainId: _dstChainId,
            resourceId: _resourceId,
            payload: _payload,
            sender: msg.sender
        }));
        return bytes32(uint256(_broadcasts.length));
    }

    // Unused stub overloads (kept to satisfy IRaylsEndpoint if needed in future).
    function sendToResourceId(uint256, bytes32, bytes calldata) external payable returns (bytes32) { return bytes32(0); }
    function send(uint256, address, bytes calldata) external payable returns (bytes32) { return bytes32(0); }
    function send(uint256, address, bytes calldata, BridgedTransferMetadata memory) external payable returns (bytes32) { return bytes32(0); }

    // ── Test helpers ──
    function broadcastCount() external view returns (uint256) {
        return _broadcasts.length;
    }

    function getBroadcast(uint256 i) external view returns (Broadcast memory) {
        return _broadcasts[i];
    }
}
