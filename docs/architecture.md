# Architecture Overview

This document provides an overview of the Rayls Contracts architecture and its components.

## System Components

### Smart Contracts

1. **Core Contracts**
   - `RaylsProtocol.sol`: Main protocol contract
   - `TokenRegistry.sol`: Token registration and management
   - `DVP.sol`: Zero-knowledge DVP implementation

2. **Token Standards**
   - `ERC721.sol`: Non-fungible token implementation
   - `ERC1155.sol`: Multi-token standard implementation
   - `Enygma.sol`: Custom token implementation

3. **Utility Contracts**
   - `SharedObjects.sol`: Shared data structures and enums
   - `PNCommunicatorV1.sol`: Cross-chain communication system

### Privacy Nodes (PLs)

The system supports multiple privacy nodes:
- PN A
- PN B
- PN C
- PN D

## Communication System

### PNCommunicatorV1 Contract

The `PNCommunicatorV1` contract is a helper that gives users the ability to have a status machine in any context. It implements a message passing system that allows different PNs to share information and coordinate operations.

#### Key Features

1. **Message Storage**
   - Uses a mapping of `bytes32` to arrays of `CommunicatiorData` structures
   - Each message is associated with a unique `sharedId`
   - Messages include status, block number, and content

2. **Message Management**
   - `addSharedInfo`: Adds new messages to the communication log
   - `getAllSharedInfo`: Retrieves all messages for a given ID
   - `getSharedInfoAt`: Gets a specific message by index
   - `removeSharedInfoAt`: Removes a specific message
   - `removeSharedInfo`: Clears all messages for an ID

3. **Security Features**
   - Inherits from `OwnableUpgradeable` for access control
   - Implements `UUPSUpgradeable` for contract upgrades
   - Uses `Initializable` for proper initialization

4. **Events**
   - `SharedInfoAdded`: Emitted when new messages are added
   - `SharedInfoRemoved`: Emitted when messages are removed

#### Usage Examples

1. **Adding a Message**
   ```solidity
   communicator.addSharedInfo(
       sharedId,    // Unique identifier for the communication
       status,      // Status code (e.g., 0 for NOSTATUS)
       message      // The actual message content
   );
   ```

2. **Retrieving Messages**
   ```solidity
   // Get all messages
   CommunicatiorData[] memory messages = communicator.getAllSharedInfo(sharedId);
   
   // Get specific message
   (uint256 status, uint256 blockNumber, string memory message) = 
       communicator.getSharedInfoAt(sharedId, index);
   ```

3. **Checking Message Existence**
   ```solidity
   bool hasMessages = communicator.hasSharedInfo(sharedId);
   uint256 messageCount = communicator.getSharedInfoCount(sharedId);
   ```

#### Status Codes

The contract uses status codes to track the state of communications:
- 0: NOSTATUS
- 1: Swap721WaitingEnygmaSwapSent
- 2: Swap721WaitingEnygmaSwapReceived
- 3: SwapEnygmaWaiting721SwapSent
- 4: SwapEnygmaWaiting721SwapReceived
- 5: SwapDone
- 6: Error

## Communication Flow

1. **Token Registration**
   ```
   User -> TokenRegistry -> Relayer -> VEN
   ```

2. **Cross-Chain Transfer**
   ```
   Source PN -> Communicator -> Destination PN
   ```

3. **DVP Operations**
   ```
   User -> DVP -> Proof Generation -> Verification -> Settlement
   ```

## Security Considerations

1. **Access Control**
   - Role-based access control (RBAC)
   - Multi-signature requirements for critical operations

2. **Data Privacy**
   - Zero-knowledge proofs for sensitive operations
   - Encrypted communication channels

3. **Audit Trail**
   - Immutable transaction records
   - Event logging for all operations

## Integration Points

1. **External Systems**
   - Relayer service
   - VEN (Virtual Exchange Network)
   - Proof generation service

2. **Development Tools**
   - Hardhat for development and testing
   - Foundry for additional testing capabilities
   - Docker for containerized development

## Performance Considerations

1. **Gas Optimization**
   - Efficient data structures
   - Batch operations where possible
   - Minimal storage usage

2. **Scalability**
   - Modular design
   - Upgradeable contracts
   - Cross-chain compatibility

## Future Considerations

1. **Planned Improvements**
   - Enhanced DVP capabilities
   - Additional token standards
   - Improved cross-chain communication

2. **Research Areas**
   - Advanced zero-knowledge proofs
   - New privacy-preserving techniques
   - Scalability solutions 