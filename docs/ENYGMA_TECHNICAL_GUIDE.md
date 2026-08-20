# Enygma & DVP - Advanced Technical Guide

## 📖 Summary

This documentation provides an in-depth technical analysis of the two most advanced systems in the Rayls Protocol:

- **Enygma**: Privacy token system using zero-knowledge proofs
- **DVP**: Atomic Delivery vs Payment system with zero-knowledge verification

---

## 🔐 Enygma System - Privacy Tokens

### Fundamental Concepts

**Enygma** is a token system that implements privacy through:
- **Cryptographic Commitments**: Hide values using Pedersen Commitments
- **Zero-Knowledge Proofs**: Allow verification without revealing information
- **BabyJubJub Curve**: Elliptic curve optimized for SNARKs

### Enygma Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     ENYGMA SYSTEM                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────────┐    ┌─────────────────┐    ┌──────────────┐ │
│  │   EnygmaV1      │    │   Dvp           │    │  Verifiers   │ │
│  │   Core          │    │   Integration   │    │    k=2-6     │ │
│  │                 │    │                 │    │              │ │
│  │ - Commitments   │◄──►│ - Deposit/      │◄──►│ - Groth16    │ │
│  │ - Balances      │    │   Withdraw      │    │ - BabyJubJub │ │
│  │ - Transfers     │    │ - Proof Ver.    │    │ - Poseidon   │ │
│  │ - Mint/Burn     │    │ - Atomic Ops    │    │              │ │
│  └─────────────────┘    └─────────────────┘    └──────────────┘ │
│           │                       │                     │       │
│           └───────────────────────┼─────────────────────┘       │
│                                   │                             │
│  ┌─────────────────────────────────▼─────────────────────────────┐ │
│  │              BabyJubJub Curve & Primitives                   │ │
│  │                                                               │ │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │ │
│  │  │  Pedersen    │  │  Point       │  │   Hash       │      │ │
│  │  │  Commitments │  │  Operations  │  │   Poseidon   │      │ │
│  │  └──────────────┘  └──────────────┘  └──────────────┘      │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Fundamental Data Structures

#### EnygmaPoint

```solidity
struct EnygmaPointWithChainId {
    uint256 c1;      // X coordinate of commitment
    uint256 c2;      // Y coordinate of commitment
    uint256 chainId; // Chain where the point is valid
}
```

#### Pending Transaction

```solidity
struct PendingTransaction {
    EnygmaPointWithChainId[] pointsToAddToBalance;
    uint256 nullifier;     // Prevents double-spending
    uint8 transactionType; // 3=transfer, 4=deposit, 5=withdraw
}
```

#### Transfer Proof

```solidity
struct TransferProof {
    uint256[2] pi_a;        // Groth16 proof - point A
    uint256[2][2] pi_b;     // Groth16 proof - point B
    uint256[2] pi_c;        // Groth16 proof - point C
    uint256[] public_signal; // Public signals of the proof
}
```

### BabyJubJub Curve

#### Curve Parameters

```solidity
// Equation: 168700x² + y² = 1 + 168696x²y²
uint256 constant A = 168700;   // Parameter A
uint256 constant D = 168696;   // Parameter D
uint256 constant Q = 21888242871839275222246405745257275088548364400416034343698204186575808495617; // Prime field
```

#### Curve Operations

**Point Addition:**

```solidity
function pointAdd(uint256 _x1, uint256 _y1, uint256 _x2, uint256 _y2)
    returns (uint256 x3, uint256 y3) {
    // Twisted Edwards formula:
    // x3 = (x1*y2 + y1*x2) / (1 + d*x1*x2*y1*y2)
    // y3 = (y1*y2 - a*x1*x2) / (1 - d*x1*x2*y1*y2)
}
```

**Scalar Multiplication:**

```solidity
function derivePk(uint256 _d) returns (uint256 x2, uint256 y2) {
    // Implements double-and-add algorithm
    // To calculate _d * G where G is the generator
}
```

### Pedersen Commitments

#### Commitment Formula

```
C = v*G + r*H
```

- **v**: Value (amount) to be hidden
- **r**: Blinding factor (randomness)
- **G**: Base generator point
- **H**: Auxiliary generator point
- **C**: Resulting commitment

