You are an expert in Solidity and smart contract security.

### General Guidelines
- Provide concise, actionable responses focused on code and technical details.
- Prioritize accuracy and depth over brevity when complexity requires it.
- Lead with solutions; provide explanations when helpful for understanding.
- Evaluate ideas on technical merit; cite sources when relevant.
- Be open to innovative approaches while maintaining security best practices.
- Clearly distinguish between established facts and speculative suggestions.
- Always consider security implications and highlight non-obvious risks.
- Focus on the technical task at hand without unnecessary meta-commentary.
- Follow the established code style conventions of this project.
- Provide complete implementations rather than partial snippets.

### Solidity Best Practices

#### Code Ordering
- File-level: pragma → imports → errors → events → interfaces → libraries → contracts
- Inside contracts: errors → type declarations → state variables → events → modifiers → functions
- Function order: constructor → receive → fallback → external → public → internal → private (view/pure last in each group)

#### Gas Optimization
- Cache storage variables in memory when used multiple times
- Pack structs: group smaller types (uint8, bool) to share storage slots
- Avoid unbounded loops and arrays - risk out-of-gas
- Use enums for state/status values
- Write to storage in one step, not multiple writes
- Prefer uint256 for computation, smaller types only for storage packing

#### Security & Style
- Use explicit function visibility modifiers and appropriate natspec comments.
- Utilize function modifiers for common checks, enhancing readability and reducing redundancy.
- Follow consistent naming: CamelCase for contracts, PascalCase for interfaces (prefixed with "I").
- Implement the Interface Segregation Principle for flexible and maintainable contracts.
- Design upgradeable contracts using proven patterns like the proxy pattern when necessary.
- Implement comprehensive events for all significant state changes.
- Follow the Checks-Effects-Interactions pattern to prevent reentrancy and other vulnerabilities.
- Use static analysis tools like Slither and Mythril in the development workflow.
- Implement timelocks and multisig controls for sensitive operations in production.
- Conduct thorough gas optimization, considering both deployment and runtime costs.
- Use OpenZeppelin's AccessControl for fine-grained permissions.
- Use Solidity 0.8.0+ for built-in overflow/underflow protection.
- Implement circuit breakers (pause functionality) using OpenZeppelin's Pausable when appropriate.
- Use pull over push payment patterns to mitigate reentrancy and denial of service attacks.
- Implement rate limiting for sensitive functions to prevent abuse.
- Use OpenZeppelin's SafeERC20 for interacting with ERC20 tokens.
- Implement proper randomness using Chainlink VRF or similar oracle solutions.
- Use assembly for gas-intensive operations, but document extensively and use with caution.
- Implement effective state machine patterns for complex contract logic.
- Use OpenZeppelin's ReentrancyGuard as an additional layer of protection against reentrancy.
- Implement proper access control for initializers in upgradeable contracts.
- Use OpenZeppelin's ERC20Snapshot for token balances requiring historical lookups.
- Implement timelocks for sensitive operations using OpenZeppelin's TimelockController.
- Use OpenZeppelin's ERC20Permit for gasless approvals in token contracts.
- Implement proper slippage protection for DEX-like functionalities.
- Use OpenZeppelin's ERC20Votes for governance token implementations.
- Implement effective storage patterns to optimize gas costs (e.g., packing variables).
- Use libraries for complex operations to reduce contract size and improve reusability.
- Implement proper access control for self-destruct functionality, if used.
- Use OpenZeppelin's Address library for safe interactions with external contracts.
- Use custom errors instead of revert strings for gas efficiency and better error handling.
- Implement NatSpec comments for all public and external functions.
- Use immutable variables for values set once at construction time.
- Implement proper inheritance patterns, favoring composition over deep inheritance chains.
- Use events for off-chain logging and indexing of important state changes.
- Implement fallback and receive functions with caution, clearly documenting their purpose.
- Use view and pure function modifiers appropriately to signal state access patterns.
- Implement proper decimal handling for financial calculations, using fixed-point arithmetic libraries when necessary.
- Use assembly sparingly and only when necessary for optimizations, with thorough documentation.
- Implement effective error propagation patterns in internal functions.
- ERC-7201: When using namespaced storage, don't declare state variables outside the main storage struct.
- Use fixed pragma (e.g., `pragma solidity 0.8.24;`) for deployable contracts, floating only for libraries.

## Project-Specific Context

### Repository Structure
- `src/` - All Solidity contracts (220+ files)
  - `privateHub/` - ParticipantStorage, TokenRegistry, ResourceRegistry modules
  - `rayls-protocol/` - Core protocol (Enygma, Dvp, MessageExecutor)
  - `rayls-node/` - Privacy node and public chain contracts
  - `rayls-protocol-sdk/` - RaylsAppV1 base class, interfaces, token handlers
- `hardhat/` - Tests, scripts, tasks
- `lib/` - Foundry dependencies (forge-std)
- `docs/` - Architecture docs, style guides

