# DeploymentProxyRegistry

## Overview
The DeploymentProxyRegistry is a smart contract that serves as a central registry for managing contract addresses in the system. It implements the UUPS (Universal Upgradeable Proxy Standard) pattern, making it upgradeable for future improvements while maintaining the same address and state.

## How it Works

### Contract Architecture
The contract uses a mapping-based storage system to maintain the relationship between contract names and their addresses. This architecture provides:
- Flexible storage for any number of contracts
- Easy lookup by contract name
- Efficient updates and removals
- Complete enumeration of all registered contracts

### Key Features
1. **Name-Based Registry**: Each contract is registered with a unique name that serves as its identifier
2. **Access Control**: Uses OpenZeppelin's AccessControl for managing administrative permissions
3. **Upgradeability**: Implements UUPS pattern for future upgrades
4. **Event Tracking**: Emits events for all important operations
5. **Enumerable**: Maintains a list of all registered contract names

### Storage Structure
- `mapping(string => address) private _contracts`: Maps contract names to their addresses
- `string[] private _contractNames`: Array of all registered contract names

### Events
- `ContractRegistered(string indexed name, address indexed contractAddress)`
- `ContractUpdated(string indexed name, address indexed oldAddress, address indexed newAddress)`
- `ContractRemoved(string indexed name, address indexed contractAddress)`

## Using the Tasks

### Prerequisites
1. Make sure you have the environment variable set:
   ```bash
   export PNH_DEPLOYMENT_PROXY_REGISTRY=<contract_address>
   ```

2. You need to have administrative rights (DEFAULT_ADMIN_ROLE) for write operations

### Available Tasks

#### 1. Query Contract Address
Get the address of a specific contract by its name:
```bash
# Command
npx hardhat deployment-proxy:get-contract --name "ResourceRegistry"

# Example Output
Getting contract address for: ResourceRegistry
Contract "ResourceRegistry" address: 0x1234...5678
```

#### 2. List All Registered Contracts
View all contracts currently registered in the system:
```bash
# Command
npx hardhat deployment-proxy:get-all-contracts --node PNH

# Example Output
Getting all registered contracts...

Registered Contracts:
ResourceRegistry: 0x1234...5678
Teleport: 0x8765...4321
Endpoint: 0xabcd...efgh
...
```

#### 3. Register a New Contract
Add a new contract to the registry:
```bash
# Command
npx hardhat deployment-proxy:register-contract \
  --name NewContract \
  --address 0x1234567890abcdef1234567890abcdef12345678 \
  --node PNH

# Example Output
Registering contract...
Name: NewContract
Address: 0x1234567890abcdef1234567890abcdef12345678
Contract registered successfully
```

#### 4. Register Multiple Contracts
Add multiple contracts at once:
```bash
# Command
npx hardhat deployment-proxy:register-contracts \
  --names Contract1,Contract2,Contract3 \
  --addresses 0x1234567890abcdef1234567890abcdef12345678,0x1234567890abcdef1234567890abcdef12345678,0x1234567890abcdef1234567890abcdef12345678 \
  --node PNH

# Example Output
Registering contracts...
Names: ["Contract1", "Contract2", "Contract3"]
Addresses: ["0x123...", "0x456...", "0x789..."]
Contracts registered successfully
```

#### 5. Update Contract Address
Update the address of an existing contract:
```bash
# Command
npx hardhat deployment-proxy:update-contract \
  --name Contract1 \
  --address 0x1234567890abcdef1234567890abcdef12345679 \
  --node PNH


# Example Output
Updating contract...
Name: ExistingContract
New Address: 0xnew...address
Contract updated successfully
```

#### 6. Remove Contract
Remove a contract from the registry:
```bash
# Command
npx hardhat deployment-proxy:remove-contract \
  --name Contract1 \
  --node PNH

# Example Output
Removing contract...
Name: ContractToRemove
Contract removed successfully
```

### Task Options
All write operations (register, update, remove) automatically include:
- `gasLimit: 5000000`
- Access control checks
- Input validation
- Event emission

### Error Handling
Common error scenarios:
1. **Invalid Address**:
   ```
   Error: Invalid contract address
   ```

2. **Duplicate Name**:
   ```
   Error: Contract name already registered
   ```

3. **Non-existent Contract**:
   ```
   Error: Contract not registered
   ```

4. **Permission Error**:
   ```
   Error: Caller is not an admin
   ```

## Standard Contract Names
The following names are used for the main system contracts:
- ResourceRegistry
- Teleport
- Endpoint
- TokenRegistry
- Proofs
- ParticipantStorage
- Dvp
- DvpTeleport
- EnygmaPNEvents

## Important Notes
- All write operations (register, update, remove) are restricted to accounts with DEFAULT_ADMIN_ROLE
- Write operations use a gasLimit of 5000000
- Contract names are case-sensitive
- When registering multiple contracts, the number of names must match the number of addresses
- Invalid or zero addresses are not allowed

## Usage in the System
The DeploymentProxyRegistry serves as a central point of truth for contract addresses in the system. This is particularly useful for:
1. **Contract Discovery**: Other contracts can look up addresses dynamically
2. **System Updates**: Easy updates of contract implementations
3. **System Monitoring**: Single point to monitor all contract deployments
4. **Access Control**: Centralized management of contract registration
5. **Upgrade Management**: Supports system-wide contract upgrades 