# Use a base image that includes Go
FROM golang:1.24.4-alpine3.22 AS gobuilder

# Install git, required for fetching Go dependencies
RUN apk add --no-cache git

# Set the working directory in the container
WORKDIR /app

# Copy the Go source file(s)
COPY ./hardhat/tasks/utils/mlkemgen /app

# Depending on the target OS and architecture, set the appropriate environment variables and build the executable
# Here, we're building for Linux as an example
RUN GOOS=linux GOARCH=amd64 go build -o mlkemgen main.go

# Stage 1: Build Environment
FROM node:22-slim AS build

# Install build dependencies and Foundry
RUN apt-get update && apt-get install -y \
    make \
    bash \
    curl \
    jq \
    python3 \
    git \
    g++ \
    && rm -rf /var/lib/apt/lists/*

SHELL ["/bin/bash", "-c"]

ENV SHELL=/bin/bash
RUN curl -L https://foundry.paradigm.xyz | bash
RUN source ~/.bashrc
ENV PATH="~/.foundry/bin:${PATH}"
RUN foundryup --install v1.4.0
RUN cp ~/.foundry/bin/* /usr/local/bin/

# Create app directory
WORKDIR /app

# Copy package.json and package-lock.json to the working directory
COPY package*.json ./
#Copy ts config
COPY tsconfig.json ./

# Install dependencies
RUN npm ci

# Copy foundry config files
COPY foundry.toml ./
COPY foundry.lock ./

# Copy source files
COPY src ./src

# Install forge-std for test files
RUN forge install foundry-rs/forge-std --no-git

# Compile contracts with Forge
RUN forge build

# Copy remaining files needed for hardhat compilation
COPY . .

# Convert Forge artifacts to Hardhat format and generate TypeChain typings
RUN npx hardhat compile

# Ensure cache directory exists
RUN mkdir -p /app/cache_hardhat

# Stage 2: Production Environment
FROM node:22-alpine3.22 AS production

# Create app directory
WORKDIR /app

# Copy the mlkemgen executable from the builder stage
COPY --from=gobuilder /app/mlkemgen /app/hardhat/tasks/utils/mlkemgen/mlkemgen

# Copy built artifacts and cache from the previous stage
COPY --from=build /app/artifacts /app/artifacts
COPY --from=build /app/cache_hardhat /app/cache_hardhat
# Forge artifacts (out/) too: some deploy tasks read them directly via
# loadForgeArtifact (out/<File>.sol/<Contract>.json), and without this the
# parallel proxy validation fails with ENOENT on out/*.json.
COPY --from=build /app/out /app/out

# Copy package.json and package-lock.json to the working directory
COPY package*.json ./
#Copy ts config
COPY tsconfig.json ./

# Copy hardhat.config.ts to allow npx hardhat usage
COPY hardhat.config.ts ./

# Copy hardhat folder to allow npx hardhat usage
COPY /hardhat ./hardhat

RUN chmod +x ./hardhat/tasks/utils/mlkemgen/mlkemgen

# Install dependencies.
#
# `--omit=dev` is NOT usable here: hardhat, @nomicfoundation/hardhat-toolbox and
# mocha are all devDependencies, and hardhat.config.ts requires them at load time
# (dropping mocha alone fails every task with "Cannot find module 'mocha'").
#
# Instead we prune what this image provably never loads. npm installs the EDR
# native binaries for *every* platform as optionalDependencies (~208MB); this
# image only ever runs as a linux container — including on macOS, where Docker
# runs it inside a linux VM — so the darwin and win32 builds are dead weight.
# All four linux variants (x64/arm64 x musl/gnu) are kept so the image still
# works on Apple Silicon and on glibc bases.
#
# prettier and ignition-ui are formatting/UI-only and unused by the deploy tasks.
# The prune must share this RUN layer: deleting in a later layer would leave the
# files in the underlying layer and save nothing.
RUN npm ci && \
    rm -rf \
      node_modules/@nomicfoundation/edr-darwin-x64 \
      node_modules/@nomicfoundation/edr-darwin-arm64 \
      node_modules/@nomicfoundation/edr-win32-x64-msvc \
      node_modules/@nomicfoundation/ignition-ui \
      node_modules/prettier \
      node_modules/prettier-plugin-solidity \
      /root/.npm

# Set entrypoint to run the CLI tasks directly
ENTRYPOINT [ "npx", "hardhat" ]

# Default command (can be overridden when running the container)
CMD [ "deployCC" ]