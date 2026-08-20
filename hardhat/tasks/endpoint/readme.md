# Endpoint Management

## Overview
The endpoint module provides tasks for checking and validating endpoint-related information, including resource ID validation and nonce parity verification.

## Available Tasks

### Check Resource ID
Verify if a resource ID exists and is valid:
```bash
npx hardhat endpoint:check-resource-id --pn A --resource-id 0x1234567890abcdef1234567890abcdef12345678
```
- `--pn`: Privacy Node identifier
- `--resource-id`: Resource ID to check

### Check Nonce Parity
Verify nonce parity between different networks or components:
```bash
npx hardhat endpoint:check-nonce-parity --pn A --nonce 123
```
- `--pn`: Privacy Node identifier
- `--nonce`: Nonce value to check for parity

## Resource ID Format
Resource IDs are 32-byte identifiers that uniquely identify resources in the system. They are typically used for:
- Token identification across networks
- Contract address mapping
- Cross-chain resource references

## Nonce Parity
Nonce parity checking ensures that transaction ordering and sequencing are consistent across different components of the system. This is crucial for:
- Maintaining transaction order
- Preventing replay attacks
- Ensuring cross-chain consistency

## Important Notes
- Resource ID checks validate the existence and format of resource identifiers
- Nonce parity verification helps maintain system integrity
- Both operations are read-only and do not modify system state
- Proper nonce management is essential for system security
