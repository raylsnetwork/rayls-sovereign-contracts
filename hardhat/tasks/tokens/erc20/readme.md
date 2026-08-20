## TOKEN ERC20

### Deploy ERC-20
```bash
npx hardhat tokens:erc20:deploy --pn A --symbol erc20-rayls
```
- `--pn`: Privacy Node identifier
- `--symbol`: Token symbol

### Mint ERC-20
```bash
npx hardhat tokens:erc20:mint --pn A --symbol erc20-rayls-2 --to 0x5c8fAA5c283B1c4d39aE24c9592aD458B5eeBa40 --amount 10
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