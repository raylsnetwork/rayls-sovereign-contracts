<div align="center">

# Rayls Sovereign Contracts

**Smart contracts and tooling for the Rayls protocol — Privacy Nodes, a Private Network Hub, and privacy-preserving cross-chain messaging via Enygma.**

[![License: Apache 2.0][license-badge]][license-url]
[![Solidity][solidity-badge]][solidity-url]

[![Discord][discord-badge]][discord-url]
[![X][x-badge]][x-url]
[![LinkedIn][linkedin-badge]][linkedin-url]
[![YouTube][youtube-badge]][youtube-url]

[Quick start](#quick-start) | [Deploy](#deploy) | [Hardhat tasks](#hardhat-tasks) | [Documentation](#documentation)

</div>

## What is this?

Rayls is a privacy-preserving blockchain network built on **Privacy Nodes (PNs)**, an intermediary **Private Network Hub (PNH)**, and cross-chain messaging with end-to-end encryption via **Enygma**. This repository holds the Solidity contracts and the Hardhat + Foundry tooling that deploy and operate them: the protocol SDK, the PN/PNH/public-chain contract sets, the Enygma and DVP (Delivery-vs-Payment) modules, and the deploy/audit task suite.

## Quick Start

```bash
git submodule update --init --recursive   # Foundry deps (forge-std), tracked as a submodule
npm install
cp .env.example-local .env   # local docker-based development
# Update .env with your RPC URLs, chain IDs, and keys
```

The toolchain is dual: **Hardhat** (primary) with **Foundry** under the hood, Solidity `0.8.24`.

### Compile

```bash
npm run compile              # Full Hardhat + Forge compilation
npm run compile:subset       # Step-by-step subset compilation (for Docker)
```

### Test

```bash
npm run test:unit            # All Hardhat unit tests
npm run test:forge           # All Forge tests
npm run test:forge:security  # Security-focused Forge tests
```

### Deploy

Local development uses a docker-based stack that deploys the contracts automatically. To deploy manually against a running local network, use the Hardhat tasks:

```bash
# Private Network Hub
npx hardhat deploy:private-hub --network localPNH

# Privacy Node (per participant: localA … localF)
npx hardhat deploy:privacy-node --privacy-node A --network localA

# Public chain (per participant)
./deploy/pcDeployContractsAndUpdateEnvs.sh A localPC 7331
```

To deploy against a self-provided chain, set `PNH_RPC_URL` / `PRIVACY_NODE_RPC_URL` / `PUBLIC_CHAIN_RPC_URL` (with the matching chain IDs) in your `.env` and use the `custom_pnh` / `custom_pn` / `public_chain` networks.

### Go Bindings

```bash
npx hardhat compile
node scripts/generate-bindings.js relayer    # or governance, ops-service
./scripts/move-bindings.sh /path/to/target/repo/contracts
```

## Project Structure

```
src/                        # Solidity contracts
  privateHub/               #   ParticipantStorage, TokenRegistry, ResourceRegistry
  rayls-protocol/           #   Core protocol (Enygma, Dvp, Endpoint, MessageExecutor)
  rayls-protocol-sdk/       #   RaylsAppV1 base class, interfaces, token handlers
  rayls-node/               #   Public chain contracts (RaylsNode governance)
  dvp/                      #   Delivery vs Payment contracts
hardhat/
  tasks/                    #   Hardhat tasks (deploy, token ops, participants, e2e)
  test/                     #   Unit and integration tests
  utils/                    #   Shared utilities (env helpers, spinner, polling)
deploy/                     # Deployment shell scripts
scripts/                    # Build utilities (compilation, bindings, static analysis)
docker/                     # Docker configuration
docs/                       # Architecture, guides, and protocol documentation
```

## Hardhat Tasks

Run `npx hardhat` to see all available tasks. Key task groups:

| Scope | Examples |
|---|---|
| **Deploy** | `deploy:private-hub`, `deploy:privacy-node`, `deploy:public-chain` |
| **Tokens** | `tokens:erc20:deploy`, `tokens:erc20:mint`, `tokens:erc20:send` |
| **Enygma** | `tokens:enygma:mint`, `tokens:enygma:send-cross` |
| **DVP** | ERC721/ERC1155 deposit, swap, withdraw |
| **Participants** | `participants:add`, status/role updates |
| **Relay Auth** | `add-authorized-relayers`, `add-authorized-relayers-pnh` |

Use `npx hardhat <task> --help` for parameters.

## Documentation

- [Getting Started](docs/getting-started.md) — setup and first steps
- [Architecture Overview](docs/architecture.md) — system architecture and components
- [Solidity Style Guide](docs/solidity-style-guide.md) — code conventions
- [Testing Guide](docs/testing-guide.md) — test strategy and patterns
- [Enygma Technical Guide](docs/ENYGMA_TECHNICAL_GUIDE.md) — Enygma encryption protocol
- [Atomic Teleport Guide](docs/ATOMIC_TELEPORT_TECHNICAL_GUIDE.md) — cross-chain atomic transfers
- [DVP Commands](docs/enygma/DVP_commands.md) — Delivery vs Payment task reference
- [Complete Documentation](docs/RAYLS_COMPLETE_DOCUMENTATION.md) — full protocol reference

## Contributing

We are not accepting external contributions at this time — see [CONTRIBUTING.md](./CONTRIBUTING.md). Please also read our [Code of Conduct](./CODE_OF_CONDUCT.md).

## Security

To report a security vulnerability, see [SECURITY.md](./SECURITY.md) — please do not open a public issue.

## License

Licensed under the Apache License, Version 2.0 — see [LICENSE](./LICENSE).

This project incorporates a small amount of third-party code that remains under its own (MIT) license — the bn254 Groth16 verifier contracts (Remco Bloemen) and the Baby JubJub curve library (iden3 / yondonfu). See [NOTICE](./NOTICE) for full attribution.

Copyright 2026 Rayls Core Ltd.

[license-badge]: https://img.shields.io/badge/License-Apache_2.0-blue.svg
[license-url]: ./LICENSE
[solidity-badge]: https://img.shields.io/badge/Solidity-0.8.24-363636?logo=solidity&logoColor=white
[solidity-url]: ./foundry.toml
[discord-badge]: https://img.shields.io/badge/Discord-join%20chat-5865F2?logo=discord&logoColor=white
[discord-url]: https://discord.gg/6THZ96357r
[x-badge]: https://img.shields.io/badge/X-%40RaylsLabs-000000?logo=x&logoColor=white
[x-url]: https://x.com/RaylsLabs
[linkedin-badge]: https://img.shields.io/badge/LinkedIn-Rayls-0A66C2?logo=linkedin&logoColor=white
[linkedin-url]: https://www.linkedin.com/company/rayls/
[youtube-badge]: https://img.shields.io/badge/YouTube-Rayls-FF0000?logo=youtube&logoColor=white
[youtube-url]: https://www.youtube.com/@Rayls_blockchain
