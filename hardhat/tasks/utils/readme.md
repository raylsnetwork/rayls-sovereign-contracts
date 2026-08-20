# Utility Tasks

## Overview
The utils module provides various utility tasks for system maintenance, testing, debugging, and development purposes.

## Available Tasks

### Mock Relayer
Simulate a relayer for testing purposes:
```bash
npx hardhat utils:mock-relayer --pn A --message "test message"
```
- `--pn`: Privacy Node identifier
- `--message`: Message to relay

### Check Blockchain Time
Verify the current blockchain time:
```bash
npx hardhat utils:check-blockchain-time --pn A
```
- `--pn`: Privacy Node identifier

### Decode Error Message
Decode error messages for debugging:
```bash
npx hardhat utils:decode-error-message --error "0x1234567890abcdef..."
```
- `--error`: Hex-encoded error message to decode

### Stress Test
Run stress tests on the system:
```bash
npx hardhat utils:stress-test --pn A --iterations 100
```
- `--pn`: Privacy Node identifier
- `--iterations`: Number of test iterations

### Interact Local
Interact with local contracts for development:
```bash
npx hardhat utils:interact-local --pn A --contract "ContractName" --function "functionName"
```
- `--pn`: Privacy Node identifier
- `--contract`: Contract name to interact with
- `--function`: Function name to call

### Update Rayls View Keys
Request new ML-KEM keys for encryption:
```bash
npx hardhat utils:update-rayls-view-keys --pn A
```
- `--pn`: Privacy Node identifier
- `--plpk`: (Optional) Private MASTER key. Falls back to PRIVATE_KEY_SYSTEM env var if not provided

### Deployment Proxy Helper
Helper utilities for deployment proxy operations:
```bash
npx hardhat utils:deployment-proxy-helper --pn A --action "get"
```
- `--pn`: Privacy Node identifier
- `--action`: Action to perform (get, set, etc.)

## Important Notes
- Mock relayer is for testing purposes only and should not be used in production
- Stress tests can be resource-intensive and should be run in appropriate environments
- Blockchain time checks help verify network synchronization
- Error message decoding is essential for debugging smart contract issues
- View key updates should be performed carefully to maintain system security
- Local interaction tasks are primarily for development and testing
