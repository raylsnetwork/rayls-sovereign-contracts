# Rayls Ethers Client

The client is used to create an abstraction layer between the ethers connections to the Ven (PrivateHub and Pls) on each Smart Contract

To utilize the Rayls Ethers Client, ensure the following configuration and deployment files are correctly set up for your environment:

- `config.[env].json`: Contains environment-specific settings such as chain IDs, URLs, account information, and participant settings.
- `deployments.[env].json`: Holds deployment addresses for smart contracts relevant to the environment.

<br/>

# Contributing

## Structure

    ├── config # Configuration loading for the Ven
    │ ├── index.ts # Main configuration loader & setter
    │ └── schema.ts # Configuration schema definitions
    │
    ├── deployments # Smart contract deployment information
    │ ├── index.ts # Main deployment configuration loader & setter
    │ └── schema.ts # Deployment information schema definitions
    │
    ├── ethers # Ethers.js abstraction layers
    │ ├── privateHub.ts # Private Network Hub specific ethers initializers
    │ └── pn.ts # PN (Privacy Node) specific ethers initializers
    │
    ├── ethers.ts # Main entry point for ethers client abstractions
    ├── storage.ts # Storage utility for getting and setting configs
    │
    ├── types # Type definitions and contract interfaces
    │ ├── ajvTypes.ts # AJV (JSON Validator) type definitions override 
    │ └── _contracts.ts # Smart contract type definitions and interfaces based of Hardhat

## Adding a new contract

#### Taking for example the ParticipantStorage contract which requires metadata (like the role) to register each PN.

```json
{
  "id": "A",
  "chainId": 1339,
  "url": "http://localhost:3000",
  "wsUrl": "ws://localhost:3000",
  "accounts": [
    "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  ],
  "participant": {
    "role": 0
  }
}
```

> The `accounts` value above is the well-known public Anvil/Hardhat account #0 key — a publicly documented test key, not a secret.

### Extending the Configs

#### Config

Since the **Role** is necessary to be know beforehand, we can add it as a required param in the config.[env].json file by going into **config/schema.ts** which has the config schema that is used as a validation for the tool.

This can be extended for our use case by adding it in the PlSchema like so:

```typescript
const PlSchema = {
  type: 'object',

  properties: {
    id: { type: 'string' },
    chainId: { type: 'number' },
    url: { type: 'string' },
    wsUrl: { type: 'string' },
    accounts: { type: 'array', items: { type: 'string' } },

    /**
     *  Adding this will ensure the participant will be present in the config
     */
    participant: {
      type: 'object',

      properties: {
        role: { type: 'number' },
      },
    },
  },
} as const;
```

**The `as const` is used to later extract the types using AJV, this is mandatory or types will be lost or converted to any**

#### Deployments Config

After deploying the ParticipantStorage, we might want to save it's address to the deployments config and make it auto initialize the contract when it's present.

To this we go into **deployments/schema.ts** which has the deployments config schema which has the same purpose as **config/schema.ts** but for managing deployments

<br/>

**When adding a new contract address, make sure it has the same name as the Contract!!**

This is because the name is used behind the scenes to import the ABI using Hardhat. Like so:
`ethers.getContractAt(name, address)`

**Attention** 👆👆👆👆👆👆👆👆👆👆👆👆👆👆👆👆👆👆👆👆👆

```typescript
const plSchema = {
  type: 'object',
  optionalProperties: {
    EndpointAddress: { type: 'string' },
    /*
     * Add here if optional
     */
  },
  properties: {
    MessageDispatcher: { type: 'string' },
    /*
     * Added here since it's mandatory
     */
    ParticipantStorage: { type: 'string' },
  },
} as const;
```

Now you should be able to both read and write configurations into the Rayls Config

### Extending ethers

After this we might want to extend the **ethers client** so for this we go into **ethers/\*.ts** which contains all the mappings done for the PrivateHub and each PN.
Giving the example of the **accounts** property, we can use it to abstract the initialization of the wallets.

```typescript
{
  signers: cfg.accounts.map((privateKey) => {
    const wallet = new ethersInstance.Wallet(privateKey).connect(provider);
    const signer = new ethersInstance.NonceManager(wallet);
    return signer;
  });
}
```
