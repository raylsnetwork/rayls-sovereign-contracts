# Enygma Cross-Chain Batching Architecture

## Overview

The Enygma protocol implements a sophisticated batching mechanism that groups multiple user transactions into a single zero-knowledge proof and Private Network Hub transaction. This dramatically improves efficiency and reduces gas costs.

## Batching Concept: Multiple Transactions → Single Proof

### Before Batching (1 tx = 1 proof)
```
User Transaction 1 → Generate Proof 1 → Send to PNH
User Transaction 2 → Generate Proof 2 → Send to PNH  
User Transaction 3 → Generate Proof 3 → Send to PNH
```

### After Batching (N txs = 1 proof)
```
User Transaction 1 ─┐
User Transaction 2 ─┤→ Collect in Block → Generate Single Proof → Send Batch to PNH
User Transaction 3 ─┘
```

## Step-by-Step Batching Process

### 1. Event Collection Phase

Multiple users call `crossTransferBatch` in the same block, each emitting separate events:

```go
// PNExecutor collects ALL events from the block
var enygmaTransferEvents []*EnygmaPnEvents.EnygmaPnEventsEnygmaSendTransferBatchPNH

for _, l := range logs {
    enygmaTransferEvent, err := enygmaPnEvents.ParseEnygmaSendTransferBatchPNH(l)
    if err == nil {
        enygmaTransferEvents = append(enygmaTransferEvents, enygmaTransferEvent) // Multiple events!
    }
}
```

### 2. Resource-Based Grouping

All events for the **same token** (resourceId) are batched together:

```go
// Group by resourceId (same token type)
enygmBatchTransfers := make(map[string][]*EnygmaPnEvents.EnygmaPnEventsEnygmaSendTransferBatchPNH)
for _, event := range enygmaTransferEvents {
    resourceId := hex.EncodeToString(event.ResourceId[:])
    
    // THIS IS THE KEY: Multiple events per resourceId
    enygmBatchTransfers[resourceId] = append(enygmBatchTransfers[resourceId], event)
}
```

### 3. Chunk Processing (The Real Batching)

Here's where **multiple user transactions** get batched into **one proof**:

```go
func (e *PNExecutor) executeEnygmaTransfers(ctx context.Context, enygmaTransferEvents map[string][]*EnygmaPnEvents.EnygmaPnEventsEnygmaSendTransferBatchPNH) error {
    for resourceId, events := range enygmaTransferEvents {
        chunkSize := 1000 // Up to 1000 user transactions in one proof!
        
        for start := 0; start < len(events); start += chunkSize {
            end := start + chunkSize
            if end > len(events) {
                end = len(events)
            }
            
            // THIS PROCESSES MULTIPLE USER TRANSACTIONS TOGETHER
            logger.Info("Executing Enygma cross transfer batch.", 
                slog.String("Resource ID", resourceId), 
                slog.String("Batch Size", fmt.Sprintf("%d", len(events[start:end]))))
                
            batchBlockNumber, err := e.handleEnygmaCrossTransferBatch(ctx, batchNumber, resourceId, events[start:end])
        }
    }
}
```

### 4. Transaction Aggregation

Multiple user transactions are combined into chain-specific batches:

```go
func (e *PNExecutor) handleEnygmaCrossTransferBatch(ctx context.Context, batchNumber uint, resourceId string, events []*EnygmaPnEvents.EnygmaPnEventsEnygmaSendTransferBatchPNH) {
    
    txsByChainID := make(map[string][]*types.EnygmaTransferBatchTx)
    
    // THIS LOOP PROCESSES MULTIPLE USER TRANSACTIONS
    for _, event := range events { // Each event = one user's transaction
        // Each user transaction can have multiple destinations
        for i, toChainId := range event.ToChainId {
            chainID := toChainId.String()
            
            txsByChainID[chainID] = append(txsByChainID[chainID], &types.EnygmaTransferBatchTx{
                MessageId:   uuid.New().String(),
                ReferenceId: event.ReferenceId, // Each user has their own reference
                FromAddress: event.From,        // Different users
                ToAmount:    event.Value[i],
                ToAddress:   event.To[i],
                ToCallables: event.Callables[i],
            })
        }
    }
    
    // Calculate TOTAL amount from ALL users
    totalAmountOfSenderPN := big.NewInt(0)
    for _, chainID := range destChainIDs {
        for _, tx := range txsByChainID[chainID.String()] {
            totalAmountOfSenderPN.Add(totalAmountOfSenderPN, tx.ToAmount) // Sum ALL users
        }
    }
}
```

### 5. Single Proof Generation for Multiple Transactions

This is the **key efficiency gain**:

