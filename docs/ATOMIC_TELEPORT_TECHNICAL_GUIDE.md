> **DEPRECATED.** Decommissioning Teleport (vanilla, atomic).

# Atomic Teleport - Complete Technical Guide

## 📖 Summary

This document provides an in-depth technical analysis of the **Atomic Teleport System** from Rayls Protocol, which implements guaranteed cross-chain transfers with automatic rollback mechanisms.

---

## 🎯 Fundamental Concepts

### What is Atomic Teleport?

The **Atomic Teleport** is a system that guarantees cross-chain **"all or nothing"** transfers:
- ✅ **Success**: Asset appears on destination chain AND disappears from origin chain
- ❌ **Failure**: Asset remains on origin chain (automatic rollback)
- 🚫 **Impossible**: Asset lost or duplicated

### Difference: Teleport vs Atomic Teleport

#### **Traditional Teleport**
```solidity
function teleport(address to, uint256 value, uint256 chainId) {
    _burn(msg.sender, value);  // Asset destroyed immediately
    // Sends cross-chain message
    // If fails on destination chain = ASSET LOST
}
```

#### **Atomic Teleport**
```solidity
function teleportAtomic(address to, uint256 value, uint256 chainId) {
    _burn(msg.sender, value);  // Asset destroyed temporarily
    // Sends with revert data
    // On destination chain: asset stays "locked" until confirmation
    // If fails: executes automatic revert
}
```

---

## 🏗️ System Architecture

### Main Components

```
┌─────────────────────────────────────────────────────────────────┐
│                 ATOMIC TELEPORT SYSTEM                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │              Private Hub (Chain ID: 999)                   │ │
│  │                                                             │ │
│  │  ┌─────────────────────────────────────────────────────┐   │ │
│  │  │                TeleportV1                           │   │ │
│  │  │                                                     │   │ │
│  │  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐ │   │ │
│  │  │  │  Message    │  │   Status    │  │   Execute   │ │   │ │
│  │  │  │  Tracking   │  │ Management  │  │   Revert    │ │   │ │
│  │  │  └─────────────┘  └─────────────┘  └─────────────┘ │   │ │
│  │  │                                                     │   │ │
│  │  │  States: Pending → Executed/Reverted               │   │ │
│  │  └─────────────────────────────────────────────────────┘   │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                              │                                   │
│  ┌─────────────────────────────▼─────────────────────────────┐   │
│  │              Privacy Nodes (Multiple Chains)           │   │
│  │                                                           │   │
│  │  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐     │   │
│  │  │    ERC20     │ │    ERC721    │ │   ERC1155    │     │   │
│  │  │   Handler    │ │   Handler    │ │   Handler    │     │   │
│  │  │              │ │              │ │              │     │   │
│  │  │ - teleport() │ │ - teleport() │ │ - teleport() │     │   │
│  │  │ - teleportA- │ │ - teleportA- │ │ - teleportA- │     │   │
│  │  │   tomic()    │ │   tomic()    │ │   tomic()    │     │   │
│  │  │ - receive()  │ │ - receive()  │ │ - receive()  │     │   │
│  │  │ - lock/      │ │ - lock/      │ │ - lock/      │     │   │
│  │  │   unlock()   │ │   unlock()   │ │   unlock()   │     │   │
│  │  │ - revert()   │ │ - revert()   │ │ - revert()   │     │   │
│  │  └──────────────┘ └──────────────┘ └──────────────┘     │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │                    Specialized Handlers                     │ │
│  │                                                             │ │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │ │
│  │  │   DVP      │  │    Enygma    │  │    Batch     │     │ │
│  │  │  Teleport    │  │   Teleport   │  │   Teleport   │     │ │
│  │  │              │  │              │  │              │     │ │
│  │  │ - Swap state │  │ - Private    │  │ - Multiple   │     │ │
│  │  │   tracking   │  │   transfers  │  │   assets     │     │ │
│  │  │ - Atomic     │  │ - Encrypted  │  │ - Optimized  │     │ │
│  │  │   execution  │  │   messages   │  │   gas costs  │     │ │
│  │  └──────────────┘  └──────────────┘  └──────────────┘     │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### TeleportV1 - Central Controller

#### Main Data Structures

```solidity
struct AtomicTeleportMessage {
    Utils.MessageStatus status;           // Current state
}

