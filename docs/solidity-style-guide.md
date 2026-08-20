# Solidity Best Practices & Gas Optimizations

This document outlines important guidelines for writing efficient, secure, and readable Solidity code. Good code organization and gas cost optimization are essential for building reliable smart contracts.

-----

## ⚡️ Gas Optimizations

Gas efficiency is critical for cost-effective and scalable smart contract execution.

* **Cache storage variables in memory** — Reading from `storage` is expensive. Store the value in a local variable if it’s used multiple times.
* **Use `immutable` and `constant` variables** — Reduces gas costs for values that do not change.
* **Pack small types** — Combine smaller data types like `uint8` and `bool` in structs to share the same storage slot.
* **Group struct variables smartly** — Reorder fields to minimize the number of storage slots.
* **Write to storage in one step** — Avoid multiple writes to the same variable.
* **Avoid `for` loops and unbounded arrays** — These can consume excessive gas and risk out-of-gas errors.
* **Use custom errors instead of revert strings** — Saves significant gas compared to regular error messages.
* **Use `enum` for state/status values** — Better readability and more efficient than numeric codes.
* **Use `revert` instead of `return` to exit functions** — Halts execution more explicitly and efficiently.
* **Use minimal types where possible** — e.g., if storing ≤256 values, use `uint8` instead of `uint256`.
* **Consider algorithmic complexity** — Refactor `O(n²)` algorithms into `O(n)` wherever possible.

-----

## ✅ Best Practices

Security, maintainability, and clarity are core goals.

* **Follow the CEI pattern** — **C**hecks → **E**ffects → **I**nteractions.
* **Pull over push** — Always let users withdraw funds themselves instead of pushing funds to them to prevent reentrancy attacks.
* **Always validate input arguments** — Avoid trusting user input blindly.
* **Check for critical edge cases** — e.g., `address(0)`, zero values, etc.
* **Never leave functions without access control** — Use modifiers like `onlyOwner`, `onlyRole`, etc.
* **Use descriptive and meaningful variable names** — e.g., `currentChainId` instead of `chainId`.
* **Emit events for significant state changes** — Helps with off-chain indexing and auditing.
* **Avoid reinitializing variables** — Don’t assign values more than once unnecessarily.
* **Avoid variable shadowing** — Don’t use duplicate names that override variables in parent scopes.
* **Use NatSpec documentation** — Write `///` comments for every public and external function.
* **Use the initializer pattern over constructors** — This is especially important when working with upgradeable contracts.

-----

## 🧱 Style & Structure

Consistent code structure improves readability and reduces bugs.

### Contract Elements Ordering

1.  Pragma statements
2.  Import statements
3.  Errors
4.  Events
5.  Interfaces
6.  Libraries
7.  Contracts

### Inside Contracts/Libraries/Interfaces

1.  Errors
2.  Type declarations
3.  State variables
4.  Events
5.  Modifiers
6.  Functions

### Naming Conventions

* **Structs** → `PascalCase`
* **Functions** → `camelCase`
* **Internal/private functions** → `_underscorePrefix()`

### Recommended Function Ordering

1.  `constructor`
2.  `receive()`
3.  `fallback()`
4.  `external`
5.  `public`
6.  `internal`
7.  `private`

Within each group, place `view`/`pure` functions last.

* **Use clear comments** — Explain logic where the code isn’t self-explanatory.
* **ERC-7201** — When using it, avoid declaring state variables outside the main storage struct.
* **Avoid floating `pragma` versions** — Use fixed compiler versions like `pragma solidity 0.8.20;` when deploying contracts to production. Floating pragmas (e.g., `^0.8.0`) are only acceptable for libraries intended to support multiple versions, as they can lead to unexpected behavior with newer Solidity releases.
* **Custom Error Format** — Use the following naming format:
  ```solidity
  error ContractName__ErrorDescription();
  // Example:
  error TokenHandler__InsufficientUserBalance();
  ```

-----

## 🛠 Tools & Validation

Use tools to catch bugs and enforce best practices.

* **Slither** — A static analyzer for Solidity vulnerabilities.
* **Aderyn** — Another analyzer for smart contract code quality.
* **Use named imports** — Enhances readability and makes dependency declarations explicit.
* **Etherscan Verification** — Using an initializer pattern makes constructor arguments cleaner for verification.
* **Unit test** — In blockchain, test coverage above 75-80% is a **MUST**.

-----

## 📚 References

* **Solidity Style Guide:** [https://docs.soliditylang.org/en/latest/style-guide.html](https://docs.soliditylang.org/en/latest/style-guide.html)
* **CEI Pattern:** [https://fravoll.github.io/solidity-patterns/checks\_effects\_interactions.html](https://fravoll.github.io/solidity-patterns/checks_effects_interactions.html)
* **ERC-7201:** [https://eips.ethereum.org/EIPS/eip-7201](https://eips.ethereum.org/EIPS/eip-7201)
* **Slither:** [https://github.com/crytic/slither](https://github.com/crytic/slither)