## DVP WITH ERC1155

### Deploy ERC-1155-DVP
```bash
npx hardhat dvp:1155:deploy --pn A --name dvp-erc155-rayls --uri test://test 
```
- `--pn`: Privacy Node identifier
- `--symbol`: Token symbol

### Mint ERC-1155-DVP
```bash
npx hardhat dvp:1155:mint --pn A --to 0x7abAf1FEE956ce15345823b67A3Ae9ea9Ae52e41 --id 10 --name dvp-erc155-rayls --value 100
```
- `--pn`: Privacy Node identifier
- `--symbol`: Token symbol
- `--amount`: Amount to mint
- `--to`: Address that will receive the amount


### Burn ERC-1155-DVP
```bash
npx hardhat dvp:1155:burn --pn A --name dvp-erc155-rayls2 --from 0x7abAf1FEE956ce15345823b67A3Ae9ea9Ae52e41 --amount 1 --id 10
```
- `--pn`: Privacy Node identifier
- `--symbol`: Token symbol
- `--amount`: Amount to burn
- `--from`: Address that will have tokes burned

### Get Infos 

npx hardhat dvp:1155:get-infos --pn A --name dvp-erc155-rayls --id 10

### Send

npx hardhat tokens:erc20:send --pn-origin A --pn-dest B --symbol erc20-rayls-2 --destination-address 0xf9260c378ea6e428a79eafe443bd24ea09af8bc9 --amount 1

### Send Batch

npx hardhat tokens:erc20:send-batch --pn-origin A --pn-dest B --symbol erc20-rayls-2 --destination-address 0xf9260c378ea6e428a79eafe443bd24ea09af8bc9 --amount 1 --total-transactions 1000

### Set Allowance

npx hardhat tokens:erc20:set-allowance --pn A --symbol erc20-rayls-2 --to 0xf9260c378ea6e428a79eafe443bd24ea09af8bc9 --amount 1 

### Get Infos

npx hardhat tokens:erc20:get-infos --pn A --symbol erc20-rayls-2 