```go
func initiateEnygmaCrossTransferBatch(..., events []*EnygmaPnEvents.EnygmaPnEventsEnygmaSendTransferBatchPNH, ...) {
    
    // SINGLE proof covers ALL user transactions in the batch
    proof, txCommitments, rValues, err := generateEnygmaBatchTransferProof(
        ctx, 
        proofClient, 
        resourceId, 
        anonymityIndex, 
        totalAmountOfSenderPN, // Sum of ALL users
        blockNumberPNH, 
        destChainIDs, 
        chainInfos, 
        batches,              // Contains ALL user transactions
        enygmaContract, 
        fromChainId, 
        ctsClient, 
        enygmaRepository, 
        enygmaHistoryRepository,
    )
    
    // ONE transaction to PNH contains ALL user transactions
    txTransfer, err := enygmaContract.TransferBatch(
        auth, 
        uint8(anonymityIndex), 
        txCommitments, 
        *proof,           // Single proof for all users
        destChainIDs, 
        encryptedBatches  // All user data encrypted together
    )
}
```

### 6. Private Hub Processing

The PNH receives **one transaction** containing **multiple user transactions**:

```solidity
// On Private Network Hub - ONE call handles MULTIPLE users
function TransferBatch(
    uint8 k,
    IEnygmaV1.Point[] memory txCommitments,  // Multiple commitments
    IEnygmaV1.TransferProof memory proof,    // Single proof
    uint256[] memory toChainIds,
    bytes[] memory encryptedBatches          // Multiple user data
) external {
    // Processes all users at once
}
```

### 7. Destination Chain Execution

The destination chains receive and execute the batched transactions:

```go
func (e *PNHExecutor) finishEnygmaCrossTransferBatch(ctx context.Context, batch *types.EnygmaTransferBatch) error {
    // Execute ALL user transactions in the batch
    for i, tx := range batch.Transactions {
        data, err := parsedABI.Pack("crossMint", tx.ToAddress, tx.ToAmount, tx.ReferenceId, tx.ToCallables)
        
        ethTx := ethTypes.NewTransaction(nonce+uint64(i), enygmaPnAddress, big.NewInt(0), 5000000, gasPrice, data)
        signedTx, err := ethTypes.SignTx(ethTx, ethTypes.NewEIP155Signer(e.pnChainId), privateKey)
        signedTxs = append(signedTxs, signedTx)
    }
    
    // Send ALL transactions as a batch to destination chain
    responses, err := e.ledgerClient.BatchSendTransactions(signedTxs)
}
```

## Efficiency Gains Comparison

### Before Batching (Individual Processing)
| Aspect | Cost |
|--------|------|
| **User A** | Generate proof → Send to PNH (Gas cost X) |
| **User B** | Generate proof → Send to PNH (Gas cost X) |
| **User C** | Generate proof → Send to PNH (Gas cost X) |
| **Total** | 3X gas cost, 3 PNH transactions |

### After Batching (Grouped Processing)
| Aspect | Cost |
|--------|------|
| **Users A, B, C** | Generate **1 proof** → Send **1 transaction** to PNH |
| **Total** | Much less gas, 1 PNH transaction |

## Key Configuration Parameters

```go
// Maximum transactions per batch chunk
chunkSize := 1000

// Anonymity index determines privacy level
anonymityIndex, err := getAnonymityIndex(len(enygmaParticipants))

// Supported anonymity levels:
// k = 2 (1→1 transfers)
// k = 6 (1→up to 5 transfers)
```

## Error Handling and Reverts

The system includes comprehensive error handling:

```go
// Identify failed transactions and create revert batch
revertTxs := make([]*types.EnygmaTransferBatchTx, 0)
for hash, status := range hashToStatusMap {
    if status == 0 { // Failed
        tx := hashToTxMap[hash]
        revertTxs = append(revertTxs, &types.EnygmaTransferBatchTx{
            FromAddress: tx.ToAddress,   // Switch addresses for revert
            ToAddress:   tx.FromAddress,
            ToAmount:    tx.ToAmount,
        })
    }
}

// Process reverts if any failed
if len(revertTxs) > 0 {
    err := initiateEnygmaCrossTransferBatch(ctx, blockNumber, batch.ResourceId, fromChainToTx, ...)
}
```

## Finalization Process

```go
// The finalization happens ONCE per batch, not per user
err := finalizeEnygmaCrossTransferBatch(
    ctx, 
    blockNumber, 
    resourceId, 
    fromChainId, 
    pnhClient, 
    conf, 
    ctsClient, 
    gnarkClient, 
    enygmaRepository, 
    enygmaHistoryRepository, 
    e.infra
)
```