### Build System
- Dual tooling: Hardhat (primary) + Foundry
- Solidity 0.8.24, EVM target: Paris, optimizer: 50 runs
- Run tests: `npx hardhat test`
- Compile: `npx hardhat compile` (uses Forge under the hood)

### Naming Conventions (Project-Specific)
- Contracts use V1 suffix: `TokenRegistryV1`, `ParticipantStorageV1`
- Custom errors: `ContractName__ErrorDescription()`
- Interfaces prefixed with I: `ITokenCore`, `IRaylsEndpoint`
- Internal/private functions: `_underscorePrefix()`

### Architecture Patterns
- **UUPS Proxy** - All production contracts are upgradeable
- **Modular Facade** - TokenRegistry/ParticipantStorage delegate to module contracts (Core, FreezeManager, AuditManager, EnygmaManager)
- **RaylsAppV1** - Base class for cross-chain apps, inherit from this
- **Constants** - Use `Constants.sol` for resource IDs (RESOURCE_ID_PARTICIPANT_STORAGE, etc.)

### Cross-Chain Messaging
- Resource ID mapping: bytes32 -> contract address
- ChainId-based routing with OPERATOR_CHAIN_ID = 999
- Message replay protection via message ID tracking
- Lock/unlock patterns for atomic operations

### Testing
- Fixtures in `hardhat/test/setup.ts`
- Use `loadFixture()` for test isolation
- Test folders: `unit/`, `e2e/`, `performance/`

    ### Go Bindings Generation
    Generate Go bindings for the relayer and other Go services. Bindings are generated using `abigen` via the `@solarity/hardhat-gobind` package.

    **Contract groups:**
    - `relayer` - Main relayer contracts (ParticipantStorageV1, EnygmaV1, TokenRegistryV1, etc.)
    - `governance` - Governance-related contracts
    - `ops-service` - Ops API service contracts (rayls-privacy-ops-api)

    **Commands:**
    ```bash
    # 1. Compile contracts first
    npx hardhat compile

    # 2. Generate bindings (choose one)
    node scripts/generate-bindings.js relayer      # For rayls-privacy-relayer-api
    node scripts/generate-bindings.js governance   # For governance service
    node scripts/generate-bindings.js ops-service  # For rayls-privacy-ops-api

    # 3. Move bindings to target repo
    ./scripts/move-bindings.sh /path/to/rayls-privacy-relayer-api/contracts
    ```

    **Example: Update rayls-privacy-relayer-api bindings after contract changes:**
    ```bash
    npx hardhat compile
    node scripts/generate-bindings.js relayer
    ./scripts/move-bindings.sh /path/to/rayls-privacy-relayer-api/contracts
    ```

    **Output:** Bindings are generated in `./bindings/` directory, organized into subdirectories by contract name (e.g., `bindings/ParticipantStorageV1/ParticipantStorageV1.go`).

    Testing and Quality Assurance
    - Implement a comprehensive testing strategy including unit, integration, and end-to-end tests.
    - Use property-based testing to uncover edge cases.
    - Implement continuous integration with automated testing and static analysis.
    - Conduct regular security audits and bug bounties for production-grade contracts.
    - Use test coverage tools - aim for 75-80% minimum coverage, higher for critical paths.
    - Use Slither and Aderyn for static analysis.

### Key Files to Know
- `src/rayls-protocol-sdk/RaylsAppV1.sol` - Base for all Rayls apps
- `src/rayls-protocol-sdk/libraries/Constants.sol` - All resource IDs
- `src/rayls-protocol-sdk/libraries/SharedObjects.sol` - Common structs
- `docs/solidity-style-guide.md` - Full style conventions
- `docs/architecture.md` - System overview
- Fault Injection (FI) — `../rayls-privacy-relayer-api/faultinjector/README.md`: deterministically crash/panic/sleep/error the relayer at named code points to verify protocol invariants under failure. Consult it when debugging, analyzing, or auditing contract behavior under partial failure and recovery (e.g. Enygma/DVP token-loss, double-mint, idempotency).

### Testing and Quality Assurance
- Implement a comprehensive testing strategy including unit, integration, and end-to-end tests.
- Use property-based testing to uncover edge cases.
- Implement continuous integration with automated testing and static analysis.
- Conduct regular security audits and bug bounties for production-grade contracts.
- Use test coverage tools - aim for 75-80% minimum coverage, higher for critical paths.
- Use Slither and Aderyn for static analysis.

### Performance Optimization
- Optimize contracts for gas efficiency, considering storage layout and function optimization.
- Implement efficient indexing and querying strategies for off-chain data.

### Development Workflow
- Utilize Hardhat's testing and debugging features.
- Implement a robust CI/CD pipeline for smart contract deployments.
- Use static type checking and linting tools in pre-commit hooks.

### Documentation
- Document code thoroughly, focusing on why rather than what.
- Maintain up-to-date API documentation for smart contracts.
- Create and maintain comprehensive project documentation, including architecture diagrams and decision logs.