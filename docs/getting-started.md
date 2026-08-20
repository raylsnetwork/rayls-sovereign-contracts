# Getting Started with Rayls Contracts

This guide will help you set up and start working with the Rayls Contracts repository.

## Prerequisites

- Node.js (v16 or later)
- npm or yarn
- Git
- Docker (optional, for containerized development)

## Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/your-org/rayls-contracts.git
   cd rayls-contracts
   ```

2. Install dependencies:
   ```bash
   npm install
   ```

3. Set up your environment:
   ```bash
   cp .env.example .env
   ```
   Edit the `.env` file with your configuration.

## Development Setup

### Local Development

1. Start the local development network:
   ```bash
   npm run dev
   ```

2. Run tests:
   ```bash
   npm test
   ```

### Docker Development

1. Build the Docker image:
   ```bash
   docker build -t rayls-contracts .
   ```

2. Run the container:
   ```bash
   docker run -it rayls-contracts
   ```

## First Steps

1. Deploy a test token:
   ```bash
   npx hardhat dvp721Deploy --pn A --name test-token --symbol TEST
   ```

2. Check the deployment:
   ```bash
   npx hardhat dvp721GetInfos --pn A --symbol TEST --id 0
   ```

## Next Steps

- Read the [Architecture Overview](architecture.md) to understand the system design
- Check the [Development Guide](development.md) for detailed development workflows
- Explore the [Version 4 Documentation](../README.v4.md) for the latest features

## Troubleshooting

Common issues and solutions:

1. **Contract deployment fails**
   - Check your `.env` configuration
   - Ensure you have sufficient funds in your test account
   - Verify network connectivity

2. **Tests failing**
   - Make sure all dependencies are installed
   - Check your Node.js version
   - Run `npm run clean` and try again

## Getting Help

- Check the [documentation](../README.md)
- Open an issue on GitHub
- Join our community chat 