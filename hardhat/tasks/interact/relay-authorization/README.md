# Relay Authorization Management Tasks

This directory contains Hardhat tasks for managing authorized relay addresses in the RelayAuthorizationRegistry contract within the Rayls Node ecosystem.

## Overview

The RelayAuthorizationRegistry contract maintains a list of authorized relay addresses that can perform relay operations. These scripts provide a convenient interface for managing this authorization list.

## Environment Variables

The scripts use the following environment variable to locate the RelayAuthorizationRegistry contract:

- `RELAY_AUTHORIZATION_REGISTRY`: The deployed RelayAuthorizationRegistry contract address

This variable is automatically set when you deploy contracts using the deployment scripts in this project.

Other environment variables used:
- `RPC_URL`: The JSON-RPC endpoint URL for blockchain interaction
- `PRIVATE_KEY_SYSTEM`: The private key used for signing transactions (required for add/remove operations)

## Available Tasks

### 1. `add-authorized-relayers`
Add multiple relay addresses to the authorization registry.

**Usage:**
```bash
npx hardhat add-authorized-relayers \
  --relayer-addresses <ADDRESS1,ADDRESS2,ADDRESS3> \
  --network <NETWORK_NAME>
```

**Parameters:**
- `--relayer-addresses` (required): Comma-separated list of Ethereum addresses to authorize as relayers
- `--registry-address` (optional): Override the RelayAuthorizationRegistry contract address (defaults to `RELAY_AUTHORIZATION_REGISTRY` env var)
- `--rpc-url` (optional): Custom RPC URL (defaults to environment variable `RPC_URL`)
- `--private-key` (optional): Private key for transactions (defaults to environment variable `PRIVATE_KEY_SYSTEM`)

**Example:**
```bash
npx hardhat add-authorized-relayers \
  --relayer-addresses 0xabc1234567890123456789012345678901234567890,0xdef1234567890123456789012345678901234567890 \
  --network privacy_node
```

### 2. `remove-authorized-relayer`
Remove a single relay address from the authorization registry.

**Usage:**
```bash
npx hardhat remove-authorized-relayer \
  --relayer-address <ADDRESS_TO_REMOVE> \
  --network <NETWORK_NAME>
```

**Parameters:**
- `--relayer-address` (required): The Ethereum address to remove from authorized relayers
- `--registry-address` (optional): Override the RelayAuthorizationRegistry contract address (defaults to `RELAY_AUTHORIZATION_REGISTRY` env var)
- `--rpc-url` (optional): Custom RPC URL (defaults to environment variable `RPC_URL`)
- `--private-key` (optional): Private key for transactions (defaults to environment variable `PRIVATE_KEY_SYSTEM`)

**Example:**
```bash
npx hardhat remove-authorized-relayer \
  --relayer-address 0xabc1234567890123456789012345678901234567890 \
  --network privacy_node
```

### 3. `list-authorized-relayers`
List all authorized relay addresses and optionally check if a specific address is authorized.

**Usage:**
```bash
# List all authorized relayers
npx hardhat list-authorized-relayers \
  --network <NETWORK_NAME>

# Check if a specific address is authorized
npx hardhat list-authorized-relayers \
  --check-address <ADDRESS_TO_CHECK> \
  --network <NETWORK_NAME>
```

**Parameters:**
- `--registry-address` (optional): Override the RelayAuthorizationRegistry contract address (defaults to `RELAY_AUTHORIZATION_REGISTRY` env var)
- `--rpc-url` (optional): Custom RPC URL (defaults to environment variable `RPC_URL`)
- `--check-address` (optional): Check if a specific address is authorized

**Examples:**
```bash
# List all authorized relayers
npx hardhat list-authorized-relayers \
  --network privacy_node

# Check specific address authorization
npx hardhat list-authorized-relayers \
  --check-address 0xabc1234567890123456789012345678901234567890 \
  --network privacy_node
```

## Prerequisites

1. **Hardhat Configuration**: Ensure your `hardhat.config.js` includes the target network configuration
2. **Environment Variables**: Set up the required environment variables (especially `RELAY_AUTHORIZATION_REGISTRY`)
3. **Contract Deployment**: The RelayAuthorizationRegistry contract must be deployed and its address known
4. **Authentication**: For add/remove operations, you need a private key with appropriate permissions
5. **Network Access**: RPC access to the target blockchain network

## Security Considerations

- **Private Key Security**: Never commit private keys to version control. Use environment variables or secure key management
- **Address Validation**: All scripts validate Ethereum addresses before processing
- **Transaction Confirmation**: Scripts wait for transaction confirmation before reporting success
- **Permission Checks**: Ensure the signing account has the necessary permissions on the RelayAuthorizationRegistry contract

## Troubleshooting

### Missing Environment Variables
If you get an error about missing environment variables:

1. **RELAY_AUTHORIZATION_REGISTRY**: This should be set automatically after deploying contracts. Check your deployment output or run the deployment script again.
2. **RPC_URL**: Set this to your blockchain RPC endpoint
3. **PRIVATE_KEY_SYSTEM**: Set this to the private key of an account with the necessary permissions

### Override Contract Address
If you need to use a different contract address than what's in the environment variable, use the `--registry-address` parameter:

```bash
npx hardhat list-authorized-relayers \
  --registry-address 0x1234567890123456789012345678901234567890 \
  --network privacy_node
```

## Output

All scripts provide detailed console output including:
- Transaction hashes and confirmation status
- Gas usage information
- Before/after state comparisons
- Event parsing for verification
- Error handling with detailed messages

## Error Handling

The scripts include comprehensive error handling for:
- Invalid Ethereum addresses
- Network connectivity issues
- Transaction failures
- Contract interaction errors
- Missing environment variables or parameters