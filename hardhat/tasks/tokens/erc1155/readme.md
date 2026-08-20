## TOKEN ERC20

### Deploy ERC-1155
```bash
npx hardhat dvp:1155:deploy --pn A --name erc1155-rayls --uri test://test
```
- `--pn`: Privacy Node identifier
- `--symbol`: Token symbol

### Mint ERC-1155
```bash
npx hardhat tokens:erc1155:mint --pn A --to 0x7abAf1FEE956ce15345823b67A3Ae9ea9Ae52e41 --id 10 --name erc1155-rayls --value 100
```
- `--pn`: Privacy Node identifier
- `--symbol`: Token symbol
- `--amount`: Amount to mint
- `--to`: Address that will receive the amount


### Burn ERC-1155
```bash
npx hardhat tokens:erc1155:burn --pn A --from 0x7abAf1FEE956ce15345823b67A3Ae9ea9Ae52e41 --id 10 --name erc1155-rayls --value 10
```
- `--pn`: Privacy Node identifier
- `--symbol`: Token symbol
- `--amount`: Amount to burn
- `--from`: Address that will have tokes burned

### Get Balance 

npx hardhat tokens:erc1155:get-balance --pn A --uri erc1155-rayls --address 0x7abAf1FEE956ce15345823b67A3Ae9ea9Ae52e41 --id 10

### Deposit

npx hardhat tokens:erc1155:send --pn-origin A --pn-dest B --name erc1155-rayls --destination-address 0xf9260c378ea6e428a79eafe443bd24ea09af8bc9 --amount 1 --id 10

### Send Batch

npx hardhat tokens:erc20:send-batch --pn-origin A --pn-dest B --symbol erc20-rayls-2 --destination-address 0xf9260c378ea6e428a79eafe443bd24ea09af8bc9 --amount 1 --total-transactions 1000

### Set Allowance

npx hardhat tokens:erc20:set-allowance --pn A --symbol erc20-rayls-2 --to 0xf9260c378ea6e428a79eafe443bd24ea09af8bc9 --amount 1 

### Get Infos

npx hardhat tokens:erc20:get-infos --pn A --symbol erc20-rayls-2 