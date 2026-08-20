# Protocol Tests

## Overview
The protocol-tests module contains specialized testing tasks designed to validate protocol security, edge cases, and malicious attack scenarios. These tests ensure the system is robust against various attack vectors and protocol violations.

## Available Tasks

### Malicious Bytecode Test
Test the system's response to malicious bytecode attempts:
```bash
npx hardhat protocol-tests:malicious-bytecode --pn A --bytecode "0x1234567890abcdef..."
```
- `--pn`: Privacy Node identifier
- `--bytecode`: Malicious bytecode to test against

## Test Categories

### Security Tests
- **Malicious Bytecode Detection**: Tests system's ability to detect and reject harmful code
- **Protocol Violation Tests**: Validates protocol rule enforcement
- **Attack Vector Simulation**: Simulates various attack scenarios
- **Edge Case Validation**: Tests boundary conditions and edge cases

### Protocol Validation
- **Smart Contract Security**: Validates contract security measures
- **Cross-Chain Protocol**: Tests cross-chain communication security
- **Access Control**: Validates permission and role enforcement
- **Data Integrity**: Tests data validation and corruption detection

## Test Scenarios

### Malicious Bytecode Test
This test validates that the system:
- Detects potentially harmful bytecode
- Rejects malicious deployment attempts
- Maintains system integrity
- Logs security violations appropriately

## Security Considerations
- Protocol tests may attempt to exploit vulnerabilities
- Run tests in isolated environments
- Monitor system logs during testing
- Document any discovered issues
- Use test accounts with limited permissions

## Important Notes
- Protocol tests are designed to break the system safely
- Always run in test environments, never in production
- Failed tests may indicate security vulnerabilities
- Successful tests confirm system robustness
- Regular protocol testing is essential for security
- Document all test results and findings