enum MessageStatus {
    Pending,   // Awaiting execution
    Executed,  // Successfully executed
    Rejected,  // Rejected (not currently used)  
    Reverted   // Reverted due to failure
}
```

#### Message Management

```solidity
mapping(string => AtomicTeleportMessage) public atomicTeleportMessages;
```

---

## 🔄 Operation Flows

### Flow 1: Successful Atomic Teleport

#### **Phase 1: Initiation (Origin Chain)**
```solidity
// User calls teleportAtomic
function teleportAtomic(address to, uint256 value, uint256 chainId) {
    // 1. Burn asset (temporary)
    _burn(msg.sender, value);
    
    // 2. Prepare execution and revert payloads
    bytes memory executePayload = abi.encodeWithSignature("receiveTeleportAtomic(address,uint256)", to, value);
    bytes memory unlockPayload = abi.encodeWithSignature("unlock(address,uint256)", to, value);
    bytes memory revertSender = abi.encodeWithSignature("revertTeleportMint(address,uint256)", msg.sender, value);
    bytes memory revertReceiver = abi.encodeWithSignature("revertTeleportBurn(uint256)", value);
    
    // 3. Send cross-chain message
    sendTeleport(chainId, executePayload, unlockPayload, revertSender, revertReceiver, metadata);
}
```

#### **Phase 2: Message Processing (Private Hub)**
```solidity
// TeleportV1.storeAtomicMessageBatch()
function storeAtomicMessageBatch(string[] calldata msgIds) {
    for (uint256 i = 0; i < msgIds.length; i++) {
        AtomicTeleportMessage storage message = atomicTeleportMessages[msgIds[i]];
        message.status = Utils.MessageStatus.Pending;
    }
    
    emit AtomicMessageTeleportStartedBatch(msgIds);
}
```

#### **Phase 3: Reception (Destination Chain)**
```solidity
// Endpoint calls receiveTeleportAtomic
function receiveTeleportAtomic(address to, uint256 value) {
    // 1. Mint asset to contract owner (temporary)
    _mint(owner(), value);
    
    // 2. If recipient is not owner, lock the asset
    if (to != owner()) {
        _lock(to, value);  // Asset stays "locked"
    }
}
```

#### **Phase 4: Confirmation & Unlock**
```solidity
// TeleportV1.executeAtomicMessageBatch()
function executeAtomicMessageBatch(string[] calldata msgIds, string calldata encryptedData_) {
    for (uint256 i = 0; i < msgIds.length; i++) {
        AtomicTeleportMessage storage message = atomicTeleportMessages[msgIds[i]];
        if (message.status == Utils.MessageStatus.Pending) {
            message.status = Utils.MessageStatus.Executed;
        }
    }
    
    emit AtomicMessageStatusChangedBatch(msgIds, Utils.MessageStatus.Executed);
    // Trigger for unlock payload execution
}

// On destination chain: unlock is executed
function unlock(address to, uint256 value) {
    bool success = _unlock(to, value);  // Remove lock
    _transfer(owner(), to, value);      // Final transfer to user
}
```

### Flow 2: Atomic Teleport with Failure

#### **Scenario**: Failure on Destination Chain

```solidity
// receiveTeleportAtomic fails (ex: invalid address)
function receiveTeleportAtomic(address to, uint256 value) {
    if (to == blacklistedAddress) {
        revert("Address not allowed");  // FAILURE HERE
    }
}
```

#### **Automatic Revert**

```solidity
// TeleportV1.revertAtomicMessageBatch()
function revertAtomicMessageBatch(string[] calldata msgIds, string calldata encryptedData_) {
    for (uint i = 0; i < msgIds.length; i++) {
        AtomicTeleportMessage storage message = atomicTeleportMessages[msgIds[i]];
        if (message.status == Utils.MessageStatus.Pending) {
            message.status = Utils.MessageStatus.Reverted;
        }
    }
    
    emit AtomicMessageStatusChangedBatch(msgIds, Utils.MessageStatus.Reverted);
    // Trigger for revert payload execution
}

// On origin chain: revert is executed
function revertTeleportMint(address to, uint256 value) {
    _mint(to, value);  // Restores original asset
}
```

---

## 🔒 Security Mechanisms

### Lock/Unlock System

#### **For ERC20 Tokens**
```solidity
mapping(address => uint256) private lockedAmount;  // address -> locked_amount

function _lock(address to, uint256 amount) internal {
    require(amount > 0, "Amount must be greater than 0");
    require(to != address(0));
    lockedAmount[to] += amount;
}

function _unlock(address to, uint256 amount) internal returns (bool) {
    require(to != address(0));
    uint256 amountToUnlock = lockedAmount[to];
    require(amount > 0 && amount <= amountToUnlock, "Not enough funds to unlock");
    lockedAmount[to] -= amount;
    return true;
}
```

#### **For ERC721 Tokens**
```solidity
mapping(address => mapping(uint256 => bool)) private lockedTokens;  // address -> tokenId -> locked

