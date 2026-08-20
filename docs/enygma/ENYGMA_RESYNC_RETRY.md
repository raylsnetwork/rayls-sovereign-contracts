# Enygma Resync and Retry Mechanism

## Overview

The Enygma synchronization service includes a robust retry mechanism for handling checkpoint validation failures and missing history scenarios. This document explains how the resync process works and the retry logic implemented to ensure reliable checkpoint processing.

## Components

### EnygmaSyncService

The main service responsible for finalizing checkpoints and managing the retry mechanism.

**Key Fields:**
- `retryAttempts map[string]int` - In-memory storage tracking retry attempts per checkpoint ID
- `maxRetries int` - Maximum retry attempts before forcing resync (default: 3)

## Retry Logic

### When Retries Are Triggered

The retry mechanism is activated in two scenarios:

1. **Missing History**: When no history records are found for a checkpoint
2. **Invalid Checkpoint**: When checkpoint validation fails (balance mismatch)

### Retry Process Flow

```
Checkpoint Processing
       |
   Validation
       |
   [FAIL] ─── Check Attempts < 3? ─── YES ─── Increment & Skip
       |                                           |
       |                                      Log Attempt
       |                                           |
       |                                       Continue
       |
      NO
       |
  Force Resync ─── Execute ResyncEnygma
       |
  Log Success ─── Continue Processing
```

### Retry Attempts Tracking

- **Key**: Checkpoint ID (`checkpoint.ID` - database ID converted to hex string)
- **Value**: Current attempt count (0-3)
- **Storage**: In-memory map for performance

## Resync Process

### ResyncEnygma Function

Located in `relayer/executor/enygma_resync_service.go`:

1. **Resource Lock**: Prevents concurrent resync operations
2. **Block Retrieval**: Gets the latest finalized block for the resource
3. **Event Refetching**: Re-processes blockchain events from the pending block
4. **Cleanup**: Removes resource lock after completion

### Force Resync Conditions

Resync is **forced** when:
- Retry attempts reach the maximum limit (3 attempts)
- Critical validation failures occur
- Resource lock conflicts are resolved

## Implementation Details

### Checkpoint Validation Scenarios

#### Scenario 1: No History Found
```go
if !exists || len(checkpointHistory) == 0 {
    attempts := s.retryAttempts[checkpoint.ID]
    if attempts < s.maxRetries {
        s.retryAttempts[checkpoint.ID] = attempts + 1
        // Skip resync, continue to next checkpoint
        continue
    }
    // Force resync after max retries
    s.enygmaResyncService.ResyncEnygma(ctx, checkpoint.ResourceId)
}
```

#### Scenario 2: Checkpoint Validation Failed
```go
if !isCheckpointValid {
    attempts := s.retryAttempts[checkpoint.ID]
    if attempts < s.maxRetries {
        s.retryAttempts[checkpoint.ID] = attempts + 1
        // Skip resync, continue to next checkpoint
        continue
    }
    // Force resync after max retries
    s.enygmaResyncService.ResyncEnygma(ctx, checkpoint.ResourceId)
}
```

### Cleanup Strategy

**Automatic Cleanup**: Retry attempts are cleaned up after successful checkpoint finalization:
```go
// After successful finalizeCheckpoint
delete(s.retryAttempts, checkpoint.ID)
```

**Benefits**:
- Prevents memory leaks
- Resets retry count for future processing
- Handles both success and failure cases

## Configuration

### Default Settings
- **Max Retries**: 3 attempts before forcing resync
- **Storage**: In-memory map (resets on service restart)
- **Cleanup**: Automatic after successful finalization

### Customization
The `maxRetries` value can be modified in the `NewEnygmaSyncService` constructor if different retry limits are needed.

## Logging

The system provides detailed logging for monitoring:

- **Retry Increment**: `"No history found, incrementing retry count"`
- **Force Resync**: `"Max retries reached, forcing resync"`
- **Cleanup**: `"Cleaned up retry attempts for finalized checkpoint"`

## Error Handling

- **Resync Failures**: Logged but don't stop processing other checkpoints
- **Lock Conflicts**: Handled gracefully with skip logic
- **Memory Management**: Automatic cleanup prevents unbounded growth

## Benefits

1. **Resilience**: Handles temporary network or blockchain issues
2. **Performance**: Avoids unnecessary resync operations
3. **Resource Efficiency**: In-memory tracking with automatic cleanup
4. **Monitoring**: Comprehensive logging for debugging
5. **Consistency**: Ensures checkpoint integrity through validation

## Considerations

- **Service Restart**: Retry counts are lost (in-memory storage)
- **Concurrent Processing**: Single-instance design (no distributed state)
- **Resource Locking**: Prevents concurrent resync operations on same resource