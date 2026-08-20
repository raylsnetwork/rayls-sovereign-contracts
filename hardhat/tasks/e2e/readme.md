# End-to-End Testing

## Overview
The e2e (end-to-end) module provides comprehensive testing tasks that simulate complete user workflows and system interactions, ensuring the entire system works correctly from start to finish.

## Available Tasks

### ERC20 Light End-to-End Test
Run a lightweight end-to-end test for ERC20 token operations:
```bash
npx hardhat e2e:erc20-light --pn A --amount 100 --recipient 0x1234567890abcdef1234567890abcdef12345678
```
- `--pn`: Privacy Node identifier
- `--amount`: Token amount for testing
- `--recipient`: Recipient address for the test transfer

## Test Scenarios

### ERC20 Light Test Flow
The ERC20 light test performs the following sequence:
1. **Token Deployment**: Deploy a test ERC20 token
2. **Initial Minting**: Mint initial tokens to test accounts
3. **Transfer Operations**: Execute token transfers between accounts
4. **Balance Verification**: Verify token balances after operations
5. **Cross-Chain Transfer**: Test cross-chain token transfers
6. **Final Validation**: Validate final system state

## Test Coverage
The end-to-end tests cover:
- **Smart Contract Deployment**: Contract creation and initialization
- **Token Operations**: Minting, burning, transferring
- **Cross-Chain Functionality**: Inter-network communication
- **State Consistency**: Data integrity across components
- **Error Handling**: Proper error responses and recovery
- **Performance**: Basic performance validation

## Test Environment
- Tests run against configured networks
- Uses test accounts and test tokens
- Simulates real user interactions
- Validates complete transaction flows
- Checks system state consistency

## Important Notes
- End-to-end tests require a fully configured environment
- Tests may take longer to complete than unit tests
- Ensure all required contracts are deployed
- Tests should be run in appropriate test networks
- Results provide confidence in system integration
- Failed tests indicate integration issues that need investigation
