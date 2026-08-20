# Testing Guide

This guide covers all aspects of testing in the Rayls Contracts project, including unit tests, end-to-end tests, and performance testing.

## Table of Contents

1. [Overview](#overview)
2. [Unit Testing](#unit-testing)
3. [E2E Testing](#e2e-testing)
4. [Performance Testing](#performance-testing)
5. [Test Configuration](#test-configuration)
6. [Best Practices](#best-practices)

## Overview

The Rayls Contracts project uses a comprehensive testing strategy to ensure code quality, functionality, and performance. The testing framework is built on Hardhat with Mocha as the test runner and Chai for assertions.

### Testing Pyramid
```
    /\
   /  \     E2E Tests (Few, Slow, Expensive)
  /____\    
 /      \   Integration Tests (Some, Medium)
/________\  
Unit Tests (Many, Fast, Cheap)
```

### Test Types
- **Unit Tests**: Individual contract functions and components
- **Integration Tests**: Contract interactions and workflows
- **E2E Tests**: Complete system workflows
- **Performance Tests**: Load and stress testing

---

## Unit Testing

Unit tests verify individual contract functions and components in isolation.

### Running Unit Tests

#### All Unit Tests
```bash
# Run all unit tests
npm run test:unit

# Run with verbose output
npx hardhat test --verbose
```

#### Specific Test Categories
```bash
# Enygma contract tests
npm run test:unit-enygma

# ERC20 token tests
npm run test:unit-erc20

# Custom token tests
npm run test:unit-custom

# Specific test file
npx hardhat test hardhat/test/unit/Enygma.ts
```

#### With Coverage
```bash
# Generate coverage report
npx hardhat coverage

# Coverage with specific files
npx hardhat coverage --testfiles "hardhat/test/unit/*.ts"
```

### Test Structure

#### File Organization
```
hardhat/test/unit/
├── Enygma.ts              # Enygma contract tests
├── TokenExample.ts        # Standard token tests
├── TokenCustomExample.ts  # Custom token tests
├── ParticipantStorage.ts  # Participant management tests
└── *.ts                   # Other unit tests
```

#### Test File Structure
```typescript
import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract, Signer } from "ethers";

describe("Contract Name", function () {
  let contract: Contract;
  let owner: Signer;
  let user: Signer;

  beforeEach(async function () {
    // Setup before each test
    [owner, user] = await ethers.getSigners();
    const ContractFactory = await ethers.getContractFactory("ContractName");
    contract = await ContractFactory.deploy();
  });

  describe("Function Name", function () {
    it("should work correctly", async function () {
      // Test implementation
      const result = await contract.functionName();
      expect(result).to.equal(expectedValue);
    });

    it("should revert on invalid input", async function () {
      // Test error conditions
      await expect(
        contract.functionName(invalidInput)
      ).to.be.revertedWith("Error message");
    });
  });
});
```

### Unit Test Examples

#### Basic Function Test
```typescript
describe("ERC20 Token", function () {
  it("should mint tokens correctly", async function () {
    const amount = ethers.parseEther("100");
    await token.mint(user.address, amount);
    
    const balance = await token.balanceOf(user.address);
    expect(balance).to.equal(amount);
  });
});
```

#### Event Testing
```typescript
it("should emit Transfer event", async function () {
  const amount = ethers.parseEther("50");
  
  await expect(token.transfer(user.address, amount))
    .to.emit(token, "Transfer")
    .withArgs(owner.address, user.address, amount);
});
```

#### Access Control Testing
```typescript
it("should restrict access to admin functions", async function () {
  await expect(
    token.connect(user).adminFunction()
  ).to.be.revertedWith("AccessControl: access is denied");
});
```

---

## E2E Testing

End-to-end tests validate complete workflows and system integration across multiple contracts and networks.

### Running E2E Tests

#### All E2E Tests
```bash
# Run all E2E tests
npm run test:e2e

# Run with specific network
npx hardhat test --network hardhat
```

#### Test Categories
```bash
# Lightweight integration tests
npm run test:e2e-light

# Token-specific tests
npm run test:e2e-erc20      # ERC20 cross-chain tests
npm run test:e2e-erc721     # ERC721 NFT tests
npm run test:e2e-erc1155    # ERC1155 multi-token tests

# Protocol tests
npm run test:e2e-enygma     # Enygma protocol tests
npm run test:e2e-dvp      # DVP operations tests

# Performance tests
npm run test:mesh           # Mesh network tests
npm run test:enygma-p       # Enygma performance tests
```

### E2E Test Structure

#### Test Organization
```
hardhat/test/e2e/
├── LightTest.ts            # Basic integration tests
├── Erc20-light.ts         # Lightweight ERC20 tests
├── erc20/                 # ERC20 comprehensive tests
├── erc721/                # ERC721 NFT tests
├── erc1155/               # ERC1155 multi-token tests
├── enygma/enygma-payments # Enygma protocol tests
├── enygma/enygma-dvp      # DVP operations tests
└── performance/           # Performance and stress tests
```

#### E2E Test Example
```typescript
describe("Cross-Chain ERC20 Transfer", function () {
  it("should complete cross-chain transfer", async function () {
    // Setup networks
    const networkA = await setupNetwork("A");
    const networkB = await setupNetwork("B");
    
    // Deploy tokens
    const tokenA = await deployToken(networkA, "TestToken");
    const tokenB = await deployToken(networkB, "TestToken");
    
    // Mint initial tokens
    await tokenA.mint(user.address, ethers.parseEther("100"));
    
    // Perform cross-chain transfer
    const transferAmount = ethers.parseEther("50");
    await tokenA.crossChainTransfer(
      networkB.id,
      user.address,
      transferAmount
    );
    
    // Verify transfer completion
    const balanceB = await tokenB.balanceOf(user.address);
    expect(balanceB).to.equal(transferAmount);
  });
});
```

### E2E Test Categories

#### Light Tests
- **Purpose**: Quick setup validation and basic functionality
- **Scope**: Essential operations and core features
- **Duration**: Fast execution (< 1 minute)
- **Use Case**: CI/CD pipelines, development verification

#### Token Tests
- **ERC20**: Cross-chain transfers, swaps, and balance management
- **ERC721**: NFT operations, cross-chain movement, metadata handling
- **ERC1155**: Multi-token batch operations and flexible transfers

#### Protocol Tests
- **Enygma**: Privacy-preserving operations and cross-chain communication
- **DVP**: Zero-knowledge proof workflows and asset swaps
- **Cross-chain**: Inter-network communication and state synchronization

#### Performance Tests
- **Atomic Operations**: Transaction throughput and latency measurement
- **Mesh Networks**: Multi-node performance and scalability testing
- **Batch Processing**: Large-scale operations and resource utilization

---

## Performance Testing

Performance tests measure system behavior under various load conditions and identify bottlenecks.

### Running Performance Tests

#### Basic Performance Tests
```bash
# Atomic stability tests
npm run test:s

# Atomic performance tests
npm run test:p

# Mesh network tests
npm run test:mesh

# Enygma performance tests
npm run test:enygma-p
```

#### Custom Performance Tests
```bash
# Run with specific parameters
npx hardhat test hardhat/test/performance/CustomPerformance.ts \
  --grep "high load scenario"

# Performance with profiling
npx hardhat test --profiling \
  hardhat/test/performance/AtomicPerformance.ts
```

### Performance Test Examples

#### Load Testing
```typescript
describe("High Load Performance", function () {
  it("should handle 1000 concurrent transactions", async function () {
    const concurrentTxs = 1000;
    const promises = [];
    
    for (let i = 0; i < concurrentTxs; i++) {
      promises.push(
        token.transfer(user.address, ethers.parseEther("1"))
      );
    }
    
    const startTime = Date.now();
    await Promise.all(promises);
    const endTime = Date.now();
    
    const throughput = concurrentTxs / ((endTime - startTime) / 1000);
    expect(throughput).to.be.greaterThan(100); // 100 TPS minimum
  });
});
```

#### Memory Usage Testing
```typescript
it("should maintain stable memory usage", async function () {
  const initialMemory = process.memoryUsage();
  
  // Perform operations
  for (let i = 0; i < 100; i++) {
    await performOperation();
  }
  
  const finalMemory = process.memoryUsage();
  const memoryIncrease = finalMemory.heapUsed - initialMemory.heapUsed;
  
  expect(memoryIncrease).to.be.lessThan(50 * 1024 * 1024); // 50MB max
});
```

---

## Test Configuration

### Hardhat Test Configuration

#### Network Configuration
```typescript
// hardhat.config.ts
module.exports = {
  networks: {
    hardhat: {
      // Local test network
    },
    localhost: {
      url: "http://127.0.0.1:8545"
    },
    testnet: {
      url: process.env.TESTNET_RPC_URL
    }
  },
  mocha: {
    timeout: 60000, // 60 seconds
    grep: process.env.TEST_GREP, // Filter tests
    reporter: "spec"
  }
};
```

#### Test Environment Variables
```bash
# Test configuration
export NODE_ENV=test
export TEST_NETWORK=hardhat
export TEST_GREP="unit|e2e"
export TEST_TIMEOUT=60000

# Test data
export TEST_PRIVATE_KEY=0x1234...
export TEST_RPC_URL=http://localhost:8545
```

### Mocha Configuration

#### Test Runner Options
```typescript
// .mocharc.js
module.exports = {
  timeout: 60000,
  reporter: "spec",
  require: ["ts-node/register"],
  extension: ["ts"],
  spec: ["hardhat/test/**/*.ts"],
  ignore: ["hardhat/test/performance/*.ts"]
};
```

#### Test Filtering
```bash
# Run only unit tests
npm run test:unit

# Run tests matching pattern
npx hardhat test --grep "ERC20"

# Exclude tests
npx hardhat test --grep "ERC20" --invert

# Run specific test file
npx hardhat test hardhat/test/unit/Enygma.ts
```

---

## Best Practices

### Test Organization

#### File Naming
- Use descriptive names: `Erc20Transfer.test.ts`
- Group related tests in directories
- Separate unit, integration, and E2E tests

#### Test Structure
- **Arrange**: Setup test data and contracts
- **Act**: Execute the function being tested
- **Assert**: Verify the expected outcome

### Test Data Management

#### Fixtures
```typescript
// Use fixtures for common test data
const setupFixture = async () => {
  const [owner, user1, user2] = await ethers.getSigners();
  const token = await deployTestToken();
  return { owner, user1, user2, token };
};
```

#### Test Accounts
```typescript
// Use Hardhat's built-in accounts
const [owner, user, admin] = await ethers.getSigners();

// Or create custom accounts
const customUser = new ethers.Wallet(
  "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
);
```

### Assertion Best Practices

#### Specific Assertions
```typescript
// Good: Specific assertions
expect(await token.balanceOf(user.address)).to.equal(expectedAmount);

// Avoid: Generic assertions
expect(await token.balanceOf(user.address)).to.be.true;
```

#### Error Testing
```typescript
// Test specific error messages
await expect(
  token.transfer(user.address, 0)
).to.be.revertedWith("Amount must be greater than 0");

// Test custom errors
await expect(
  token.adminFunction()
).to.be.revertedWithCustomError(token, "AccessDenied");
```

### Performance Considerations

#### Test Isolation
- Reset state between tests
- Use fresh contract instances
- Clean up test data

#### Efficient Testing
- Group related tests
- Use shared setup when possible
- Avoid unnecessary contract deployments

### Continuous Integration

#### CI/CD Pipeline
```yaml
# .github/workflows/test.yml
- name: Run Tests
  run: |
    npm run test:unit
    npm run test:e2e-light
    npm run test:coverage
```

#### Test Reports
```bash
# Generate test reports
npx hardhat test --reporter mocha-junit-reporter

# Coverage reports
npx hardhat coverage --reporter lcov
```

---

## Troubleshooting

### Common Test Issues

#### Timeout Errors
```bash
# Increase timeout
npx hardhat test --timeout 120000

# Check for hanging promises
# Ensure all async operations complete
```

#### Network Issues
```bash
# Reset Hardhat network
npx hardhat node --reset

# Check network configuration
npx hardhat console --network localhost
```

#### Contract Deployment Failures
```bash
# Clear Hardhat cache
npx hardhat clean

# Check contract compilation
npx hardhat compile
```

### Debugging Tests

#### Verbose Output
```bash
# Run with detailed output
npx hardhat test --verbose

# Use console.log in tests
console.log("Debug info:", await contract.getData());
```

#### Hardhat Console
```bash
# Interactive debugging
npx hardhat console --network localhost

# Test contracts interactively
const token = await ethers.getContract("TestToken");
await token.balanceOf(user.address);
```

---

## Support

For testing-related issues:
1. Check this testing guide
2. Review test examples in the codebase
3. Consult Hardhat and Mocha documentation
4. Check test logs and error messages
5. Contact the development team

### Additional Resources
- [Hardhat Testing Documentation](https://hardhat.org/docs/testing)
- [Mocha Testing Framework](https://mochajs.org/)
- [Chai Assertion Library](https://www.chaijs.com/)
- [Ethers.js Testing](https://docs.ethers.org/v6/testing/)
