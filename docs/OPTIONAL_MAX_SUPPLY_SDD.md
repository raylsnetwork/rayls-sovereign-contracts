# Software Design Document — Optional Max Supply for Token Handlers

| | |
|---|---|
| **Status** | Draft |
| **Author** | Marcos Lobo |
| **Date** | 2026-06-10 |
| **Scope** | `RaylsEnygmaHandler`, `RaylsErc20Handler`, `RaylsErc721Handler` (+ DvP), `RaylsErc1155Handler` (+ DvP), `EnygmaV1` hub |
| **Related** | `docs/ENYGMA_TECHNICAL_GUIDE.md`, `docs/architecture.md`, `docs/solidity-style-guide.md` |

---

## 1. Overview

### 1.1 Problem

Today, minting in every Rayls token handler (`src/rayls-protocol-sdk/tokens/`) is gated **only** by access control — the `restricted` modifier plus the AccessManager role system. There is no notion of a supply ceiling anywhere in the codebase (`maxSupply` / `supplyCap` / `supplyLimit` do not exist; the only related constant is `MAX_DECIMALS = 77` in `RaylsEnygmaHandler`, an unrelated overflow guard).

This means an authorized minter — or a compromised one — can mint without bound. For regulated and issued assets, a **hard, declared maximum supply** is frequently part of the asset's terms and must be enforced on-chain, independent of who holds the minter role.

### 1.2 Goal

Add an **optional, immutable** maximum supply to all token handlers and the Enygma hub:

- **Optional** — `maxSupply == 0` means *unlimited* (feature disabled). Any non-zero value is a hard cap. This keeps the change fully backward compatible.
- **Immutable** — the cap is set once (at deployment for fungible tokens; on first registration for per-id tokens) and can never be changed afterwards. Holders get a permanent guarantee.
- **Enforced at every mint entry point** — no minting path may exceed the cap.

### 1.3 Non-goals

- **No per-chain supply rebalancing.** The Enygma cap is a single global ceiling, not a per-chain allocation system.
- **No zero-knowledge / hidden cap.** The cap value and the aggregate `totalSupply` are public. Per-participant balances remain confidential (unchanged). See §8.
- **No retroactive cap on already-deployed tokens.** The feature applies to tokens deployed after the upgrade; existing tokens keep `maxSupply == 0` (unlimited) by storage default.

---

## 2. Scope — Affected Contracts

| Contract | Path | Role |
|---|---|---|
| `RaylsEnygmaHandler` | `src/rayls-protocol-sdk/tokens/RaylsEnygmaHandler.sol` | On-chain ERC20-style handler (per-chain cap) |
| `RaylsErc20Handler` | `src/rayls-protocol-sdk/tokens/RaylsErc20Handler.sol` | Standard ERC20 handler |
| `RaylsErc721Handler` | `src/rayls-protocol-sdk/tokens/RaylsErc721Handler.sol` | NFT handler (per-id cap) |
| `RaylsErc721DvpHandler` | `src/rayls-protocol-sdk/tokens/RaylsErc721DvpHandler.sol` | NFT + DvP |
| `RaylsErc1155Handler` | `src/rayls-protocol-sdk/tokens/RaylsErc1155Handler.sol` | Multi-token handler (per-id cap) |
| `RaylsErc1155DvpHandler` | `src/rayls-protocol-sdk/tokens/RaylsErc1155DvpHandler.sol` | Multi-token + DvP |
| `EnygmaV1` | `src/rayls-protocol/Enygma/Enygma-Payments/EnygmaV1.sol` | Confidential hub — authoritative global cap |
| `AbstractContractFactoryV1` | `src/rayls-protocol/RaylsContractFactory/AbstractContractFactoryV1.sol` | Typed deploy functions (plumbing) |
| `EnygmaTokenManagerV1` | `src/privateHub/.../EnygmaTokenManagerV1.sol` | Threads cap into Enygma creation |
| `EnygmaFactory` | (Enygma factory) | Constructs `EnygmaV1` with cap |

### 2.1 Design summary

| Token family | Granularity | Where set | Enforcement points |
|---|---|---|---|
| ERC20 / Enygma handler | Single contract-wide cap | `initialize()` (factory userArgs) | `mint`, `crossMint`, `crossRevertMint` |
| Enygma hub (`EnygmaV1`) | Single global cap | construction (`EnygmaInitParams`) | `updateSupply` (Mint) |
| ERC721 / ERC1155 (+DvP) | **Per token-id** | write-once `setMaxSupply(id, cap)` | `mint` (and cross-chain mint paths) |

