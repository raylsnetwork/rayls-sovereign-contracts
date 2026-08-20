# DVP 721 Tasks - Testing Commands

This guide provides a comprehensive list of commands for testing DVP 721 token operations.

## Token Management

### Deploy a new token
```bash
npx hardhat dvp721Deploy --pn A --name lobon10 --symbol lobos10
```
- `--pn`: Privacy Node identifier (A, B, C, D)
- `--name`: Token name
- `--symbol`: Token symbol

### Approve all tokens
```bash
npx hardhat approveAllTokens
```
> Note: After approval, run the command to put resource ID into .env file

### Mint a token
```bash
npx hardhat dvp721Mint --pn A --address 0xf9260C378ea6E428A79EAfe443BD24EA09Af8Bc9 --id 3 --symbol lobos3 --extra-data-path ./extra/dvp-721-extra-data.json
```
- `--pn`: Privacy Node identifier
- `--address`: Recipient address
- `--id`: Token ID to mint
- `--symbol`: Token symbol
- `--extra-data-path`: Path to JSON file containing extra data

### Burn a token
```bash
npx hardhat dvp721Burn --pn A --id 2 --symbol lobos12
```
- `--pn`: Privacy Node identifier
- `--id`: Token ID to burn
- `--symbol`: Token symbol

### Get token information
```bash
npx hardhat dvp721GetInfos --pn B --symbol lobos8 --id 0
```
- `--pn`: Privacy Node identifier
- `--symbol`: Token symbol
- `--id`: Token ID to query

## DVP Operations

### Deposit token into DVP
```bash
npx hardhat dvp721Deposit --pn A --symbol lobos10 --id 0
```
- `--pn`: Privacy Node identifier
- `--symbol`: Token symbol
- `--id`: Token ID to deposit

### Swap token for Enygma
```bash
npx hardhat dvp721SwapForEnygma --pn A --symbol lobos10 --id 0 --amountreceive 10 --resourceidtoreceive 0xc65a7bb8d6351c1cf70c95a316cc6a92839c986682d98bc35f958f4883f9d2a8 --destinationchainid 600001 --sharedid 0xc65a7bb8d6351c1cf70c95a316cc6a92839c986682d98bc35f958f4883f9d2a8
```
- `--pn`: Privacy Node identifier
- `--symbol`: Token symbol
- `--id`: Token ID to swap
- `--amountreceive`: Amount to receive
- `--resourceidtoreceive`: Resource ID to receive
- `--destinationchainid`: Destination chain ID
- `--sharedid`: Shared ID for the swap

### Complete swap
```bash
npx hardhat dvp721SwapComplete --pn A --symbol lobos1 --id 3 --destinationchainid 600001 --receiveraddress 0xf9260C378ea6E428A79EAfe443BD24EA09Af8Bc9
```
- `--pn`: Privacy Node identifier
- `--symbol`: Token symbol
- `--id`: Token ID
- `--destinationchainid`: Destination chain ID
- `--receiveraddress`: Receiver's address

### Withdraw token from DVP
```bash
npx hardhat dvp721WithdrawFromDvp --pn B --symbol lobos1 --id 3
```
- `--pn`: Privacy Node identifier
- `--symbol`: Token symbol
- `--id`: Token ID to withdraw


# ERC1155 Token Tasks - Testing Commands


## Token Management

### Deploy a new 1155 token
```bash
npx hardhat dvp1155Deploy --pn A --name lobon10 --uri Test1155uriNewB
```
- `--pn`: Privacy Node identifier (A, B, C, D)
- `--name`: Token name
- `--uri`: Token URI


### Approve all tokens
```bash
npx hardhat approveAllTokens
```
> Note: After approval, run the command to put resource ID into .env file

### Mint a token
```bash
npx hardhat dvp1155Mint --pn A --address 0xf9260C378ea6E428A79EAfe443BD24EA09Af8Bc9 --uri Test1155uriNewB --id 13 --value 100
```
- `--pn`: Privacy Node identifier
- `--address`: Recipient address
- `--uri`: Token URI
- `--id`: Token ID to mint
- `--value`: Amount to mint

### Burn a token
```bash
npx hardhat dvp1155Burn --pn A --from 0xf9260C378ea6E428A79EAfe443BD24EA09Af8Bc9 --id 13 --value 100 --uri Test1155uriNewB
```
- `--pn`: Privacy Node identifier
- `--from`: Address to burn from
- `--id`: Token ID to burn
- `--value`: Amount to burn
- `--uri`: Token URI

### Deposit a token into DVP
```bash
npx hardhat dvp1155Deposit --pn A --uri Test1155uriNewB --id 13 --value 100
```
- `--pn`: Privacy Node identifier
- `--uri`: Token URI
- `--id`: Token ID to deposit
- `--value`: Amount to deposit

### Withdraw a token from DVP
```bash
npx hardhat dvp1155WithdrawFromDvp --pn B --id 13 --value 100 --uri Test1155uriNewB
```
- `--pn`: Privacy Node identifier
- `--id`: Token ID to withdraw  
- `--value`: Amount to withdraw
- `--uri`: Token URI

### Swap a token for Enygma
```bash
npx hardhat dvp1155SwapForEnygma --pn B --token-id 13 --token-value 100 --enygma-amount 100 --enygma-resource-id 0xc65a7bb8d6351c1cf70c95a316cc6a92839c986682d98bc35f958f4883f9d2a8 --dest-chain-id 13345 --shared-id 0x47a6e83af1c2d572b6908f42d13889c09df92efc83f78d8b9f8b7eb0e48a2c15
```
- `--pn`: Privacy Node identifier
- `--token-id`: Token ID to swap
- `--token-value`: Amount to swap
- `--enygma-amount`: Amount of Enygma to receive
- `--enygma-resource-id`: Resource ID of the Enygma to receive
- `--dest-chain-id`: Destination chain ID
- `--shared-id`: Shared ID for the swap

### Swap Enygma for a token
```bash
npx hardhat swapEnygmaForERC1155 --pn A --symbol SDEVE --amount 100 --nft-id 13 --nft-amount-or-one 1 --nft-resource-id 0x6e1540171b6c0c960b71a7020d9f60077f6af931a8bbf590da0223dacf75c7af --chain-id 133456 --shared-id 0x47a6e83af1c2d572b6908f42d13889c09df92efc83f78d8b9f8b7eb0e48a2c15
```
- `--pn`: Privacy Node identifier
- `--symbol`: Token symbol
- `--amount`: Amount of Enygma to swap
- `--nft-id`: Token ID to receive
- `--nft-amount-or-one`: Amount of the token to receive
- `--nft-resource-id`: Resource ID of the token to receive
- `--chain-id`: Chain ID of the destination
- `--shared-id`: Shared ID for the swap

### Test the swap
```bash
npx hardhat test ./hardhat/test/e2e/Dvp_Swap_ERC1155_Enygma.ts
```
- This command runs the test suite for the swap functionality between Enygma and ERC1155 tokens.
