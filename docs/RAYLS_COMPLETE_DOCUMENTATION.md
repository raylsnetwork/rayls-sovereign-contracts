# Rayls Protocol Complete Documentation

## Executive Summary

The **Rayls Protocol** is an advanced blockchain infrastructure that provides secure and private cross-chain communication, with a focus on privacy-preserving token transfers through zero-knowledge techniques and atomic Delivery vs Payment (DVP) operations. The protocol is designed to interconnect multiple blockchain networks in an interoperable manner, maintaining transaction privacy and ensuring atomic execution of complex financial operations.

## 📋 Table of Contents

1. [System Overview](#system-overview)
2. [Protocol Architecture](#protocol-architecture)
3. [Main Components](#main-components)
4. [Cross-Chain Messaging System](#cross-chain-messaging-system)
5. [Privacy and Zero-Knowledge](#privacy-and-zero-knowledge)
6. [Delivery vs Payment (DVP)](#delivery-vs-payment-dvp)
7. [Data Flow](#data-flow)
8. [Configuration and Deployment](#configuration-and-deployment)
9. [Security](#security)
10. [Usage Examples](#usage-examples)

---

## 🔭 System Overview

### What is the Rayls Protocol?

The Rayls Protocol is a complete solution for:

- **Cross-Chain Communication**: Enables different blockchains to communicate securely
- **Private Transfers**: Uses zero-knowledge proofs to maintain transaction privacy
- **Atomic DVP**: Executes Delivery vs Payment operations atomically using DVP
- **Token Management**: Support for ERC20, ERC721, ERC1155 and custom tokens (Enygma)

### Main Features

- ✅ **Interoperability**: Connects multiple blockchains
- ✅ **Privacy**: Zero-knowledge proofs for confidential transactions
- ✅ **Atomicity**: DVP operations guarantee atomic execution
- ✅ **Scalability**: Modular and upgradeable architecture
- ✅ **Security**: Multiple layers of validation and access control

---

## 🏗️ Protocol Architecture

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        RAYLS PROTOCOL                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────────┐    ┌─────────────────┐    ┌──────────────┐ │
│  │   Private Hub   │    │ Privacy Nodes   │    │   DVP        │ │
│  │                 │    │                 │    │   System     │ │
│  │ - Participants  │◄──►│ - Enygma Tokens │◄──►│ - Atomic     │ │
│  │ - Token Registry│    │ - Private TX    │    │   Swaps      │ │
│  │ - Resource Mgmt │    │ - Cross-chain   │    │ - ZK Proofs  │ │
│  └─────────────────┘    └─────────────────┘    └──────────────┘ │
│           │                       │                     │       │
│           └───────────────────────┼─────────────────────┘       │
│                                   │                             │
│  ┌─────────────────────────────────▼─────────────────────────────┐ │
│  │                Message Bus & Communication Layer             │ │
│  │                                                               │ │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │ │
│  │  │  Endpoint    │  │  Message     │  │   Message    │      │ │
│  │  │  Handler     │  │  Dispatcher  │  │   Executor   │      │ │
│  │  └──────────────┘  └──────────────┘  └──────────────┘      │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Architecture Components

1. **Private Hub**: Coordination and management layer
2. **Privacy Nodes**: Execution layer with privacy
3. **DVP System**: Atomic swap system
4. **Message Bus**: Cross-chain communication layer

---

## 🧩 Main Components

### 1. Private Hub

The Private Hub is the central coordination layer that manages:

#### Participant Storage
- **Functionality**: Manages network participants
- **Main File**: `ParticipantStorageV1.sol`
- **Responsibilities**:
  - Participant registration and validation
  - Status control (ACTIVE, INACTIVE, FROZEN)
  - Public key and audit data management
  - Information broadcast to all chains

```solidity
struct Participant {
    uint256 chainId;
    Role role;
    Status status;
    string ownerId;
    string name;
    uint256 createdAt;
    uint256 updatedAt;
    bool allowedToBroadcast;
}
```

#### Token Registry
- **Functionality**: Token registration and management
- **Main File**: `TokenRegistryV1.sol`
- **Responsibilities**:
  - New token registration (ERC20, ERC721, ERC1155, Enygma)
  - Token validation for participants
  - Token freeze/unfreeze control
  - Resource management via Resource Registry

#### Resource Registry
- **Functionality**: Resource mapping by ID
- **Main File**: `ResourceRegistryV1.sol`
- **Responsibilities**:
  - Mapping between resource IDs and contracts
  - Bytecode management for dynamic deployment
  - Resource versioning control

### 2. Privacy Nodes (PLs)

Privacy Nodes are where private transactions occur:

#### Endpoint System
- **Functionality**: Entry point for cross-chain messages
- **Main File**: `EndpointV1.sol`
- **Responsibilities**:
  - Cross-chain message receiving and sending
  - Nonce validation for message ordering
  - Payload execution via Message Executor
  - Resource ID management

#### Enygma System
- **Functionality**: Privacy-enabled token via zero-knowledge
- **Main Files**: `EnygmaV1.sol`, `EnygmaDvpIntegration.sol`
- **Features**:
  - Private transactions using BabyJubJub curve
  - Cryptographic commitments for balances
  - DVP integration for atomic swaps
  - Support for multiple verifiers (k=2 to k=6)

```solidity
struct EnygmaPointWithChainId {
    uint256 c1;  // X coordinate of the point
    uint256 c2;  // Y coordinate of the point
    uint256 chainId;
}
```

### 3. DVP System

Delivery vs Payment system with zero-knowledge:

#### Dvp Core
- **Functionality**: Main engine for atomic swaps
- **Main File**: `Dvp.sol`
- **Features**:
  - Support for ERC20, ERC721, ERC1155 and Enygma
  - Zero-knowledge proofs for ownership verification
  - Merkle trees for commitment tracking
  - Nullifiers for double-spending prevention

#### Supported Operations
1. **Deposit**: Deposit tokens into DVP
2. **Withdraw**: Withdraw tokens from DVP
3. **Swap**: Atomically swap tokens
4. **Mix**: Mix tokens for privacy

### 4. Message System

#### Message Structure
```solidity
struct RaylsMessage {
    RaylsMessageMetadata messageMetadata;
    bytes payload;
}

struct RaylsMessageMetadata {
    bool valid;
    uint256 nonce;
    NewResourceMetadata newResourceMetadata;
    bytes32 resourceId;
    bytes lockData;
    bytes revertPayloadDataSender;
    bytes revertPayloadDataReceiver;
    BridgedTransferMetadata transferMetadata;
    bool ignoresNonce;
}
```

#### Communication Flow
1. **Dispatch**: Message is created and sent via Endpoint
2. **Transport**: Relayer transports message to destination chain
3. **Receive**: Destination Endpoint receives and validates message
4. **Execute**: Message Executor executes payload on destination contract

---

## 📨 Cross-Chain Messaging System

### Message Flow

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   Sender    │───►│  Endpoint   │───►│   Relayer   │───►│ Destination │
│   Chain A   │    │   Chain A   │    │             │    │   Chain B   │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
      │                     │                │                   │
      │                     │                │                   │
      ▼                     ▼                ▼                   ▼
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│ Create      │    │ Validate &  │    │ Transport   │    │ Receive &   │
│ Message     │    │ Dispatch    │    │ Message     │    │ Execute     │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
```

### Message Types

1. **Single Message**: Individual message to a specific address
2. **Batch Messages**: Multiple messages in one transaction
3. **Resource ID Messages**: Messages to specific resources
4. **Broadcast Messages**: Messages to all participants

### Validations

- **Nonce Validation**: Ensures message ordering
- **Participant Validation**: Verifies sender and recipient are valid
- **Token Validation**: Confirms tokens are supported on both chains
- **Resource Validation**: Verifies resource ID is valid

---

## 🔐 Privacy and Zero-Knowledge

### Enygma System

The Enygma system implements privacy through:

#### Cryptographic Commitments
```solidity
// Pedersen Commitment: C = vG + rH
function pedCom(uint256 v, uint256 r) public view returns (uint256, uint256) {
    (uint256 gX, uint256 gY) = derivePk(v);      // vG
    (uint256 hX, uint256 hY) = derivePkH(r);     // rH
    (uint256 pedComX, uint256 pedComY) = CurveBabyJubJub.pointAdd(gX, gY, hX, hY);
    return (pedComX, pedComY);
}
```

#### Zero-Knowledge Proofs
- **k=2 to k=6 Verifiers**: Support different proof sizes
- **Groth16**: Uses the Groth16 proof system for efficiency
- **BabyJubJub**: Elliptic curve optimized for SNARKs

#### Private Transaction Flow
```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│  Generate       │───►│  Create         │───►│  Verify &       │
│  ZK Proof       │    │  Transaction    │    │  Execute        │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │                       │                       │
         ▼                       ▼                       ▼
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│ - Commitment    │    │ - Encrypted     │    │ - Update        │
│ - Nullifier     │    │   Message       │    │   Balances      │
│ - Proof         │    │ - Public        │    │ - Emit Events   │
│                 │    │   Signals       │    │                 │
└─────────────────┘    └─────────────────┘    └─────────────────┘
```

### Privacy Features

1. **Hidden Amounts**: Transaction values are private
2. **Hidden Recipients**: Recipients can be hidden
3. **Unlinkability**: Transactions cannot be easily linked
4. **Mix Transactions**: Allows mixing tokens for greater privacy

---

## 💱 Delivery vs Payment (DVP)

### DVP Concept

DVP (Delivery vs Payment) guarantees that asset delivery only occurs if the corresponding payment is made, atomically.

### DVP Implementation

#### Components
```
┌─────────────────────────────────────────────────────────────────┐
│                       DVP System                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐        │
│  │   Merkle    │    │   Dvp       │    │ Verifiers   │        │
│  │   Trees     │    │   Core      │    │   System    │        │
│  │             │    │             │    │             │        │
│  │ - ERC20     │◄──►│ - Deposits  │◄──►│ - JoinSplit │        │
│  │ - ERC721    │    │ - Withdraws │    │ - Ownership │        │
│  │ - ERC1155   │    │ - Swaps     │    │ - ERC1155   │        │
│  │ - Enygma    │    │ - Mix       │    │   Support   │        │
│  └─────────────┘    └─────────────┘    └─────────────┘        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

#### Supported Swaps

1. **Enygma ↔ ERC721**: Swap private tokens for NFTs
2. **Enygma ↔ ERC1155**: Swap private tokens for semi-fungible tokens
3. **ERC721 ↔ ERC20**: NFT for fungible tokens
4. **Mix Operations**: Token mixing for privacy

#### Swap Flow Example
```
┌─────────────────────────────────────────────────────────────────┐
│                    Atomic Swap Process                          │
└─────────────────────────────────────────────────────────────────┘

Step 1: Preparation
┌─────────────┐    ┌─────────────┐
│   User A    │    │   User B    │
│  (Enygma)   │    │  (ERC721)   │
└─────────────┘    └─────────────┘
       │                  │
       ▼                  ▼
┌─────────────┐    ┌─────────────┐
│  Deposit    │    │  Deposit    │
│  Enygma     │    │  ERC721     │
│  to DVP     │    │  to DVP     │
└─────────────┘    └─────────────┘

Step 2: Proof Generation
┌─────────────────────────────────────────┐
│  Generate ZK Proofs for:                │
│  - Ownership of deposited assets        │
│  - Commitment to swap                   │
│  - Valid swap parameters                │
└─────────────────────────────────────────┘

Step 3: Atomic Execution
┌─────────────────────────────────────────┐
│  DVP Validates & Executes:              │
│  1. Verify ownership proofs             │
│  2. Check swap compatibility            │
│  3. Execute atomic transfer             │
│  4. Update merkle trees                 │
│  5. Nullify old commitments             │
└─────────────────────────────────────────┘

Step 4: Completion
┌─────────────┐    ┌─────────────┐
│   User A    │    │   User B    │
│  now has    │    │  now has    │
│   ERC721    │    │   Enygma    │
└─────────────┘    └─────────────┘
```

---

## 🔄 Data Flow

### Cross-Chain Transaction Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                    Complete Transaction Flow                    │
└─────────────────────────────────────────────────────────────────┘

1. Initiation (Source Chain)
┌─────────────┐
│ User calls  │
│ crossTransfer() │────┐
└─────────────┘      │
                     ▼
               ┌─────────────┐
               │ Burn tokens │
               │ locally     │────┐
               └─────────────┘    │
                                 ▼
                           ┌─────────────┐
                           │ Create      │
                           │ message     │────┐
                           └─────────────┘    │
                                             ▼
                                       ┌─────────────┐
                                       │ Emit event  │
                                       │ to relayer  │
                                       └─────────────┘

2. Transport (Relayer)
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│ Listen for  │───►│ Validate    │───►│ Forward to  │
│ events      │    │ message     │    │ destination │
└─────────────┘    └─────────────┘    └─────────────┘

3. Execution (Destination Chain)
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│ Receive     │───►│ Validate    │───►│ Mint tokens │
│ message     │    │ nonce &     │    │ to recipient│
└─────────────┘    │ participants│    └─────────────┘
                   └─────────────┘
```

### Data Persistence

#### On-Chain Storage
- **Participants**: Network participant state
- **Tokens**: Token registry and metadata
- **Messages**: Nonces and message history
- **Commitments**: Merkle trees for DVP
- **Nullifiers**: Double-spending prevention

#### Off-Chain Storage
- **Proofs**: Zero-knowledge proofs (generated off-chain)
- **Encrypted Data**: Private transaction data
- **Relayer Logs**: Message transport logs

---

## ⚙️ Configuration and Deployment

### Deployment Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Deployment Structure                        │
└─────────────────────────────────────────────────────────────────┘

Private Hub (Chain ID: 999)
├── ParticipantStorageV1
├── TokenRegistryV1
├── ResourceRegistryV1
└── TeleportV1

Privacy Node (Chain ID: X)
├── EndpointV1
├── RaylsMessageExecutorV1
├── RaylsContractFactoryV1
├── ParticipantStorageReplicaV1
├── EnygmaPnEvents
├── PNCommunicatorV1
└── Dvp (if enabled)
```

### Configuration Files

#### `config.dev.json`
```json
{
  "privateHubChainId": 999,
  "participantChainIds": [1000, 1001, 1002],
  "relayerConfig": {
    "enabled": true,
    "endpoints": ["http://localhost:8545"]
  },
  "dvpConfig": {
    "enabled": true,
    "verifiers": {
      "k2": "0x...",
      "k3": "0x..."
    }
  }
}
```

### Deployment Scripts

#### Quick Deploy
```bash
# Deploy all contracts on development
npm run deploy:dev

# Deploy specific components
npm run deploy:private-hub
npm run deploy:privacy-node
```

#### Deployment
```bash
# Local development deploys the contracts automatically via the docker-based stack.
# To deploy manually against a running local network, use the Hardhat tasks:
npx hardhat deploy:private-hub --network localPNH
npx hardhat deploy:privacy-node --privacy-node A --network localA
./deploy/pcDeployContractsAndUpdateEnvs.sh A localPC 7331
```

---

## 🔒 Security

### Security Layers

#### 1. Access Control
- **Role-Based Access**: Different permission levels
- **Multi-Signature**: Critical operations require multiple signatures
- **Upgradeability**: Upgradeable contracts with access control

#### 2. Cryptographic Security
- **Zero-Knowledge Proofs**: Privacy without compromising verifiability
- **Elliptic Curve Cryptography**: BabyJubJub for SNARK efficiency
- **Hash Functions**: Poseidon for ZK compatibility

#### 3. Protocol Security
- **Nonce Management**: Replay attack prevention
- **Message Validation**: Complete cross-chain message validation
- **Participant Validation**: Active participant verification

#### 4. Economic Security
- **Token Freezing**: Ability to freeze compromised tokens
- **Participant Suspension**: Malicious participant suspension
- **Audit Trail**: Complete audit trail

### Security Best Practices

```solidity
// Example: Secure message validation
function _validateRaylsMessageAndGetPayload(
    uint256 _srcChainId,
    address _dstAddress,
    RaylsMessage memory _raylsMessage
) internal returns (bytes memory payload, address destinationAddress) {
    // Validate nonce to prevent replay
    if (!_raylsMessage.messageMetadata.ignoresNonce) {
        require(_raylsMessage.messageMetadata.nonce == ++inboundNonce[_srcChainId],
                'Rayls: wrong nonce');
    }

    // Validate participants
    participantStorageReplica.validateMessageParticipants(_srcChainId, chainId);

    // Validate destination
    destinationAddress = _handleWithResourceId(_raylsMessage.messageMetadata, _dstAddress);

    return (_raylsMessage.payload, destinationAddress);
}
```

---

## 💡 Usage Examples

### 1. Cross-Chain Token Transfer

```solidity
// Transfer 100 Enygma tokens to chain 1001
address[] memory recipients = new address[](1);
recipients[0] = 0x1234...;

uint256[] memory amounts = new uint256[](1);
amounts[0] = 100 * 10**18;

uint256[] memory chainIds = new uint256[](1);
chainIds[0] = 1001;

SharedObjects.EnygmaCrossTransferCallable[][] memory callables =
    new SharedObjects.EnygmaCrossTransferCallable[][](1);
callables[0] = new SharedObjects.EnygmaCrossTransferCallable[](0);

bytes32 referenceId = enygmaToken.crossTransfer(
    recipients,
    amounts,
    chainIds,
    callables
);
```

### 2. DVP Atomic Swap

```solidity
// Swap Enygma tokens for ERC721 NFT
uint8 k = 2; // Number of participants
IEnygmaV1.Point[] memory commitments = new IEnygmaV1.Point[](2);
// ... populate commitments

IEnygmaDvpIntegration.WithdrawOrDepositProof memory proof;
// ... generate proof off-chain

uint256[] memory chainIds = new uint256[](k);
bytes[] memory encryptedMessages = new bytes[](k);

bool success = enygmaDvpIntegration.depositToDvp(
    k,
    commitments,
    proof,
    chainIds,
    encryptedMessages
);
```

### 3. Register New Participant

```solidity
// Register new participant on Private Network Hub
ParticipantStorageV1.ParticipantData memory newParticipant =
    ParticipantStorageV1.ParticipantData({
        chainId: 1003,
        role: ParticipantStorageV1.Role.PARTICIPANT,
        ownerId: "org123",
        name: "New Bank"
    });

participantStorage.addParticipant(newParticipant);
```

### 4. Token Registration

```solidity
// Register new ERC20 token
SharedObjects.TokenRegistrationData memory tokenData =
    SharedObjects.TokenRegistrationData({
        name: "MyToken",
        symbol: "MTK",
        totalSupply: abi.encode(1000000 * 10**18),
        issuerChainId: 1001,
        bytecode: erc20Bytecode,
        initializerParams: abi.encode("MyToken", "MTK", 18),
        isFungible: true,
        ercStandard: SharedObjects.ErcStandard.ERC20,
        isCustom: false
    });

bytes32 resourceId = tokenRegistry.addToken(tokenData);
```

---

## 📈 Performance Considerations

### Gas Optimization
- **Batch Operations**: Multiple operations in one transaction
- **Efficient Storage**: Optimized data structures
- **Minimal External Calls**: Reduced external calls

### Scalability Features
- **Modular Architecture**: Independent components
- **Upgradeable Contracts**: Evolution without full migration
- **Cross-Chain Parallel Processing**: Parallel operations across multiple chains

### Monitoring & Analytics
- **Event Logging**: Complete logs for monitoring
- **Performance Metrics**: Gas and latency metrics
- **Error Tracking**: Error tracking system

---

## 🔮 Roadmap and Future

### Upcoming Features
- **Enhanced DVP**: Support for more asset types
- **Advanced Privacy**: New privacy techniques
- **Layer 2 Integration**: Integration with Layer 2 solutions
- **Cross-Chain Governance**: Decentralized cross-chain governance

### Research and Development
- **Novel ZK Techniques**: Research into new zero-knowledge techniques
- **Quantum Resistance**: Preparation for the post-quantum era
- **Interoperability Standards**: Contribution to industry standards

---

## 📞 Support and Contribution

### Additional Documentation
- `docs/architecture.md`: Architectural details
- `docs/development.md`: Development guide
- `docs/getting-started.md`: Getting started guide

### Scripts and Tools
- `cli/`: Command line interface
- `hardhat/tasks/`: Automated tasks
- `docker/`: Containerization for development

### Contact
For technical questions or contributions, consult the specific documentation in each module or contact the development team.

---

*For the current protocol version, see the repository tag / `package.json`.*