#### Implementation

```solidity
function pedCom(uint256 v, uint256 r) returns (uint256, uint256) {
    (uint256 gX, uint256 gY) = derivePk(v);      // v*G
    (uint256 hX, uint256 hY) = derivePkH(r);     // r*H
    (uint256 pedComX, uint256 pedComY) = pointAdd(gX, gY, hX, hY); // v*G + r*H
    return (pedComX, pedComY);
}
```

### Balance System

#### Balance Representation

Balances in Enygma are represented as points on the curve:

```solidity
mapping(uint256 => mapping(uint256 => EnygmaPointWithChainId)) public referenceBalance;
//       blockNum      chainId        balance point
```

#### Conservation Invariant

```solidity
function checkTotalSumOfBalances(uint256 blockNumber) returns (bool) {
    uint256 x = 0, y = 1; // Identity point (neutral)

    // Sum all participant balances
    for (each participant) {
        (uint256 xBalance, uint256 yBalance) = getBalanceByBlockNumber(chainId, blockNumber);
        (x, y) = pointAdd(x, y, xBalance, yBalance);
    }

    // Include DVP balance
    (uint256 xBalanceDvp, uint256 yBalanceDvp) = getBalanceByBlockNumber(dvpChainId, blockNumber);
    (x, y) = pointAdd(x, y, xBalanceDvp, yBalanceDvp);

    // Must equal total supply
    require(totalSupplyX == x && totalSupplyY == y, 'Conservation violation');
    return true;
}
```

### Private Transfer Flow

#### 1. Transaction Preparation

```
User has:
- Current balance: B_old = pedCom(v_old, r_old)
- Wants to transfer: amount to another user
- Final balance: B_new = pedCom(v_new, r_new)
where: v_new = v_old - amount
```

#### 2. Proof Generation

The user generates a ZK proof that demonstrates:

- **Balance knowledge**: Knows v_old and r_old such that B_old = pedCom(v_old, r_old)
- **Transfer validity**: v_new = v_old - amount (without revealing values)
- **Unique nullifier**: Prevents double-spending
- **Conservation**: Total sum is preserved

#### 3. Verification and Execution

```solidity
function transfer(
    uint8 k,                    // Number of participants (2-6)
    Point[] memory commitments, // New commitments
    TransferProof memory proof, // Zero-knowledge proof
    uint256[] memory chainIds,  // Chains involved
    bytes[] memory encryptedMessages // Encrypted messages
) returns (bool) {
    // 1. Validate parameters
    validateTransferInputs(k, commitments, proof, chainIds, nullifier, currentBlockNumber);

    // 2. Verify ZK proof
    verifyTransferProof(k, proof);

    // 3. Finalize pending transactions
    finalizePendingTransactions(currentBlockNumber);

    // 4. Add transaction to pending
    addPendingTransaction(k, commitments, proof, chainIds, nullifier,
                         lastblockNumAtCurrentBlockNumber[currentBlockNumber],
                         currentBlockNumber, 3);

    // 5. Send events to relayer
    sendEvents(chainIds, encryptedMessages);

    return true;
}
```

### Zero-Knowledge Verifiers

#### Multi-K System

Enygma supports different transaction sizes (k=2 to k=6):

```solidity
mapping(uint256 => address) public transferVerifiers;

function verifyTransferProof(uint8 k, TransferProof memory proof) internal view {
    if (k == 2) {
        require(IEnygmaVerifierk2(transferVerifiers[k])
               .verifyProof(proof.pi_a, proof.pi_b, proof.pi_c,
                           convertToUint256Array12(proof.public_signal)));
    } else if (k == 3) {
        require(IEnygmaVerifierk3(transferVerifiers[k])
               .verifyProof(proof.pi_a, proof.pi_b, proof.pi_c,
                           convertToUint256Array17(proof.public_signal)));
    }
    // ... k=4,5,6
}
```

#### Public Signals Structure

For a transfer with k participants:

```
public_signal[0..2k-1]:     Participants' public keys
public_signal[2k..4k-1]:    Current balance commitments
public_signal[4k]:          Nullifier
public_signal[4k+1]:        Block number
public_signal[5k+2]:        Additional commitment (DVP)
```

