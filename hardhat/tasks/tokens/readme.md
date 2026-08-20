# Token Management

## Overview
The tokens module provides comprehensive token management capabilities across different token standards (ERC20, ERC721, ERC1155) and the Enygma protocol. It includes operations for deployment, minting, burning, transferring, and managing token permissions.

## Token Standards

### ERC20 Tokens
Standard fungible tokens with basic operations:
- **Deployment**: Create new ERC20 tokens
- **Minting**: Generate new tokens
- **Burning**: Destroy existing tokens
- **Transfers**: Move tokens between accounts
- **Balance Management**: Check and manage token balances

### ERC721 Tokens
Non-fungible tokens with unique identifiers:
- **Deployment**: Create new ERC721 collections
- **Minting**: Generate unique tokens
- **Transfers**: Move NFTs between accounts
- **Resource ID Management**: Handle cross-chain resource identification

### ERC1155 Tokens
Multi-token standard supporting both fungible and non-fungible tokens:
- **Deployment**: Create ERC1155 contracts
- **Batch Operations**: Handle multiple token types
- **Flexible Transfers**: Support various transfer scenarios

### Enygma Tokens
Privacy-focused token implementation:
- **Privacy Features**: Enhanced privacy capabilities
- **Cross-Chain Support**: Native cross-chain functionality
- **Advanced Operations**: Specialized minting and burning

## Available Tasks

### General Token Operations
```bash
# Get all tokens
npx hardhat tokens:get-all --pn A

# Check token across all chains
npx hardhat tokens:check-all-chains --pn A --symbol "TOKEN"

# Check token resource ID
npx hardhat tokens:check-resource-id --pn A --symbol "TOKEN"

# Approve all tokens (hub) / authorize all tokens (PN)
npx hardhat tokens:approve-all-hub
npx hardhat tokens:approve-all-pn --pn A

# Approve last token
npx hardhat tokens:approve-last-hub --pn A --spender 0x1234...

# Approve last tokens (batch, hub) / authorize last n tokens (PN)
npx hardhat tokens:approve-last-batch-hub --n 3
npx hardhat tokens:approve-last-batch-pn --pn A --n 3
```

### Token Management
```bash
# Freeze token
npx hardhat tokens:freeze --pn A --symbol "TOKEN"

# Unfreeze token
npx hardhat tokens:unfreeze --pn A --symbol "TOKEN"

# Check if token is frozen
npx hardhat tokens:check-frozen --pn A --symbol "TOKEN"
```

## Submodules

### [ERC20 Tokens](./erc20/readme.md)
Complete ERC20 token management including deployment, minting, burning, and transfers.

### [ERC721 Tokens](./erc721/readme.md)
NFT management with deployment, minting, and cross-chain operations.

### [ERC1155 Tokens](./erc1155/readme.md)
Multi-token standard management with batch operations and flexible transfers.

### [Enygma Tokens](./enygma/readme.md)
Privacy-focused token operations with enhanced cross-chain capabilities.

## Important Notes
- All token operations require appropriate permissions
- Cross-chain operations may take time to complete
- Resource IDs are essential for cross-chain token identification
- Token freezing affects all operations on that token
- Approval operations are required before transfers
- Enygma tokens provide enhanced privacy features