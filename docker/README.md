# Docker Setup Guide

This guide covers Docker setup and usage for the Rayls Contracts project.

## Overview

Docker provides a consistent development environment across different machines and operating systems. The project includes both development and production Docker configurations.

## Docker Images

### Development Image (`Dockerfile.dev`)
- **Purpose**: Development and testing environment
- **Base**: Node.js 18+ with development tools
- **Features**: Hot reloading, debugging tools, development dependencies

### Production Image (`Dockerfile`)
- **Purpose**: Production deployment
- **Base**: Node.js 18+ with minimal dependencies
- **Features**: Optimized for production, security hardened

## Quick Start

### 1. Build Development Image
```bash
# Build the development image
docker build -f Dockerfile.dev -t rayls-contracts:dev .

# Verify the image was created
docker images | grep rayls-contracts
```

### 2. Run Development Container
```bash
# Start development container with volume mounting
docker run -it --rm \
  -v $(pwd):/app \
  -w /app \
  -p 8545:8545 \
  rayls-contracts:dev

# Alternative: Run in detached mode
docker run -d --name rayls-dev \
  -v $(pwd):/app \
  -w /app \
  -p 8545:8545 \
  rayls-contracts:dev
```

### 3. Inside the Container
```bash
# Install dependencies
npm install

# Generate Go bindings
npm run bindings:generate

# Compile contracts
npm run compile

# Run tests
npm run test:light
```

## Docker Compose (Optional)

Create a `docker-compose.yml` file for easier management:

```yaml
version: '3.8'

services:
  rayls-dev:
    build:
      context: .
      dockerfile: Dockerfile.dev
    volumes:
      - .:/app
      - /app/node_modules
    working_dir: /app
    ports:
      - "8545:8545"
      - "3000:3000"
    environment:
      - NODE_ENV=development
    command: tail -f /dev/null

  rayls-test:
    build:
      context: .
      dockerfile: Dockerfile.dev
    volumes:
      - .:/app
    working_dir: /app
    environment:
      - NODE_ENV=test
    command: npm run test:light
```

### Using Docker Compose
```bash
# Start development environment
docker-compose up -d rayls-dev

# Run tests
docker-compose run rayls-test

# Stop all services
docker-compose down
```

## Advanced Docker Usage

### Multi-Stage Builds
```bash
# Build with multiple stages for optimization
docker build --target development -t rayls-contracts:dev .
docker build --target production -t rayls-contracts:prod .
```

### Custom Environment Variables
```bash
# Run with custom environment
docker run -it --rm \
  -v $(pwd):/app \
  -e NODE_ENV=production \
  -e LOG_LEVEL=debug \
  -e PRIVATE_KEY_SYSTEM=your_key \
  rayls-contracts:dev
```

### Network Configuration
```bash
# Create custom network
docker network create rayls-network

# Run container with custom network
docker run -it --rm \
  --network rayls-network \
  --name rayls-node \
  -v $(pwd):/app \
  rayls-contracts:dev
```

## Development Workflow

### 1. Daily Development
```bash
# Start development container
docker run -it --rm \
  -v $(pwd):/app \
  -w /app \
  rayls-contracts:dev

# Inside container: develop and test
npm run compile
npm run test:unit
npm run test:e2e-light
```

### 2. Testing in Container
```bash
# Run specific test suites
docker run --rm \
  -v $(pwd):/app \
  -w /app \
  rayls-contracts:dev \
  npm run test:e2e

# Run with coverage
docker run --rm \
  -v $(pwd):/app \
  -w /app \
  rayls-contracts:dev \
  npx hardhat coverage
```

### 3. Contract Deployment
```bash
# Deploy to local network
docker run --rm \
  -v $(pwd):/app \
  -w /app \
  -e PRIVATE_KEY_SYSTEM=your_key \
  rayls-contracts:dev \
  npx hardhat deploy:privacy-node --pn A --network localhost
```

## Troubleshooting

### Common Issues

#### Permission Denied
```bash
# Fix bindings folder permissions
sudo chmod 777 bindings/

# Or run container with proper user
docker run -it --rm \
  -v $(pwd):/app \
  -w /app \
  -u $(id -u):$(id -g) \
  rayls-contracts:dev
```

#### Volume Mount Issues
```bash
# Check volume mounting
docker run -it --rm \
  -v $(pwd):/app \
  -w /app \
  rayls-contracts:dev \
  ls -la /app

# Verify file permissions
docker run -it --rm \
  -v $(pwd):/app \
  -w /app \
  rayls-contracts:dev \
  chown -R node:node /app
```

#### Network Issues
```bash
# Check container networking
docker network ls
docker inspect rayls-network

# Reset Docker networking
docker system prune -f
docker network prune -f
```

### Performance Optimization

#### Build Optimization
```bash
# Use build cache
docker build --build-arg BUILDKIT_INLINE_CACHE=1 \
  -f Dockerfile.dev \
  -t rayls-contracts:dev .

# Multi-stage build for smaller images
docker build --target production \
  -f Dockerfile \
  -t rayls-contracts:prod .
```

#### Runtime Optimization
```bash
# Limit container resources
docker run -it --rm \
  --memory=4g \
  --cpus=2 \
  -v $(pwd):/app \
  rayls-contracts:dev

# Use tmpfs for temporary files
docker run -it --rm \
  --tmpfs /tmp \
  -v $(pwd):/app \
  rayls-contracts:dev
```

## Production Deployment

### Building Production Image
```bash
# Build production image
docker build -f Dockerfile -t rayls-contracts:latest .

# Tag for registry
docker tag rayls-contracts:latest your-registry/rayls-contracts:latest

# Push to registry
docker push your-registry/rayls-contracts:latest
```

### Production Run
```bash
# Run production container
docker run -d \
  --name rayls-prod \
  -p 8545:8545 \
  -e NODE_ENV=production \
  -e PRIVATE_KEY_SYSTEM=your_key \
  your-registry/rayls-contracts:latest

# Check logs
docker logs -f rayls-prod

# Monitor resources
docker stats rayls-prod
```

## Best Practices

### Security
- Never commit private keys or sensitive data
- Use environment variables for configuration
- Run containers with minimal privileges
- Regularly update base images

### Performance
- Use multi-stage builds for smaller images
- Optimize layer caching
- Limit container resources
- Use appropriate base images

### Development
- Use volume mounting for live code changes
- Implement proper logging
- Use health checks for production
- Document container requirements

## Support

For Docker-related issues:
1. Check this documentation
2. Review Docker logs: `docker logs <container_name>`
3. Check container status: `docker ps -a`
4. Consult Docker documentation
5. Contact the development team
