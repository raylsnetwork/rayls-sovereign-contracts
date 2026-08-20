# Rayls Node Tasks

This directory contains Hardhat tasks for interacting with Rayls Node components.

## Tasks Overview

- **createUser** - Create a user with auto-generated or provided credentials
- **approveUser** - Approve all pending address pairs for a user
- **tokens:register** - Register a new token on the PN TokenRegistry (privacyNodeStatus = WAITING_APPROVAL)
- **tokens:approve-pn** - Authorize a token (privacyNodeStatus = AUTHORIZED) by token address
- **tokens:approve-last-pn** - Approve (AUTHORIZE) the most recently added token
- **submitTokenToHub** - Submit a PN-authorized token to the Private Hub (private cross-chain path)
- **submitTokenToPublicChain** - Submit a PN-authorized token to the public chain (bridging path)
- **sendTokenToPublicChain** - Send ERC20 token from privacy node to public chain by private address
- **sendTokenToPublicChainErc721** - Send ERC721 NFT from privacy node to public chain by private address
- **sendTokenToPublicChainErc1155** - Send ERC1155 multi-token from privacy node to public chain by private address
- **checkPublicChainBalance** - Check balance of a token on public chain after bridging from privacy node

## Token Lifecycle

A token's lifecycle is expressed as **three independent status layers**, each with its own owner and
state machine: `privacyNodeStatus` (PN operator/admin), `hubStatus` (Private Hub, via cross-chain
callbacks), and `publicChainStatus` (relayer/bridge). Registration is **not** auto-propagated — after
the two shared prerequisites, the operator explicitly drives whichever cross-chain path(s) they need.

### Shared prerequisites

1. **Register** — `tokens:register` → `privacyNodeStatus = WAITING_APPROVAL`.
2. **Authorize on the PN** — `tokens:approve-pn` → `privacyNodeStatus = AUTHORIZED`.

### Two independent use cases (pick either, both, or neither)

These are **independent**: neither requires the other, and each only requires
`privacyNodeStatus == AUTHORIZED`.

**A. Hub registration — private cross-chain (PN ↔ PNH ↔ other PNs)**

1. `submitTokenToHub` → `hubStatus = WAITING_APPROVAL` (sends `addToken(...)` to the PNH TokenRegistry).
2. The PNH operator approves on the hub (`tokens:approve-hub`); the callback sets `hubStatus = AUTHORIZED`.

**B. Public-chain availability — external-chain bridging**

1. `submitTokenToPublicChain` → `publicChainStatus = PENDING_DEPLOYMENT`.
2. The relayer deploys on the public chain and calls `updatePublicTokenAddress`, setting
   `publicChainStatus = DEPLOYED`. Only then is the token bridgeable
   (`isTokenActiveForPublicChain == true`) and usable by the `sendTokenToPublicChain*` tasks.

A token is fully operational (`isTokenFullyOperational`) only when all three layers are
AUTHORIZED/DEPLOYED.

## tokens:register

Registers a token on the TokenRegistry contract of a Privacy Node.

### Usage

```bash
npx hardhat tokens:register \
  --pn A \
  --token-address 0x1234567890123456789012345678901234567890
```

### Parameters

- `--pn`: Privacy Node identification (A, B, C, D)
- `--token-address`: Address of the deployed token contract to register

#### Optional Parameters

- `--is-custom`: Whether the token uses a custom implementation (`true`/`false`, default `false`)
- `--rpc-url`: Custom RPC URL (overrides environment variable)
- `--private-key`: Custom private key (overrides environment variable)
- `--registry-address`: Custom DeploymentProxyRegistry address (overrides environment variable)

> **Note**: Token metadata (name, symbol, uri, standard) is read on-chain from the token by the
> registry during registration, so you don't need to provide these parameters manually. The task
> additionally reads name/symbol/standard best-effort for its console output.

### Environment Variables

The task uses the following environment variables:

- `PRIVACY_NODE_{PN}_RPC_URL`: RPC URL for the specified privacy node
- `PRIVATE_KEY_SYSTEM`: Private key for the TokenRegistry contract owner
- `PRIVACY_NODE_{PN}_DEPLOYMENT_PROXY_REGISTRY`: Address of the DeploymentProxyRegistry, used to
  resolve the `TokenRegistry` contract address

### Examples

#### Register a token
```bash
npx hardhat tokens:register \
  --pn A \
  --token-address 0x742d35cc6464c532d4c1a3d9a5a8b9a25a8c3c6c
```

### Output

When successful, the task will:

1. ✅ Register the token on TokenRegistry (`privacyNodeStatus = WAITING_APPROVAL`)
2. 📄 Display the transaction hash
3. 🏪 Show the private address (token contract address)
4. 📋 Provide next steps (PN authorization, then the hub and/or public-chain paths)

