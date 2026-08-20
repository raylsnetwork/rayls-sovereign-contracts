// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../../rayls-protocol-sdk/RaylsMessage.sol";

/**
 * @title MockEndpointForSecurityTest
 * @notice Mock endpoint for testing access control on token functions
 * @dev Used to test receiveMethod modifier behavior
 */
contract MockEndpointForSecurityTest {
    address public trustedExecutor;
    uint256 public chainId;
    uint256 public privateHubId;
    address private _authority;
    uint256 public lastSendDstChainId;
    address public lastSendDestination;
    bytes public lastSendPayload;

    mapping(string => address) public privateHubAddresses;
    mapping(bytes32 => address) public resourceIdToAddress;

    constructor(uint256 _chainId, uint256 _privateHubId) {
        chainId = _chainId;
        privateHubId = _privateHubId;
    }

    function setTrustedExecutor(address _executor) external {
        trustedExecutor = _executor;
    }

    function setAuthority(address authority_) external {
        _authority = authority_;
    }

    function authority() external view returns (address) {
        return _authority;
    }

    function getUserGovernanceAddress() external pure returns (address) {
        return address(0);
    }

    function getChainId() external view returns (uint256) {
        return chainId;
    }

    function getPrivateHubId() external view returns (uint256) {
        return privateHubId;
    }

    function getPrivateHubAddress(string calldata name) external view returns (address) {
        return privateHubAddresses[name];
    }

    function setPrivateHubAddress(string calldata name, address addr) external {
        privateHubAddresses[name] = addr;
    }

    function registerResourceId(bytes32 resourceId, address tokenAddress) external {
        resourceIdToAddress[resourceId] = tokenAddress;
    }

    function getAddressByResourceId(bytes32 resourceId) external view returns (address) {
        return resourceIdToAddress[resourceId];
    }

    // Stub functions - simplified for testing
    function send(uint256 dstChainId, address destination, bytes calldata payload) external payable returns (bytes32) {
        lastSendDstChainId = dstChainId;
        lastSendDestination = destination;
        lastSendPayload = payload;
        return bytes32(0);
    }
    function send(uint256, address, bytes calldata, BridgedTransferMetadata memory) external payable returns (bytes32) { return bytes32(0); }
    function sendToResourceId(uint256, bytes32, bytes calldata) external payable returns (bytes32) { return bytes32(0); }
    function sendToResourceId(uint256, bytes32, bytes calldata, bytes calldata, bytes calldata, bytes calldata, BridgedTransferMetadata memory) external payable returns (bytes32) { return bytes32(0); }

}
