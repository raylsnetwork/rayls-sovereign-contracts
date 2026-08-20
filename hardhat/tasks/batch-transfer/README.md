Deploy Token

npx hardhat batch-transfer:deploy-erc20 --pn A --name "Batch Token Daily" --symbol BTKY

0x7cd332d19b93bcabe3cce7ca0c18a052f57e5fd03b4758a09f30f5ddc4b22ec4

Approve Token

npx hardhat tokens:approve-last-hub

Check Balance

npx hardhat batch-transfer:erc20-get-balance --pn A --address 0xf9260C378ea6E428A79EAfe443BD24EA09Af8Bc9 --resource-id 0x7cd332d19b93bcabe3cce7ca0c18a052f57e5fd03b4758a09f30f5ddc4b22ec4

Mint

npx hardhat batch-transfer:erc20-mint --amount 1000 --pn A --address 0xf9260C378ea6E428A79EAfe443BD24EA09Af8Bc9 --resource-id 0x7cd332d19b93bcabe3cce7ca0c18a052f57e5fd03b4758a09f30f5ddc4b22ec4

Batch Transfer

0xfaAF1Cbca846d10efCe8A9Ac28483db7D5624f9c
0x2906c1834DB2848e3C766f0F17Fa1E6EAC7009ef

npx hardhat batch-transfer:erc20-batch-token B 0xfaAF1Cbca846d10efCe8A9Ac28483db7D5624f9c 100 B 0x2906c1834DB2848e3C766f0F17Fa1E6EAC7009ef 200 --pn A --address 0xf9260C378ea6E428A79EAfe443BD24EA09Af8Bc9 --resource-id 0x7cd332d19b93bcabe3cce7ca0c18a052f57e5fd03b4758a09f30f5ddc4b22ec4

Check Balances

npx hardhat batch-transfer:erc20-get-balance --pn A --address 0xf9260C378ea6E428A79EAfe443BD24EA09Af8Bc9 --resource-id 0x7cd332d19b93bcabe3cce7ca0c18a052f57e5fd03b4758a09f30f5ddc4b22ec4
npx hardhat batch-transfer:erc20-get-balance --pn B --address 0xfaAF1Cbca846d10efCe8A9Ac28483db7D5624f9c --resource-id 0x7cd332d19b93bcabe3cce7ca0c18a052f57e5fd03b4758a09f30f5ddc4b22ec4
npx hardhat batch-transfer:erc20-get-balance --pn B --address 0x2906c1834DB2848e3C766f0F17Fa1E6EAC7009ef --resource-id 0x7cd332d19b93bcabe3cce7ca0c18a052f57e5fd03b4758a09f30f5ddc4b22ec4

---

Batch Transfer Arbitrary Messages

npx hardhat batch-transfer:arbitrary-messages "Putting" "the" "world" "in" "blockchain" "rayls"

Check Messages

npx hardhat batch-transfer:get-messages --pn B --address 0xE7a79a46D9E1EE897a75c1207d0d4335c457E3Fc