function _lock(address to, uint256 id) internal {
    require(to != address(0));
    lockedTokens[to][id] = true;
}

function _unlock(address to, uint256 id) internal returns (bool) {
    require(to != address(0));
    bool isLocked = lockedTokens[to][id];
    require(isLocked == true, "No funds to unlock");
    lockedTokens[to][id] = false;
    return true;
}
```

#### **For ERC1155 Tokens**
```solidity
mapping(address => mapping(uint256 => uint256)) private lockedAmount;  // address -> tokenId -> amount

function _lock(address to, uint256 id, uint256 amount) internal {
    require(amount > 0, "Amount must be greater than 0");
    require(to != address(0));
    lockedAmount[to][id] += amount;
}

function _unlock(address to, uint256 id, uint256 amount) internal returns (bool) {
    require(to != address(0));
    uint256 amountToUnlock = lockedAmount[to][id];
    require(amount > 0 && amount <= amountToUnlock, "Not enough funds to unlock");
    lockedAmount[to][id] -= amount;
    return true;
}
```

### Revert System

#### **Payload Structure**
```solidity
struct TeleportPayloads {
    bytes executePayload;           // For normal execution
    bytes lockPayload;              // For unlock after confirmation
    bytes revertPayloadSender;      // For revert on origin chain
    bytes revertPayloadReceiver;    // For revert on destination chain
}
```

#### **Revert Scenarios**
1. **Execution fails on destination chain** → Executes `revertPayloadSender`
2. **Validation fails** → Automatic rollback

---

## 🚀 Specialized Operations

### Batch Teleports

#### **Batch Structure**
```solidity
struct BatchTeleportPayloadRequest {
    address to;
    uint256 value; 
    uint256 chainId;
}

function batchTeleportAtomic(BatchTeleportPayloadRequest[] calldata requests) {
    ResourceIdCompletePayloadRequest[] memory payloadRequests = 
        new ResourceIdCompletePayloadRequest[](requests.length);
    
    for (uint256 i = 0; i < requests.length; i++) {
        BatchTeleportPayloadRequest calldata request = requests[i];
        
        _burn(msg.sender, request.value);  // Burn each asset
        
        payloadRequests[i] = ResourceIdCompletePayloadRequest({
            _dstChainId: request.chainId,
            _resourceId: resourceId,
            _payload: abi.encodeWithSignature("receiveTeleportAtomic(address,uint256)", request.to, request.value),
            _lockData: abi.encodeWithSignature("unlock(address,uint256)", request.to, request.value),
            _revertDataSender: abi.encodeWithSignature("revertTeleportMint(address,uint256)", msg.sender, request.value),
            _revertDataReceiver: abi.encodeWithSignature("revertTeleportBurn(uint256)", request.value),
            transferMetadata: transferMetadata
        });
    }
    
    sendBatchTeleport(payloadRequests);  // Batch sending
}
```

### DVP Teleports

#### **DvpTeleport Contract**
```solidity
contract DvpTeleport {
    mapping(bytes32 sharedId => uint8 executions) public calldataExecutions;
    mapping(bytes32 sharedId => bool initialised) public swapInitialisations;
    
    enum SwapState {
        SwapCompleted,
        SwapFailed
    }
    
    function executeCalldata(bytes32 sharedId) {
        uint8 executions = calldataExecutions[sharedId];
        require(executions < 2, "Calldata already executed");
        
        executions = executions + 1;
        calldataExecutions[sharedId] = executions;
        
        if (executions == 2) {  // Both parties confirmed
            emit CalldataExecuted(sharedId);
        }
    }
}
```

### Enygma Teleports

#### **Private Message Handling**
```solidity
contract EnygmaTeleport {
    function transfer(bytes32 resourceId, uint256 toChainId, bytes calldata encryptedMessage) {
        emit EnygmaTransfer(resourceId, toChainId, encryptedMessage);
    }
    
    function enygmaTransferCompleted(bytes calldata encryptedMessage) {
        emit EnygmaTransferCompleted(encryptedMessage);
    }
}
```

---

## 💡 Practical Use Cases

### Case 1: DeFi Cross-Chain Arbitrage

```typescript
// Automatic arbitrage between chains
async function crossChainArbitrage(
    tokenAmount: bigint,
    sourceChain: number,
    destChain: number
) {
    // 1. Atomic teleport to chain with better price
    await erc20Token.teleportAtomic(
        arbitrageBot.address,
        tokenAmount,
        destChain
    );
    
    // 2. If arbitrage fails → automatic revert
    // 3. If successful → profit is locked until confirmation
    // 4. Unlock executes after cross-chain confirmation
}
```

### Case 2: Cross-Chain NFT Marketplace

```typescript
// NFT sale between different chains
async function crossChainNFTSale(
    nftId: bigint,
    buyerChain: number,
    buyer: string,
    paymentToken: string,
    price: bigint
) {
    // 1. Seller: Teleport atômico do NFT
    await nft721.teleportAtomic(buyer, nftId, buyerChain);
    
    // 2. Buyer: Teleport atômico do pagamento (chain reversa)
    await paymentToken.teleportAtomic(seller, price, sellerChain);
    
    // 3. Both execute or both revert
    // 4. Cross-chain atomicity guarantee
}
```

### Case 3: Gaming Asset Migration

```typescript
// Game asset migration between chains
async function migrateGameAssets(
    player: string,
    assets: GameAsset[],
    destChain: number
) {
    const batchRequests = assets.map(asset => ({
        to: player,
        value: asset.amount,
        chainId: destChain
    }));
    
    // Batch teleport atômico
    await gameToken.batchTeleportAtomic(batchRequests);
    
    // All assets migrate together or none migrate
}
```

---

## 🛡️ Security and Guarantees

### Security Properties

#### **Guaranteed Atomicity**
```
PROPRIEDADE: ∀ teleport_atomico(asset, origem, destino)
GARANTIA: (asset ∈ origem ∧ asset ∉ destino) ∨ (asset ∉ origem ∧ asset ∈ destino)
NUNCA: asset ∈ origem ∧ asset ∈ destino (duplicação)
NUNCA: asset ∉ origem ∧ asset ∉ destino (perda)
```

#### **Reentrancy Protection**
```solidity
bool private processing;