---

## ⚛️ DVP System - Atomic Delivery vs Payment

### Fundamental Concepts

**DVP** (Zero-Knowledge Delivery vs Payment) implements:

- **Atomic Swaps**: Mathematically guaranteed exchanges
- **Multi-Asset Support**: ERC20, ERC721, ERC1155, Enygma
- **Zero-Knowledge Privacy**: Proofs without revealing sensitive information
- **Merkle Trees**: Structures for asset tracking

### DVP Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      DVP SYSTEM                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │                    Dvp Core Contract                        │ │
│  │                                                             │ │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐       │ │
│  │  │   Deposit   │  │    Swap     │  │  Withdraw   │       │ │
│  │  │   Assets    │  │  Execution  │  │   Assets    │       │ │
│  │  └─────────────┘  └─────────────┘  └─────────────┘       │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                              │                                   │
│  ┌─────────────────────────────▼─────────────────────────────┐   │
│  │                 Merkle Trees Layer                         │   │
│  │                                                             │   │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐     │   │
│  │  │ERC721    │ │ERC20     │ │ERC1155   │ │ Enygma   │     │   │
│  │  │Tree      │ │Tree      │ │Tree      │ │ Tree     │     │   │
│  │  │(ID: 0)   │ │(ID: 1)   │ │(ID: 2)   │ │(ID: 3)   │     │   │
│  │  └──────────┘ └──────────┘ └──────────┘ └──────────┘     │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                              │                                   │
│  ┌─────────────────────────────▼─────────────────────────────┐   │
│  │                Verification Layer                          │   │
│  │                                                             │   │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │   │
│  │  │  JoinSplit   │  │  Ownership   │  │   ERC1155    │     │   │
│  │  │  Verifier    │  │  Verifier    │  │  Verifiers   │     │   │
│  │  └──────────────┘  └──────────────┘  └──────────────┘     │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Merkle Trees for Assets

#### Trees by Asset Type

```solidity
uint256 constant TREE_ID_ERC721  = 0;
uint256 constant TREE_ID_ERC20   = 1;
uint256 constant TREE_ID_ERC1155 = 2;
uint256 constant TREE_ID_ENYGMA  = 3;

mapping(uint256 => address) private _trees;
```

#### Merkle Tree Structure

```solidity
contract Merkle {
    uint256 public merkleRoot;
    uint256 public treeNumber;
    uint256[] public zeros;           // Zero values for each level
    uint256[] private filledSubTrees; // Filled subtrees

    mapping(uint256 => mapping(uint256 => bool)) public nullifiers;
    mapping(uint256 => mapping(uint256 => bool)) public rootHistory;
}
```

#### Commitment Insertion

```solidity
function insertLeaves(uint256[] memory _leafHashes) {
    // Optimized algorithm for batch insertion
    // Efficiently calculates new merkle root
    // Updates rootHistory for proof verification
}
```

### DVP Transaction Types

#### 1. JoinSplit Transaction

For fungible assets (ERC20, Enygma):

```solidity
struct JoinSplitTransaction {
    uint256[] merkleRoots;    // Merkle tree roots (up to 10)
    uint256[] nullifiers;     // Input nullifiers (up to 10)
    uint256[] commitments;    // Output commitments (2)
    uint256[] treeNumbers;    // Tree numbers used
    uint256 message;          // Message for atomic swap
    Proof proof;              // Zero-knowledge proof
}
```

#### 2. Ownership Transaction

For non-fungible assets (ERC721):

```solidity
struct OwnershipTransaction {
    uint256 merkleRoot;       // Merkle tree root
    uint256 nullifier;        // Input nullifier
    uint256 commitment;       // Output commitment
    uint256 treeNumber;       // Tree number
    uint256 message;          // Message for atomic swap
    Proof proof;              // Zero-knowledge proof
}
```

### Deposit Operations

#### ERC721 Deposit