Registration is PN-local only — it does **not** propagate cross-chain. The token becomes cross-chain
available only after the operator authorizes it on the PN and then walks the hub and/or public-chain
paths (see [Token Lifecycle](#token-lifecycle)).

### Error Handling

The task handles common errors:

- **Token already exists**: Displays the existing private address and exits gracefully
- **Invalid owner**: Ensures you're using the correct private key for TokenRegistry contract
- **Invalid address**: Validates the token address format using `ethers.isAddress()`
- **Missing environment variables**: Clear error messages for required configuration
- **Contract call failures**: Handles cases where token contract doesn't implement required functions (name, symbol, GetERCStandard)
- **Insufficient permissions**: Detects and reports ownership issues

### After registration

Registration alone does not make the token cross-chain available. Continue with:

1. Authorize on the PN: `tokens:approve-pn` (`privacyNodeStatus = AUTHORIZED`).
2. Then, depending on the use case (independent — see [Token Lifecycle](#token-lifecycle)):
   - **Public-chain bridging**: `submitTokenToPublicChain` → the relayer deploys
     `PublicChainERC20`/`PublicChainERC721`/`PublicChainERC1155` on the target public chain and sets
     `publicChainStatus = DEPLOYED`. Users can then bridge with `sendTokenToPublicChain`,
     `sendTokenToPublicChainErc721`, `sendTokenToPublicChainErc1155`.
   - **Private cross-chain**: `submitTokenToHub` → the PNH operator approves (`tokens:approve-hub`).

## tokens:approve-pn

Authorizes a specific token in TokenRegistry by token address (sets `privacyNodeStatus = AUTHORIZED`).

### Usage

```bash
npx hardhat tokens:approve-pn \
  --pn A \
  --token-address 0x1234567890123456789012345678901234567890
```

### Parameters

- `--pn`: Privacy Node identification (A, B, C, D)
- `--token-address`: The token contract address to authorize

### Example

```bash
npx hardhat tokens:approve-pn \
  --pn A \
  --token-address 0x742d35cc6464c532d4c1a3d9a5a8b9a25a8c3c6c
```

## tokens:approve-last-pn

Automatically approves (sets to ACTIVE) the most recently added token in TokenRegistry.

### Usage

```bash
npx hardhat tokens:approve-last-pn --pn A
```

### Parameters

- `--pn`: Privacy Node identification (A, B, C, D)

### Optional Parameters

- `--rpc-url`: Custom RPC URL (overrides environment variables)
- `--private-key`: Custom private key (overrides environment variables)
- `--token-registry-address`: Custom TokenRegistry contract address (overrides environment variables)

### Examples

#### Approve Last Token on Ledger A
```bash
npx hardhat tokens:approve-last-pn --pn A
```

#### Approve Last Token on Ledger B with Custom RPC
```bash
npx hardhat tokens:approve-last-pn \
  --pn B \
  --rpc-url https://custom-rpc-url.com
```

### Workflow Integration

This task is particularly useful in development workflows:

1. Register a new token: `npx hardhat tokens:register --pn A --token-address 0x123...`
2. Approve it immediately: `npx hardhat tokens:approve-last-pn --pn A` (privacyNodeStatus = AUTHORIZED)
3. Then submit it to the hub and/or public chain — see [Token Lifecycle](#token-lifecycle)

> **Note**: Token information (name, symbol, standard) is automatically extracted from the contract, so you don't need to specify them manually.

## submitTokenToHub

Submits a PN-authorized token to the Private Hub — the **private cross-chain** path (use case A).
Requires `privacyNodeStatus == AUTHORIZED`; sets `hubStatus = WAITING_APPROVAL` and dispatches
`addToken(...)` to the PNH TokenRegistry. Independent of the public-chain path.

### Usage

```bash
npx hardhat submitTokenToHub \
  --pn A \
  --token-address 0x742d35cc6464c532d4c1a3d9a5a8b9a25a8c3c6c
```

### Parameters

- `--pn`: Privacy Node identification (A, B, C, D)
- `--token-address`: The private address (token contract address) to submit to the hub

After this, the PNH operator must approve the token on the hub (e.g. `npx hardhat tokens:approve-hub ...`);
the callback sets `hubStatus = AUTHORIZED`, enabling private cross-chain operations.

## submitTokenToPublicChain

Submits a PN-authorized token to the public chain — the **external-chain bridging** path (use case B).
Requires `privacyNodeStatus == AUTHORIZED` (independent of `hubStatus`); sets
`publicChainStatus = PENDING_DEPLOYMENT`.

### Usage

```bash
npx hardhat submitTokenToPublicChain \
  --pn A \
  --token-address 0x742d35cc6464c532d4c1a3d9a5a8b9a25a8c3c6c
```

### Parameters

- `--pn`: Privacy Node identification (A, B, C, D)
- `--token-address`: The private address (token contract address) to submit to the public chain

After this, the relayer deploys the token on the public chain and calls `updatePublicTokenAddress`,
setting `publicChainStatus = DEPLOYED`. Only then is the token bridgeable
(`isTokenActiveForPublicChain == true`).

## Token Status Management

See [Token Lifecycle](#token-lifecycle) for the three status layers, their owners, and the two
independent cross-chain paths.

### Status Change Events

Each status transition emits a `TokenStatusChanged` event. The relayer acts on the **public-chain**
path only after `submitTokenToPublicChain` (`publicChainStatus = PENDING_DEPLOYMENT`) — it deploys the
public token and calls `updatePublicTokenAddress` to advance the token to `DEPLOYED`. The hub path is
driven separately via `submitTokenToHub` + PNH approval.

### Environment Variables

All tasks use these environment variables:

- `PRIVACY_NODE_{PN}_RPC_URL`: RPC URL for the specified privacy node
- `PRIVATE_KEY_SYSTEM`: Private key for the TokenRegistry contract owner  
- `PRIVACY_NODE_{PN}_TOKEN_REGISTRY_ADDRESS`: Address of the TokenRegistry contract

### Error Handling

Common errors and solutions:

- **Token does not exist**: Check the private address is correct
- **Caller is not the owner**: Use the correct private key for TokenRegistry owner
- **Invalid private address format**: Must be a valid Ethereum address
- **No tokens found**: Register tokens first using `tokens:register`

## Implementation Details

### Token Information Retrieval

During `tokens:register`, the TokenRegistry reads token metadata on-chain from the token contract:

```solidity
string memory tokenName = tokenContract.name();
string memory tokenSymbol = tokenContract.symbol(); 
uint256 tokenStandard = tokenContract.GetERCStandard();
```

### Private Address Usage

When a token is successfully added, the system uses the token contract's private address as the unique identifier for cross-chain operations across all participating networks.

### Event Monitoring

Tasks emit specific events that external systems can monitor:
- `TokenAdded(address tokenAddress, string name, string symbol)` - Emitted during `tokens:register`
- `TokenStatusChanged(address tokenAddress, uint8 oldStatus, uint8 newStatus, ...)` - Emitted by status updates

Relayers and monitoring systems should listen for these events to trigger automated deployments and configuration updates.

## createUser Task Enhancement

The `createUser` task has been enhanced to automatically generate user credentials when they are not provided.

### Auto-Generation Mode

When no credentials are provided, the task automatically generates:
- **User ID**: Using `ethers.keccak256(ethers.randomBytes(32))` to create a unique 32-byte identifier  
- **Public Wallet**: Using `ethers.Wallet.createRandom()` for public chain interactions
- **Private Wallet**: Using `ethers.Wallet.createRandom()` for privacy node interactions

### Usage Examples

#### Auto-Generate All Credentials
```bash
npx hardhat createUser --pn A
```

#### Use Existing Credentials  
```bash
npx hardhat createUser \
  --pn A \
  --user-id 0x1234... \
  --public-address 0x5678... \
  --private-address 0x9abc...
```

### Security Features

When credentials are auto-generated, the task:
- Displays all generated credentials clearly in the console
- Shows both wallet addresses and their corresponding private keys
- Provides prominent security warnings about private key management
- Includes best practices for storing credentials securely

### Output Format

Auto-generated credentials are displayed in a structured format:

```
🎉 AUTO-GENERATED USER CREDENTIALS:
════════════════════════════════════════════════
👤 User ID: 0x...

🌐 PUBLIC WALLET (for public chain interactions):
   Address: 0x...
   Private Key: 0x...

🔐 PRIVATE WALLET (for privacy node interactions):  
   Address: 0x...
   Private Key: 0x...
════════════════════════════════════════════════

🔴 SECURITY WARNING:
• SAVE these private keys securely - they cannot be recovered!
• Store them in a secure password manager or encrypted file
• Never share private keys or commit them to version control
• You are responsible for the security of these credentials
```

### Validation Logic

- **All or none**: Either provide all three parameters (userId, publicAddress, privateAddress) or none for auto-generation
- **Partial parameters**: Providing only some parameters will result in an error
- **Format validation**: When provided manually, all parameters are validated for correct format

### User Approval Requirement

⚠️ **Important**: After creating a user, all address pairs are initially in **PENDING** status and **INACTIVE**. The user must be approved using the `approveUser` task before they can participate in cross-chain operations.

## approveUser

Approve all pending address pairs for a user in the UserGovernance contract on Privacy Node.

### Purpose

This task allows administrators to approve users by setting the approval status to APPROVED and activating all their pending address pairs in a single operation. It's the primary method for user approval after account creation.

### Usage

```bash
npx hardhat approveUser \
  --pn A \
  --user-id 0x1234567890123456789012345678901234567890123456789012345678901234
```

### Parameters

#### Required Parameters

- `--pn`: Privacy Node identification (A, B, C, D)
- `--user-id`: The user ID as a 32-byte hex string (bytes32)

#### Optional Parameters

- `--rpc-url`: Custom RPC URL (overrides environment variable)
- `--private-key`: Custom private key (overrides environment variable)
- `--user-governance-address`: Custom UserGovernance contract address (overrides environment variable)

### Environment Variables

The task uses the following environment variables:

- `PRIVACY_NODE_{PN}_RPC_URL`: RPC URL for the specified privacy node
- `PRIVATE_KEY_SYSTEM`: Private key for the UserGovernance contract owner
- `PRIVACY_NODE_{PN}_RAYLS_NODE_USER_GOVERNANCE`: Address of the UserGovernance contract

### Examples

#### Approve a User (Approve All Pending Address Pairs)
```bash
npx hardhat approveUser \
  --pn A \
  --user-id 0x1234567890123456789012345678901234567890123456789012345678901234
```

#### Using Custom Environment Variables
```bash
npx hardhat approveUser \
  --pn C \
  --user-id 0x1234567890123456789012345678901234567890123456789012345678901234 \
  --rpc-url https://custom-rpc-url.com \
  --user-governance-address 0x9876543210987654321098765432109876543210
```

### User Management Workflow

The typical user management workflow involves two steps:

1. **Create User**: Use `createUser` task to create a user and add address pairs (status: PENDING, INACTIVE)
2. **Approve User**: Use `approveUser` task to approve and activate all address pairs (status: APPROVED, ACTIVE)

```bash
# Step 1: Create user
npx hardhat createUser --pn A

# Step 2: Approve user (copy user ID from step 1 output)
npx hardhat approveUser \
  --pn A \
  --user-id 0x[USER_ID_FROM_STEP_1]
```

### Output

When successful, the task provides detailed feedback:

```
✅ User successfully approved!
📄 Transaction Hash: 0xabcdef...
👤 User ID: 0x1234...
⚡ Status: APPROVED & ACTIVE
🔗 Affected address pairs: 2

📋 Result:
All pending address pair(s) for this user have been approved and activated
```

### Batch Operations

This task operates on **all pending address pairs** for a given user simultaneously:
- If a user has multiple address pairs, only those in PENDING status are approved
- Already approved or rejected address pairs are not affected
- Approved address pairs are automatically set to active status

### Error Handling

The task handles common errors with clear messages:

- **Invalid user ID format**: Must be a 32-byte hex string starting with 0x
- **User does not exist**: The specified user ID is not found in UserGovernance
- **User has no address pairs**: The user exists but has no address pairs to approve
- **Missing environment variables**: Clear guidance on required configuration
- **Transaction failures**: Network or contract interaction issues

### Integration with Other Tasks

- **After createUser**: Always run `approveUser` to approve new users
- **User rejection**: Use contract functions directly to reject users if needed
- **Monitoring**: Check user status using view functions on the UserGovernance contract

### Security Considerations

- Only the UserGovernance contract owner can execute this task
- User approval affects only pending address pairs, enabling cross-chain operations
- Approval is permanent and cannot be undone through this task
- All status changes emit events for monitoring and audit purposes

## sendTokenToPublicChain

Send ERC20 token from privacy node to public chain by locking tokens on the sender side and triggering bridge operations.

### Purpose

This task allows users to bridge their ERC20 tokens from a privacy node to a public blockchain. It locks the tokens on the privacy node and emits bridge events that relayers monitor to mint corresponding tokens on the target public chain.

### Usage

```bash
npx hardhat sendTokenToPublicChain \
  --pn A \
  --token-address 0x021eB2dB34A1D23eC4Ee3d1D7f40B01f90C096FF \
  --destination-address 0x742d35cc6464c532d4c1a3d9a5a8b9a25a8c3c6c \
  --amount 100 \
  --destination-chain-id 1
```

### Parameters

#### Required Parameters

- `--pn`: Privacy node identification (A, B, C, D)
- `--token-address`: The token private address (contract address on the privacy node)
- `--destination-address`: Recipient address on the target public chain
- `--amount`: Amount of tokens to bridge (in token's base units)
- `--destination-chain-id`: Chain ID of the target public blockchain

#### Optional Parameters

- `--rpc-url`: Custom RPC URL (overrides environment variable)
- `--private-key`: Custom private key (overrides environment variable)

### Environment Variables

The task uses the following environment variables:

- `PRIVACY_NODE_{PN}_RPC_URL`: RPC URL for the specified privacy node
- `PRIVATE_KEY_SYSTEM`: Private key for the token sender
- `PRIVACY_NODE_{PN}_TOKEN_REGISTRY_ADDRESS`: Address of the TokenRegistry contract

### Examples

#### Bridge USDC to Ethereum Mainnet
```bash
npx hardhat sendTokenToPublicChain \
  --pn A \
  --token-address 0x021eB2dB34A1D23eC4Ee3d1D7f40B01f90C096FF \
  --destination-address 0x742d35cc6464c532d4c1a3d9a5a8b9a25a8c3c6c \
  --amount 100 \
  --destination-chain-id 1
```

#### Bridge Test Token to Sepolia Testnet
```bash
npx hardhat sendTokenToPublicChain \
  --pn B \
  --token-address 0x742d35cc6464c532d4c1a3d9a5a8b9a25a8c3c6c \
  --destination-address 0x123456789012345678901234567890123456789a \
  --amount 50 \
  --destination-chain-id 11155111
```

#### Using Custom RPC URL
```bash
npx hardhat sendTokenToPublicChain \
  --pn C \
  --token-address 0x9876543210987654321098765432109876543210 \
  --destination-address 0xabcdefabcdefabcdefabcdefabcdefabcdefabcd \
  --amount 25 \
  --destination-chain-id 137 \
  --rpc-url https://custom-rpc-endpoint.com
```

### Bridge Workflow

The bridging process involves several steps:

1. **Token Locking**: Tokens are locked on the privacy node (not burned)
2. **Event Emission**: A bridge event is emitted with transfer details
3. **Relayer Detection**: Bridge relayers monitor for these events
4. **Public Chain Minting**: Relayers mint equivalent tokens on the target public chain
5. **User Receipt**: User receives tokens at the specified destination address

```bash
Privacy Node (Lock) → Bridge Event → Relayers → Public Chain (Mint)
```

### Output

When successful, the task provides detailed feedback:

```
✅ Token successfully sent to public chain!
📄 Transaction Hash: 0xabcdef...
🪙 Token Address: 0x021eB2dB34A1D23eC4Ee3d1D7f40B01f90C096FF
💰 Amount: 100
🌐 From PN: A
📍 To Address: 0x742d35cc...
⛓️  To Chain ID: 1

📋 Next steps:
• Relayers will detect the bridge event
• Tokens will be minted on the target public chain
• Check the destination address on the public chain for received tokens
```

### Token Requirements

Before using this task, ensure:

- **Token exists**: The token must be deployed and registered on the privacy node
- **Token governance**: The token must be registered on TokenRegistry using `tokens:register` task
- **User registration**: The sender must be a registered user in UserGovernance
- **Sufficient balance**: The sender must have enough tokens to bridge
- **Token approval**: The token must be active in TokenRegistry (status = 2, AUTHORIZED)
- **Public mapping**: The token must have a public address mapping set by relayers

### Bridge Infrastructure

This task integrates with the Rayls bridge infrastructure:

- **Token lookup**: Uses `getTokenByAddress()` from TokenRegistry to get token details
- **Lock mechanism**: Uses `teleportToPublicChain` function to lock tokens
- **Event system**: Emits standardized bridge events for relayer consumption  
- **Relayer network**: Relies on bridge relayers to complete the transfer
- **Public chain contracts**: Requires deployed bridge contracts on target chains

### Common Use Cases

- **DeFi integration**: Bridge tokens to participate in public DeFi protocols
- **Liquidity provision**: Move tokens to public DEXs for trading
- **Multi-chain operations**: Access services available only on specific public chains
- **Asset management**: Consolidate holdings across different blockchain networks

### Security Considerations

- **Token locking**: Tokens are locked (not burned) and can potentially be unlocked
- **Relayer trust**: Bridging relies on honest relayer operations
- **Transaction finality**: Wait for sufficient confirmations before considering transfer complete
- **Address validation**: Double-check destination address as transfers are irreversible

## sendTokenToPublicChainErc721

Send ERC721 NFT from privacy node to public chain by burning the token on the sender side and triggering bridge operations.

### Purpose

This task allows users to bridge their ERC721 tokens (NFTs) from a privacy node to a public blockchain. It burns the NFT on the privacy node and emits bridge events that relayers monitor to mint the corresponding NFT on the target public chain.

### Usage

```bash
npx hardhat sendTokenToPublicChainErc721 \
  --pn A \
  --token-address 0x021eB2dB34A1D23eC4Ee3d1D7f40B01f90C096FF \
  --token-id 123 \
  --destination-address 0x742d35cc6464c532d4c1a3d9a5a8b9a25a8c3c6c \
  --destination-chain-id 1
```

### Parameters

#### Required Parameters

- `--pn`: Privacy node identification (A, B, C, D)
- `--token-address`: The token private address (NFT contract address on the privacy node)
- `--token-id`: The unique ID of the NFT to be transferred
- `--destination-address`: Recipient address on the target public chain
- `--destination-chain-id`: Chain ID of the target public blockchain

#### Optional Parameters

- `--rpc-url`: Custom RPC URL (overrides environment variable)
- `--private-key`: Custom private key (overrides environment variable)

### Environment Variables

The task uses the following environment variables:

- `PRIVACY_NODE_{PN}_RPC_URL`: RPC URL for the specified privacy node
- `PRIVATE_KEY_USER`: Private key for the NFT owner
- `PRIVACY_NODE_{PN}_TOKEN_REGISTRY_ADDRESS`: Address of the TokenRegistry contract

### Examples

#### Bridge NFT to Ethereum Mainnet
```bash
npx hardhat sendTokenToPublicChainErc721 \
  --pn A \
  --token-address 0x021eB2dB34A1D23eC4Ee3d1D7f40B01f90C096FF \
  --token-id 1234 \
  --destination-address 0x742d35cc6464c532d4c1a3d9a5a8b9a25a8c3c6c \
  --destination-chain-id 1
```

#### Bridge Art NFT to Polygon
```bash
npx hardhat sendTokenToPublicChainErc721 \
  --pn B \
  --token-address 0x742d35cc6464c532d4c1a3d9a5a8b9a25a8c3c6c \
  --token-id 456 \
  --destination-address 0x123456789012345678901234567890123456789a \
  --destination-chain-id 137
```

#### Using Custom RPC URL
```bash
npx hardhat sendTokenToPublicChainErc721 \
  --pn C \
  --token-address 0x9876543210987654321098765432109876543210 \
  --token-id 789 \
  --destination-address 0xabcdefabcdefabcdefabcdefabcdefabcdefabcd \
  --destination-chain-id 11155111 \
  --rpc-url https://custom-rpc-endpoint.com
```

### Bridge Workflow

The NFT bridging process involves several steps:

1. **Token Burning**: The specific NFT is burned on the privacy node (permanently removed)
2. **Event Emission**: A bridge event is emitted with NFT transfer details
3. **Relayer Detection**: Bridge relayers monitor for these events
4. **Public Chain Minting**: Relayers mint the equivalent NFT on the target public chain
5. **User Receipt**: User receives the NFT at the specified destination address

```bash
Privacy Node (Burn NFT) → Bridge Event → Relayers → Public Chain (Mint NFT)
```

### Output

When successful, the task provides detailed feedback:

```
✅ ERC721 token successfully sent to public chain!
📄 Transaction Hash: 0xabcdef...
🪙 Token Address: 0x021eB2dB34A1D23eC4Ee3d1D7f40B01f90C096FF
🆔 Token ID: 1234
🌐 From PN: A
📍 To Address: 0x742d35cc...
⛓️  To Chain ID: 1

📋 Next steps:
• Relayers will detect the bridge event
• Token will be minted on the target public chain
• Check the destination address on the public chain for received token
```

### Token Requirements

Before using this task, ensure:

- **NFT ownership**: The sender must own the specific NFT token ID
- **Token exists**: The NFT collection must be deployed and registered on the privacy node
- **Token governance**: The token must be registered on TokenRegistry using `tokens:register` task
- **User registration**: The sender must be a registered user in UserGovernance
- **Token approval**: The NFT collection must be active in TokenRegistry (status = 2, AUTHORIZED)
- **Public mapping**: The token must have a public address mapping set by relayers

### Bridge Infrastructure

This task integrates with the Rayls bridge infrastructure:

- **Token lookup**: Uses `getTokenByAddress()` from TokenRegistry to get token details
- **Burn mechanism**: Uses `teleportToPublicChain` function to burn the specific NFT
- **Event system**: Emits standardized bridge events for relayer consumption
- **Relayer network**: Relies on bridge relayers to complete the transfer
- **Public chain contracts**: Requires deployed bridge contracts on target chains

### Common Use Cases

- **NFT marketplaces**: Move NFTs to public marketplaces for trading
- **Gaming assets**: Transfer game items between privacy and public environments
- **Digital collectibles**: Bridge collectibles to participate in public DeFi protocols
- **Cross-chain exhibitions**: Display NFTs on different blockchain networks

### Security Considerations

- **Permanent burning**: NFTs are permanently burned on the source chain and cannot be recovered
- **Ownership verification**: Only the current owner can initiate the bridge transfer
- **Relayer trust**: Bridging relies on honest relayer operations
- **Transaction finality**: Wait for sufficient confirmations before considering transfer complete
- **Address validation**: Double-check destination address as transfers are irreversible
- **Unique tokens**: Each NFT can only exist on one chain at a time

## sendTokenToPublicChainErc1155

Send ERC1155 multi-token from privacy node to public chain by locking tokens on the sender side and triggering bridge operations.

### Purpose

This task allows users to bridge their ERC1155 tokens (multi-tokens) from a privacy node to a public blockchain. It locks the specified amount of tokens on the privacy node and emits bridge events that relayers monitor to mint corresponding tokens on the target public chain.

### Usage

```bash
npx hardhat sendTokenToPublicChainErc1155 \
  --pn A \
  --token-address 0x021eB2dB34A1D23eC4Ee3d1D7f40B01f90C096FF \
  --token-id 50 \
  --amount 100 \
  --destination-address 0x742d35cc6464c532d4c1a3d9a5a8b9a25a8c3c6c \
  --destination-chain-id 1 \
  --data 0x1234abcd
```

### Parameters

#### Required Parameters

- `--pn`: Privacy node identification (A, B, C, D)
- `--token-address`: The token private address (ERC1155 contract address on the privacy node)
- `--token-id`: The ID of the token type to be transferred
- `--amount`: Amount of tokens to bridge (in token's base units)
- `--destination-address`: Recipient address on the target public chain
- `--destination-chain-id`: Chain ID of the target public blockchain

#### Optional Parameters

- `--data`: Additional data to pass with the transfer (hex string, default: "0x")
- `--rpc-url`: Custom RPC URL (overrides environment variable)
- `--private-key`: Custom private key (overrides environment variable)

### Environment Variables

The task uses the following environment variables:

- `PRIVACY_NODE_{PN}_RPC_URL`: RPC URL for the specified privacy node
- `PRIVATE_KEY_USER`: Private key for the token sender
- `PRIVACY_NODE_{PN}_TOKEN_REGISTRY_ADDRESS`: Address of the TokenRegistry contract

### Examples

#### Bridge Gaming Assets to Ethereum Mainnet
```bash
npx hardhat sendTokenToPublicChainErc1155 \
  --pn A \
  --token-address 0x021eB2dB34A1D23eC4Ee3d1D7f40B01f90C096FF \
  --token-id 1 \
  --amount 50 \
  --destination-address 0x742d35cc6464c532d4c1a3d9a5a8b9a25a8c3c6c \
  --destination-chain-id 1
```

#### Bridge Collectibles to Polygon with Data
```bash
npx hardhat sendTokenToPublicChainErc1155 \
  --pn B \
  --token-address 0x742d35cc6464c532d4c1a3d9a5a8b9a25a8c3c6c \
  --token-id 100 \
  --amount 25 \
  --destination-address 0x123456789012345678901234567890123456789a \
  --destination-chain-id 137 \
  --data 0x68656c6c6f776f726c64
```

#### Bridge Utility Tokens to Sepolia Testnet
```bash
npx hardhat sendTokenToPublicChainErc1155 \
  --pn C \
  --token-address 0x9876543210987654321098765432109876543210 \
  --token-id 5 \
  --amount 1000 \
  --destination-address 0xabcdefabcdefabcdefabcdefabcdefabcdefabcd \
  --destination-chain-id 11155111 \
  --rpc-url https://custom-rpc-endpoint.com
```

### Bridge Workflow

The ERC1155 bridging process involves several steps:

1. **Token Locking**: The specified amount of tokens is locked on the privacy node (not burned)
2. **Event Emission**: A bridge event is emitted with transfer metadata and optional data
3. **Relayer Detection**: Bridge relayers monitor for these events
4. **Public Chain Minting**: Relayers mint equivalent tokens on the target public chain
5. **User Receipt**: User receives tokens at the specified destination address

```bash
Privacy Node (Lock Tokens) → Bridge Event → Relayers → Public Chain (Mint Tokens)
```

### Output

When successful, the task provides detailed feedback:

```
✅ ERC1155 token successfully sent to public chain!
📄 Transaction Hash: 0xabcdef...
🪙 Token Address: 0x021eB2dB34A1D23eC4Ee3d1D7f40B01f90C096FF
🆔 Token ID: 1
💰 Amount: 50
🌐 From PN: A
📍 To Address: 0x742d35cc...
⛓️  To Chain ID: 1
📊 Data: 0x1234abcd

📋 Next steps:
• Relayers will detect the bridge event
• Tokens will be minted on the target public chain
• Check the destination address on the public chain for received tokens
```

### Token Requirements

Before using this task, ensure:

- **Sufficient balance**: The sender must have enough tokens of the specified ID
- **Token exists**: The ERC1155 collection must be deployed and registered on the privacy node
- **Token governance**: The token must be registered on TokenRegistry using `tokens:register` task
- **User registration**: The sender must be a registered user in UserGovernance
- **Token approval**: The ERC1155 collection must be active in TokenRegistry (status = 2, AUTHORIZED)
- **Public mapping**: The token must have a public address mapping set by relayers

### Data Parameter

The optional `--data` parameter allows passing additional metadata with the transfer:

- **Format**: Must be a valid hex string (e.g., "0x" for empty, "0x1234abcd" for data)
- **Use cases**: Transfer metadata, recipient instructions, or application-specific data
- **Validation**: Automatically validated for proper hex format
- **Default**: Empty bytes ("0x") if not specified

### Bridge Infrastructure

This task integrates with the Rayls bridge infrastructure:

- **Token lookup**: Uses `getTokenByAddress()` from TokenRegistry to get token details
- **Lock mechanism**: Uses `teleportToPublicChain` function to lock tokens with metadata
- **Event system**: Emits standardized bridge events for relayer consumption
- **Relayer network**: Relies on bridge relayers to complete the transfer
- **Public chain contracts**: Requires deployed bridge contracts on target chains

### Common Use Cases

- **Gaming ecosystems**: Bridge game assets and currencies between privacy and public chains
- **Loyalty programs**: Transfer reward tokens to public marketplaces
- **Multi-token collections**: Bridge specific quantities of collectible items
- **Utility tokens**: Move functional tokens for cross-chain protocol participation
- **Fractional ownership**: Bridge portions of tokenized assets

### Security Considerations

- **Token locking**: Tokens are locked (not burned) and can potentially be unlocked on failure
- **Balance verification**: Sender must have sufficient balance of the specific token ID
- **Relayer trust**: Bridging relies on honest relayer operations
- **Transaction finality**: Wait for sufficient confirmations before considering transfer complete
- **Address validation**: Double-check destination address as transfers are irreversible
- **Data integrity**: Ensure data parameter contains expected information for the recipient

## Unit Testing

### Running Rayls Node Unit Tests

The Rayls Node contracts include comprehensive unit test coverage for all core components.

#### Run All Unit Tests
```bash
# Run all Rayls Node unit tests
npx hardhat test hardhat/test/unit/rayls-node/

# Run with verbose logging
TEST_LOGGING_LEVEL=0 npx hardhat test hardhat/test/unit/rayls-node/
```

#### Run Individual Contract Tests
```bash
# RNEndpointV1 - Cross-chain messaging and relayer management
npx hardhat test hardhat/test/unit/rayls-node/privacy-node/RNEndpointV1.test.ts

# TokenRegistryV1 - Token lifecycle and status management
npx hardhat test hardhat/test/unit/rayls-node/privacy-node/TokenRegistryV1.test.ts

# RNUserGovernanceV1 - User management and address pair approval
npx hardhat test hardhat/test/unit/rayls-node/privacy-node/RNUserGovernanceV1.test.ts

# RNMessageExecutorV1 - Message execution and gas handling
npx hardhat test hardhat/test/unit/rayls-node/privacy-node/RNMessageExecutorV1.test.ts
```

#### Test Coverage
- **RNEndpointV1**: Message sending/receiving, relayer authorization, nonce management, replay protection
- **TokenRegistryV1**: Token registration, status transitions, public address mapping, data consistency
- **RNUserGovernanceV1**: User creation, address pair management, approval workflows, status management
- **RNMessageExecutorV1**: Message execution, error handling, gas consumption, access control

#### Test Configuration
Set environment variables for test customization:
```bash
# Enable detailed logging
export TEST_LOGGING_LEVEL=0

# Run specific test pattern
npx hardhat test --grep "should approve user"
```

The unit tests provide comprehensive validation of contract functionality, security features, and edge cases to ensure reliable operation of the Rayls Node infrastructure.

## Integration Testing

### Public Chain Bridge Integration Tests

The Rayls Node includes comprehensive end-to-end integration tests for public chain bridging functionality. These tests validate the complete workflow from user creation to token transfer verification on public chains.

#### Test Coverage

The integration test suite covers all three token standards:

- **ERC20 Integration Test** (`Erc20-public-chain.ts`): Tests fungible token bridging to public chains
- **ERC721 Integration Test** (`Erc721-public-chain.ts`): Tests NFT bridging with ownership verification  
- **ERC1155 Integration Test** (`Erc1155-public-chain.ts`): Tests multi-token bridging including batch operations

#### Prerequisites

Before running integration tests, ensure your environment has:

```bash
# Required environment variables
PUBLIC_CHAIN_RPC_URL=http://public-chain:8845    # Public chain RPC endpoint
PUBLIC_CHAIN_ID=7331                       # Public chain ID
PRIVACY_NODE_A_RPC_URL=http://privacy-node-a:8545 # Privacy node RPC
PRIVATE_KEY_SYSTEM=0x...                    # System private key
PRIVACY_NODE_A_TOKEN_REGISTRY_ADDRESS=0x...
PRIVACY_NODE_A_RAYLS_NODE_USER_GOVERNANCE=0x...
PRIVACY_NODE_A_RAYLS_NODE_ENDPOINT_ADDRESS=0x...
```

#### Running Integration Tests

##### Individual Tests

```bash
# Test ERC20 public chain bridging
npm run test:e2e-erc20-public

# Test ERC721 NFT public chain bridging  
npm run test:e2e-erc721-public

# Test ERC1155 multi-token public chain bridging
npm run test:e2e-erc1155-public
```

##### Complete Public Chain Test Suite

```bash
# Run all public chain integration tests
npm run test:e2e-public
```

##### Direct Hardhat Commands

```bash
# Individual tests
npx hardhat test hardhat/test/e2e/Erc20-public-chain.ts
npx hardhat test hardhat/test/e2e/Erc721-public-chain.ts  
npx hardhat test hardhat/test/e2e/Erc1155-public-chain.ts
```

#### Test Workflow

Each integration test follows this comprehensive workflow:

1. **User Setup**:
   - Auto-generates user credentials (userId, publicWallet, privateWallet)
   - Creates user in UserGovernance contract
   - Approves user for cross-chain operations

2. **Token Deployment**:
   - Deploys token contract using user's private key
   - Mints initial tokens/NFTs to user's privacy node address
   - Verifies token ownership and balances

3. **Token Registration**:
   - Registers token in TokenRegistry contract
   - Updates token status to ACTIVE (triggers relayer)
   - Waits for relayer to deploy public token with exponential backoff

4. **Public Chain Mapping Discovery**:
   - Polls `getPublicAddressByPrivateAddress()` until mapping is available
   - Verifies relayer has successfully deployed public token
   - Retrieves public token contract address

5. **Cross-Chain Transfer**:
   - Calls `teleportToPublicChain()` using user's private key
   - Sends tokens to user's public wallet address
   - Locks/burns tokens on privacy node

6. **Balance Verification**:
   - Verifies token locking on privacy node
   - Continuously polls public chain balance with exponential backoff
   - Confirms tokens received at user's public address
   - Validates transfer completion

#### Expected Test Output

Successful test runs display detailed progress:

```
🚀 Starting ERC20 Public Chain Transfer E2E Test
📝 Step 1: Creating user...
✅ User created with public address: 0x1234...
📝 Step 2: Approving user...
✅ User approved
📝 Step 3: Deploying ERC20 token...
✅ ERC20 token deployed at: 0x5678...
📝 Step 4: Registering token...
✅ Token registered
📝 Step 5: Approving token...
✅ Token approved and activated
📝 Step 6: Waiting for relayer to register token on public chain...
✅ Public token deployed at: 0x9abc...
📝 Step 7: Sending tokens to public chain...
✅ Tokens sent to public chain
📝 Step 8: Verifying balances...
✅ Privacy node balance: 2000
✅ Public chain balance verified: 1000
✅ Balance verification completed successfully!
```

#### Integration with Rayls Node Tasks

The integration tests utilize the same underlying functionality as manual tasks:

- **User Management**: Equivalent to `createUser` and `approveUser` tasks
- **Token Registration**: Equivalent to `tokens:register` and `tokens:approve-pn` tasks
- **Cross-Chain Transfer**: Equivalent to `sendTokenToPublicChain*` tasks
- **Balance Verification**: Uses same logic as `checkPublicChainBalance` task

#### Timing and Reliability

The tests implement robust timing mechanisms:

- **Exponential Backoff**: Automatic retry with increasing delays for network operations
- **Relayer Timing**: Waits for relayers to process token approval and deploy public contracts
- **Network Propagation**: Accounts for block confirmation times on both chains
- **Timeout Handling**: Comprehensive timeout management prevents hanging tests

#### Troubleshooting

**Common Issues**:

- **Environment Variables**: Ensure all required RPC URLs and addresses are configured
- **Network Connectivity**: Verify both privacy node and public chain are accessible
- **Relayer Status**: Confirm relayers are running and processing events
- **Gas Limits**: Ensure sufficient gas is available for contract deployments
- **Symbol Conflicts**: Tests use unique symbols to prevent collision with existing tokens

**Debug Mode**:
```bash
# Run tests with detailed logging
TEST_LOGGING_LEVEL=0 npx hardhat test hardhat/test/e2e/Erc20-public-chain.ts
```

The integration tests provide comprehensive validation that the complete public chain bridging workflow operates correctly in a live environment.

## checkPublicChainBalance

Check the balance of a token on a public chain after it has been bridged from a privacy node using `sendTokenToPublicChain`.

### Purpose

This task allows users to verify that their tokens were successfully bridged to a public chain by checking the balance at the destination address. It automatically fetches the public token address using the private token address and queries the balance on the target public chain.

### Usage

```bash
npx hardhat checkPublicChainBalance \
  --private-token-address 0x1234567890123456789012345678901234567890 \
  --user-address 0x742d35cc6464c532d4c1a3d9a5a8b9a25a8c3c6c \
  --destination-chain-id 1 \
  --pn A
```

### Parameters

#### Required Parameters

- `--private-token-address`: The token contract address on the privacy node (where the token was bridged from)
- `--user-address`: The user address to check balance for on the public chain
- `--destination-chain-id`: The chain ID of the public blockchain where tokens were bridged to
- `--pn`: Privacy Node identification (A, B, C, D)

#### Optional Parameters

- `--token-id`: Token ID for ERC1155 tokens (required for ERC1155, ignored for ERC20/ERC721)
- `--public-rpc-url`: Custom RPC URL for the public chain (overrides environment variable)
- `--private-rpc-url`: Custom RPC URL for the privacy node (overrides environment variable)
- `--private-key`: Custom private key (overrides environment variable)

### Environment Variables

The task uses the following environment variables:

- `PRIVACY_NODE_{PN}_RPC_URL`: RPC URL for the specified privacy node
- `PRIVATE_KEY_SYSTEM`: Private key for accessing the privacy node contracts
- `PRIVACY_NODE_{PN}_TOKEN_REGISTRY_ADDRESS`: Address of the TokenRegistry contract
- `PUBLIC_CHAIN_{CHAIN_ID}_RPC_URL` or `RPC_URL_CHAIN_{CHAIN_ID}`: RPC URL for the public chain

### Examples

#### Check USDC Balance After Bridging to Ethereum
```bash
npx hardhat checkPublicChainBalance \
  --private-token-address 0x1234567890123456789012345678901234567890 \
  --user-address 0x742d35cc6464c532d4c1a3d9a5a8b9a25a8c3c6c \
  --destination-chain-id 1 \
  --pn A
```

#### Check Balance with Custom RPC URL
```bash
npx hardhat checkPublicChainBalance \
  --private-token-address 0x1234567890123456789012345678901234567890 \
  --user-address 0x742d35cc6464c532d4c1a3d9a5a8b9a25a8c3c6c \
  --destination-chain-id 137 \
  --pn B \
  --public-rpc-url https://polygon-rpc.com
```

#### Check NFT Balance After Bridging
```bash
npx hardhat checkPublicChainBalance \
  --private-token-address 0xabcdefabcdefabcdefabcdefabcdefabcdefabcd \
  --user-address 0x123456789012345678901234567890123456789a \
  --destination-chain-id 1 \
  --pn C
```

#### Check ERC1155 Balance After Bridging
```bash
npx hardhat checkPublicChainBalance \
  --private-token-address 0xfedcbafedcbafedcbafedcbafedcbafedcbafedcba \
  --user-address 0x987654321098765432109876543210987654321b \
  --destination-chain-id 137 \
  --pn D \
  --token-id 100
```

### How It Works

The task follows this process:

1. **Validation**: Validates input parameters and checks required environment variables
2. **Privacy Node Connection**: Connects to the specified privacy node
3. **Token Lookup**: Queries `TokenRegistryV1.getPublicAddressByPrivateAddress()` to get the public token address
4. **Token Verification**: Verifies the token exists and has a public address mapping
5. **Public Chain Connection**: Connects to the destination public chain
6. **Balance Query**: Queries the token balance using the appropriate ERC standard (ERC20/ERC721)
7. **Result Display**: Shows comprehensive balance information

### Output

When successful, the task provides detailed information:

```
✅ Public chain token balance retrieved successfully!
📄 Privacy Node: A
🏦 Private Token Address: 0x1234...
🌐 Public Token Address: 0x5678...
🪙 Token Name: USD Coin
🎫 Token Symbol: USDC
📊 Token Standard: ERC20
👤 User Address: 0x742d...
⛓️  Chain ID: 1
💰 Balance: 100.0 USDC
🔢 Raw Balance: 100000000
```

### Token Standards Support

- **ERC20**: Shows formatted balance with decimals and raw balance using `PublicChainERC20` contracts
- **ERC721**: Shows NFT count (number of tokens owned) using `PublicChainERC721` contracts  
- **ERC1155**: Shows balance for specific token ID using `PublicChainERC1155` contracts (requires `--token-id` parameter)

### Error Handling

The task handles common scenarios:

- **Invalid addresses**: Validates private token and user address formats
- **Token not found**: Checks if token exists in TokenRegistry
- **No public mapping**: Verifies public token address is set (not zero address)
- **Network issues**: Handles RPC connection failures
- **Contract errors**: Provides clear error messages for contract interaction failures

### Integration with Bridge Workflow

This task is typically used after bridging tokens:

1. Use `sendTokenToPublicChain` to bridge tokens from privacy node to public chain
2. Wait for relayers to process the bridge transaction
3. Use `checkPublicChainBalance` to verify tokens arrived at destination address

### Common Use Cases

- **Verification**: Confirm successful token bridging after using `sendTokenToPublicChain`
- **Balance monitoring**: Regular checks of token balances on public chains
- **Debugging**: Troubleshoot bridging issues by verifying token mappings and balances
- **Auditing**: Track token distribution across multiple chains