modifier nonReentrant() {
    require(!processing, "Contract is processing another transaction.");
    processing = true;
    _;
    processing = false;
}
```

### Integrity Validations

#### **Resource ID Validation**
```solidity
function sendTeleport(...) internal {
    require(resourceId != bytes32(0), "Token not registered.");
    // Only registered tokens can teleport
}
```

#### **Chain ID Validation**
```solidity
function _raylsSendToResourceId(uint256 _dstChainId, ...) internal {
    require(_dstChainId != endpoint.getChainId(), "Cannot send to same chain");
    // Prevents infinite loops
}
```

#### **Amount Validation**
```solidity
function _lock(address to, uint256 amount) internal {
    require(amount > 0, "Amount must be greater than 0");
    require(to != address(0), "Invalid recipient");
}
```

---

## 📊 Performance and Optimizations

### Performance Metrics

#### **Gas Costs (estimate)**
```
ERC20 Atomic Teleport:     ~180-220k gas
ERC721 Atomic Teleport:    ~160-200k gas  
ERC1155 Atomic Teleport:   ~200-250k gas
Batch Teleport (10 items):  ~600-800k gas
```

#### **Cross-Chain Latency**
```
Message Processing:   ~10-30 segundos
Unlock Execution:    ~5-15 segundos
Total Time (success): 15-45 segundos
```

### Implemented Optimizations

#### **Batch Operations**
```solidity
// Instead of N separate transactions
for (uint i = 0; i < N; i++) {
    teleportAtomic(requests[i]);  // N * gas_cost
}

// One batch transaction
batchTeleportAtomic(allRequests);  // ~0.6 * N * gas_cost
```

#### **Efficient Data Structures**
```solidity
// Optimized mapping for O(1) lookup
mapping(string => AtomicTeleportMessage) public atomicTeleportMessages;

// Packed struct for storage savings
struct AtomicTeleportMessage {
    Utils.MessageStatus status; // 1 byte
}
```

#### **Event-Driven Architecture**
```solidity
// Events for efficient off-chain tracking
event AtomicMessageTeleportStartedBatch(string[] msgIds);
event AtomicMessageStatusChangedBatch(string[] msgIds, Utils.MessageStatus status);

// Relayers can monitor events instead of polling
```

---

## 🔧 Configuration and Deployment

### System Setup

#### **1. Deploy Sequence**
```bash
# Deploy em cada chain
1. Deploy TeleportV1 (apenas Private Hub)
2. Deploy ERC20Handler, ERC721Handler, ERC1155Handler  
3. Deploy DvpTeleport, EnygmaTeleport (if needed)
4. Configure Resource IDs
5. Configure Cross-Chain Endpoints
```

#### **2. Parameter Configuration**
```solidity
// Handler Configuration  
address public endpoint;     // Endpoint address for each chain
bytes32 public resourceId;   // Unique ID for each token
```

#### **3. Permissions Setup**
```solidity
// Only endpoint can call receive methods
modifier receiveMethod() {
    require(msg.sender == address(endpoint), "Only endpoint can call");
    _;
}