---

## 3. Design — Fungible Single-Supply Tokens (`RaylsErc20Handler`, `RaylsEnygmaHandler`)

### 3.1 State

Append (see §6 for storage-safety rules) a single field:

```solidity
/// @notice Hard cap on total supply in base units. 0 == unlimited (feature disabled).
/// @dev Set once in initialize(); never mutated thereafter.
uint256 public maxSupply;
```

Set it from the handler's `initialize()` user arguments (decoded from the factory `abi.encode(...)` payload — see §7). Default `0` preserves current unlimited behavior.

### 3.2 Custom error

```solidity
error RaylsErc20Handler__MaxSupplyExceeded(uint256 requested, uint256 cap);
error RaylsEnygmaHandler__MaxSupplyExceeded(uint256 requested, uint256 cap);
```

### 3.3 Enforcement

Add an internal guard and call it from **every** mint entry point, before `_mint(...)`:

```solidity
function _checkMaxSupply(uint256 _value) internal view {
    if (maxSupply != 0 && totalSupply() + _value > maxSupply) {
        revert RaylsEnygmaHandler__MaxSupplyExceeded(totalSupply() + _value, maxSupply);
    }
}
```

Call sites:

- **`RaylsErc20Handler.mint(...)`** — before the OZ `_mint`.
- **`RaylsEnygmaHandler.mint(address _to, uint256 _value)`** (`RaylsEnygmaHandler.sol:235`) — after the existing `_value == 0` check, before `_mint(_to, _value)` at line 238.
- **`RaylsEnygmaHandler.crossMint(...)`** (`RaylsEnygmaHandler.sol:284`) — the check must be placed **after** the idempotency guard (lines 294–298) and before `_mint` at line 305, so that a replayed (already-`RECEIVED`/`REVERTED`) reference id remains a silent no-op and does not falsely trip the cap.
- **`RaylsEnygmaHandler.crossRevertMint(...)`** (`RaylsEnygmaHandler.sol:257`) — same placement: after the idempotency guard (lines 266–270), before `_mint` at line 271. A revert re-mint restores tokens that were already counted before the failed transfer, so under normal operation it cannot exceed the cap; the guard is retained for defense-in-depth and self-consistency across mint paths.

> **CEI note:** `_checkMaxSupply` is a pure read + revert and introduces no external call, so it does not affect the Checks-Effects-Interactions ordering of `crossMint`'s callable loop.

---

## 4. Design — Enygma Hub (`EnygmaV1`)

The hub is the **authoritative, global** cap. `EnygmaV1` already maintains a **plaintext** `uint256 public totalSupply` (`EnygmaV1.sol:24`) alongside the BabyJubJub curve commitments — confidential per-participant balances are unaffected; only the public aggregate is used for the cap.

### 4.1 State + plumbing

```solidity
/// @notice Global hard cap on minted supply. 0 == unlimited.
uint256 public maxSupply;
```

Thread the value through creation:

`EnygmaInitParams` (new field `maxSupply`) → `EnygmaTokenManagerV1.registerEnygmaToken(...)` → `EnygmaFactory.initiateEnygmaCreation(params)` → `EnygmaV1` constructor/initializer. The source value originates from `SharedObjects.TokenRegistrationData` (the issuer's registration), so the issuer declares the cap at token registration time.

### 4.2 Enforcement — and the pending-finalisation nuance

`updateSupply(...)` (`EnygmaV1.sol:150`) does **not** increment `totalSupply` inline. It calls `finalisePendingTransactions(_blockNumber)` (line 157), pushes the new mint/burn onto `pendingMintsAndBurns` (lines 171–178), and the plaintext `totalSupply += amount` happens later when those pending actions are finalised (`processPendingActions`). Therefore a naive `totalSupply + amount <= maxSupply` check **undercounts** mints that are pending but not yet finalised.

The cap must account for the not-yet-finalised pending mints. Recommended approach:

```solidity
if (_update.txType == TxType.Mint) {
    uint256 projected = totalSupply + _pendingNetMint() + _update.amount; // sum of pending Mint - pending Burn
    require(maxSupply == 0 || projected <= maxSupply, 'EnygmaV1__MaxSupplyExceeded');
    (amountX, amountY) = derivePk(_update.amount);
}
```

where `_pendingNetMint()` sums the unfinalised entries in `pendingMintsAndBurns` (Mint positive, Burn negative). Implementation note: `finalisePendingTransactions` at line 157 has already drained entries for blocks `<= _blockNumber`, so only genuinely-future pending entries remain to be summed — keep the loop bounded (the array is already pruned on finalisation; document the bound to satisfy the project's "no unbounded loops" rule, and prefer maintaining a running `pendingNetMint` accumulator updated on push/finalise instead of looping).

> **Decision:** maintain a running `int256 pendingNetMint` accumulator (incremented on push, decremented on finalise) rather than looping the array — O(1) and avoids the unbounded-loop concern entirely.

### 4.3 Consistency with the per-chain handler cap (layered defense)

The hub cap and the `RaylsEnygmaHandler` per-chain cap are **both** enforced (user decision: layered). They are consistent because the relayer drives both the hub `updateSupply` and the per-chain `crossMint` from the same issuance flow. The hub is the single source of truth for the *global* total; the handler cap is a *local* guard that limits issuance on an individual chain. When configuring a token, the per-chain handler caps should sum to (or each be ≤) the hub `maxSupply`; document this operational invariant for issuers. A divergence (handler cap > hub cap) is harmless — the stricter hub cap wins; the reverse simply limits a chain below the global ceiling.

---

## 5. Design — Per-Token-Id Tokens (ERC721 / ERC1155, incl. DvP)

Token ids are created on demand at mint time, so an "immutable-at-deploy" single value does not fit. Instead the cap is **per id, write-once**.

### 5.1 State

```solidity
/// @notice Per-id hard cap. 0 (and unset) == unlimited.
mapping(uint256 id => uint256) private _maxSupply;
/// @notice Write-once guard: true once a cap has been registered for `id`.
mapping(uint256 id => bool) private _maxSupplySet;
```

### 5.2 Registration — write-once

```solidity
event MaxSupplySet(uint256 indexed id, uint256 cap);
error RaylsErc1155Handler__MaxSupplyAlreadySet(uint256 id);
error RaylsErc1155Handler__MaxSupplyBelowExisting(uint256 id, uint256 cap, uint256 existing);

/// @notice Register an immutable per-id cap. Callable once per id. cap == 0 leaves it unlimited.
function setMaxSupply(uint256 id, uint256 cap) external virtual restricted {
    if (_maxSupplySet[id]) revert RaylsErc1155Handler__MaxSupplyAlreadySet(id);
    // Guard against setting a cap below tokens already minted (relevant if an id was minted
    // before any cap was registered).
    uint256 existing = totalSupply(id); // ERC1155Supply / handler _totalSupply[id]
    if (cap != 0 && cap < existing) revert RaylsErc1155Handler__MaxSupplyBelowExisting(id, cap, existing);
    _maxSupply[id] = cap;
    _maxSupplySet[id] = true;
    emit MaxSupplySet(id, cap);
}
```

> **Alternative considered (documented, not chosen):** pass the cap as an extra argument on the *first* `mint` of an id. Rejected because it couples cap declaration to the first mint and complicates the mint signatures across all four per-id handlers; a dedicated `setMaxSupply` keeps mint signatures stable and lets issuers declare caps ahead of any minting.

### 5.3 Enforcement

A shared guard, called at the top of each `mint`:

```solidity
function _checkMaxSupply(uint256 id, uint256 value) internal view {
    uint256 cap = _maxSupply[id];
    if (cap != 0 && totalSupply(id) + value > cap) {
        revert RaylsErc1155Handler__MaxSupplyExceeded(id, totalSupply(id) + value, cap);
    }
}
```

Call sites:

- **`RaylsErc1155Handler.mint(...)`** (`RaylsErc1155Handler.sol:640`) — before `_mint`; `totalSupply(id)` is available via the `_totalSupply[id]` tracking / `ERC1155Supply` (`RaylsErc1155Handler.sol:103`).
- **`RaylsErc1155DvpHandler.mint(...)`** (`RaylsErc1155DvpHandler.sol:380`) — before `_mint`.
- **`RaylsErc721Handler.mint(address to, uint256 id)`** (`RaylsErc721Handler.sol:613`) — for ERC721 the meaningful "supply" of an id is 0 or 1. The per-id cap is the maximum number of times that id may exist; a cap of `1` is the natural NFT semantics. Enforce against the existence flag (`_exists[id]`, `RaylsErc721Handler.sol:106`): minting an id whose cap is `1` while it already exists must revert.
- **`RaylsErc721DvpHandler.mint(...)`** (`RaylsErc721DvpHandler.sol:349`) — same.

#### ERC721 burn-then-remint

Because ERC721 ids can be burned and the project's handlers remove them from tracking (`_exists[id] = false`), a cap of `1` would by itself allow re-minting a burned id (existence is back to 0). Decide and document the intended semantics:

- **Default (recommended):** the cap limits *concurrent existence*, so re-minting a previously-burned id is allowed (matches the existing existence-based tracking with zero extra storage).
- If *cumulative* mint count must be capped instead (a burned id can never be re-minted once the cap's worth has ever been minted), add a `mapping(uint256 id => uint256) _everMinted;` counter and check against it. This is heavier; only adopt if the asset's terms require it.

The SDD adopts the **concurrent-existence** semantics for ERC721 unless a specific issuance explicitly requires cumulative capping.

### 5.4 DvP cross-chain paths

DvP settlement (`dvpSwapCompleted` and the Merkle-level swap orchestration in `Dvp.sol`) **moves existing tokens** between parties — it nets to zero new supply — and is therefore **exempt** from the cap. The cap applies only to *issuance*: the handler `mint` functions and any destination-side `crossMint`-style issuance triggered by a swap. Document this distinction clearly so implementers do not add a redundant (and incorrect) cap check on the settlement path that would block legitimate swaps once a token reaches its cap.

---

## 6. Storage & Upgrade Safety

All handlers use **plain sequential storage** (not ERC-7201 namespaced storage). All production handlers are **UUPS-upgradeable**. Therefore:

- **Append-only.** Every new state variable (`maxSupply`, the per-id mappings, the Enygma `pendingNetMint` accumulator) MUST be added **after** all existing state variables in each contract. Never insert between or reorder existing variables — that shifts slots and corrupts deployed proxies.
- **Per-contract checklist** before merge:
  - [ ] New vars appended at the end of each modified handler.
  - [ ] No change to the declaration order/type of any pre-existing variable.
  - [ ] If a `__gap` exists in any base, reduce it by the number of slots consumed.
  - [ ] Run the OpenZeppelin storage-layout check (hardhat-upgrades / `validateUpgrade`) against the prior deployed implementation for each handler.

---

## 7. Factory / Deployment Plumbing

The typed deploy functions in `AbstractContractFactoryV1.sol` (`AbstractContractFactoryV1.sol:126-189`) build the handler init args via `abi.encode(...)`. Extend each to carry an optional `maxSupply`:

```solidity
// Before
function deployEnygma(string calldata name, string calldata symbol, uint8 decimals, bytes32 resourceId) ...
    return _deployRegistered(RAYLS_ENYGMA_KEY, abi.encode(name, symbol, decimals), resourceId);

// After
function deployEnygma(string calldata name, string calldata symbol, uint8 decimals, uint256 maxSupply, bytes32 resourceId) ...
    return _deployRegistered(RAYLS_ENYGMA_KEY, abi.encode(name, symbol, decimals, maxSupply), resourceId);
```

Apply the same pattern to `deployErc20`, `deployErc721`, `deployErc1155`, `deployErc721Dvp`, `deployErc1155Dvp`. For the per-id handlers, the deploy-time `maxSupply` is **not** a contract-wide cap (ids are per-id) — either omit it from the per-id deploy functions and rely solely on `setMaxSupply(id, cap)`, **or** treat the deploy-time value as a *default per-id cap* applied lazily on first mint. **Recommendation:** keep per-id handlers' deploy signatures unchanged and use only `setMaxSupply` — this avoids ambiguous semantics. Only the fungible deploys (`deployErc20`, `deployEnygma`) gain the `maxSupply` argument.

**Backward compatibility:** the handler `initialize()` must tolerate the absence of a `maxSupply` field in legacy encodings (decode defensively / default to 0). Document the encoding version bump.

**Go bindings:** any ABI change requires regenerating bindings for the relayer and services:

```bash
npx hardhat compile
node scripts/generate-bindings.js relayer
./scripts/move-bindings.sh /path/to/rayls-privacy-relayer-api/contracts
```

---

## 8. Security Considerations

- **Immutability guarantee.** Caps cannot be raised or lowered after they are set (`initialize` for fungibles; write-once `setMaxSupply` for per-id). This is the core holder guarantee; reviewers must confirm there is no other write path to the cap variables.
- **Idempotent cross-chain mints.** The cap check in `crossMint`/`crossRevertMint` is placed *after* the existing `referenceIdsStatus` idempotency guard (issue #75) so replays/out-of-order forwards stay no-ops and do not double-count or spuriously trip the cap.
- **Hub vs handler consistency.** The hub `EnygmaV1.maxSupply` is authoritative for the global total; per-chain handler caps are local. Operators must configure per-chain caps so they cannot collectively exceed the hub cap (the hub enforces the true ceiling regardless).
- **Pending-finalisation accounting.** The Enygma hub must count not-yet-finalised pending mints (§4.2) or a burst of pending mints could transiently exceed the cap before finalisation. The running `pendingNetMint` accumulator closes this gap.
- **Burn/re-mint semantics.** Explicitly chosen per token family (§5.3). For ERC1155, `totalSupply(id)` naturally decreases on burn, so burning frees headroom — this is intended.
- **Confidentiality trade-off.** Enforcing a numeric cap publishes the cap value and the aggregate `totalSupply` (already public in `EnygmaV1`). Per-participant balances remain hidden in the BabyJubJub commitments — the cap does **not** weaken individual-balance confidentiality.
- **No unbounded loops.** The hub accumulator avoids iterating `pendingMintsAndBurns`; per-id checks are O(1) map reads.

---

## 9. Testing Strategy

Use `loadFixture` and the fixtures in `hardhat/test/setup.ts`. Target ≥80% coverage on the new paths (critical path).

**Per fungible handler (`RaylsErc20Handler`, `RaylsEnygmaHandler`):**
- Mint exactly to the cap succeeds; one wei over reverts with `*__MaxSupplyExceeded`.
- `maxSupply == 0` ⇒ unlimited (large mints succeed).
- `crossMint` replay (same `_referenceId`) is a no-op and does not trip the cap.
- `crossRevertMint` after a failed transfer restores supply without exceeding the cap.

**Per per-id handler (ERC721/ERC1155 + DvP):**
- `setMaxSupply` write-once: second call reverts `*__MaxSupplyAlreadySet`.
- `setMaxSupply` below already-minted supply reverts `*__MaxSupplyBelowExisting`.
- Mint to id cap succeeds; over-cap reverts.
- ERC721 cap=1: mint once OK, second mint of live id reverts; burn then re-mint allowed (concurrent-existence semantics).
- DvP swap settlement of a fully-capped token still succeeds (settlement exempt).

**Enygma hub (`EnygmaV1`):**
- `updateSupply` Mint to cap OK; over-cap reverts `EnygmaV1__MaxSupplyExceeded`.
- Pending (unfinalised) mints are counted — two pending mints that individually fit but together exceed the cap: the second reverts.
- Burn frees headroom for a subsequent mint.

**End-to-end (cross-chain):**
- Deploy an Enygma token with a hub cap and per-chain handler caps; drive issuance through the relayer flow and assert hub `totalSupply` and the sum of handler `totalSupply()` never exceed the hub cap, and that an over-cap issuance is rejected at the hub.

**Static analysis:** run Slither/Aderyn on the modified handlers; confirm no new findings on the mint paths.

---

## 10. Rollout

- Fully backward compatible: every existing/new token defaults to `maxSupply == 0` (unlimited) unless a cap is explicitly provided.
- Suggested follow-up implementation tickets (one per layer, to keep PRs reviewable):
  1. Fungible handlers (`RaylsErc20Handler`, `RaylsEnygmaHandler`) + factory `deployErc20`/`deployEnygma`.
  2. Enygma hub (`EnygmaV1` + `EnygmaInitParams` + `EnygmaTokenManagerV1`/`EnygmaFactory` plumbing).
  3. Per-id handlers (ERC721/ERC1155 + DvP) with `setMaxSupply`.
  4. Go-bindings regeneration + relayer config for per-chain caps.
- Each ticket includes the storage-layout upgrade check (§6) and the test matrix slice (§9).