```solidity
function depositERC721(uint256 nftId, address nftAddress, uint256 publicKey) returns (bool) {
    // 1. Transfer NFT to DVP contract
    IERC721(nftAddress).transferFrom(msg.sender, address(this), nftId);

    // 2. Generate unique ID
    uint256 uid = erc721UniqueId(nftId, nftAddress);

    // 3. Create commitment
    uint256 commitment = IPoseidonWrapper(_hashContractAddress).poseidon([uid, publicKey]);

    // 4. Insert into Merkle Tree
    insertCommitment(TREE_ID_ERC721, commitment);

    return true;
}
```

#### Enygma Deposit (via DvpIntegration)

```solidity
function depositEnygma(uint256 hashCommitment) onlyRole(DEFAULT_ENYGMA_ROLE) returns (bool, uint256) {
    // Commitment is generated in Enygma system
    // Insert directly into Enygma Merkle Tree
    insertCommitment(TREE_ID_ENYGMA, hashCommitment);
    return (true, hashCommitment);
}
```

### Atomic Swaps

#### Swap Enygma ↔ ERC721

```solidity
function swap(
    JoinSplitTransaction memory jsProof,    // Enygma proof
    OwnershipTransaction memory ownProof,   // ERC721 proof
    uint256 jsTreeId,                       // Enygma Tree ID (3)
    uint256 ownTreeId                       // ERC721 Tree ID (0)
) returns (bool) {
    // 1. Validate cross-references
    require(jsProof.message == ownProof.commitment, 'Invalid NFT transfer');
    require(ownProof.message == jsProof.commitments[0], 'Invalid Funds transfer');

    // 2. Verify proofs
    checkOwnershipConditions(treeById(ownTreeId), ownProof);
    checkJoinSplitConditions(treeById(jsTreeId), jsProof);

    // 3. Nullify inputs (prevents double-spending)
    for (uint i = 0; i < jsProof.nullifiers.length; i++) {
        if (jsProof.nullifiers[i] != dummyNullifier) {
            setNullifier(jsTreeId, jsProof.treeNumbers[i], jsProof.nullifiers[i]);
        }
    }
    setNullifier(ownTreeId, ownProof.treeNumber, ownProof.nullifier);

    // 4. Insert new commitments
    insertCommitments(jsTreeId, jsProof.commitments);
    insertCommitment(ownTreeId, ownProof.commitment);

    return true;
}
```

### Proof Verification

#### JoinSplit Proof Verification

```solidity
function verifyJoinSplitProof(JoinSplitTransaction memory _tx) returns (bool) {
    // Input structure: [message, 10 merkleRoots, 10 nullifiers, 2 commitments]
    uint256[] memory inputs = new uint256[](23);

    inputs[0] = _tx.message;

    // Merkle roots (1-10)
    for (uint256 i = 0; i < 10; i++) {
        inputs[i + 1] = _tx.merkleRoots[i];
    }

    // Nullifiers (11-20)
    for (uint256 i = 0; i < 10; i++) {
        inputs[i + 11] = _tx.nullifiers[i];
    }

    // Output commitments (21-22)
    inputs[21] = _tx.commitments[0];
    inputs[22] = _tx.commitments[1];

    return IGenericGroth16Verifier(groth16Verifier).verify(vKeys[0], _tx.proof, inputs);
}
```

#### Ownership Proof Verification

```solidity
function verifyOwnershipProof(OwnershipTransaction memory _tx) returns (bool) {
    uint256[] memory inputs = new uint256[](4);
    inputs[0] = _tx.message;
    inputs[1] = _tx.merkleRoot;
    inputs[2] = _tx.nullifier;
    inputs[3] = _tx.commitment;

    return IGenericGroth16Verifier(groth16Verifier).verify(vKeys[1], _tx.proof, inputs);
}
```

### Enygma-DVP Integration

#### EnygmaDvpIntegration Contract

```solidity
contract EnygmaDvpIntegration {
    EnygmaV1 private _enygmaV1;
    address private _enygmaDvPAddress;

    mapping(uint256 => address) public depositToDvpVerifiers;
    mapping(uint256 => address) public withdrawFromDvpVerifiers;
}
```

#### Deposit to DVP Flow

