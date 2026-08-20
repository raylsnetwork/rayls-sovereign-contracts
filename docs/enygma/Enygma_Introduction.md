# **Enygma Technical Documentation**

Author: Pedro Manuel Pereira
Last Updated (Date - Rayls Version): 30/01/2026 - v2.6.2

**Note:** As of this version, Enygma uses gnark (Go-based ZK framework) instead of Circom for zero-knowledge proof generation. This provides better performance through server-side proof generation and eliminates WASM overhead.

Sources: Research Team Docs, Rayls: A Novel Design for CBDCs paper, Rayls II: Fast, Private, and Compliant CBDCs. Rayls Codebase

The purpose of this document is to provide a technical coverage of how Enygma operates.

It provides the necessary concepts to understand the basis to create a secure and private environment where zero-sum transactions are possible using elliptic curve cryptography and Pedersen Commitments, specifically using the Baby Jubjub elliptic curve.

After this initial coverage, it dwells on the details of how Enygma operates.

**TABLE OF CONTENTS**

- [**Enygma Technical Documentation**](#enygma-technical-documentation)
  - [Groups, Rings and Fields](#groups-rings-and-fields)
    - [Group](#group)
      - [Abelian Group](#abelian-group)
    - [Ring](#ring)
    - [Field](#field)
      - [Negation of a value in a field](#negation-of-a-value-in-a-field)
      - [Finite Prime Field: F\_p](#finite-prime-field-f_p)
  - [Zero Knowledge (ZK) Proofs](#zero-knowledge-zk-proofs)
    - [TO DO](#to-do)
    - [ZK-SNARKs](#zk-snarks)
    - [ZK-STARKs](#zk-starks)
  - [ZK Circuits](#zk-circuits)
    - [Signals and Gates](#signals-and-gates)
    - [Constraints and Rank-1 Constraint Systems (R1CS)](#constraints-and-rank-1-constraint-systems-r1cs)
    - [Circuit Satisfiablity and Witnesses](#circuit-satisfiablity-and-witnesses)
    - [Proof Generation](#proof-generation)
    - [Verifying a Proof](#verifying-a-proof)
  - [Diffie-Hellman (Post Quantum) Key Exchange](#diffie-hellman-post-quantum-key-exchange)
    - [Classical Diffie-Hellman Key Exchange](#classical-diffie-hellman-key-exchange)
    - [Post-Quantum Key Exchange](#post-quantum-key-exchange)
  - [Elliptic Curves](#elliptic-curves)
    - [Elliptic Curves Over a Finite Prime Field](#elliptic-curves-over-a-finite-prime-field)
  - [Baby JubJub Elliptic Curve](#baby-jubjub-elliptic-curve)
    - [Operations on Baby Jubjub Elliptic Curve](#operations-on-baby-jubjub-elliptic-curve)
      - [Pedersen Commitments](#pedersen-commitments)
      - [The Point at Infinity ("Zero" Point, Identity Point)](#the-point-at-infinity-zero-point-identity-point)
      - [1. Point Addition](#1-point-addition)
      - [2. Scalar Multiplication](#2-scalar-multiplication)
      - [3. Checking Curve Membership](#3-checking-curve-membership)
    - [Public Key Generation in Enygma](#public-key-generation-in-enygma)
  - [Secure, Zero-sum transactions in a Private Environment using Baby JubJub Elliptic Curve Cryptography](#secure-zero-sum-transactions-in-a-private-environment-using-baby-jubjub-elliptic-curve-cryptography)
    - [Security and Privacy of Public Keys and Secret Values in Pedersen Commitments](#security-and-privacy-of-public-keys-and-secret-values-in-pedersen-commitments)
    - [Unique Mapping and Privacy](#unique-mapping-and-privacy)
    - [Balanced Commitments and Zero-Sum Transactions](#balanced-commitments-and-zero-sum-transactions)
  - [Implementation in Enygma](#implementation-in-enygma)
    - [Keys and Setup](#keys-and-setup)
    - [Representation and Evolution of Balances](#representation-and-evolution-of-balances)
    - [What Defines a Valid Transaction, Ensuring Zero-Sum](#what-defines-a-valid-transaction-ensuring-zero-sum)
    - [Nullifier and Double-Spending](#nullifier-and-double-spending)
    - [Privacy, k-Anonymity and Anonymity Sets](#privacy-k-anonymity-and-anonymity-sets)
      - [Number of Participants = k](#number-of-participants--k)
      - [Number of Participants \> k](#number-of-participants--k-1)
      - [Number of Participants \< k](#number-of-participants--k-2)
      - [Fake Transactions: Enhancing Privacy Beyond Anonymity Sets (Especially Relevant when Number of Participants \< k)](#fake-transactions-enhancing-privacy-beyond-anonymity-sets-especially-relevant-when-number-of-participants--k)
        - [Fake Transactions and Number of Participants \< k](#fake-transactions-and-number-of-participants--k)
    - [Concurrency of Transactions](#concurrency-of-transactions)
      - [Pending and Finalised States, Rollover and tally of balances](#pending-and-finalised-states-rollover-and-tally-of-balances)
      - [The role of the relayer in handling concurrent transactions](#the-role-of-the-relayer-in-handling-concurrent-transactions)
        - [Validation Transactions](#validation-transactions)
      - [Limitation: The Region where Enygma better Operates (ProofTime/UnitTime  \<= 1)](#limitation-the-region-where-enygma-better-operates-prooftimeunittime---1)
      - [Theoretical Throughput Limit](#theoretical-throughput-limit)
    - [Enygma Transaction Flow in Rayls](#enygma-transaction-flow-in-rayls)
    - [Quantum Resistance](#quantum-resistance)
    - [Enygma Programmability](#enygma-programmability)
  - [Gnark](#gnark)
    - [Overview](#overview)
    - [The Gnark Framework](#the-gnark-framework)
      - [Circuit Definition in Go](#circuit-definition-in-go)
      - [Public and Private Inputs](#public-and-private-inputs)
      - [Constraint API](#constraint-api)
      - [Hint Functions](#hint-functions)
    - [Using Gnark](#using-gnark)
      - [Writing a Circuit](#writing-a-circuit)
      - [Compilation and Setup](#compilation-and-setup)
        - [Compiling the Circuit](#compiling-the-circuit)
        - [Key Generation (Trusted Setup)](#key-generation-trusted-setup)
        - [Generating the Solidity Verifier](#generating-the-solidity-verifier)
      - [Normal Usage: Proof generation via API call and Enygma contract checking if it is valid by calling the Enygma Verifier before sending the transaction](#normal-usage-proof-generation-via-api-call-and-enygma-contract-checking-if-it-is-valid-by-calling-the-enygma-verifier-before-sending-the-transaction)
  - [Enygma ZK conditions (The Go circuit file, Explained)](#enygma-zk-conditions-the-go-circuit-file-explained)
    - [Variables in the Circuit](#variables-in-the-circuit)
    - [Circuit Specifications and Public Signals](#circuit-specifications-and-public-signals)
      - [Enygma Payments Circuits](#enygma-payments-circuits)
      - [Enygma DVP Circuits](#enygma-dvp-circuits)
    - [Components of the Enygma Circuit Explained](#components-of-the-enygma-circuit-explained)
      - [1. `Sender is in AnonymitySet`](#1-sender-is-in-anonymityset)
      - [2. `Check that amount to send SenderTxValue corresponds to Sender's TxValues entry`](#2-check-that-amount-to-send-sendertxvalue-corresponds-to-senders-txvalues-entry)
      - [3. `Sender knows the secret corresponding to their position`](#3-sender-knows-the-secret-corresponding-to-their-position)
      - [4. `HashedSharedSecrets values are correctly computed`](#4-hashedsharedsecrets-values-are-correctly-computed)
      - [5. `PreviousCommits and TxCommits are OnCurve()`](#5-previouscommits-and-txcommits-are-oncurve)
      - [6. `Sender has the SecretKey correspondent to its PublicKey`](#6-sender-has-the-secretkey-correspondent-to-its-publickey)
      - [7. `Check if sender's last Pedersen Commitment can be replicated using its PreviousSenderBalance and PreviousSenderRandomValue`](#7-check-if-senders-last-pedersen-commitment-can-be-replicated-using-its-previoussenderbalance-and-previoussenderrandomvalue)
      - [8. `Sum of the Pedersen Commitments of all banks in the tx should give the "zero" point`](#8-sum-of-the-pedersen-commitments-of-all-banks-in-the-tx-should-give-the-zero-point)
      - [9. `Ensure SenderTxValue is smaller or equal than sender's PreviousSenderBalance and bigger or equal to 0`](#9-ensure-sendertxvalue-is-smaller-or-equal-than-senders-previoussenderbalance-and-bigger-or-equal-to-0)
      - [10. `Ensure nullifier is correctly derived from HashedSharedSecrets and BlockNumber`](#10-ensure-nullifier-is-correctly-derived-from-hashedsharedsecrets-and-blocknumber)
      - [11. `Ensures new Pedersen Commitments of participants are correctly formed`](#11-ensures-new-pedersen-commitments-of-participants-are-correctly-formed)
      - [12. `Ensures TxRandomValues are correctly derived from Poseidon hashes`](#12-ensures-txrandomvalues-are-correctly-derived-from-poseidon-hashes)
      - [13. `Ensures MessageTags are correctly formed`](#13-ensures-messagetags-are-correctly-formed)
    - [Summary of Enygma's Logical Flow](#summary-of-enygmas-logical-flow)
  - [What is Missing and WIP](#what-is-missing-and-wip)
  - [Changelog](#changelog)
    - [v2.6.2 (30/01/2026)](#v262-30012026)


## Groups, Rings and Fields

Fields, more specifically, Prime Fields will be a very important concept used in elliptic curve cryptography. But first we need to introduce other mathematical structures that are the fundamental building blocks of fields: groups and rings.

### Group

A **GROUP** is a set G which is CLOSED under an operation *, that is, for any x, y ∈ G, x ∗ y ∈ G.

So it always possible to perform one operation between two elements of the group (usually addition or multiplication mod n for us) with the following properties

- Existence of Identity Element– There is an element e in G, such that for every x ∈ G, e ∗ x = x ∗ e = x.
- Existence of Inverse Element – For every x in G there is an element y ∈ G such that x ∗ y = y ∗ x = e,
where again e is the identity.
- Associativity – The following identity holds for every x, y, z ∈ G:
x ∗ (y ∗ z) = (x ∗ y) ∗ z

**Example:**

The integers mod n under addition.
For n=3, G = {0,1,2},

0 + 0 mod 3 = 0, 0 + 1 mod 3 = 1, 0 + 2 mod 3 = 2

1 + 0 mod 3 = 1, 1 + 1 mod 3 = 2, 1 +2 mod 3 = 0

2 + 0 mod 3 = 2, 2 + 1 mod 3 = 0, 2 + 2 mod 3 = 1

Associativity is a property of addition. 0 is the Identity Element, the inverse of 0 is 0, the inverse of 1 is 2 and the inverse of 2 is 1.

#### Abelian Group

Let's define an Abelian Group A, with operation ~. Abelian means commutative, so an Abelian Group is a Group where the following identity holds for every x, y, z ∈ A:

x ~ y = y ~ x = z

### Ring

A **RING** is a set R which is CLOSED under two operations, let's call them addition and multiplication for simplicity. It is a **GROUP** under one of them (let's say addition, +) and satisfies some of the properties of a group for the other one (let's say multiplication, *). These are the properties it needs to satisfy:

- R is an abelian group under operation +

- Associativity of operation *– For every a, b, c ∈ R, a* (b *c) = (a* b) * c

- Distributive Properties – For every a, b, c ∈ R the following identities hold:
a *(b + c) = (a* b) + (a *c)
and (b + c)* a = b *a + c* a

**Examples:**

The integers mod n under addition and multiplication or the integers under addition and multiplication - note that multiplicative inverses are not required.

### Field

A **FIELD** is a set F which is CLOSED under two operations + and *. It is a **GROUP** under both + and* and satisfies the following properties:

- F is an abelian group under + and *
- F − {0} (the set F without the identity element of +, '0') is an abelian group under *.

**Example:**

The integers mod n under addition and multiplication, **where n is a prime number**. Like for n=7, F = {0,1,2,3,4,5,6},
Check that it is an additive group and that without 0 it is a group under multiplication.

**Note that if n is not a prime number** the integers mod n is no longer a field since  without 0 it is no longer a group under multiplication.

#### Negation of a value in a field

The **negation** (or **additive inverse**) of an element `a` in a finite field **F_p** is the value `-a` such that:

```markdown
a + (-a) ≡ 0 (mod p)
```

In other words, the negation of `a` is the element that, when added to `a`, results in the **additive identity** of the field, which is `0`.

To find the negation of a number `a` in a field **F_p**:

```markdown
neg(a) = (p - a) mod p
```

For example, if `p = 7` (i.e., **F_7**):
- The negation of `3` is `(7 - 3) mod 7 = 4`.
- The negation of `0` is `(7 - 0) mod 7 = 0` (since `0` is its own inverse).
- The negation of `6` is `(7 - 6) mod 7 = 1`.

#### Finite Prime Field: F_p

The previous example is a case of a Finite Prime Field, sometimes denoted as F_p. The group properties they have under multiplication and addition will be fundamental to develop ZK circuits.

Understanding the connection between finite prime fields and ZK circuits is crucial to grasp how ZK proofs work, especially in systems like zk-SNARKs and zk-STARKs. They are fundamental to the construction of elliptic curve cryptography (ECC) and the arithmetic in ZK circuits.

## Zero Knowledge (ZK) Proofs

### TO DO
### ZK-SNARKs

### ZK-STARKs

## ZK Circuits

ZK circuits are the computational circuits that verify a statement or proof without revealing the underlying data. These circuits are built over finite fields (such as F_p) to enable efficient computation and verification.

An F_p-arithmetic circuit is a circuit consisting of set of wires that carry values from the field F_p and connect them to addition and multiplication gates modulo p.

### Signals and Gates

So, an arithmetic circuit takes some input signals that are values between 0,...,p-1 and performs additions and multiplications between them modulo the prime p. The output of every addition and multiplication gate is considered an intermediate signal, except for the last gate of the circuit, the output of which is the output signal of the circuit.

**Example**
An F_7-arithmetic circuit given by

```markdown
out = in_1*in_2 + in_3
```

The input signals are in_1, in_2 and in_3 and the output signal is out. The operationn should be done one at the time so actually it works like this

```markdown
intermediate = in_1*in_2 mod 7
out = intermediate+ in_3 mod 7
```

intermediate is an intermediate signal.

### Constraints and Rank-1 Constraint Systems (R1CS)

An arithmetic circuit with signals s_1, ... , s_n (inputs and output) can be written as a set of equations of the form

```markdown
(a_1*s_1 + ... + a_n*s_n) * (b_1*s_1 + ... + b_n*s_n) + (c_1*s_1 + ... + c_n*s_n) = 0
```

this form defines a constraint. The a_i, b_i and c_i are coefficients and must also belong to the prime field, i.e. their values are between 0,...,p-1.

In the previous simple F_7-arithmetic circuit example we have:

```markdown
s_1 = in_1, s_2 = in_2, s_3 = in_3, s_4 = out
a_1 = 1, b_2 = 1, c_3 = 1, c_4 = -1 mod 7 = 7 - 1 = 6
```

This defines the constraint

```markdown
in_1 * in_2 + in_3 + 6 out = 0
```

**Remember that all operations in the prime field are defined mod p.** Hence, note that

```markdown
in_1 * in_2 + in_3 + 6 out mod 7 = 0
```

is equivalent to

```markdown
in_1*in_2 + in_3 = out mod 7
```

what we used to define the circuit in the first place.

This form that defines a constraint is just a more useful, compact and standardized form that can be used to define all circuits. Constraints must be quadratic (have at least one term s * s), linear (no quadratic terms and have two or more addition terms with different signals, ex: s_i + a s_j = 0, where a is a coefficient) or constant equations (s = coefficient, no more terms).

The set of constraints describing the circuit is called rank-1 constraint system (R1CS):

```markdown
(a_11*s_1 + ... + a_1n*s_n) * (b_11*s_1 + ... + b_1n*s_n) + (c_11*s_1 + ... + c_1n*s_n) = 0
```

...

```markdown
(a_m1*s_1 + ... + a_mn*s_n) * (b_m1*s_1 + ... + b_mn*s_n) + (c_m1*s_1 + ... + c_mn*s_n) = 0
```

where m <=n (m is the total number of equations, n is the total number of signals).
In production environments the logical conditions that define everything form one big circuit that is composed of many smaller circuit. The R1CS of the system describes all of them. It is a set of equations in the aforementioned form that may be written in matrix form as

\[
\mathbf{A} \mathbf{s} \odot \mathbf{B} \mathbf{s} + \mathbf{C} \mathbf{s} = 0
\]
where

\[
\mathbf{s} = \begin{bmatrix} s_1 \\ s_2 \\ \vdots \\ s_n \end{bmatrix}
\]


- \(\mathbf{A} = \begin{bmatrix} a_{11} & a_{12} & \dots & a_{1n} \\ a_{21} & a_{22} & \dots & a_{2n} \\ \vdots & \vdots & \ddots & \vdots \\ a_{m1} & a_{m2} & \dots & a_{mn} \end{bmatrix}\) is the matrix of coefficients for the first terms in each equation.
  
- \(\mathbf{B} = \begin{bmatrix} b_{11} & b_{12} & \dots & b_{1n} \\ b_{21} & b_{22} & \dots & b_{2n} \\ \vdots & \vdots & \ddots & \vdots \\ b_{m1} & b_{m2} & \dots & b_{mn} \end{bmatrix}\) is the matrix of coefficients for the second terms in each equation.

- \(\mathbf{C} = \begin{bmatrix} c_{11} & c_{12} & \dots & c_{1n} \\ c_{21} & c_{22} & \dots & c_{2n} \\ \vdots & \vdots & \ddots & \vdots \\ c_{m1} & c_{m2} & \dots & c_{mn} \end{bmatrix}\) is the matrix of coefficients for the constant terms.

and  \(\odot\) denotes the element-wise (Hadamard) product of the resulting vectors \(\mathbf{A} \mathbf{s}\) and \(\mathbf{B} \mathbf{s}\).

### Circuit Satisfiablity and Witnesses

Zero-knowledge permits proving circuit satisfiability. What this means is, that you can prove that you know a set of signals that satisfy the circuit, or in other words, that you know a solution to the R1CS. This set of signals is called the **witness**.

Given a set of inputs, the calculation of the intermediate and output signals is pretty straightforward. So, given any set of inputs, we can always calculate the rest of the signals. So, why should we talk about circuit satisfiability? The key aspect of zero-knowledge proofs is that it allows you to compute these circuits without revealing information about the signals.

For instance, imagine that in the previous circuit, the input in_1 is a private key and the input in_2 is the corresponding public key. You may be okay with revealing in_2 but you certainly do not want to reveal in_1. If we define in_1 as a private input, in_2, in_3 as public inputs and out as a public output, with zero-knowledge we are able to prove, without revealing its value, that we know a private input in_1 such that, for certain public values in_2, in_3 and out, the equationin_1*in_2 + in_3 = out mod 7 holds.

**An assignment of the signals is called a witness**. For example, {in_1 = 2, in_2 = 6, in_3 = -1, out = 4} would be a valid witness for the example F-7-arithmetic circuit. The assignment {in_1 = 1, in_2 = 2, in_3 = 1, out = 0} would not be a valid witness, since it does not satisfy the equation in_1*in_2 + in_3 = out mod 7.

Thus, a witness may be valid and be able to generate a **proof** or invalid and fail to generate a **proof**.

### Proof Generation

When one has a witness one may create a proof using the Groth16 zk-SNARK protocol and the snarkJS library. For this, one needs to generate a trusted setup in order to generate a zkey and a verification key. The zkey and the witness are then used to generate a proof.

### Verifying a Proof

To verify a proof using the Groth16 zk-SNARK protocol one needs the proof and the verification key.

## Diffie-Hellman (Post Quantum) Key Exchange

**Diffie-Hellman (DH) post-quantum key exchange** refers to a cryptographic key exchange mechanism that provides security even against quantum computers. In traditional Diffie-Hellman key exchange, security is based on the **discrete logarithm problem**, which can be efficiently solved by quantum computers using **Shor's algorithm**, making it vulnerable to quantum attacks.

### Classical Diffie-Hellman Key Exchange

In its classical form, the Diffie-Hellman key exchange involves two parties, Alice and Bob, who wish to agree on a shared secret key without anyone eavesdropping on their conversation being able to compute the secret.

**Step 1: Public Parameters**  
Alice and Bob agree on a large prime number `p` and a generator `g` of a multiplicative group modulo `p`. Both `p` and `g` are public and can be known by everyone.

**Step 2: Private Keys**  
Alice randomly chooses a private key `a`, and Bob chooses a private key `b`. These keys remain secret.

**Step 3: Public Keys**  
Alice computes her public key `A = g^a mod p`, and Bob computes his public key `B = g^b mod p`. They exchange their public keys.

**Step 4: Shared Secret**  
Using the received public key, Alice computes the shared secret as `s = B^a mod p`, and Bob computes the same shared secret as `s = A^b mod p`. Since `A = g^a` and `B = g^b`, both derive the same shared secret `s = g^(ab) mod p`.

This shared secret can now be used as a key to encrypt subsequent communications between Alice and Bob.

### Post-Quantum Key Exchange

Classical Diffie-Hellman key exchange relies on the difficulty of solving the discrete logarithm problem (i.e., finding `a` from `g^a mod p`), which is computationally hard for classical computers. However, quantum computers can solve this problem efficiently using Shor's algorithm, making the classical Diffie-Hellman protocol vulnerable.

Post-quantum key exchange aims to replace the classical protocol with algorithms that remain secure even in the presence of quantum computers. Some proposed alternatives for post-quantum key exchange are based on mathematical problems that are believed to be resistant to quantum attacks. These include:

**Lattice-based Cryptography**
This approach relies on the hardness of problems like the Shortest Vector Problem (SVP) or the Learning With Errors (LWE) problem. Protocols like Kyber and NewHope are lattice-based and are candidates for post-quantum key exchange.

**Multivariate Quadratic Equations**
Systems based on solving systems of multivariate quadratic equations are also considered post-quantum secure. Cryptographic systems such as Rainbow operate on this principle.

**Code-based Cryptography**
This approach relies on the hardness of decoding random linear codes. An example is the McEliece cryptosystem.

**In summary**, Diffie-Hellman post-quantum key exchange refers to methods that replace traditional DH with quantum-resistant alternatives, ensuring secure key exchange even against quantum adversaries.

## Elliptic Curves

**Elliptic curves** are a type of algebraic curve that has found numerous applications in modern cryptography. When defined over a finite field, elliptic curves provide the foundation for secure cryptographic protocols due to their hard-to-reverse mathematical properties.

An elliptic curve is a set of points that satisfy a specific equation of the form:

```markdown
y^2 = x^3 + ax + b
```

This equation represents a **cubic curve** that is non-singular, meaning it has no cusps or self-intersections. The parameters \( a \) and \( b \) determine the shape and properties of the curve, and they must satisfy a specific condition to ensure that the curve is smooth:

```markdown
4a^3 + 27b^2 != 0
```

This condition ensures that the curve has no sharp corners or other singularities.

### Elliptic Curves Over a Finite Prime Field

In cryptographic applications, elliptic curves are often defined over a **finite field** \( F_p \), where \( p \) is a **prime number**. This means that all calculations are performed modulo \( p \), resulting in a set of points that form an **abelian group** under an operation, usually named addition, defined in the curve, see [1. Point Addition](#1-point-addition).

Hence, an elliptic curve over a finite prime field is no longer a continuous curve, but rather a set of discrete points, where each point can be obtained through repeated applications of the elliptic curve point addition operation on other points. An elliptic curve over a finite prime field \( F_p \) is defined by the equation:

```markdown
y^2 = x^3 + ax + b mod p
```

Where:

- \( x, y, a, b \) are elements of the finite field \( F_p \).
- \( p \) is a prime number that defines the size of the field.

In this context, the values of \( x \) and \( y \) are restricted to the integers between \( 0 \) and \( p-1 \), and all arithmetic operations (addition, subtraction, multiplication, division) are performed modulo \( p \).

An elliptic curve over a finite prime field \( F_p \) equation can also be written in its Twisted Edwards form

```markdown
ax^2 + y^2 = 1 + dx^2y^2 mod p
```

Where:

- \( x, y, a, d \) are elements of the finite field \( F_p \).
- \( p \) is a prime number that defines the size of the field.

The Twisted Edwards form is particularly popular in cryptography because of its efficient addition formulas, which help with faster computation of operations like point addition and scalar multiplication.

## Baby JubJub Elliptic Curve

**Baby Jubjub** is a specialized elliptic curve designed for use in cryptographic systems that require efficient and secure operations, such as zero-knowledge proofs, privacy-preserving transactions, and digital signatures. Defined by a twisted Edwards curve equation, Baby Jubjub provides an optimal balance of security and performance, making it a popular choice for modern cryptographic applications.

Baby Jubjub is commonly used in **zero-knowledge proof** systems like zk-SNARKs, which enable a party to prove knowledge of a value without revealing the value itself. Its efficient arithmetic properties make Baby Jubjub particularly well-suited for these applications, where performance is crucial.

Additionally, Baby Jubjub is used in **privacy-preserving transactions**, particularly for creating **Pedersen commitments**. These commitments allow transaction values to remain hidden while still enabling validation of the correctness of transactions.

The curve also plays a role in **digital signatures**, where private keys are used to sign messages and public keys are used for verification. The efficiency of elliptic curve operations on Baby Jubjub ensures that both the signing and verification processes are secure and efficient.

 In general, elliptic curves can be described by equations of a particular form, and for Baby Jubjub, it uses a twisted Edwards curve equation, which is given by:

```markdown
ax^2 + y^2 = 1 + dx^2y^2
```

In the specific case of Baby Jubjub, the constants \(a\) and \(d\) have particular values:

- a = 168700
- d = 168696

Using these values, the curve equation becomes:

```markdown
168700*x^2 + y^2 = 1 + 168696*x^2*y^2 mod p
```

This equation is the defining property of the Baby Jubjub elliptic curve. A point \((x, y)\) is said to **lie on the curve** if and only if the above equation holds true when we plug in the values of \(x\) and \(y\). The coordinates x and y for both points are large integers within the prime field F_p, for Baby Jubjub curve the prime p

```markdown
p = 21888242871839275222246405745257275088548364400416034343698204186575808495617
```

This is the field prime of the BN254 elliptic curve, also known as BLS12-381 or BN128 (depending on the application).

### Operations on Baby Jubjub Elliptic Curve

#### Pedersen Commitments

Pedersen commitments are a fundamental cryptographic building block used extensively in privacy-preserving applications, including zero-knowledge proofs, blockchain protocols, and confidential transactions. They provide a way to commit to a value while keeping it hidden but still allowing verification of consistency without revealing the value itself.

Pedersen commitments are designed to be binding and hiding:

- Binding: Once you commit to a value, you cannot change it (you cannot commit to two different values with the same commitment).
- Hiding: The commitment does not reveal the committed value.

A Pedersen commitment allows one to commit to a value v_i using a random value r_i such that the commitment can be used later to verify the value without revealing it. The commitment scheme uses elliptic curves or other finite cyclic groups and leverages the difficulty of the discrete logarithm problem for security.
A Pedersen commitment can be written in the form

```markdown
Pedersen_commit(v_i, r_i) = v_i . G + r_i . H
```
where . means scalar multiplication, see [2. Scalar Multiplication](#2-scalar-multiplication), G is the base point of the Baby JubJub elliptic curve, see section **2. Base Point on Baby Jubjub** on  [Public Key Generation in Baby Jubjub Elliptic Curve](#public-key-generation-in-enygma), and H is another fixed point in the Baby Jubjub elliptic curve, known as randomizing point.  H = (x_H, y_H) where

```markdown
x_H = 10100005861917718053548237064487763771145251762383025193119768015180892676690
y_H = 7512830269827713629724023825249861327768672768516116945507944076335453576011
```

**H Parameter Generation (NUMS - Nothing Up My Sleeve)**

The H parameter is generated using the **Nothing Up My Sleeve (NUMS)** methodology to ensure security. For Pedersen commitments `Commit(v, r) = v*G + r*H`, security requires that **nobody knows the discrete log relationship** between G and H. If someone knew `k` such that `H = k*G`, they could open commitments to arbitrary values, breaking the binding property.

The NUMS approach:

1. Starts with a seed value (1)
2. Hashes repeatedly using SHA256 until finding a valid x-coordinate on the curve
3. Computes the corresponding y-coordinate
4. Clears the cofactor by multiplying by 8 (to ensure the point is in the prime-order subgroup)

This ensures:

- **No trapdoor** — you can't secretly pick an H where you know the discrete log to G
- **Publicly verifiable** — anyone can reproduce this exact computation starting from seed=1
- **Deterministic** — the SHA256 chain makes it computationally infeasible to have "aimed" for a specific point

The H parameter generation utility is available in `rayls-gnark-api/cmd/setup/generate_h_parameter/`.

G and H are **linearly independent**, meaning that **there is no scalar k** such that

```markdown
 H = k . G
 ```

 This linear independence is important for the security of Pedersen commitments, ensuring that the randomness added by H is effective in hiding the value v_i.

#### The Point at Infinity ("Zero" Point, Identity Point)

In elliptic curve arithmetic, the **point at infinity** plays the role of the **identity element**, similar to how `0` acts as the identity in addition for regular numbers. This point is special because when it is added to any other point on the curve, it yields that same point.

For the **Baby Jubjub** elliptic curve, the point at infinity is represented as:

```markdown
(0, 1)
```

**Properties of the Point `(0, 1)`**

- **Identity Element**: The point `(0, 1)` is the identity element in the group of points on the Baby Jubjub curve. This means that for any point `P` on the curve, the addition `P + (0, 1)` results in `P`.
- **Elliptic Curve Group Law**: The addition of points on the Baby Jubjub curve is defined such that `(0, 1)` behaves like the "zero" of the group. This property is essential for cryptographic operations like scalar multiplication, where repeated addition of points is used.

**Pedersen Commitment for `v = 0` and `r = 0`**

The **Pedersen commitment** is a cryptographic primitive that allows for committing to a value while maintaining privacy:

```markdown
C(v, r) = v . G + r . H
```

Where:
- `v` is the value to commit.
- `r` is a randomizing factor.
- `G` and `H` are fixed points on the elliptic curve.

For the Baby Jubjub curve, when both `v = 0` and `r = 0`, the commitment becomes:

```markdown
C(0, 0) = 0 . G + 0 . H = (0, 1)
```

Thus, the point `(0, 1)` is the **commitment** for `v = 0` and `r = 0`, indicating the "neutral" or "zero" state of the commitment.

#### 1. Point Addition

Points on the Baby Jubjub curve can be **added** together using specific rules that maintain their membership on the curve. This operation is used in generating public keys and performing various cryptographic protocols.

The **addition** of two points `P = (x1, y1)` and `Q = (x2, y2)` on an elliptic curve is defined as follows:

- If `P = O`, then `P + Q = Q`.
- If `Q = O`, then `P + Q = P`.
- If `x1 = x2` and `y1 = -y2 mod p`, then `P + Q = O`.
- Otherwise, the sum `R = P + Q = (x3, y3)` is calculated using:
  - The slope `lambda` is computed as:

    ```markdown
    lambda = (y2 - y1) / (x2 - x1) mod p  if P != Q
    ```

    or

    ```markdown
    lambda = (3*x1^2 + a) / (2*y1) mod p  if P = Q
    ```

  - The coordinates of the resulting point `R = (x3, y3)` are given by:

    ```markdown
    x3 = lambda^2 - x1 - x2 mod p
    y3 = lambda * (x1 - x3) - y1 mod p
    ```

#### 2. Scalar Multiplication

**Scalar multiplication** involves multiplying a point by an integer, which is achieved through repeated point addition. This operation is at the core of elliptic curve cryptography and is used to derive the public key from the private key.

**Scalar multiplication** involves adding a point `P` to itself repeatedly. For a scalar `k`, the scalar multiplication `k . P` represents adding the point `P` to itself `k` times. This operation is the foundation of elliptic curve cryptography (ECC):

```markdown
k . P = P + P + ... + P  (k times)
```

Scalar multiplication is computationally efficient in one direction (finding `k . P`) but is very difficult to reverse (finding `k` given `P` and `k . P`), which is known as the **elliptic curve discrete logarithm problem (ECDLP)**.

#### 3. Checking Curve Membership

To verify whether a point `(x, y)` lies on the Baby Jubjub curve, substitute the coordinates into the curve equation:

```markdown
168700*x^2 + y^2 = 1 + 168696*x^2*y^2 mod p
```

If the equation holds, the point is a valid point on the curve.

### Public Key Generation in Enygma

**Steps to Generate the Enygma Spend Key Pair**

1. Choose a Private Key (Secret Key)

The private key is a randomly chosen integer, sk, that is an element of the field F_p, i.e., a large random number modulo p. For Baby Jubjub, the prime p is

```markdown
p = 21888242871839275222246405745257275088548364400416034343698204186575808495617
```

so the private key is in the range:

```markdown
0 <= sk < p
```

In pseudocode:

```markdown
sk = random(0, p-1)
```

2. Calculate the Public Key

The public key is calculated using the Poseidon hash function:

```markdown
pk = PoseidonHash(sk, sk) mod p_subgroup
```

where `p_subgroup = 2736030358979909402780800718157159386076813972158567259200215660948447373041` is the Baby JubJub subgroup order.

The public key pk is a scalar value (not a curve point), which is more efficient for circuit verification.

**Note on Base Point G**

Baby Jubjub has a defined base point G on the curve, used for Pedersen commitments (not for public key generation in Enygma):

G = (x_G, y_G) where

```markdown
x_G = 16540640123574156134436876038791482806971768689494387082833631921987005038935
y_G = 20819045374670962167435360035096875258406992893633759881276124905556507972311
```

## Secure, Zero-sum transactions in a Private Environment using Baby JubJub Elliptic Curve Cryptography

### Security and Privacy of Public Keys and Secret Values in Pedersen Commitments

In elliptic curve cryptography, including the **Baby Jubjub** curve, the security of a **secret key** relies on the difficulty of the **Elliptic Curve Discrete Logarithm Problem (ECDLP)**. The ECDLP states that given a point `P` on the elliptic curve and a point `Q` that is the result of scalar multiplication (`Q = sk . P`), it is computationally infeasible to determine the scalar `sk` (the secret key) from the points `P` and `Q`. This property ensures that:

- **Secret keys are safe** because it is practically impossible to derive the secret key from the public key, even with significant computational power.
- The security of elliptic curve cryptography comes from the fact that no efficient algorithm exists to solve the discrete logarithm problem for elliptic curves of sufficient size.

Thus, **Baby Jubjub** provides strong security guarantees for secret keys, making it ideal for use in zero-knowledge proofs and digital signatures, where the secrecy of the private key is paramount.

**Pedersen commitments** are used to **hide values** in cryptographic protocols, ensuring privacy while allowing verification of the commitment's correctness. The value `v` in a Pedersen commitment is hidden because the commitment `C(v, r)` is a point on the elliptic curve that uniquely depends on both `v` and `r`. The properties of elliptic curve arithmetic ensure that:

- The **commitment** `C(v, r)` maps uniquely to a single point on the curve, but given just the point `C(v, r)`, it is **infeasible to determine** either `v` or `r` without knowing the other.
- This means that **only knowing `v` or `r`** is insufficient to reveal the other value or the commitment itself, providing a high level of privacy.

### Unique Mapping and Privacy

- The commitment `C(v, r)` uniquely represents the combination of `v` and `r`, and due to the properties of the elliptic curve, the result of `v . G + r . H` cannot be separated back into `v` and `r` independently.
- Even if an adversary knows the points `G` and `H`, as well as the resulting commitment `C(v, r)`, they cannot determine the individual values of `v` or `r` due to the **hardness of the discrete logarithm problem** on elliptic curves.

Thus, Pedersen commitments provide privacy by ensuring that the committed value v remains hidden unless the randomizing factor r is known. While knowledge of r allows calculation of v, without r, the commitment reveals no information about v due to the hardness of the discrete logarithm problem. This property makes Pedersen commitments highly effective for privacy-preserving protocols, such as those involving Baby Jubjub elliptic curves.

**Summary**

- **Secret keys** are safe in Baby Jubjub elliptic curves due to the difficulty of solving the Elliptic Curve Discrete Logarithm Problem (ECDLP).
- In **Pedersen commitments**, the value `v` is hidden because the commitment `C(v, r)` is a unique point on the curve that cannot be separated into `v` and `r` independently without knowing both values.
- The combination of strong security for secret keys and the privacy guarantees of Pedersen commitments makes Baby Jubjub an ideal choice for modern cryptographic systems focused on privacy and security.

### Balanced Commitments and Zero-Sum Transactions

A way to enforce a valid transaction is to require that the **sum of all commitments equals the identity point** :
```markdown
Sum(C_i) = Sum(v_i . G + r_i . H) = (0, 1)  (for i in B)
```

Where `B` is the set of all commitments in the transaction. This equation ensures that the transaction is **balanced**, meaning there are no net gains or losses (`zero-sum`), and the commitments effectively "cancel out" to zero.

Breaking down the summation further, we have:

```markdown
Sum(C_i) = Sum(v_i . G) + Sum(r_i . H) = (0, 1)
```

To satisfy this condition, both components must independently sum to their respective identity elements on the elliptic curve:

1. **Sum of All Values (`v`)**:

   ```markdown
   Sum(v_i . G) = 0 . G
   ```

   Since `G` is a fixed point on the curve, this implies that:

   ```markdown
   Sum(v_i) ≡ 0 (mod p)
   ```

   This means that the total value of all commitments must be zero modulo `p`. In other words, the sum of all values (`v_i`) in the transaction must balance out to zero, ensuring that no tokens are created or destroyed.

2. **Sum of All Random Values (`r`)**:

   ```markdown
   Sum(r_i . H) = 0 . H
   ```

   Since `H` is also a fixed point on the curve, this implies that:

   ```markdown
   Sum(r_i) ≡ 0 (mod p)
   ```

   This means that the total sum of all random values (`r_i`) used in the commitments must also be zero modulo `p`. This ensures that the randomness used to obscure the commitments balances out, preserving privacy while maintaining consistency.

This ensures that the randomness used in the commitments balances out, maintaining the privacy of the transaction while ensuring consistency.

**Summary**

- **Balanced Commitments**: In privacy-preserving transactions, all commitments must balance to yield the **identity point** `(0, 1)` on the elliptic curve. This guarantees that no value is created or lost in the process.
- **Zero-Sum Property**: The requirement that the sum of all commitments equals the identity point implies that both the **sum of all values** (`v`) and the **sum of all random values** (`r`) must be zero modulo `p`.
- These properties ensure that the cryptographic commitments are **correct**, **consistent**, and **privacy-preserving**, providing the basis for **secure zero-knowledge transactions**.

The concepts of **balanced commitments** and **zero-sum transactions** are crucial for maintaining the integrity of cryptographic systems that rely on elliptic curve commitments, such as those using **Baby Jubjub**.

## Implementation in Enygma

### Keys and Setup

When a participant is registered in the VEN (Value Exchange Network) two keys are generated for them:

- **Enygma Spend Key**: A secret key (sk) used to spend funds in Enygma. The corresponding public key is derived as `pk = PoseidonHash(sk, sk) mod p`. This key is never shared and is used to prove ownership when spending.
- **View Key (DH Key)**: A post-quantum Diffie-Hellman key, see [Diffie-Hellman (Post Quantum) Key Exchange](#diffie-hellman-post-quantum-key-exchange). This key is used to encrypt transactions for the recipient. The secret key is shared in an encrypted manner with the VEN operator. It is also used to generate shared secrets among the Enygma participants. These secrets are used in the generation of the random factors and tag messages that enter in the Pedersen Commitments of transactions, see [What Defines a Valid Transaction, Ensuring Zero-Sum](#what-defines-a-valid-transaction-ensuring-zero-sum).

When a participant joins the VEN, it should use its Diffie-Hellman key to generate a secret with all other participants and send the correspondent value individually to each one of them. Each participant should have an array of shared secrets with all other participants, with 0 in the position that corresponds to the shared secret with himself.

For instance, participant C joins a VEN with two other participants, A and B. A has chainId 0, B chaindId 1 and C chainId 2.

Before C joins, A and B have a shared secrets array given by

```markdown
s_A = [0, s_AB]
s_B = [s_AB, 0]
```

C joins and generates s_AC and s_BC and sends these values to A and B, respectively.
After that, the shared secret arrays in the VEN will be

```markdown
s_A = [0, s_AB, s_AC]
s_B = [s_AB, 0, s_BC]
s_C = [s_AC, s_BC, 0]
```

Note that all the shared secrets may be combined in a n x n symmetric matrix with 0s in the diagonal, where n is the total number of participants in Enygma.
This matrix can only be viewed by an auditor with god view privilege, each participant only has access to its array.

### Representation and Evolution of Balances

In Enygma the balance of each participant is represented by a Pedersen Commitment, see section [Pedersen Commitments](#pedersen-commitments). So, in Enygma each participant has two Baby Jubjub EC points associated to its `chainId` (identifier inside the VEN):

- Its Baby JubJub Public Key
- Its Balance.

The Balance starts as the Identity Point (0,1), see [The Point at Infinity ("Zero" Point, Identity Point)](#the-point-at-infinity-zero-point-identity-point), that corresponds to the Pedersen Commitment C(0,0).

Its balance evolves by summing the new Pedersen Commitment (submited in a transaction) to their current balance, see [1. Point Addition](#1-point-addition). 

Example Flow:

**Start**

```markdown
Current_Balance = C(0,0) = (0,1)
```

**1st Transaction**

```markdown
Last_Balance = C(0,0) = (0,1)
New_Commitment = C(v_1,r_1)
Current_Balance = Last_Balance + New Commitment = (0,1) + C(v_1,r_1) = C(v_1,r_1)  
```

The property of the addition of the identity point was used.

**2nd Transaction**

```markdown
Last_Balance = C(v_1,r_1)
New_Commitment = C(v_2,r_2)
Current_Balance = Last_Balance + New Commitment = C(v_1,r_1) + C(v_2,r_2) = C(v_1+v_2,r_1+r_2)  
```

This can be generalised to the nth transaction:

**nth Transaction**

```markdown
Last_Balance = C(Sum(v_1,...,v_n-1), Sum(r_1,...,r_n-1))
New_Commitment = C(v_n,r_n)
Current_Balance =  C(Sum(v_1,...,v_n), Sum(r_1,...,r_n))  
```

Hence, the **current balance** of a participant is always given by the **Sum of all the txValues of that participant in all the transactions it was involved in**.

 As for the random values r_i, the **current random value - the one that needs to be inputed in a transaction (more on this later)** - is given by the **Sum of all the rValues of that participant in all the transactions it was involved in**.

Therefore, it is **essential** to **store and track the v and r values for all participants.**

### What Defines a Valid Transaction, Ensuring Zero-Sum

A transaction is defined by a set of Pedersen Commitments that represent the points to be added to the points that correspond to the balances of the participants in the transactions.

The transaction is valid when the sum of this set of Pedersen Commitments yields the Identity Point. For this to happen, the sum of all vs and all rs should yield 0 mod p, see [Balanced Commitments and Zero-Sum Transactions](#balanced-commitments-and-zero-sum-transactions).

To achieve this, the sender's value is set as the negative, in the elliptic curve sense, see section [Negation of a value in a field](#negation-of-a-value-in-a-field),  of the total value being sent, ensuring that the sum of all committed values (`v_i`) is zero.

Example of a valid transaction with 3 participants

```markdown
C_sender(totalValueToSend, r_Sender) = neg(totalValueToSend) . G + r_sender . H
```

```markdown
C_receiver_1(v_1, r_1) = v_1 . G + r_1 . H
```

```markdown
C_receiver_2(v_2, r_2) = v_2 . G + r_2 . H
```

and

```markdown
totalValueToSend = v_1 + v_2
```

As for the random values, one should also have

```markdown
Sum(r_i) = 0 (mod p)
```

In an Enygma transaction this is ensured by deriving the random values (`r_i`) for each receiver participant using a **Poseidon hash** function. This function takes as input the shared secret between sender and receiver i, see [Keys and Setup](#keys-and-setup), and the current block number, ensuring that each `r` value is unique for each block number. Hence, the random values for the receivers are given by

```markdown
r_Receiver_i = neg(PoseidonHash(BlockNumber, s_SenderReceiver_i) mod p)
```
where neg is negation function in the prime field, see  [Negation of a value in a field](#negation-of-a-value-in-a-field).
As for the Sender, its r is given by
```markdown
r_Sender = Sum(neg(r_Receiver_i)) mod p = Sum(PoseidonHash(BlockNumber, s_SenderReceiver_i)) mod p
```
rSender is hence given by the sum of all negated receiver `r` values. Note that these two definitions **guarantee** Sum(r_i) = 0 mod p.

Example with 3 participants in a prime field p=7:
Let's say the Poseidon hashes of (SharedSecrets, blocknumber) give 25 and 36.
```markdown
r_Receiver_1 = neg(25 mod 7) = neg(4) = 3
```

```markdown
r_Receiver_2 = neg(36 mod 7) = neg(1) = 6
```

```markdown
r_Sender = Sum(neg(3), neg(6)) mod 7 = neg(3) + neg(6) mod 7 = 4 + 1 mod 7 = 5
```

and check that

```markdown
r_Sender + r_Receiver_1 + r_Receiver_2 = 5+ 3 +6 = 14 = 0 mod 7
```

### Nullifier and Double-Spending

A **nullifier** is a cryptographic value used to ensure that a particular transaction cannot be reused or spent multiple times, thus preventing double-spending. Nullifiers are unique to each transaction, ensuring that no two transactions use the same identifier, while also preserving the privacy of the participants.

Now follows an explanation of how the nullifier is implemented in enygma.

The **nullifier** in Enygma is calculated by hashing the following values using the **Poseidon hash** function:

- `block_number`: This ensures that the nullifier is tied to a specific block.
- `sk_Sender`: The Baby Jubjub secret key of the sender.

```markdown
nullifier = PoseidonHash(sk_Sender, block_number)
```

Properties and Uniqueness

- The use of the `block_number` in both the **random value** and **nullifier** calculations guarantees that each transaction generates unique `r` values for each block.
- As a result, the `nullifier` is also unique for each transaction, ensuring that the same set of commitments cannot be reused, thus preventing **double-spending**.
- However, this approach also means that each Sender is limited to **one "transaction" per block**, as the `block_number` is a key component in ensuring the uniqueness of both `r` values and the `nullifier`. "Transaction" because it is not a normal EVM transaction, this "transaction" has one sender but may have many receivers. So a participant may at most need to wait a block time, in the meantime it can agregate all the txs it needs to send and then send them all at once in the new block.

The nullifier is used in the function validateTransferInputs inside the function transfer, see [Pending and Finalised States, Rollover and tally of balances](#pending-and-finalised-states-rollover-and-tally-of-balances)

### Privacy, k-Anonymity and Anonymity Sets

In Enygma the balances and values in a transaction are always hidden, see [Security and Privacy of Public Keys and Secret Values in Pedersen Commitments](#security-and-privacy-of-public-keys-and-secret-values-in-pedersen-commitments). However, the participants involved in a transaction are public, since their Baby Jubjub public keys are in the public data of the transaction. By introducing anonymity sets and only performing transactions in a given set, one can hide the fact that some participants transacted with each other by adding other participants to the transaction, of course with a 0 txValue. The participants that exchange value in a transaction within a set are named active participants and the ones that don't are named passive participants. Obviously, the minimal number of active participants in a transaction that exchanges value, `MinimalNumberActiveParticipantsInOneTxWValue`, is two (2). This number is important in some edge cases. The number of participants in an anonymity set is defined by `k`. Naturally, if one does not introduce dummy participants in an anonymity set, the possible values for `k` are

```markdown
MinimalNumberActiveParticipantsInOneTxWValue = 2 <= k <= NumberOfParticipants (without dummies)
```

k-Anonymity is a privacy concept used to protect individual identities within a dataset. A dataset is said to have k-anonymity if each individual cannot be distinguished from at least k - 1 other individuals. In other words, an individual's data is indistinguishable from the data of k - 1 other participants, making it harder to identify them uniquely.

An anonymity set refers to the group of participants within a transaction or system that are indistinguishable from one another. The size of the anonymity set, typically represented as k, determines the degree of anonymity—the larger the set, the higher the privacy level, as it becomes more difficult to identify any one individual within the set.

Ideally, k would always be equal to the number of participants in the VEN, however for large k values one would have severe performance issues due to the size of the proofs. Hence, **in Enygma, k is set to 6**. It is important to discuss differently the three possible scenarios, when **Number of Participants > k**, when **Number of Participants = k** and when **Number of Participants < k** (the most problematic).

Before proceeding, note the edge case where **k <= 3 = MinimalNumberActiveParticipantsInOneTxWValue +1** or **Number of participants =3**.

For **k = 3**, when the minimal number of active participants in a transaction that exchanges value = 2 = k-1, if one participant sees a transaction that involves him went through and notices that his balance hasn't changed, he knows with **certainty** that the other two involved in the transaction exchanged value. Obviously, for **k=2**, the identity of the two active participants and the fact that they exchanged value is **public** to the VEN.

All of this is reflected when **Number of participants =3**, since the possible values for `k` (without introducing dummies) are 2 and 3. In this case it is indifferent if one chooses `k=2` or `k=3` since the shared information in one transaction is the **same**. For k=3 one knows when the other two transacted with themselves, with k=2 this would be seeing that a transaction went through where one was not involved.

In this case, k-anonymity is **not enough** to protect the identity of the ones in a transaction.

#### Number of Participants = k

When Number of Participants = k = 6, a transaction will always include all the participants in the VEN. If one participant sees a transaction went through and notices that his balance hasn't changed the only thing he can know with certainty is that at least two (minimal number of active participants in a transaction that exchanges value) of the other five (k-1) participants were active in a transaction.

#### Number of Participants > k

When Number of Participants > k = 6 we have two cases:

- A participant wants to send value to 5 (k-1) or less other participants
- A participant wants to send value to more than 5 (k-1) other participants

In the first case, the sender will just submit a transaction with 6 (k) participants, the other 5 (k-1) participants might be active or not. For the ones in the transaction, what they know reduces to the case of Number of Participants = k. For the ones not in the transaction, they know with certainty that at least two (minimal number of active participants in a transaction that exchanges value) of the other six (k) participants were active in a transaction.

In the second case, the transaction needs to be split into partial transactions with 6 (k) participants. In general,

```markdown
NumberOfTransactions = IntFloor(ActiveParticipantsInTx / k + 1)
```

where IntFloor(3.343543) = 3, IntFloor(1.84343) = 1 is a function that rounds down a number to a integer form. The ones in one of the partial transactions know the same information as the ones in the transaction in the first case. The ones not in a partial transaction also know the same information per transaction as the ones not in the transaction in the first case.

#### Number of Participants < k

The two previous case are the cases where k-anonymity works as expected.

In the case of `Number of Participants < k` a problem arises, there are not enough participants to complete the anonymity set. The natural solution is to add dummy participants, however these need to be completely indistinguishable from real participants. This would mean not exposing the relation `Baby Jubjub public key <-> chainId` and maybe even run infrastructure for the dummies.

But even with all that, since the **number and identity of participants in a VEN is public**, introducing dummy participants to complete the anonymity set would not solve the issue of  protecting the identity of the ones in a transaction when Number of participants = 3. The aforementioned problem would persist since **revealing the number of real participants** effectively reduces the anonymity set from `k` to `NumberOfParticipants`.

The best possible solution (without introducing fake transactions, see section [Fake Transactions: Enhancing Privacy Beyond Anonymity Sets (Especially Relevant when Number of Participants \< k)](#fake-transactions-enhancing-privacy-beyond-anonymity-sets-especially-relevant-when-number-of-participants--k)) is to, in the case of Number of Participants < k to always use

```markdown
k = NumberOfParticipants
```

So we would have:

- k = 2, Only two in the VEN, public things in the VEN are private to the two of them, no problems here.
- k = 3, The aformentioned issue persists. A third participant would know when the other two transact.
- k = 4 and k = 5 , One participant sees that a transaction went through and notices that his balance hasn't changed. The only thing he can know with certainty is that at least two (`MinimalNumberActiveParticipantsInOneTxWValue`) of the other 3/4 (`k-1`) participants were active in a transaction. This is OK.

This is the best possible solution for when `Number of Participants < k`, since introducing dummy participants is not viable. However, one may introduce fake transactions and improve the solution for this scenario and in general.

#### Fake Transactions: Enhancing Privacy Beyond Anonymity Sets (Especially Relevant when Number of Participants < k)

A way to improve the solution in all possible scenarios is to introduce **random transactions with random participants that exchange no value**. This removes the determinism in the conclusions one may extract from being in one transaction, since it is no longer guaranteed that in that transaction value was exchanged.

Introducing this changes the following earlier sentence

`" If one participant sees a transaction went through and notices that his balance hasn't changed the only thing he can know with certainty is that at least two (minimal number of active participants in a transaction that exchanges value) of the other five (k-1) participants were active in a transaction."`

to

`" If one participant sees a transaction went through and notices that his balance hasn't changed the only thing he can know with certainty is that MAYBE at least two (minimal number of active participants in a transaction that exchanges value) of the other five (k-1) participants were active in a transaction."`

and

`When k=3, if one participant sees a transaction that involves him went through and notices that his balance hasn't changed, he knows with **certainty** that the other two involved in the transaction exchanged value.`

to

`When k=3, if one participant sees a transaction that involves him went through and notices that his balance hasn't changed, he DOES NOT KNOW if the other two involved in the transaction exchanged value.`

This effectively solves the problem for **k <= 3** or **Number of participants =3** and improves the solution for the other cases since with it **a transaction does not translate to an exchange of value**.

Fake transactions were implemented in the protocol natively in the flow needed to deal with concurrent transactions (see [Concurrency of Transactions](#concurrency-of-transactions)). One can also incentivize participants in the VEN to periodically send random transactions to random receivers with 0 txValues.

##### Fake Transactions and Number of Participants < k

With fake transactions implemented, one would achieve the same level of privacy for Number of Participants < k by doing `k=2`. Doing `k = NumberOfParticipants` is more complicated in terms of infrastructure because one would need to change the proof setup everytime a participant joins the VEN up until NumberOfParticipants = 6 = k.

Hence, the proposed solution for privacy is

```markdown
k = 6 (+Fake Transactions), NumberOfParticipants >= 6
k = 2 + Fake Transactions, NumberOfParticipants < 6
```

(+Fake Transactions) means optional, but recommended.

### Concurrency of Transactions

It should be clear now that in Enygma a participant can only send one "transaction" per block. However, this is not a transaction in the EVM sense, since he may send value to `k-1` other participants. So, really the sentence should be

`In Enygma a participant can send value to 5 (k-1) other participants once per block.`

The values in the transaction and the identities of those involved are secret (if fake transactions are implement, if not the identities are k-anonymous, see [Privacy, k-Anonymity and Anonymity Sets](#privacy-k-anonymity-and-anonymity-sets)).

But what happens if multiple participants send transactions in the same block? We now dwell on the problem of concurrent transactions. There are two different issues:

- What happens if two different participants try to send a transaction simultaneously that has participants in common? Although both might be valid, only the first one that is submitted to the blockchain is going to go through and the other will fail. Why? Because the first one will change the Balances (Points in the Baby Jubjub EC, see [Representation and Evolution of Balances](#representation-and-evolution-of-balances)) of the ones in the transaction and possibly the `previous_r` and `previous_v` of the sender of the other one, causing these values in the second transaction to be wrong at the time of submission to the blockchain, causing that transaction to fail.
- What happens if a participant tries to send more than one transaction per block? He cannot generate two valid transactions with different nullifiers in one block, so a check on the nullifier in the contract will only allow one transaction to go through (the first one to be submitted). This is what **should** happen. Right now what happens is that the first one will go through and the second will timeout or will fail because of the same problem as above, the first transaction changes the balances and the value of the `previous_r` (current random value) and `previous_v` (current balance) of the sender, causing the values in the second transaction to be wrong.

A proper solution to these issues should solve for the case of different participants sending concurrent transactions with participants in common and also use the nullifier to prevent concurrent transactions from the same participant.

#### Pending and Finalised States, Rollover and tally of balances

This was implemented by creating two states: `finalised` and `pending`. `Finalised` indicates that the registration/update is complete, while `pending` means that transactions are currently being accepted and updates are in progress. This implementation required numerous changes. Previously, since balances are stored per block number, `lastBlockNum` recorded the last block number where balances were updated. Now, we have `lastBlockNum` (the last block number where balances were finalised) and `lastBlockNumPending` (the next block number to be finalised, which is currently accepting transactions). This functions as a buffer or mempool, where the following structs

```solidity

    struct PendingTransaction {
        EnygmaPointWithChainId[] pointsToAddToBalance;
        uint256 nullifier;
    }

    struct PendingMintOrBurn {
        EnygmaPointWithChainId pointToAddToBalance;
        uint256 amount;
        uint256 blockNumber;
        uint8 transactionType; // 1 = mint, 2 = burn
    }
```

will populate the arrays

```solidity
    PendingTransaction[] public pendingTransactions;
    PendingMintOrBurn[] public pendingMintsAndBurns;
```

for the block number `lastBlockNumPending`. `lastBlockNumPending` becomes `lastBlockNum` when a transaction arrives with a current block number `currentBlockNum` > `lastBlockNumPending`. So a balance is finalised when a transaction with a block larger than `lastBlockNumPending` arrives to the contract. This is done by calling the transfer function

```solidity
    function transfer(uint8 k, Point[] memory commitments, Proof memory proof, uint256[] memory chainIds, bytes[] memory encryptedMessages) public checkFreeze nonReentrant returns (bool) {
        uint256 currentBlockNumber = uint256(proof.public_signal[4 * k + 1]);
        uint256 nullifier = uint256(proof.public_signal[4 * k]);
        validateTransferInputs(k, commitments, proof, chainIds, nullifier, currentBlockNumber);
        verifyProof(k, proof);
        finalisePendingTransactions(currentBlockNumber);
        // Add the current transaction to pending balances
        addPendingTransaction(k, commitments, proof, chainIds, nullifier, lastblockNumAtCurrentBlockNumber[currentBlockNumber], currentBlockNumber);

        sendEvents(chainIds, encryptedMessages);
        lastblockNumPending = currentBlockNumber;

        emit TransactionSuccessful(msg.sender);
        return true;
    }
```

where validateTransferInputs will check if the nullifier is unique and if the block number is valid and other requirements

```solidity
    function validateTransferInputs(uint8 k, Point[] memory commitments, Proof memory proof, uint256[] memory chainIds, uint256 nullifier, uint256 currentBlockNumber) internal view {
        require(k >= 2, 'Invalid value for k');
        require(commitments.length == k, 'Wrong commitments length');
        require(chainIds.length == k, 'Wrong ChainIds Array length');
        require(proof.public_signal.length == 5 * k + 2, 'Wrong public_signal length in proof');
        require(verifiers[k] != address(0), 'Verifier not set for given k');
        require(currentBlockNumber > lastblockNum, 'BlockNumber in Proof was already finalised.');
        require(currentBlockNumber >= lastblockNumPending, 'Invalid BlockNumber Used in Proof.');
        require(currentBlockNumber <= block.number, 'BlockNumber Used in Proof is bigger than Current Block Number.');
        require(isNullifierUnique(nullifier), 'Nullifier already used in pending transaction.');
    }
```

and the finalisePendingTransactions does the behaviour previously explained, where the pending balances become finalised:

```solidity

    function finalisePendingTransactions(uint256 currentBlockNumber) internal {
        // Initialize block state if not already set
        if (lastblockNumAtCurrentBlockNumber[currentBlockNumber] == 0) {
            lastblockNumAtCurrentBlockNumber[currentBlockNumber] = lastblockNum;
            copyReferenceBalancesFromBlockNumberSourceToBlockNumberNew(currentBlockNumber, lastblockNumPending);
        }

        // Process pending actions if currentBlockNumber > lastblockNum
        if (currentBlockNumber > lastblockNum && (pendingTransactions.length > 0 || pendingMintsAndBurns.length > 0) && currentBlockNumber != lastblockNumPending) {
            processPendingActions(lastblockNumPending);
            lastblockNum = lastblockNumPending;
            pendingBalancesTallied[lastblockNumPending] = true;
            emit BalancesFinalised(lastblockNum);
        }
    }
```

verifyProof calls the verifier contract and checks if the proof in the input is valid, addPendingTransaction adds transactions to the pending arrays and sendEvents sends the events to all the receiving PLs. Note that the transactions are added to the pending pool and only finalised later, but the events are sent right away. The relayer plays an important role, see next.

Mints and burns are added to the pending transaction pool and also finalise previous transactions. mint function contains a speical case for the first mint.

```solidity
    function mintSupply(uint256 _amount, uint256 toChainId, uint256 _blockNumber) public onlyIssuer nonReentrant returns (bool) {
        (uint256 amtX, uint256 amtY) = derivePk(_amount);

        if (totalSupply == 0) {
            (totalSupplyX, totalSupplyY) = CurveBabyJubJub.pointAdd(totalSupplyX, totalSupplyY, amtX, amtY);
            totalSupply += _amount;

            updateBalances(toChainId, amtX, amtY, _blockNumber, true); // Global update for all participants
            lastblockNum = _blockNumber;
            lastblockNumPending = _blockNumber;
            pendingBalancesTallied[lastblockNumPending] = true;
            emit SupplyMinted(lastblockNum, _amount, toChainId);
        } else {
            uint256 currentBlockNumber = uint256(_blockNumber);

            finalisePendingTransactions(currentBlockNumber);

            // Add to pending mints and burns
            pendingMintsAndBurns.push(
                PendingMintOrBurn({
                    pointToAddToBalance: EnygmaPointWithChainId({c1: amtX, c2: amtY, chainId: toChainId}),
                    amount: _amount,
                    blockNumber: _blockNumber,
                    transactionType: 1 // Mint transaction
                })
            );
            lastblockNumPending = currentBlockNumber;
            updateBalances(toChainId, amtX, amtY, lastblockNumPending, false); // Specific update for one participant
        }

        return true;
    }

    function burn(uint256 _chainId, uint256 burnValue, uint256 _blockNumber) public onlyIssuer nonReentrant returns (bool) {
        require(burnValue <= CurveBabyJubJub.P, 'Error: burnValue > Q');
        (uint256 commX, uint256 commY) = pedCom(CurveBabyJubJub.P - burnValue, 0);

        uint256 currentBlockNumber = uint256(_blockNumber);

        finalisePendingTransactions(currentBlockNumber);

        // Add to pending mints and burns
        pendingMintsAndBurns.push(
            PendingMintOrBurn({
                pointToAddToBalance: EnygmaPointWithChainId({c1: commX, c2: commY, chainId: _chainId}),
                amount: burnValue,
                blockNumber: _blockNumber,
                transactionType: 2 // Burn transaction
            })
        );
        lastblockNumPending = currentBlockNumber;

        updateBalances(_chainId, commX, commY, lastblockNumPending, false); // Specific update for one participant

        return true;
    }
```

The finalisation is handled by the aforementioned function finalisePendingTransactions, where note the special handling of pending mints and burns, only if its registered block number is <= blockNumber that is being finalised are considered.

```solidity
    function processPendingActions(uint256 blockNumber) internal {
        delete pendingTransactions;

        uint256[] memory indicesToDelete = new uint256[](pendingMintsAndBurns.length);
        uint256 deleteCount = 0;

        for (uint256 i = 0; i < pendingMintsAndBurns.length; i++) {
            PendingMintOrBurn memory pending = pendingMintsAndBurns[i];

            if (pending.blockNumber <= blockNumber) {
                (totalSupplyX, totalSupplyY) = CurveBabyJubJub.pointAdd(totalSupplyX, totalSupplyY, pending.pointToAddToBalance.c1, pending.pointToAddToBalance.c2);
                if (pending.transactionType == 1) {
                    totalSupply += pending.amount;
                    emit SupplyMinted(lastblockNum, pending.amount, pending.pointToAddToBalance.chainId);
                } else if (pending.transactionType == 2) {
                    totalSupply -= pending.amount;
                    emit BurnSuccessful(pending.pointToAddToBalance.chainId, pending.amount);
                }

                indicesToDelete[deleteCount] = i;
                deleteCount++;
            }
        }

        for (uint256 i = 0; i < deleteCount; i++) {
            uint256 index = indicesToDelete[i];
            delete pendingMintsAndBurns[index];
        }
        uint256 length = pendingMintsAndBurns.length;
        uint256 writeIndex = 0;

        for (uint256 i = 0; i < length; i++) {
            if (pendingMintsAndBurns[i].amount != 0) {
                pendingMintsAndBurns[writeIndex] = pendingMintsAndBurns[i];
                writeIndex++;
            }
        }

        for (uint256 i = writeIndex; i < length; i++) {
            pendingMintsAndBurns.pop();
        }
    }
```

#### The role of the relayer in handling concurrent transactions

The relayer serves as a critical intermediary in the transaction process, performing several key functions in parallel, using `goroutines`. Before and after handling transaction sending and transaction reception events, the relayer will query the Private Network Hub to see if some or all of the current pending balances have been finalised, if yes, it will update the database. Next follows the expect behaviour of the realyer when handling the events.

1. **Handling Transaction Sending Event**: When receiving a transfer request, the relayer builds the transaction and proof by:
   - Selecting random participants to add to the transaction to fill the anonimity set (if needed)
   - Using the last finalized values for balances (all involved) and sender's r value

2. **Handling Transaction Reception Event**: After the receiver gets the event, the relayer:
   - Mints tokens in the receiver's PN (if received any)
   - Updates pending balance and r values in the database for the receiver

When the sender of a transaction receives the transaction reception event of it has a special behaviour, see next subsection.

##### Validation Transactions

After the sender receives the reception event correspondent to the transaction it just sent, the relayer, if the previous transaction was not retried (no congestion detected)

- Waits until blockNumber has increased from previous transaction
- Creates a "validation" (fake) transaction with k-1 random participants
- Sends 0 transaction value to all participants
- Flags the transaction in the encrypted message to prevent recursive validation

This process enables the system to handle concurrent transactions efficiently while maintaining security and anonymity through the carefully structured anonymity sets and validation mechanism, which ensures the last real transaction is finalised.

The need to retry some transactions is explained in the next section. Validation transactions are never retried.


#### Limitation: The Region where Enygma better Operates (ProofTime/UnitTime  <= 1)

The identified behavior represents a limitation rather than a defect. The contract previously lacked handling for a specific edge case, which has been addressed by implementing error handling as agreed.

  What happens in this edge case is that a transaction with a blocknumber N arrives to the PNH and blocknumber N was already finalised (the current pending block, the next to be finalised, is, let's say N+2), that transaction will fail and will be retried (new proof built + transmission) in the relayer with the most updated block number.

This occurs frequently when the ratio of `ProofTime/UnitTime >> 1`, where:

* **ProofTime**: Time required for relayer transaction construction and transmission (predominantly proof generation time)
* **UnitTime**: Contract time unit measurement used in the tally of balances (currently equivalent to `BlockTime`)

UnitTime defines the maximum expected wait time between transaction submission and finalization, due to the validation transaction mechanism. So basically it occurs frequently when the proof generation is too slow comparing to the pace of finalisation of pending balances.
This constraint can be mitigated by implementing an epoch-based time unit system:

```
UnitTime = n * BlockTime = 1 Epoch
```

Where `n` is a configurable multiplier. This approach:

1. Decouples time measurement from blockchain-specific block times
2. Enables pending balance tallying at epoch boundaries
3. Permits environment-specific optimization

**Current Implementation**: `UnitTime = 1 * BlockTime = 1 epoch`

Modifying the contract to support configurable epoch values would require some effort.

The system remains operational when `ProofTime/UnitTime > 1`, but exhibits the following behaviors:

* Error conditions occur with increasing frequency
* Transaction retries are initiated automatically
* Under high concurrency, timeout failures may occur after x retry attempts
* System integrity remains intact, but transaction throughput efficiency decreases

**Implementation Recommendations**

Enygma requires parameter optimization for each deployment environment. Optimal operation requires:

* Target ratio: `ProofTime/UnitTime <= 1`
* `ProofTime` typically ranges between 2-5 seconds on contemporary hardware
  * May fluctuate under relayer load conditions
* `UnitTime` configuration should consider:
  * Target blockchain's block time
  * Acceptable transaction finalization latency

Example Configuration

For blockchain with 1s block time:

```text
UnitTime = 5 * BlockTime = 1 epoch = 5s
```

This achieves the optimal operational ratio: `ProofTime/UnitTime <= 1`.

Failure to meet this condition results in the relayer frequently submitting proofs that are technically valid but based on outdated balance information. The smart contract rejects these submissions, forcing the relayer to retry transactions that would succeed if submitted with current data.

**Future Optimizations**

`ProofTime` reduction in Enygma V2.


#### Theoretical Throughput Limit

If every participant in the network, a bank, submits an Enygma transaction, using a k-anonymity of k, the theoretical maximum throughput is given by:

$$n_{\text{banks}} \times (k-1) \times n^i_{\text{addr}} \quad \text{per block}$$

where:
- $n_{\text{banks}} = \sum_i$ is the number of banks in the network
- $n^i_{\text{addr}}$ denotes the number of receiving addresses per bank

Given the double batching architecture of the design, overall system throughput is determined by the upper bound on receiving addresses per bank per block that the system can accommodate.

### Enygma Transaction Flow in Rayls

It all starts in the PNs. A PN deploys a enygma token in its PN, this generates a correspondent Enygma contract in the PNH, with the same resourceId.

A mint inside the PN will trigger a mint in the PNH contract, if it is the first mint in the contract, it is imediately finalised, otherwise it will be added to the pending transactions. A burn in the PN will trigger a burn in the PNH contract, that will be added to the pending transactions. The full flow for a transaction from one PN A to a PN B in a VEN with 10 participants follows.

A VEN with 10 participants will have k=6. So, if PN A wants to transfer x to PN B, it will call the crossTransfer function inside its PN, this will burn x enygma and send that transfer request to the relayer. The relayer then builds the transaction and the proof, and for that it chooses 4 random participants to add to the transaction such that it has 6 participants (4+ sender + receiver), to fill the anonimity set k=6.

 The values used in the proof (balances of all involved and r value of the sender) will be the current last finalised values, let's say those are from blockNumber N, the value of `lastBlockNum`.

 The random participants will receive 0 value but their r value will change in this transaction. The transaction will be registered in the contract with blocknumber N+1, the current value of `lastBlockNumPending`, the pending values will be updated in the PNH. After adding the tx to the pending arrays, the receiving transaction encrypted events will be sent to all the receivers of the transaction (4 random with 0 tx value + sender + receiver). Even the sender receives this event, to not reveal the identity of the sender of the transaction.

 When the receiver gets the event, it will mint in his PN x tokens and update the pending values of balance and r in the DB, the other participants of the tx will only update the r value in their db. When the sender receives this event, the relayer will wait for blockNumber N+2  and will build a `validation` (fake) transaction by selecting 5 random participants (from the pool of 10) and sending 0 tx value to all of them.

 When this arrives to the contract, since N+2 > N+1 > N, the last real transaction will be finalised and `lastBlockNum` will be changed to N+1 and `lastBlockNumPending` will be changed to N+2. This validation transaction is also added to the pending values and arrays, but it will only change the r values. Furthermore, it is flagged in the encrypted message sent to the relayer, so it will not generate another `validation` (fake) transaction when the reception event reaches the relayer of the sender.

### Quantum Resistance

Enygma uses post-quantum Diffie-Hellman keys, Baby Jubjub elliptic curve keys (susceptible to quantum attacks) and zero knowledge proofs based on ZK-SNARKs, also susceptible to quantum attacks.

However, Enygma becomes Quantum-private when a check on the correct structure and values of the shared secrets per Participant in a transaction is introduced in the circuit. This resistance is inherited from the shared secrets because these are generated using the Diffie-Hellman Post-Quantum Key, see [Diffie-Hellman (Post Quantum) Key Exchange](#diffie-hellman-post-quantum-key-exchange) and [Keys and Setup](#keys-and-setup).

This happens because even if a quantum hacker obtains the Baby Jubjub secret key that corresponds to the Public Key (ECC is not quantum resistant, in general) of one the participants he cannot generate their correct random values, as it would need the Diffie-Hellman Post-Quantum Key of the sender to generate them for a given block, see [What Defines a Valid Transaction, Ensuring Zero-Sum](#what-defines-a-valid-transaction-ensuring-zero-sum). This means that the values in the transactions are never disclosed even after a quantum attack.

Nonetheless, a quantum attacker may spoil the zero knowledge proofs, since they are based on ZK-SNARKs (Groth16).
However, when in danger of a quantum computer, a switch to post-quantum ZK proofs (e.g.,
ZK-STARKs) may be performed, thus ensuring end-to-end quantum-security in the system.

### Enygma Programmability

TODO

## Gnark

Gnark is a high-performance zero-knowledge proof library written in Go, developed by Consensys. It provides a framework for defining arithmetic circuits and generating zk-SNARK proofs. Enygma uses gnark v0.14.0 with the Groth16 proving system over the BN254 elliptic curve.

Unlike domain-specific languages like Circom, gnark circuits are defined directly in Go, providing type safety, native tooling support, and better performance for server-side proof generation.

### Overview

**Technology Stack:**
- **ZK Framework:** gnark v0.14.0 (Consensys)
- **Proving System:** Groth16
- **Elliptic Curve:** BN254 (256-bit pairing-friendly curve)
- **Hash Function:** Poseidon (custom Go implementation optimized for BN254)
- **Language:** Go

**Key Advantages over Circom:**
- **Server-side proving:** Proofs are generated directly in Go, eliminating WASM overhead
- **Type safety:** Go compiler catches errors at compile time
- **Performance:** Direct native execution, significantly faster than browser-based approaches
- **Custom hints:** Native Go functions can be registered for complex computations
- **Standard tooling:** Uses standard Go build tools, testing frameworks, and IDEs

### The Gnark Framework

#### Circuit Definition in Go

In gnark, circuits are defined as Go structs that implement the `frontend.Circuit` interface. Each field in the struct represents a signal (variable) in the circuit.

```go
package circuits

import (
    "github.com/consensys/gnark/frontend"
)

// Multiplier2Circuit multiplies two inputs
type Multiplier2Circuit struct {
    In1 frontend.Variable `gnark:",public"`  // Public input
    In2 frontend.Variable `gnark:",public"`  // Public input
    Out frontend.Variable `gnark:",public"`  // Public output
}

// Define implements the circuit logic
func (circuit *Multiplier2Circuit) Define(api frontend.API) error {
    // Constraint: Out == In1 * In2
    result := api.Mul(circuit.In1, circuit.In2)
    api.AssertIsEqual(circuit.Out, result)
    return nil
}
```

The `Define` method specifies the constraints that must be satisfied for a valid proof. The `frontend.API` provides methods for arithmetic operations and constraint generation.

#### Public and Private Inputs

In gnark, the visibility of circuit variables is controlled using struct tags:

- **Public inputs:** Use the tag `gnark:",public"` - these values are visible to the verifier
- **Private inputs:** No tag or empty tag `gnark:""` - these values are hidden from the verifier

```go
type EnygmaCircuit struct {
    // Private inputs (hidden from verifier)
    SenderId   frontend.Variable                    // Sender's identifier
    Secrets    [k]frontend.Variable                 // Shared secrets array
    Sk         frontend.Variable                    // Sender's secret key
    PreviousV  frontend.Variable                    // Previous balance
    PreviousR  frontend.Variable                    // Previous random factor
    TxValue    [k]frontend.Variable                 // Transaction values
    TxRandom   [k]frontend.Variable                 // Transaction random factors
    V          frontend.Variable                    // Amount to send

    // Public inputs (visible to verifier)
    PublicKey      [k][2]frontend.Variable `gnark:",public"`  // Public keys
    PreviousCommit [k][2]frontend.Variable `gnark:",public"`  // Previous commitments
    TxCommit       [k][2]frontend.Variable `gnark:",public"`  // New commitments
    Nullifier      frontend.Variable       `gnark:",public"`  // Anti-double-spend
    BlockNumber    frontend.Variable       `gnark:",public"`  // Block number
    KIndex         [k]frontend.Variable    `gnark:",public"`  // Participant indices
}
```

**Important:** In Enygma, there are no output signals. All public data is provided as public inputs, and the circuit verifies that the private inputs are consistent with these public values.

#### Constraint API

The `frontend.API` provides methods for building constraints:

**Arithmetic Operations:**
```go
api.Add(a, b)           // Addition: a + b
api.Sub(a, b)           // Subtraction: a - b
api.Mul(a, b)           // Multiplication: a * b
api.Div(a, b)           // Division: a / b (field division)
api.Neg(a)              // Negation: -a
```

**Constraint Assertions:**
```go
api.AssertIsEqual(a, b)      // Assert a == b
api.AssertIsDifferent(a, b)  // Assert a != b
api.AssertIsBoolean(a)       // Assert a ∈ {0, 1}
api.AssertIsLessOrEqual(a, b) // Assert a <= b (for range proofs)
```

**Conditional Logic:**
```go
api.Select(condition, ifTrue, ifFalse)  // Returns ifTrue if condition==1, else ifFalse
api.IsZero(a)                            // Returns 1 if a==0, else 0
api.Cmp(a, b)                            // Compare a and b
```

**Example - Binary Check:**
```go
func (circuit *BinaryCheckCircuit) Define(api frontend.API) error {
    // Constraint: in * (in - 1) == 0
    // This is satisfied only when in ∈ {0, 1}
    inMinusOne := api.Sub(circuit.In, 1)
    product := api.Mul(circuit.In, inMinusOne)
    api.AssertIsEqual(product, 0)

    // Output equals input
    api.AssertIsEqual(circuit.Out, circuit.In)
    return nil
}
```

#### Hint Functions

Hint functions allow complex computations that cannot be expressed as quadratic constraints. They compute values outside the constraint system, and the circuit must add constraints to verify correctness.

```go
// Register a hint function
func init() {
    solver.RegisterHint(ModHintBabyJubJub)
}

// Hint function for modular reduction
func ModHintBabyJubJub(mod *big.Int, inputs []*big.Int, outputs []*big.Int) error {
    p := new(big.Int)
    p.SetString("2736030358979909402780800718157159386076813972158567259200215660948447373041", 10)
    outputs[0] = new(big.Int).Mod(inputs[0], p)
    return nil
}

// Usage in circuit
func (circuit *MyCircuit) Define(api frontend.API) error {
    // Use hint to compute modular reduction
    reduced, err := api.Compiler().NewHint(ModHintBabyJubJub, 1, circuit.Value)
    if err != nil {
        return err
    }
    // Add constraint to verify the hint output
    // (actual verification logic here)
    return nil
}
```

Hint functions are used in Enygma for:
- Modular reduction to the Baby JubJub subgroup order
- Poseidon hash computation
- Elliptic curve point operations

### Using Gnark

#### Writing a Circuit

Circuits are organized in the `pkg/circuits/` directory with the following structure:

```
pkg/circuits/
└── enygma/
    ├── enygma-payments/
    │   ├── common/
    │   │   └── common-checks.go      # Shared validation logic
    │   ├── enygma-transfer/
    │   │   ├── circuit-logic.go      # Shared constraint logic
    │   │   ├── circuit-k2.go         # Circuit for k=2
    │   │   ├── circuit-k3.go         # Circuit for k=3
    │   │   ├── circuit-k4.go         # Circuit for k=4
    │   │   ├── circuit-k5.go         # Circuit for k=5
    │   │   ├── circuit-k6.go         # Circuit for k=6
    │   │   └── handler.go            # HTTP handler for proof generation
    │   ├── enygma-deposit/           # Deposit circuits
    │   └── enygma-withdraw/          # Withdraw circuits
    └── enygma-dvp/
        ├── enygma-joinsplit-dvp/     # Join-split for DVP
        ├── erc721-ownership-dvp/     # ERC721 ownership proofs
        └── erc1155-joinsplit-dvp/    # ERC1155 join-split
```

Each `k` value requires a separate circuit definition because gnark requires fixed array sizes at compile time. The shared logic is implemented in `circuit-logic.go` and called from each variant.

**Example Circuit Structure:**
```go
// circuit-k6.go
const k6 = 6

type Enygmak6Circuit struct {
    SenderId       frontend.Variable
    Secrets        [k6]frontend.Variable
    PublicKey      [k6][2]frontend.Variable `gnark:",public"`
    Sk             frontend.Variable
    PreviousV      frontend.Variable
    PreviousCommit [k6][2]frontend.Variable `gnark:",public"`
    TxCommit       [k6][2]frontend.Variable `gnark:",public"`
    TxValue        [k6]frontend.Variable
    TxRandom       [k6]frontend.Variable
    V              frontend.Variable
    Nullifier      frontend.Variable       `gnark:",public"`
    BlockNumber    frontend.Variable       `gnark:",public"`
    KIndex         [k6]frontend.Variable   `gnark:",public"`
    PreviousR      frontend.Variable
}

func (circuit *Enygmak6Circuit) Define(api frontend.API) error {
    // Convert fixed arrays to slices for shared logic
    return circuitLogic(api, k6,
        circuit.SenderId,
        circuit.Secrets[:],
        circuit.PublicKey[:],
        // ... other parameters
    )
}
```

#### Compilation and Setup

##### Compiling the Circuit

Circuit compilation converts the Go circuit definition into an R1CS (Rank-1 Constraint System):

```go
// cmd/setup/setup_r1cs.go
package main

import (
    "github.com/consensys/gnark-crypto/ecc"
    "github.com/consensys/gnark/frontend"
    "github.com/consensys/gnark/frontend/cs/r1cs"
    circuits "rayls-gnark-api/pkg/circuits/enygma-transfer"
)

func main() {
    // Compile circuit for k=6
    var circuit circuits.Enygmak6Circuit
    r1cs, err := frontend.Compile(ecc.BN254.ScalarField(), r1cs.NewBuilder, &circuit)
    if err != nil {
        panic(err)
    }

    // Save R1CS to file
    file, _ := os.Create("last_build/circuits/enygma-transfer-k6.r1cs")
    r1cs.WriteTo(file)
    file.Close()

    fmt.Printf("Compiled circuit with %d constraints\n", r1cs.GetNbConstraints())
}
```

Run compilation:
```bash
go run cmd/setup/setup_r1cs.go
```

##### Key Generation (Trusted Setup)

After compilation, generate the proving and verifying keys:

```go
// cmd/setup/setup_keys_verifiers.go
package main

import (
    "github.com/consensys/gnark-crypto/ecc"
    "github.com/consensys/gnark/backend/groth16"
)

func main() {
    // Load compiled R1CS
    r1cs := groth16.NewCS(ecc.BN254)
    file, _ := os.Open("last_build/circuits/enygma-transfer-k6.r1cs")
    r1cs.ReadFrom(file)
    file.Close()

    // Generate proving and verifying keys (trusted setup)
    pk, vk, err := groth16.Setup(r1cs)
    if err != nil {
        panic(err)
    }

    // Save proving key
    pkFile, _ := os.Create("last_build/keys/enygma-transfer-k6.pk")
    pk.WriteTo(pkFile)
    pkFile.Close()

    // Save verifying key
    vkFile, _ := os.Create("last_build/keys/enygma-transfer-k6.vk")
    vk.WriteTo(vkFile)
    vkFile.Close()
}
```

Run key generation:
```bash
go run cmd/setup/setup_keys_verifiers.go
```

##### Generating the Solidity Verifier

Gnark can export verifying keys as Solidity contracts:

```go
// Export Solidity verifier
vk := // loaded verifying key
file, _ := os.Create("contracts/EnygmaVerifierk6.sol")
vk.ExportSolidity(file)
file.Close()
```

The generated Solidity contract contains a `verifyProof` function that can be called on-chain to verify proofs.

#### Normal Usage: Proof generation via API call and Enygma contract checking if it is valid by calling the Enygma Verifier before sending the transaction

The proof generation API is a Go HTTP server that exposes endpoints for each circuit type:

**API Endpoints:**
```
POST /healthcheck                    → Health status
POST /generateProofTransfer-k2       → Generate transfer proof (k=2)
POST /generateProofTransfer-k3       → Generate transfer proof (k=3)
POST /generateProofTransfer-k4       → Generate transfer proof (k=4)
POST /generateProofTransfer-k5       → Generate transfer proof (k=5)
POST /generateProofTransfer-k6       → Generate transfer proof (k=6)
POST /generateProofDeposit-kN        → Generate deposit proof
POST /generateProofWithdraw-kN       → Generate withdraw proof
POST /join-split-enygma              → Generate join-split proof
POST /ownership-721                  → Generate ERC721 ownership proof
POST /join-split-1155                → Generate ERC1155 join-split proof
```

**Request Format:**
```json
{
  "sender_id": "0",
  "sk": "35",
  "v": "100",
  "public_keys": [[...], [...]],
  "previous_commits": [[...], [...]],
  "previous_v": "1000",
  "previous_r": "0",
  "tx_commit": [[...], [...]],
  "tx_value": ["-100", "100", "0", "0", "0", "0"],
  "tx_random": [...],
  "secrets": [...],
  "block_number": "1589775",
  "nullifier": "...",
  "kIndex": [0, 1, 2, 3, 4, 5]
}
```

**Response Format:**
```json
{
  "pi_a": ["x", "y"],
  "pi_b": [["x0", "x1"], ["y0", "y1"]],
  "pi_c": ["x", "y"],
  "public_signal": [...]
}
```

**Proof Generation Flow:**
1. API receives JSON request with circuit inputs
2. Handler validates inputs (computes expected commitments, verifies sender exists)
3. Loads pre-compiled circuit and proving key (cached via `sync.Once` for performance)
4. Creates witness assignment from request data
5. Generates proof: `groth16.Prove(r1cs, pk, witness)`
6. Extracts proof components from BN254 curve points
7. Returns JSON response with proof data

**Handler Implementation Pattern:**
```go
func handleProofK6(c *gin.Context) {
    // 1. Bind and validate request
    var req ProofRequest
    if err := c.ShouldBindJSON(&req); err != nil {
        c.JSON(400, gin.H{"error": err.Error()})
        return
    }

    // 2. Load circuit (cached)
    compiled := getOrLoadCircuitK6(pkPath, r1csPath)

    // 3. Create witness
    var circuit Enygmak6Circuit
    circuit.SenderId = req.SenderId
    // ... set all circuit fields

    witness, _ := frontend.NewWitness(&circuit, ecc.BN254.ScalarField())

    // 4. Generate proof
    proof, _ := groth16.Prove(compiled.R1CS, compiled.PK, witness)

    // 5. Extract and return proof components
    response := extractProofComponents(proof)
    c.JSON(200, response)
}
```

**Integration with Enygma Contract:**
1. Relayer calls the proof generation API with transaction data
2. API returns the Groth16 proof
3. Relayer submits proof to the Enygma smart contract
4. Contract calls the on-chain verifier (`EnygmaVerifierk6.sol`)
5. If `verifyProof` returns true, the transaction is executed

## Enygma ZK conditions (The Go circuit file, Explained)

The `Enygma` circuit is designed to verify the validity of a transaction in a zero-knowledge manner. It performs checks to validate a sender’s secret key, ensures that a balance is greater or equal than a transaction value, verifies no double-spending, and manages several Pedersen commitments to guarantee privacy.

### Variables in the Circuit

**Constants**

`p = 2736030358979909402780800718157159386076813972158567259200215660948447373041`

The prime number that defines the prime field F_p where the v and r values should live. This defines a subgroup of the Baby Jubjub curve the prime p = 21888242871839275222246405745257275088548364400416034343698204186575808495617

By doing operations on v and r mod p = 2736030358979909402780800718157159386076813972158567259200215660948447373041 one guarantees that the balances and pedersen commitments are always inside the Baby JubJub curve.

**Variables**

`k` is size of the anonimity set, the size of the array with identifiers of the banks that are in the transaction.

**Circuit Fields (Variables)**

In gnark, circuit variables are defined as struct fields. Fields without the `gnark:",public"` tag are private (hidden from the verifier).

1. `SenderId`

- **Type**: Private (`frontend.Variable`)
- **Description**: Identifier for the sender of the transaction. This is used to determine which secret keys, commitments, and public keys are associated with the sender.

2. `SharedSecrets[k]`

- **Type**: Private (`[k]frontend.Variable`)
- **Description**: An array of shared secret values for each participant in the transaction. For the sender, the secret is computed as `Poseidon(PreviousSenderRandomValue, SecretKey) mod p`. For receivers, this represents the shared secret derived from DH key exchange. The sender's secret with himself is implicitly zero (not stored, computed).

3. `HashedSharedSecrets[k]`

- **Type**: Public (`[k]frontend.Variable` with `gnark:",public"` tag)
- **Description**: An array of hashed secrets for each participant. Each value is computed as `Poseidon(SharedSecrets[i], SharedSecrets[i]) mod p`. This is used for nullifier computation and provides a public binding to the private secrets without revealing them.

4. `PublicKey[k]`

- **Type**: Public (`[k]frontend.Variable` with `gnark:",public"` tag)
- **Description**: An array holding the public keys (Enygma spend keys) of all participants involved in the transaction. Each public key is a scalar value derived from `PoseidonHash(sk, sk) mod p`.

5. `SecretKey`

- **Type**: Private (`frontend.Variable`)
- **Description**: The secret key of the sender. This is used to prove knowledge of the sender's identity and to compute the sender's secret.

6. `PreviousSenderBalance`

- **Type**: Private (`frontend.Variable`)
- **Description**: The previous balance in the sender's account, represented in the last Pedersen commitment.

7. `PreviousSenderRandomValue`

- **Type**: Private (`frontend.Variable`)
- **Description**: The random factor used in the last Pedersen commitment to obscure the previous balance. Also used in computing the sender's secret.

8. `PreviousCommits[k][2]`

- **Type**: Public (`[k][2]frontend.Variable` with `gnark:",public"` tag)
- **Description**: A 2D array of previous balances for all participants involved in the transaction, represented as Pedersen commitments. Each commitment has two parts (`x` and `y` coordinates in the Baby JubJub elliptic curve).

9. `TxCommits[k][2]`

- **Type**: Public (`[k][2]frontend.Variable` with `gnark:",public"` tag)
- **Description**: A 2D array containing the new commitments for the transaction. Each commitment has two values (`x` and `y` coordinates in the Baby JubJub elliptic curve).

10. `TxValues[k]`

- **Type**: Private (`[k]frontend.Variable`)
- **Description**: An array representing the balance debited or credited in the transaction for each participant involved. The sum of `TxValues` must be zero for the transaction to be valid.

11. `TxRandomValues[k]`

- **Type**: Private (`[k]frontend.Variable`)
- **Description**: An array of random factors used for generating the new Pedersen commitments in the transaction. Each participant has a separate random factor.

12. `SenderTxValue`

- **Type**: Private (`frontend.Variable`)
- **Description**: The balance that is being spent in the transaction. It must be less than or equal to `PreviousSenderBalance` (the sender's previous balance).

13. `Nullifier`

- **Type**: Public (`frontend.Variable` with `gnark:",public"` tag)
- **Description**: A value used to prevent double-spending. It is derived from `Poseidon(HashedSharedSecrets[senderIdx], BlockNumber)`, where `HashedSharedSecrets[senderIdx]` is selected based on the sender's position in `AnonymitySet`.

14. `BlockNumber`

- **Type**: Public (`frontend.Variable` with `gnark:",public"` tag)
- **Description**: The number of the previous block, used to ensure that the random factors are correctly generated and linked to a specific block in the blockchain.

15. `AnonymitySet[k]`

- **Type**: Public (`[k]frontend.Variable` with `gnark:",public"` tag)
- **Description**: An array of identifiers representing the banks or participants involved in the transaction. The length of this array is `k`, representing the subset of the total number of participants that is involved in the transaction.

16. `MessageTags[k]`

- **Type**: Public (`[k]frontend.Variable` with `gnark:",public"` tag)
- **Description**: An array of tag messages used to authenticate the transaction for each participant. Each tag message is derived as `PoseidonHash(HashTag, SharedSecrets[i], BlockNumber) mod p`, where `HashTag = Poseidon(12)` provides domain separation.

Now before analysing each component of the circuit it is useful to show an example of a valid API request JSON that will be used by a PN to generate a valid proof:

```json
{
  "sender_id": "12345",
  "secret_key": "606558265546426769417388655868912908180763471395599039458694595012871541522",
  "sender_tx_value": "0",
  "public_keys": [
    "218054448918393120088497531260689723378581005180533320695297411412615699713",
    "139959694827881611611487405358893988678303111820869114442016552278388510929"
  ],
  "previous_commits": [
    ["0", "1"],
    ["0", "1"]
  ],
  "previous_sender_balance": "0",
  "previous_sender_random_value": "0",
  "tx_commits": [
    [
      "9888426410067051030249221381988503555034880721583618753298794515247278058842",
      "12649249486646112511591270176562329723533819899189287718484601528767223341301"
    ],
    [
      "11999816461772224191997184363268771533513483678832415590399409671328530436775",
      "12649249486646112511591270176562329723533819899189287718484601528767223341301"
    ]
  ],
  "tx_values": [
    "2736030358979909402780800718157159386076813972158567259200215660948447373041",
    "0"
  ],
  "tx_random_values": [
    "1940896117707151925931462838637753983278762828023801898241056114375303209265",
    "795134241272757476849337879519405402798051144134765360959159546573144163776"
  ],
  "shared_secrets": [
    "1234567890123456789012345678901234567890123456789012345678901234",
    "934477690919234866504484350757553869577334563699977689832414549845186905478"
  ],
  "hashed_shared_secrets": [
    "2089012345678901234567890123456789012345678901234567890123456789",
    "1567890123456789012345678901234567890123456789012345678901234567"
  ],
  "message_tags": [
    "2441583625052518639129451996766573368534656792572427185065088067145123512746",
    "2131591347025272119742549246169073056423289677722955521198198098450893491243"
  ],
  "block_number": "1680",
  "nullifier": "13065678538592839105111856048758919688786946665541891629645034963082002922680",
  "anonymity_set": [
    "12345",
    "12346"
  ]
}
```

**Note:** The `hashed_shared_secrets` values are computed as `Poseidon(SharedSecrets[i], SharedSecrets[i]) mod p` for each participant. These are public signals used for nullifier computation.

This should be a solution to the R1CS generated by compiling the circuit. The logical conditions expressed in the Go circuit file should be satisfied by these values.

### Circuit Specifications and Public Signals

This section documents the public signal counts for all Enygma circuit variants. The public signals are the values passed to the on-chain Solidity verifier contracts.

#### Enygma Payments Circuits

**Transfer Circuit (EnygmaVerifier)**

Used for private transfers between participants within a VEN.

| Anonymity Set (k) | Public Signals | Verifier Contract |
|-------------------|----------------|-------------------|
| k=2 | 18 | `EnygmaVerifierk2.sol` |
| k=3 | 26 | `EnygmaVerifierk3.sol` |
| k=4 | 34 | `EnygmaVerifierk4.sol` |
| k=5 | 42 | `EnygmaVerifierk5.sol` |
| k=6 | 50 | `EnygmaVerifierk6.sol` |

**Formula:** `8k + 2` public signals

Public signals breakdown:
- `HashedSharedSecrets[k]` - k signals
- `PublicKey[k]` - k signals
- `PreviousCommits[k][2]` - 2k signals
- `TxCommits[k][2]` - 2k signals
- `Nullifier` - 1 signal
- `BlockNumber` - 1 signal
- `AnonymitySet[k]` - k signals
- `MessageTags[k]` - k signals

**Deposit to DVP Circuit (EnygmaDepositToDvpVerifier)**

Used when depositing Enygma tokens into a DVP (Delivery vs Payment) contract.

| Anonymity Set (k) | Public Signals | Verifier Contract |
|-------------------|----------------|-------------------|
| k=2 | 19 | `EnygmaDepositToDvpVerifierk2.sol` |
| k=3 | 27 | `EnygmaDepositToDvpVerifierk3.sol` |
| k=4 | 35 | `EnygmaDepositToDvpVerifierk4.sol` |
| k=5 | 43 | `EnygmaDepositToDvpVerifierk5.sol` |
| k=6 | 51 | `EnygmaDepositToDvpVerifierk6.sol` |

**Formula:** `8k + 3` public signals

Additional public signal compared to Transfer:
- `Hash` - 1 signal (commitment hash for DVP integration)

**Withdraw from DVP Circuit (EnygmaWithdrawFromDvpVerifier)**

Used when withdrawing Enygma tokens from a DVP contract.

| Anonymity Set (k) | Public Signals | Verifier Contract |
|-------------------|----------------|-------------------|
| k=2 | 28 | `EnygmaWithdrawFromDvpVerifierk2.sol` |
| k=3 | 36 | `EnygmaWithdrawFromDvpVerifierk3.sol` |
| k=4 | 44 | `EnygmaWithdrawFromDvpVerifierk4.sol` |
| k=5 | 52 | `EnygmaWithdrawFromDvpVerifierk5.sol` |
| k=6 | 60 | `EnygmaWithdrawFromDvpVerifierk6.sol` |

**Formula:** `8k + 12` public signals

Additional public signals compared to Transfer:
- `Hashes[10]` - 10 signals (deposit commitment hashes for withdrawal verification)

#### Enygma DVP Circuits

**Enygma JoinSplit DVP Circuit**

Used for private token transfers within DVP operations for Enygma-wrapped tokens.

| Circuit | Public Signals | Verifier Contract |
|---------|----------------|-------------------|
| EnygmaJoinSplit | 33 | `EnygmaJoinSplitVerifier.sol` |

Public signals breakdown:
- `NftCommitment` - 1 signal
- `MerkleRoots[10]` - 10 signals
- `Nullifiers[10]` - 10 signals
- `TreeNumbers[10]` - 10 signals
- `CommitmentsOut[2]` - 2 signals

**ERC-1155 JoinSplit DVP Circuit**

Used for private ERC-1155 token transfers within DVP operations.

| Circuit | Public Signals | Verifier Contract |
|---------|----------------|-------------------|
| Erc1155JoinSplit | 33 | `Erc1155JoinSplitVerifier.sol` |

Public signals breakdown (same as EnygmaJoinSplit):
- `NftCommitment` - 1 signal
- `MerkleRoots[10]` - 10 signals
- `Nullifiers[10]` - 10 signals
- `TreeNumbers[10]` - 10 signals
- `CommitmentsOut[2]` - 2 signals

**ERC-721 Ownership DVP Circuit**

Used for proving ownership of ERC-721 NFTs in DVP operations.

| Circuit | Public Signals | Verifier Contract |
|---------|----------------|-------------------|
| Erc721Ownership | 5 | `Erc721OwnershipVerifier.sol` |

Public signals breakdown:
- `PaymentCommitment` - 1 signal
- `MerkleRoot` - 1 signal
- `Nullifiers[1]` - 1 signal
- `TreeNumber` - 1 signal
- `CommitmentsOut[1]` - 1 signal

### Components of the Enygma Circuit Explained

Each constraint used in the `Enygma` circuit is explained below, with the actual gnark Go implementation from `circuit-logic.go` in the `rayls-gnark-api` repository. This shows how constraints are built using gnark's `frontend.API`.

#### 1. `Sender is in AnonymitySet`

```go
// Check if SenderId is in K
sumIsInK := frontend.Variable(0)
for i := 0; i < k; i++ {
    isEqual := api.IsZero(api.Sub(anonymity_set[i], senderId))
    sumIsInK = api.Add(isEqual, sumIsInK)
}
api.AssertIsEqual(sumIsInK, 1)
```

- **Purpose**: This constraint checks if the senderId appears exactly once in the AnonymitySet array.
- **How it works**:
  - `api.IsZero(api.Sub(anonymity_set[i], senderId))` returns 1 if `anonymity_set[i] == senderId`, 0 otherwise
  - Sums up all matches and asserts the total equals 1

#### 2. `Check that amount to send SenderTxValue corresponds to Sender's TxValues entry`

```go
// Check if Amount To Transfer Corresponds To Sender TxValues
selected_v := frontend.Variable(0)
for i := 0; i < k; i++ {
    diff := api.Sub(senderId, anonymity_set[i])
    eq := api.IsZero(diff)
    selected_v = api.Add(selected_v, api.Mul(eq, txValue[i]))
}
negativeV := api.Sub(JubJubPrimeSubGroup, sender_tx_value)
api.AssertIsEqual(selected_v, negativeV)
```

- **Purpose**: This constraint checks if the amount to send `SenderTxValue` equals the negation of the sender's TxValues entry.
- **How it works**:
  - Selects the TxValues at the sender's position using conditional multiplication
  - Computes `negativeV = p - sender_tx_value` (negation in the prime field)
  - Asserts `selected_v == negativeV`

#### 3. `Sender knows the secret corresponding to their position`

```go
// CheckSecretKnowledge verifies the sender knows the secret via Poseidon(PreviousSenderRandomValue, SecretKey) == SharedSecrets[senderIdx]
selectedSecret := frontend.Variable(0)
for i := 0; i < k; i++ {
    eq := api.IsZero(api.Sub(senderId, anonymity_set[i]))
    selectedSecret = api.Add(selectedSecret, api.Mul(eq, shared_secrets[i]))
}

secretSenderCalculated := pos.Poseidon(api, []frontend.Variable{previousR, secret_key})
secretInter, _ := api.NewHint(primitives.ModHintBabyJubJub, 2, secretSenderCalculated)
secretRemain := secretInter[0] // remainder

api.AssertIsEqual(secretRemain, selectedSecret)
```

- **Purpose**: Verifies the sender knows the secret key and previous random factor that produce their secret value.
- **How it works**:
  - Selects the sender's secret from the `SharedSecrets` array based on their position in `AnonymitySet`
  - Computes the expected secret as `Poseidon(PreviousSenderRandomValue, SecretKey) mod p`
  - Asserts the computed secret matches the provided secret value

#### 4. `HashedSharedSecrets values are correctly computed`

```go
// CheckHashArrayOfSecrets verifies that HashedSharedSecrets[i] = Poseidon(SharedSecrets[i], SharedSecrets[i])
for i := 0; i < k; i++ {
    calculatedHash := pos.Poseidon(api, []frontend.Variable{shared_secrets[i], shared_secrets[i]})
    hashInter, _ := api.NewHint(primitives.ModHintBabyJubJub, 2, calculatedHash)
    hashMod := hashInter[0] // remainder

    api.AssertIsEqual(hashMod, arrayHashSecret[i])
}
```

- **Purpose**: Ensures the public `HashedSharedSecrets` values are correctly derived from the private `SharedSecrets`.
- **How it works**:
  - For each participant, computes `Poseidon(SharedSecrets[i], SharedSecrets[i]) mod p`
  - Asserts this matches the corresponding `HashedSharedSecrets[i]`
  - This creates a public binding to private secrets for use in nullifier computation

#### 5. `PreviousCommits and TxCommits are OnCurve()`

```go
// Check if previous commits and tx commits are on Curve
for i := 0; i < k; i++ {
    X := previousCommit[i][0]
    Y := previousCommit[i][1]
    primitives.AssertPointsIsOnCurve(api, X, Y)

    X2 := txCommit[i][0]
    Y2 := txCommit[i][1]
    primitives.AssertPointsIsOnCurve(api, X2, Y2)
}
```

- **Purpose**: Verifies that all previous commitments and transaction commitments lie on the Baby JubJub elliptic curve.
- **How it works**:
  - Calls `primitives.AssertPointsIsOnCurve` which adds constraints verifying: `168700*X² + Y² = 1 + 168696*X²*Y² mod p`
  - Note: Public keys are now scalar values (not curve points), so they are not checked here

See section [3. Checking Curve Membership](#3-checking-curve-membership).

#### 6. `Sender has the SecretKey correspondent to its PublicKey`

```go
// Knowledge of SecretKey
selectedPK := frontend.Variable(0)

for i := 0; i < k; i++ {
    diff := api.Sub(senderId, anonymity_set[i])
    eq := api.IsZero(diff)
    selectedPK = api.Add(selectedPK, api.Mul(eq, publicKey[i]))
}

pk := pos.Poseidon(api, []frontend.Variable{secret_key, secret_key}) // Pk = PoseidonHash(SecretKey, SecretKey)
pkInter, _ := api.NewHint(primitives.ModHintBabyJubJub, 2, pk)
pkMod := pkInter[0] // remainder

api.AssertIsEqual(selectedPK, pkMod)
```

- **Purpose**: Proves the sender knows the secret key corresponding to their public key.
- **How it works**:
  - Selects the sender's public key (a scalar value) from the array
  - Computes `pk = PoseidonHash(SecretKey, SecretKey) mod p` using the Poseidon hash function
  - Asserts computed pk matches the selected public key

See section [Public Key Generation in Enygma](#public-key-generation-in-enygma)

#### 7. `Check if sender's last Pedersen Commitment can be replicated using its PreviousSenderBalance and PreviousSenderRandomValue`

```go
// Check Knowledge of Previous Commitment
selectedPreviousCommitmentX := frontend.Variable(0)
selectedPreviousCommitmentY := frontend.Variable(0)
for i := 0; i < k; i++ {
    diff := api.Sub(senderId, anonymity_set[i])
    eq := api.IsZero(diff)
    selectedPreviousCommitmentX = api.Add(selectedPreviousCommitmentX, api.Mul(eq, previousCommit[i][0]))
    selectedPreviousCommitmentY = api.Add(selectedPreviousCommitmentY, api.Mul(eq, previousCommit[i][1]))
}

computedPreviousCommitment := primitives.PedersenCommitment(api, previousV, previousR)

api.AssertIsEqual(selectedPreviousCommitmentX, computedPreviousCommitment.X)
api.AssertIsEqual(selectedPreviousCommitmentY, computedPreviousCommitment.Y)
```

- **Purpose**: Verifies the sender knows the values (PreviousSenderBalance, PreviousSenderRandomValue) that produced their previous commitment.
- **How it works**:
  - Selects sender's previous commitment from the array
  - Computes `C(PreviousSenderBalance, PreviousSenderRandomValue) = PreviousSenderBalance * G + PreviousSenderRandomValue * H`
  - Asserts computed commitment matches the stored one

See section [Pedersen Commitments](#pedersen-commitments)

#### 8. `Sum of the Pedersen Commitments of all banks in the tx should give the "zero" point`

```go
// Check Pedersen (Sum TxValues, Sum TxRandomValues) = Pedersen (0, 0) = (0,1)
sumX := frontend.Variable(0)
sumY := frontend.Variable(0)

for i := 0; i < k; i++ {
    sumX = api.Add(sumX, txValue[i])
    sumY = api.Add(sumY, txRandom[i])
}
PedersenZero := primitives.PedersenCommitment(api, sumX, sumY)
api.AssertIsEqual(PedersenZero.X, frontend.Variable(0))
api.AssertIsEqual(PedersenZero.Y, frontend.Variable(1))

// Check Sum TxCommits = (0,1)
sum := twistededwards.Point{
    X: txCommit[0][0],
    Y: txCommit[0][1],
}

for i := 1; i < k; i++ {
    point := twistededwards.Point{
        X: txCommit[i][0],
        Y: txCommit[i][1],
    }
    sum = primitives.PointAdd(api, sum, point)
}

api.AssertIsEqual(sum.X, frontend.Variable(0))
api.AssertIsEqual(sum.Y, frontend.Variable(1))
```

- **Purpose**: Ensures the transaction is zero-sum (no value created or destroyed).
- **How it works**:
  - Sums all TxValues and TxRandomValues, verifies `C(sumV, sumR) == (0, 1)`
  - Also sums all commitment points using elliptic curve addition
  - Both must equal the identity point `(0, 1)`

See sections [The Point at Infinity](#the-point-at-infinity-zero-point-identity-point) and [Balanced Commitments and Zero-Sum Transactions](#balanced-commitments-and-zero-sum-transactions).

#### 9. `Ensure SenderTxValue is smaller or equal than sender's PreviousSenderBalance and bigger or equal to 0`

```go
// Range Proof
prevVGreaterEqualV := api.Cmp(previousV, sender_tx_value)
vGreaterEqualZero := api.Cmp(sender_tx_value, frontend.Variable(0))

api.AssertIsEqual(api.IsZero(api.Add(prevVGreaterEqualV, frontend.Variable(1))), frontend.Variable(0))
api.AssertIsEqual(api.IsZero(api.Add(vGreaterEqualZero, frontend.Variable(1))), frontend.Variable(0))
```

- **Purpose**: Ensures `PreviousSenderBalance >= SenderTxValue` and `SenderTxValue >= 0` (no overdraft, no negative sends).
- **How it works**:
  - `api.Cmp(a, b)` returns -1 if a < b, 0 if a == b, 1 if a > b
  - The assertions verify neither comparison returns -1

#### 10. `Ensure nullifier is correctly derived from HashedSharedSecrets and BlockNumber`

```go
// CheckNullifierKnowledge verifies knowledge of nullifier = Poseidon(selectedPreImage, blockNumber)
// where selectedPreImage is selected from HashedSharedSecrets based on senderId
selectedPreImage := frontend.Variable(0)

for i := 0; i < k; i++ {
    diff := api.Sub(senderId, anonymity_set[i])
    eq := api.IsZero(diff)
    selectedPreImage = api.Add(selectedPreImage, api.Mul(eq, arrayHashSecret[i]))
}

computedNullifier := pos.Poseidon(api, []frontend.Variable{selectedPreImage, blockNumber})
api.AssertIsEqual(computedNullifier, nullifier)
```

- **Purpose**: Verifies the nullifier is correctly computed to prevent double-spending.
- **How it works**:
  - Selects the sender's `HashedSharedSecrets` value based on their position in `AnonymitySet`
  - Computes `PoseidonHash(HashedSharedSecrets[senderIdx], BlockNumber)` inside the circuit
  - Asserts it matches the provided nullifier
  - Using `HashedSharedSecrets` (which is `Poseidon(SharedSecrets, SharedSecrets)`) instead of `SecretKey` directly provides better privacy

See section [Nullifier and Double-Spending](#nullifier-and-double-spending)

#### 11. `Ensures new Pedersen Commitments of participants are correctly formed`

```go
// Check if Tx Commitment is well formed
for i := 0; i < k; i++ {
    computedPedersenCommitment := primitives.PedersenCommitment(api, txValue[i], txRandom[i])
    api.AssertIsEqual(txCommit[i][0], computedPedersenCommitment.X)
    api.AssertIsEqual(txCommit[i][1], computedPedersenCommitment.Y)
}
```

- **Purpose**: Verifies each transaction commitment matches `C(TxValues[i], TxRandomValues[i])`.
- **How it works**:
  - For each participant, computes `TxValues[i] * G + TxRandomValues[i] * H`
  - Asserts it equals the provided `TxCommits[i]`

See [Representation and Evolution of Balances](#representation-and-evolution-of-balances).

#### 12. `Ensures TxRandomValues are correctly derived from Poseidon hashes`

```go
// Check if random factors R are well formed
calculatedRandomFactor := make([]frontend.Variable, k)
receiverHashesModP := make([]frontend.Variable, k)
sumOfReceiverHashes := frontend.Variable(0)

// Domain separation tag for random factor generation
HashRandom := pos.Poseidon(api, []frontend.Variable{21})

// First pass: compute all hashes using SharedSecrets[i], reduce modulo JubJubPrimeSubGroup
for i := 0; i < k; i++ {
    RandomFactor := pos.Poseidon(api, []frontend.Variable{HashRandom, shared_secrets[i], blockNumber})

    // Reduce RandomFactor modulo JubJubPrimeSubGroup using hint
    randomInter, _ := api.NewHint(primitives.ModHintBabyJubJub, 2, RandomFactor)
    hashModP := randomInter[0] // remainder (hash mod p)
    q := randomInter[1]        // quotient

    // Assert the modular reduction is correct: q * p + remainder == original
    api.AssertIsEqual(api.Add(api.Mul(q, JubJubPrimeSubGroup), hashModP), RandomFactor)
    isValid := cmp.IsLess(api, hashModP, JubJubPrimeSubGroup)
    api.AssertIsEqual(isValid, 1)

    receiverHashesModP[i] = hashModP

    // Add to sum only if this is a receiver (not sender)
    isSender := api.IsZero(api.Sub(anonymity_set[i], senderId))
    isReceiver := api.Sub(1, isSender)
    sumOfReceiverHashes = api.Add(sumOfReceiverHashes, api.Mul(isReceiver, hashModP))
}

// Reduce the sum modulo JubJubPrimeSubGroup
sumInter, _ := api.NewHint(primitives.ModHintBabyJubJub, 2, sumOfReceiverHashes)
senderRandomFactor := sumInter[0]
sumQ := sumInter[1]

api.AssertIsEqual(api.Add(api.Mul(sumQ, JubJubPrimeSubGroup), senderRandomFactor), sumOfReceiverHashes)
isSumValid := cmp.IsLess(api, senderRandomFactor, JubJubPrimeSubGroup)
api.AssertIsEqual(isSumValid, 1)

// Assign correct random factors: receivers get neg(hash), sender gets sum
for i := 0; i < k; i++ {
    isSender := api.IsZero(api.Sub(anonymity_set[i], senderId))
    receiverRandomFactor := api.Sub(JubJubPrimeSubGroup, receiverHashesModP[i])
    calculatedRandomFactor[i] = api.Select(isSender, senderRandomFactor, receiverRandomFactor)
}

// Verify calculated factors match provided TxRandomValues
for i := 0; i < k; i++ {
    api.AssertIsEqual(calculatedRandomFactor[i], txRandom[i])
}
```

- **Purpose**: Ensures random values are deterministically derived so receivers can compute them independently.
- **How it works**:
  - Uses domain separation: `HashRandom = Poseidon(21)` to distinguish from other hash uses
  - For receivers: `r[i] = neg(PoseidonHash(HashRandom, SharedSecrets[i], BlockNumber) mod p)`
  - For sender: `r[sender] = Sum(receiver hashes) mod p` (ensures total sum is zero)
  - Uses hint functions for modular reduction (computed outside circuit, verified inside)

#### 13. `Ensures MessageTags are correctly formed`

```go
// Knowledge of Tag Message - Perform verification tag message is well formed
HashTag := pos.Poseidon(api, []frontend.Variable{12})
for i := 0; i < k; i++ {
    calculatedTagMessage := pos.Poseidon(api, []frontend.Variable{HashTag, shared_secrets[i], blockNumber})
    calculatedTagMessageInter, _ := api.NewHint(primitives.ModHintBabyJubJub, 2, calculatedTagMessage)
    calculatedTagMessageMod := calculatedTagMessageInter[0]

    api.AssertIsEqual(message_tags[i], calculatedTagMessageMod)
}
```

- **Purpose**: Verifies that tag messages are correctly derived, enabling receivers to validate transaction authenticity.
- **How it works**:
  - Uses domain separation: `HashTag = Poseidon(12)` to distinguish from random factor hashes
  - For each participant: `MessageTags[i] = PoseidonHash(HashTag, SharedSecrets[i], BlockNumber) mod p`
  - Tag messages allow receivers to verify they are legitimate recipients of the transaction

See [What Defines a Valid Transaction, Ensuring Zero-Sum](#what-defines-a-valid-transaction-ensuring-zero-sum).

### Summary of Enygma's Logical Flow

The `Enygma` circuit ensures the validity and privacy of a transaction involving multiple participants (banks) in a zero-knowledge manner, verifying several key conditions:

**1. Ensure sender's has no secret with himself and check Public Keys of all Involved in the Tx are valid**

- Ensure the sender's shared secret with themselves is zero, which guarantees that no participant has a secret shared with themselves.
- Verify that the public keys of all participants involved in the transaction are valid and lie on the Baby Jubjub elliptic curve.

**2. Verify Sender's Identity and checks if his Information is well represented in the Transaction**

- Select the public key associated with the sender's identifier (`SenderId`) from the list of public keys.
- Prove that the sender knows the secret key (`SecretKey`) corresponding to their public key, ensuring that only the legitimate account holder can initiate the transaction.
- Checks if the sender's identifier (`SenderId`) is in the array `AnonymitySet`, the array with the IDs of all involved in the transaction
- Checks if amount to send `SenderTxValue` corresponds to the sender's value in the array `TxValues`, the array with the transaction values of all in the transaction.

**3. Verify Sender's Previous Commitment and checks previous commitments of all other Involved in the Tx are valid**

- Retrieve the previous Pedersen commitment of the sender, which represents the sender's balance before the transaction.
- Recalculate the Pedersen commitment using the previous balance (`PreviousSenderBalance`) and random factor (`PreviousSenderRandomValue`) and compare it to the stored commitment to ensure correctness.
- Verify that the previous commitments of all participants involved in the transaction are valid and lie on the Baby Jubjub elliptic curve. The previous commitments of all participants involved in the transaction represent their balance before the transaction.

**4. Verify Transaction Validity**

- **Zero-Sum Condition**: Ensure that the sum of all new Pedersen commitments (`TxCommits`) is equal to the identity point `(0, 1)` on the Baby Jubjub elliptic curve. This guarantees that the transaction is balanced, meaning no new value is created or destroyed.
- **Balance Check**: Ensure that the sender's previous balance (`PreviousSenderBalance`) is greater than or equal to the value being sent (`SenderTxValue`). This prevents overdraft or spending more than the available balance.
- **Amount to Send Sanity check**: Ensures that the value being sent (`SenderTxValue`) is bigger or equal to zero.
- **Transaction Value Sum**: Ensure that the sum of the transaction values (`TxValues`) for all participants equals zero modulo `p`. This condition ensures that the total value transferred among participants is conserved.
- **Random Values Check and Sum**: Ensures that the random values are calculated as intended and that the sum of their values used in Pedersen Commitments is zero.

**5. Check Nullifier Calculation**

- **Nullifier Calculation**: Calculate a nullifier using the `HashedSharedSecrets` (derived from `SharedSecrets`) and the current `BlockNumber`. The nullifier is used to uniquely identify the transaction and prevent the same transaction from being used multiple times (i.e., double-spending).

**6. Verify Updated Commitments for All Participants in the transaction**

- For each participant involved in the transaction (including the sender), verify that the updated Pedersen commitment can be correctly calculated using their respective transaction value (`TxValues`) and random factor (`TxRandomValues`). This ensures that the updated commitments for all participants are consistent and accurate.

## What is Missing and WIP

- A check on the structure and value of the shared secrets, only checking if own secret is 0 is not enough. This is WIP according to Research team. Important for quantum privacy. -> Coming in next Enygma Upgrade (work in progress atm)
- Transactions to more than k-1 participants (splitting of a big transaction into smaller ones with size of the anonymity set) -> Done
- Add enygma programmability to this doc

## Changelog

### v2.6.2 (30/01/2026)

- Updated H parameter coordinates (new NUMS-generated values)
- Added NUMS (Nothing Up My Sleeve) methodology documentation for H parameter generation
- Clarified key terminology: Enygma Spend Key (sk/pk via Poseidon hash) vs View Key (DH key)
- **Breaking**: Public key derivation changed from `pk = sk * G` to `pk = PoseidonHash(sk, sk) mod p`
- Added TagMessages circuit check for transaction authentication
- Added domain-separated hashes: `HashRandom = Poseidon(21)` for random factors, `HashTag = Poseidon(12)` for tag messages
- Updated circuit directory structure to reflect new organization under `enygma/enygma-payments/` and `enygma/enygma-dvp/`
- Added `common/common-checks.go` for shared validation logic across circuits
- Fixed deposit circuit bug for 0 value transfers
- Added `HashedSharedSecrets[k]` as new public signal across all circuits (k additional signals per circuit)
- **Circuit Public Signal Counts Updated**:
  - Transfer: `8k + 2` (was `7k + 2`)
  - Deposit to DVP: `8k + 3` (was `7k + 3`)
  - Withdraw from DVP: `8k + 12` (was `7k + 12`)
- Added "Circuit Specifications and Public Signals" section documenting all verifier contracts and their signal counts
