// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import './EnygmaDvpIntegration.sol';


contract DvpIntegrationCreator {
    event IntegrationCreated(address integration, address enygma, bytes32 resourceId);
    
    function createIntegration(
        address _enygmaAddr,
        bytes32 _resourceId,
        address _settingsContract
    ) external returns (address) {
        // Create integration contract with msg.sender (EnygmaFactory) as the authorized factory
        EnygmaDvpIntegration integration = new EnygmaDvpIntegration(_enygmaAddr, msg.sender);
        address integrationAddr = address(integration);
        
        emit IntegrationCreated(integrationAddr, _enygmaAddr, _resourceId);
        return integrationAddr;
    }
}