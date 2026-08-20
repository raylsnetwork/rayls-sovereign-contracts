## TOKEN ENYGMA ERC20

### Deploy ENYGMA ERC-20
```bash
npx hardhat tokens:enygma:deploy --pn A --symbol enygma-rayls
```
- `--pn`: Privacy Node identifier
- `--symbol`: Token symbol

### Mint ENYGMA ERC-20
```bash
npx hardhat tokens:enygma:mint --pn A --symbol enygma-rayls --to 0x7abAf1FEE956ce15345823b67A3Ae9ea9Ae52e41 --amount 1000
```
- `--pn`: Privacy Node identifier
- `--symbol`: Token symbol
- `--amount`: Amount to mint
- `--to`: Address that will receive the amount


### Burn ERC-20
```bash
npx hardhat tokens:erc20:burn --pn A --symbol erc20-rayls-2 --from 0x5c8fAA5c283B1c4d39aE24c9592aD458B5eeBa40 --amount 1
```
- `--pn`: Privacy Node identifier
- `--symbol`: Token symbol
- `--amount`: Amount to burn
- `--from`: Address that will have tokes burned

### Get Balance 

npx hardhat tokens:erc20:get-balance --pn A --symbol erc20-rayls-2 --address 0x5c8fAA5c283B1c4d39aE24c9592aD458B5eeBa40

### Send

npx hardhat tokens:erc20:send --pn-origin A --pn-dest B --symbol erc20-rayls-2 --destination-address 0xf9260c378ea6e428a79eafe443bd24ea09af8bc9 --amount 1

### Send Batch

npx hardhat tokens:erc20:send-batch --pn-origin A --pn-dest B --symbol erc20-rayls-2 --destination-address 0xf9260c378ea6e428a79eafe443bd24ea09af8bc9 --amount 1 --total-transactions 1000

### Set Allowance

npx hardhat tokens:erc20:set-allowance --pn A --symbol erc20-rayls-2 --to 0xf9260c378ea6e428a79eafe443bd24ea09af8bc9 --amount 1 

### Get Infos

npx hardhat tokens:erc20:get-infos --pn A --symbol erc20-rayls-2 