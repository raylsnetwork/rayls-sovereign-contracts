# DVP WITH ERC721

## Overview
The ERC721 DVP module provides zero-knowledge proof-based operations for non-fungible tokens, enabling secure cross-chain NFT swaps and transfers with privacy guarantees.

## Available Tasks

### Deploy ERC721 DVP
```bash
npx hardhat dvp:erc721:deploy --pn A --name enygma-dvp-erc721-rayls --uri https://example.com/ --symbol DVP721
```
- `--pn`: Privacy Node identifier
- `--name`: Token name
- `--uri`: Base URI for token metadata
- `--symbol`: Token symbol

### Mint ERC721 DVP
```bash
npx hardhat dvp:erc721:mint --pn A --to 0x7abAf1FEE956ce15345823b67A3Ae9ea9Ae52e41 --id 10 --symbol DVP721
```
- `--pn`: Privacy Node identifier
- `--to`: Address that will receive the NFT
- `--id`: NFT ID to mint
- `--symbol`: Token symbol
- `--extraDataPath`: Optional path to extra data file

### Burn ERC721 DVP
```bash
npx hardhat dvp:erc721:burn --pn A --from 0x7abAf1FEE956ce15345823b67A3Ae9ea9Ae52e41 --id 10
```
- `--pn`: Privacy Node identifier
- `--from`: Address that will have NFT burned
- `--id`: NFT ID to burn

### Get ERC721 DVP Information
```bash
npx hardhat dvp:erc721:get-infos --pn A --symbol DVP721
```
- `--pn`: Privacy Node identifier
- `--symbol`: Token symbol

### Check Resource ID
```bash
npx hardhat dvp:erc721:check-resource-id --pn A --contract 0x1234567890abcdef1234567890abcdef12345678
```
- `--pn`: Privacy Node identifier
- `--contract`: Contract address to check

### Deposit to DVP
```bash
npx hardhat dvp:erc721:deposit --pn A --symbol DVP721 --id 10
```
- `--pn`: Privacy Node identifier
- `--symbol`: Token symbol
- `--id`: NFT ID to deposit

### Swap ERC721 for Enygma
```bash
npx hardhat dvp:erc721:swap-for-enygma --pn A --symbol DVP721 --id 10
```
- `--pn`: Privacy Node identifier
- `--symbol`: Token symbol
- `--id`: NFT ID to swap

### Cancel ERC721 → Enygma Swap
```bash
npx hardhat dvp:erc721:enygma:cancel --pn A --shared-id 0xc43c1e24e1884c4e28a16bbd9506f60b5ca9f18fc90635e729d3cfe13abcf002 --nft-id 10 --nft-symbol ENYGMA_DVP721 --dest-chain-id 600000 --enygma-amount 100 --enygma-resource-id 0xc43c1e24e1884c4e28a16bbd9506f60b5ca9f18fc90635e729d3cfe13abcf001
```
- `--pn`: Privacy Node identifier
- `--shared-id`: Shared transaction ID to cancel
- `--nft-id`: NFT ID to refund
- `--nft-symbol`: NFT token symbol
- `--dest-chain-id`: Destination chain ID
- `--enygma-amount`: Enygma amount from the original swap
- `--enygma-resource-id`: Enygma resource ID from the original swap

### Swap Enygma for ERC721
```bash
npx hardhat dvp:enygma:721:swap --pn A --symbol enygma-rayls --nft-id 10 --nft-resource-id 0xb10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6 --amount 1 --chain-id 12346 --shared-id 0xc43c1e24e1884c4e28a16bbd9506f60b5ca9f18fc90635e729d3cfe13abcf002 --nft-amount-or-one 1
```
- `--pn`: Privacy Node identifier
- `--symbol`: Enygma token symbol
- `--nft-id`: NFT ID to receive
- `--nft-resource-id`: NFT resource ID
- `--amount`: Enygma amount to swap
- `--chain-id`: Destination chain ID
- `--shared-id`: Shared transaction ID
- `--nft-amount-or-one`: NFT amount (should be 1 for ERC721)

### Cancel Enygma → ERC721 Swap
```bash
npx hardhat dvp:enygma:erc721:cancel --pn A --symbol enygma-rayls --amount 1 --shared-id 0xc43c1e24e1884c4e28a16bbd9506f60b5ca9f18fc90635e729d3cfe13abcf002 --chain-id 12346 --nft-id 10 --nft-resource-id 0xb10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6
```
- `--pn`: Privacy Node identifier
- `--symbol`: Enygma token symbol
- `--amount`: Enygma amount from the original swap
- `--shared-id`: Shared transaction ID to cancel
- `--chain-id`: Destination chain ID
- `--nft-id`: NFT ID from the original swap
- `--nft-resource-id`: NFT resource ID from the original swap

### Withdraw from DVP
```bash
npx hardhat dvp:erc721:withdraw --pn A --symbol DVP721 --id 10
```
- `--pn`: Privacy Node identifier
- `--symbol`: Token symbol
- `--id`: NFT ID to withdraw