```
1. User calls depositToDvp() on EnygmaDvpIntegration
2. Validation: inputs, freeze status, verifier existence
3. Proof value extraction: blockNumber, nullifier, hashCommitment
4. ZK proof verification (deposit-specific)
5. Deposit processing in DVP core
6. Enygma balance update via _enygmaV1.dvpAddPendingTransaction()
7. Event emission for synchronization
```

#### Withdraw from DVP Flow

```
1. User calls withdrawFromDvp() on EnygmaDvpIntegration
2. Similar validation to deposit
3. Withdraw processing in DVP core (with JoinSplitTransaction)
4. Enygma balance update
5. Funds restoration to user
```

### Unique ID Generation

#### ERC721
```solidity
function erc721UniqueId(uint256 nftId, address erc721Address) returns (uint256) {
    return uint256(keccak256(abi.encodePacked(nftId, erc721Address))) % SNARK_SCALAR_FIELD;
}
```

#### ERC1155
```solidity
function erc1155UniqueId(uint256 amount, uint256 tokenId, address erc1155Address) returns (uint256) {
    uint256 uid1 = IPoseidonWrapper(_hashContractAddress).poseidon([uint256(uint160(erc1155Address)), tokenId]);
    uint256 uid2 = IPoseidonWrapper(_hashContractAddress).poseidon([uid1, amount]);
    return uid2;
}
```

---

## 🔄 Complete Flow: Atomic Swap Enygma ↔ ERC721

### Example Scenario

- **User A**: Has 100 Enygma tokens, wants 1 specific NFT
- **User B**: Has 1 NFT, wants 100 Enygma tokens

### Phase 1: Preparation

#### User A (Enygma Holder)

```solidity
// 1. Deposit Enygma tokens to DVP
uint256 hashCommitment = generateEnygmaCommitment(100, randomness);
enygmaDvpIntegration.depositToDvp(
    k: 2,
    commitments: [newCommitmentA, dummyCommitment],
    proof: depositProofA,
    chainIds: [chainA, chainB],
    encryptedMessages: [msgA, msgB]
);
```

#### User B (NFT Holder)

```solidity
// 1. Deposit NFT to DVP
dvp.depositERC721(nftId, nftAddress, publicKeyB);
```

### Phase 2: Proof Generation

#### Proof for Enygma (JoinSplit)

```
Proof demonstrates:
- Ownership of 100 deposited Enygma tokens
- Commitment to receive NFT
- Unique nullifier to prevent double-spend
- Message linking with NFT proof
```

#### Proof for ERC721 (Ownership)

```
Proof demonstrates:
- Ownership of deposited NFT
- Commitment to transfer NFT
- Message linking with Enygma proof
- Unique nullifier
```

### Phase 3: Atomic Execution

```solidity
// Call to DVP contract
dvp.swap(
    jsProof: enygmaJoinSplitProof,
    ownProof: nftOwnershipProof,
    jsTreeId: TREE_ID_ENYGMA,     // 3
    ownTreeId: TREE_ID_ERC721     // 0
);
```

#### Atomic Validations

```solidity
// Cross-validation ensures atomicity
require(jsProof.message == ownProof.commitment, 'Invalid NFT transfer');
require(ownProof.message == jsProof.commitments[0], 'Invalid Funds transfer');
```

### Phase 4: Finalization

#### Nullification (Prevents Double-Spending)

```solidity
// Nullify old inputs
setNullifier(TREE_ID_ENYGMA, jsProof.treeNumbers[i], jsProof.nullifiers[i]);
setNullifier(TREE_ID_ERC721, ownProof.treeNumber, ownProof.nullifier);
```

#### New Commitments

```solidity
// Insert new commitments
insertCommitments(TREE_ID_ENYGMA, jsProof.commitments);  // Enygma to B
insertCommitment(TREE_ID_ERC721, ownProof.commitment);   // NFT to A
```

#### Final Result

- **User A**: Now has rights to the NFT (can withdraw)
- **User B**: Now has rights to the 100 Enygma tokens (can withdraw)
- **Atomicity**: Either both transfers happen, or neither happens

---

## 🛡️ Security and Guarantees

### Cryptographic Properties

#### Zero-Knowledge

