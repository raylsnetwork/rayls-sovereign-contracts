# Setup Guide (Without Docker)

This guide covers setting up the Rayls Contracts project without Docker, using native tools and dependencies.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Installation](#installation)
3. [Configuration](#configuration)
4. [Verification](#verification)
5. [Troubleshooting](#troubleshooting)

## Prerequisites

### System Requirements
- **Operating System**: Linux, macOS, or Windows (WSL2 recommended for Windows)
- **Architecture**: x86_64, ARM64, or ARMv7
- **Memory**: Minimum 8GB RAM, recommended 16GB+
- **Storage**: Minimum 10GB free space, recommended 50GB+

### Required Software

#### Node.js and npm
```bash
# Check current versions
node --version  # Should be 18.0.0 or higher
npm --version   # Should be 8.0.0 or higher

# Install Node.js 18+ (Ubuntu/Debian)
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs

# Install Node.js 18+ (macOS)
brew install node@18
brew link node@18

# Install Node.js 18+ (Windows)
# Download from https://nodejs.org/
```

#### Go Language
```bash
# Check current version
go version  # Should be 1.19.0 or higher

# Install Go (Ubuntu/Debian)
sudo apt-get update
sudo apt-get install golang-go

# Install Go (macOS)
brew install go

# Install Go (Windows)
# Download from https://golang.org/dl/
```

#### Git
```bash
# Check current version
git --version

# Install Git (Ubuntu/Debian)
sudo apt-get install git

# Install Git (macOS)
brew install git

# Install Git (Windows)
# Download from https://git-scm.com/
```

#### Additional Tools
```bash
# Build tools (Ubuntu/Debian)
sudo apt-get install build-essential

# Python (for some dependencies)
sudo apt-get install python3 python3-pip

# Make utility
sudo apt-get install make
```

---

## Installation

### 1. Clone Repository
```bash
# Clone the repository
git clone <repository-url>
cd rayls-contracts

# Check out the desired branch/tag
git checkout main  # or specific version tag
```

### 2. Install Dependencies
```bash
# Install Node.js dependencies
npm install

# Verify installation
npm list --depth=0
```

### 3. Generate Go Bindings
```bash
# Generate Go bindings for smart contracts
npm run bindings:generate

# Move bindings to appropriate location
npm run bindings:move

# Fix permissions if needed
sudo chmod 777 bindings/
```

### 4. Compile Contracts
```bash
# Compile all smart contracts
npm run compile

# Verify compilation
ls -la artifacts/
```

---

## Configuration

### 1. Environment Setup
```bash
# Copy environment template
cp .env.example .env

# Edit environment file
nano .env  # or use your preferred editor
```

### 2. Required Environment Variables
```bash
# Core Configuration
export NODE_ENV=development
export LOG_LEVEL=info

# Blockchain Configuration
export PRIVATE_KEY_SYSTEM=your_private_key_here
export PNH_DEPLOYMENT_PROXY_REGISTRY=contract_address_here

# Network RPC URLs
export PRIVACY_NODE_A_RPC_URL=https://node-a-rpc-url
export PRIVACY_NODE_B_RPC_URL=https://node-b-rpc-url
export PRIVACY_NODE_C_RPC_URL=https://node-c-rpc-url

# Optional: Custom Networks
export CUSTOM_RPC_URL=https://custom-rpc-url
export CUSTOM_CHAIN_ID=12345
```

### 3. Configuration Files
```bash
# Create environment-specific config
mkdir -p cfg
cp cfg/config.example.json cfg/config.dev.json

# Edit configuration
nano cfg/config.dev.json
```

#### Configuration File Structure
```json
{
  "environment": "development",
  "networks": {
    "nodeA": {
      "rpcUrl": "https://node-a-rpc-url",
      "chainId": 12345,
      "name": "Node A"
    },
    "nodeB": {
      "rpcUrl": "https://node-b-rpc-url",
      "chainId": 12346,
      "name": "Node B"
    }
  },
  "contracts": {
    "deploymentProxy": "0x...",
    "privacyNode": "0x...",
    "privateHub": "0x..."
  }
}
```

### 4. Hardhat Configuration
```typescript
// hardhat.config.ts
import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "dotenv/config";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.19",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200
      }
    }
  },
  networks: {
    hardhat: {
      // Local development network
    },
    localhost: {
      url: "http://127.0.0.1:8545"
    },
    nodeA: {
      url: process.env.PRIVACY_NODE_A_RPC_URL || "",
      accounts: process.env.PRIVATE_KEY_SYSTEM ? [process.env.PRIVATE_KEY_SYSTEM] : []
    },
    nodeB: {
      url: process.env.PRIVACY_NODE_B_RPC_URL || "",
      accounts: process.env.PRIVATE_KEY_SYSTEM ? [process.env.PRIVATE_KEY_SYSTEM] : []
    }
  },
  mocha: {
    timeout: 60000
  }
};

export default config;
```

---

## Verification

### 1. Basic System Check
```bash
# Check all required tools
echo "=== System Check ==="
echo "Node.js: $(node --version)"
echo "npm: $(npm --version)"
echo "Go: $(go version)"
echo "Git: $(git --version)"
echo "Python: $(python3 --version)"

# Check project structure
echo "=== Project Structure ==="
ls -la
echo "Node modules: $(ls node_modules | wc -l) packages"
echo "Artifacts: $(ls artifacts | wc -l) files"
echo "Bindings: $(ls bindings | wc -l) files"
```

### 2. Contract Compilation Test
```bash
# Test contract compilation
npm run compile

# Check for compilation errors
if [ $? -eq 0 ]; then
  echo "✅ Contract compilation successful"
else
  echo "❌ Contract compilation failed"
  exit 1
fi
```

### 3. Basic Test Run
```bash
# Run lightweight tests
npm run test:light

# Check test results
if [ $? -eq 0 ]; then
  echo "✅ Basic tests passed"
else
  echo "❌ Basic tests failed"
  exit 1
fi
```

### 4. Hardhat Task Verification
```bash
# Check available Hardhat tasks
npx hardhat

# Test specific task
npx hardhat participants:add --help

# Verify task execution
npx hardhat utils:check-blockchain-time --pn A
```

---

## Development Workflow

### 1. Daily Development Setup
```bash
# Start development session
cd rayls-contracts

# Check environment
source .env

# Verify dependencies
npm list --depth=0

# Compile contracts (if needed)
npm run compile
```

### 2. Testing Workflow
```bash
# Run unit tests
npm run test:unit

# Run E2E tests
npm run test:e2e-light

# Run specific test category
npm run test:e2e-erc20

# Run with coverage
npx hardhat coverage
```

### 3. Contract Deployment
```bash
# Deploy to local network
npx hardhat node

# In another terminal, deploy contracts
npx hardhat deploy:privacy-node --pn A --network localhost
npx hardhat deploy:private-hub --pn A --network localhost
```

### 4. Code Quality
```bash
# Format code
npx prettier --write "**/*.{ts,js,json,md}"

# Lint code (if configured)
npx eslint "**/*.{ts,js}"

# Type checking
npx tsc --noEmit
```

---

## Troubleshooting

### Common Issues

#### Node.js Version Issues
```bash
# Check Node.js version
node --version

# If version is too old, use nvm
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.0/install.sh | bash
source ~/.bashrc
nvm install 18
nvm use 18
```

#### Permission Issues
```bash
# Fix npm permissions
sudo chown -R $USER:$GROUP ~/.npm
sudo chown -R $USER:$GROUP ~/.config

# Fix bindings permissions
sudo chmod 777 bindings/
```

#### Dependency Issues
```bash
# Clear npm cache
npm cache clean --force

# Remove node_modules and reinstall
rm -rf node_modules package-lock.json
npm install

# Check for conflicting dependencies
npm ls
```

#### Go Binding Issues
```bash
# Check Go installation
go version
go env GOPATH
go env GOROOT

# Regenerate bindings
rm -rf bindings/
npm run bindings:generate
npm run bindings:move
```

#### Contract Compilation Issues
```bash
# Clear Hardhat cache
npx hardhat clean

# Check Solidity version compatibility
npx hardhat compile --verbose

# Verify contract syntax
npx hardhat check
```

### Performance Issues

#### Memory Issues
```bash
# Increase Node.js memory limit
export NODE_OPTIONS="--max-old-space-size=8192"

# Check system memory
free -h
top

# Monitor Node.js memory usage
node --max-old-space-size=8192 node_modules/.bin/hardhat compile
```

#### Network Issues
```bash
# Check network connectivity
ping google.com
curl -I https://node-a-rpc-url

# Test RPC endpoints
npx hardhat console --network nodeA
```

### Debugging

#### Verbose Output
```bash
# Enable verbose logging
export LOG_LEVEL=debug
export DEBUG=hardhat:*

# Run with verbose output
npx hardhat compile --verbose
npx hardhat test --verbose
```

#### Hardhat Console
```bash
# Interactive debugging
npx hardhat console --network localhost

# Test contracts interactively
const accounts = await ethers.getSigners()
const balance = await ethers.provider.getBalance(accounts[0].address)
console.log("Balance:", ethers.formatEther(balance))
```

---

## Advanced Configuration

### 1. Custom Networks
```typescript
// hardhat.config.ts
networks: {
  customNetwork: {
    url: "https://custom-rpc-url",
    chainId: 12345,
    accounts: [process.env.PRIVATE_KEY_SYSTEM],
    gas: 2100000,
    gasPrice: 8000000000
  }
}
```

### 2. Environment-Specific Configs
```bash
# Create multiple environment configs
cp cfg/config.dev.json cfg/config.staging.json
cp cfg/config.dev.json cfg/config.production.json

# Use environment-specific config
export CONFIG_ENV=staging
npx hardhat deploy:privacy-node --pn A --network staging
```

### 3. Custom Scripts
```bash
# Add custom scripts to package.json
{
  "scripts": {
    "setup:dev": "npm run compile && npm run test:light",
    "setup:full": "npm run compile && npm run test",
    "deploy:all": "npm run deploy:private-hub && npm run deploy:privacy-node"
  }
}
```

---

## Best Practices

### 1. Environment Management
- Use `.env` files for sensitive data
- Never commit private keys or secrets
- Use environment-specific configurations
- Document all required environment variables

### 2. Dependency Management
- Keep dependencies up to date
- Use exact versions for critical packages
- Regular security audits with `npm audit`
- Lock file version control

### 3. Development Workflow
- Always run tests before committing
- Use meaningful commit messages
- Regular code formatting and linting
- Document complex configurations

### 4. Security
- Secure private key storage
- Use environment variables for secrets
- Regular security updates
- Access control for sensitive operations

---

## Support

For setup-related issues:
1. Check this setup guide
2. Review error messages and logs
3. Check system requirements
4. Consult troubleshooting section
5. Contact the development team

### Additional Resources
- [Node.js Documentation](https://nodejs.org/docs/)
- [Go Language Documentation](https://golang.org/doc/)
- [Hardhat Documentation](https://hardhat.org/docs)
- [Ethers.js Documentation](https://docs.ethers.org/)

### Getting Help
- **Documentation**: Check the [docs](./docs/) directory
- **Issues**: Report problems via [GitHub issues](https://github.com/your-repo/issues)
- **Discussions**: Join [community discussions](https://github.com/your-repo/discussions)
- **Team**: Contact the development team directly