// Only Private Hub can send Resource IDs
modifier onlyFromPrivateHub() {
    require(endpoint.getChainId() == endpoint.getPrivateHubChainId(), "Only from private hub");
    _;
}
```

### Production Monitoring

#### **Health Checks**
```solidity
// Check de status das mensagens
function getAtomicMessageStatuses(string[] calldata msgIds) 
    external view returns (MessageStatusResult[] memory);

// Check de balances locked
function getTotalLockedAmount(address token) 
    external view returns (uint256);
```

#### **Alertas Recomendados**
```typescript
// Monitor para high lock ratios
const lockedRatio = await calculateLockRatio(tokenAddress);
if (lockedRatio > 0.8) {  // 80% dos tokens locked
    alert("Alto volume de tokens em lock state!");
}
```

---

## 🚀 Exemplos de Implementação

### Exemplo 1: Cross-Chain DEX Integration

```typescript
class CrossChainDEX {
    async atomicSwap(
        fromToken: string,
        toToken: string, 
        amount: bigint,
        fromChain: number,
        toChain: number,
        slippage: number
    ) {
        // 1. Calculate expected output
        const expectedOutput = await this.getQuote(toToken, amount, toChain);
        const minOutput = expectedOutput * (100 - slippage) / 100;
        
        // 2. Setup atomic teleport with revert conditions
        const revertCondition = `if(output < ${minOutput}) revert("Slippage too high")`;
        
        // 3. Execute atomic teleport
        const txHash = await fromToken.teleportAtomic(
            this.address,
            amount,
            toChain,
            { revertCondition }
        );
        
        // 4. Wait for confirmation or revert
        return await this.waitForAtomicCompletion(txHash);
    }
}
```

### Exemplo 2: Cross-Chain Lending Protocol

```typescript
class CrossChainLending {
    async atomicBorrow(
        collateralAsset: string,
        borrowAsset: string,
        collateralAmount: bigint,
        borrowAmount: bigint,
        collateralChain: number,
        borrowChain: number
    ) {
        // 1. Teleport collateral atomically
        await collateralAsset.teleportAtomic(
            this.lendingPool,
            collateralAmount, 
            borrowChain
        );
        
        // 2. Borrow against collateral (embedded in teleport payload)
        const borrowPayload = abi.encodeWithSignature(
            "borrowWithCollateral(address,uint256,address,uint256)",
            borrower,
            borrowAmount,
            collateralAsset.address,
            collateralAmount
        );
        
        // 3. If borrow fails → collateral reverts automatically
        // 4. If successful → borrower receives tokens on borrowChain
    }
}
```

### Exemplo 3: Gaming Tournament Rewards

```typescript
class CrossChainTournament {
    async distributeRewards(
        winners: Winner[],
        rewardToken: string,
        amounts: bigint[],
        destinationChains: number[]
    ) {
        // Batch atomic distribution
        const batchRequests = winners.map((winner, i) => ({
            to: winner.address,
            value: amounts[i],
            chainId: destinationChains[i]
        }));
        
        // All winners receive rewards or no one does
        await rewardToken.batchTeleportAtomic(batchRequests);
        
        // Guarantees fairness - no partial distributions
    }
}
```

---

## 📚 References and Resources

### Main Contracts
- **TeleportV1.sol**: Central controller for atomic messages
- **RaylsErc20Handler.sol**: Handler for ERC20 tokens
- **RaylsErc721Handler.sol**: Handler for ERC721 tokens  
- **RaylsErc1155Handler.sol**: Handler for ERC1155 tokens
- **DvpTeleport.sol**: Specialized handler for DVP
- **EnygmaTeleport.sol**: Handler for private transfers

### Interfaces and Libraries
- **IRaylsEndpoint.sol**: Interface for cross-chain communication
- **MessageLib.sol**: Utilities for message encoding/decoding
- **Utils.sol**: Basic enums and data structures

### Security Patterns
- **ReentrancyGuard**: Protection against reentrancy attacks
- **Access Control**: Role-based permission management
- **Resource ID Validation**: Validation of registered tokens

### Best Practices
1. **Validate Resource IDs** before accepting teleports
2. **Use batch operations** to optimize gas costs
3. **Implement health checks** for proactive monitoring

---

*This documentation provides a complete guide to understand and implement the Atomic Teleport system from Rayls Protocol. For specific use cases, refer to the code examples and reference contracts.* 