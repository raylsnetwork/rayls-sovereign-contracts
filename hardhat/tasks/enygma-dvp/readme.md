# DVP (Delivery versus Payment)

## Overview
The DVP module implements Delivery versus Payment settlement mechanisms for cross-chain asset swaps using zero-knowledge proofs. DVP ensures that the transfer of assets (delivery) occurs simultaneously with the transfer of payment, eliminating settlement risk where one party could default after receiving their side of the trade. Zero-knowledge proofs provide privacy-preserving verification while maintaining cryptographic integrity.

## DVP Types

### ERC721 DVP
Non-fungible token DVP operations:
- **Deployment**: Create DVP contracts for ERC721 tokens
- **Minting**: Mint ERC721 tokens for DVP operations
- **Swapping**: Atomic swap ERC721 tokens for Enygma tokens
- **Withdrawals**: Withdraw tokens from DVP contracts

### ERC1155 DVP
Multi-token DVP operations:
- **Deployment**: Create DVP contracts for ERC1155 tokens
- **Batch Operations**: Handle multiple token types efficiently
- **Flexible Swaps**: Support various atomic swap scenarios
- **Account Management**: Track balances and operations

### Enygma DVP
Privacy-focused DVP operations:
- **Deposits**: Deposit Enygma tokens into DVP contracts
- **Withdrawals**: Withdraw tokens from DVP contracts
- **Cross-Chain**: Enable cross-chain atomic swaps

## Available Tasks

For detailed command information and specific operations, please refer to the individual submodule documentation:

### [ERC721 DVP](./721/readme.md)
Complete ERC721 DVP management with deployment, minting, and swap operations.

### [ERC1155 DVP](./1155/readme.md)
Multi-token DVP operations with batch processing and flexible swaps.

### [Enygma DVP](./enygma/readme.md)
Privacy-focused DVP operations for Enygma token management.