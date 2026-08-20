# Benchmark Tasks

## Overview
The benchmark module provides performance testing and benchmarking tools for evaluating system performance, particularly for cross-chain transfers and cryptographic operations.

## Available Tasks

### Enygma Single Transfer Benchmark
Benchmark single transfer operations using the Enygma protocol:
```bash
npx hardhat benchmark:enygma-single-transfer --pn A --iterations 100 --amount 1000
```
- `--pn`: Privacy Node identifier
- `--iterations`: Number of benchmark iterations
- `--amount`: Transfer amount for testing

### TraceQL Benchmark
Run TraceQL performance benchmarks:
```bash
npx hardhat benchmark:traceql --pn A --query "SELECT * FROM transfers" --iterations 50
```
- `--pn`: Privacy Node identifier
- `--query`: TraceQL query to benchmark
- `--iterations`: Number of benchmark iterations

## Benchmark Types

### Performance Metrics
The benchmark tasks measure various performance indicators:
- **Transaction Throughput**: Transactions per second
- **Latency**: Time to complete operations
- **Gas Usage**: Gas consumption for operations
- **Memory Usage**: Memory consumption during operations
- **CPU Usage**: CPU utilization during operations

### Cross-Chain Transfer Benchmarks
- Single transfer performance
- Batch transfer performance
- Cross-chain message relay performance
- Cryptographic operation performance

## Benchmark Results
Results are typically output in the following format:
- Average execution time
- Standard deviation
- Minimum and maximum values
- Gas consumption statistics
- Performance comparison with baseline

## Important Notes
- Benchmark tasks can be resource-intensive
- Run benchmarks in appropriate test environments
- Results may vary based on network conditions
- Use consistent parameters for comparable results
- Benchmark results help identify performance bottlenecks
- Consider running benchmarks multiple times for statistical significance