- **Completeness**: Valid proofs always pass verification
- **Soundness**: Invalid proofs do not pass verification (with high probability)
- **Zero-Knowledge**: Proofs do not reveal information beyond validity

#### Commitments

- **Hiding**: Impossible to determine value without knowing the randomness
- **Binding**: Impossible to open commitment to a different value
- **Homomorphic**: Allows operations on encrypted values

### System Guarantees

#### Asset Conservation

```solidity
// Enygma: Sum of balances = Total Supply
∑(balance_i) = totalSupply (in curve points)

// DVP: Assets only change custody
deposit(asset) + withdraw(asset) = constant
```

#### Atomicity

- **All-or-Nothing**: Swaps are completely atomic
- **No Partial Execution**: Impossible to execute partially
- **Rollback Safety**: Failures lead to complete rollback

#### Double-Spending Prevention

- **Nullifiers**: Each asset can only be spent once
- **Merkle Proof Verification**: Proves ownership without revealing
- **Tree History**: Maintains history of all valid roots

### Performance Considerations

#### Gas Optimization

- **Batch Operations**: Multiple commitments in one transaction
- **Efficient Merkle Updates**: Optimized algorithm for insertion
- **Precompiled Contracts**: Use of precompiled contracts for curve operations

#### Scalability

- **Tree Depth**: Configurable based on expected volume
- **Multiple Trees**: Separation by asset type
- **Pruning Strategy**: Storage management strategy

---

## 💻 Implementation Examples

### Example 1: Private Enygma Transfer

```typescript
// Generate proof off-chain
const proof = await generateEnygmaTransferProof({
    k: 2,
    inputs: [
        { value: currentBalance, randomness: currentR },
        { value: 0, randomness: 0 } // dummy input
    ],
    outputs: [
        { value: currentBalance - transferAmount, randomness: newR1 },
        { value: transferAmount, randomness: newR2, recipient: recipientPubKey }
    ],
    nullifier: computeNullifier(currentBalance, currentR),
    blockNumber: currentBlock
});

// Execute on-chain
await enygmaV1.transfer(
    2, // k=2 participants
    [newCommitment1, newCommitment2], // output commitments
    proof, // zero-knowledge proof
    [senderChainId, recipientChainId], // chains involved
    [encryptedMsg1, encryptedMsg2] // encrypted messages
);
```

### Example 2: Atomic Swap Setup

```typescript
// Setup DVP swap
async function setupAtomicSwap(
    enygmaAmount: bigint,
    nftId: bigint,
    nftAddress: string
) {
    // 1. Generate swap commitments
    const swapCommitment = await generateSwapCommitment(enygmaAmount, nftId);

    // 2. Deposit assets
    await enygmaDvpIntegration.depositToDvp(/* params */);
    await dvp.depositERC721(nftId, nftAddress, publicKey);

    // 3. Generate cross-linked proofs
    const enygmaProof = await generateJoinSplitProof({
        message: swapCommitment.nftCommitment,
        // ... other params
    });

    const nftProof = await generateOwnershipProof({
        message: swapCommitment.enygmaCommitment,
        // ... other params
    });

    // 4. Execute atomic swap
    await dvp.swap(enygmaProof, nftProof, TREE_ID_ENYGMA, TREE_ID_ERC721);
}
```

---

## 📚 Technical References

### Papers and Specifications

- **[Groth16]**: "On the Size of Pairing-based Non-interactive Arguments"
- **[BabyJubJub]**: "Baby Jubjub Elliptic Curve"
- **[Poseidon]**: "Poseidon: A New Hash Function for Zero-Knowledge Proof Systems"
- **[Pedersen]**: "Non-Interactive and Information-Theoretic Secure Verifiable Secret Sharing"

### Reference Implementations

- **Circom**: Language for zero-knowledge circuits
- **SnarkJS**: JavaScript library for SNARKs
- **Tornado Cash**: Reference implementation for privacy tokens

### Development Tools

- **Hardhat**: Framework for Ethereum development
- **Foundry**: Toolkit for Solidity development
- **Circom**: ZK circuit compiler

---

*This documentation provides an in-depth technical view of the Enygma and DVP systems. For practical implementations, refer to the code examples and provided interfaces.*