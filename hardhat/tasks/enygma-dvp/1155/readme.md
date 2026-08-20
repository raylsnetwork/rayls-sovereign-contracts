# DVP WITH ERC1155

## Overview
The ERC1155 DVP module provides zero-knowledge proof-based operations for multi-token standards, enabling secure cross-chain token swaps and transfers with privacy guarantees.

## Available Tasks

### Deploy ERC1155 DVP
```bash
npx hardhat dvp:erc1155:deploy --pn A --name enygma-dvp-erc1155-rayls --uri test://test
```
- `--pn`: Privacy Node identifier
- `--name`: Token name
- `--uri`: Base URI for token metadata

### Mint ERC1155 DVP
```bash
npx hardhat dvp:erc1155:mint --pn A --to 0x7abAf1FEE956ce15345823b67A3Ae9ea9Ae52e41 --id 10 --name enygma-dvp-erc1155-rayls --value 100
```
- `--pn`: Privacy Node identifier
- `--to`: Address that will receive the tokens
- `--id`: Token ID to mint
- `--name`: Token name
- `--value`: Amount to mint

### Burn ERC1155 DVP
```bash
npx hardhat dvp:erc1155:burn --pn A --name enygma-dvp-erc1155-rayls2 --from 0x7abAf1FEE956ce15345823b67A3Ae9ea9Ae52e41 --amount 1 --id 10
```
- `--pn`: Privacy Node identifier
- `--name`: Token name
- `--from`: Address that will have tokens burned
- `--amount`: Amount to burn
- `--id`: Token ID to burn

### Get ERC1155 DVP Balance
```bash
npx hardhat dvp:erc1155:get-balance --pn A --name enygma-dvp-erc1155-rayls --id 10 --address 0x7abAf1FEE956ce15345823b67A3Ae9ea9Ae52e41
```
- `--pn`: Privacy Node identifier
- `--name`: Token name
- `--id`: Token ID
- `--address`: Address to check balance for

### Deposit to DVP
```bash
npx hardhat dvp:erc1155:deposit --pn A --name enygma-dvp-erc1155-rayls --id 10 --amount 1
```
- `--pn`: Privacy Node identifier
- `--name`: Token name
- `--id`: Token ID to deposit
- `--amount`: Amount to deposit

### Swap Enygma for ERC1155
```bash
npx hardhat dvp:enygma:1155:swap --pn A --symbol enygma-rayls --nft-id 10 --nft-resource-id 0xb10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6 --amount 1 --chain-id 12346 --shared-id 0xc43c1e24e1884c4e28a16bbd9506f60b5ca9f18fc90635e729d3cfe13abcf002 --nft-amount-or-one 5
```
- `--pn`: Privacy Node identifier
- `--symbol`: Enygma token symbol
- `--nft-id`: Token ID to receive
- `--nft-resource-id`: Token resource ID
- `--amount`: Enygma amount to swap
- `--chain-id`: Destination chain ID
- `--shared-id`: Shared transaction ID
- `--nft-amount-or-one`: Token amount to receive

### Cancel Enygma → ERC1155 Swap
```bash
npx hardhat dvp:enygma:erc1155:cancel --pn A --symbol enygma-rayls --amount 1 --shared-id 0xc43c1e24e1884c4e28a16bbd9506f60b5ca9f18fc90635e729d3cfe13abcf002 --chain-id 12346 --nft-id 10 --nft-amount 5 --nft-resource-id 0xb10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6
```
- `--pn`: Privacy Node identifier
- `--symbol`: Enygma token symbol
- `--amount`: Enygma amount from the original swap
- `--shared-id`: Shared transaction ID to cancel
- `--chain-id`: Destination chain ID
- `--nft-id`: Token ID from the original swap
- `--nft-amount`: Token amount from the original swap
- `--nft-resource-id`: Token resource ID from the original swap

### Swap ERC1155 for Enygma
```bash
npx hardhat dvp:1155:enygma:swap --pn B --token-name enygma-dvp-erc1155-rayls --token-id 10 --token-value 50 --enygma-amount 10 --enygma-resource-id 0xc43c1e24e1884c4e28a16bbd9506f60b5ca9f18fc90635e729d3cfe13abcf001 --dest-chain-id 600000 --shared-id 0xc43c1e24e1884c4e28a16bbd9506f60b5ca9f18fc90635e729d3cfe13abcf002 --token-data 0xa80a8fcc11760162f08bb091d2c9389d07f2b73d0e996161dfac6f1043b5fc0b
```
- `--pn`: Privacy Node identifier
- `--token-name`: Token name to swap
- `--token-id`: Token ID to swap
- `--token-value`: Token amount to swap
- `--enygma-amount`: Enygma amount to receive
- `--enygma-resource-id`: Enygma resource ID
- `--dest-chain-id`: Destination chain ID
- `--shared-id`: Shared transaction ID
- `--token-data`: Additional token data

### Cancel ERC1155 → Enygma Swap
```bash
npx hardhat dvp:erc1155:enygma:cancel --pn B --name enygma-dvp-erc1155-rayls --shared-id 0xc43c1e24e1884c4e28a16bbd9506f60b5ca9f18fc90635e729d3cfe13abcf002 --chain-id 600000 --token-id 10 --token-value 50 --enygma-resource-id 0xc43c1e24e1884c4e28a16bbd9506f60b5ca9f18fc90635e729d3cfe13abcf001 --enygma-amount 10
```
- `--pn`: Privacy Node identifier
- `--name`: ERC1155 token name
- `--shared-id`: Shared transaction ID to cancel
- `--chain-id`: Destination chain ID
- `--token-id`: Token ID to refund
- `--token-value`: Token amount to refund
- `--enygma-resource-id`: Enygma resource ID from the original swap
- `--enygma-amount`: Enygma amount from the original swap

### Withdraw from DVP
```bash
npx hardhat dvp:erc1155:withdraw --pn A --name enygma-dvp-erc1155-rayls --id 10 --amount 1
```
- `--pn`: Privacy Node identifier
- `--name`: Token name
- `--id`: Token ID to withdraw
- `--amount`: Amount to withdraw