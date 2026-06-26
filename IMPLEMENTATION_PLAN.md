# Collaborative Vanity Address Mining — Implementation Plan (v3)

## Context

Building the first implementation of the collaborative vanity address mining system described in the "Capturing and Distributing Cryptographic Luck" paper (Section 4). Smart contracts on Base (Ethereum L2) for collaborative vanity address mining with on-chain share registration and fair token distribution.

---

## Tech Stack

- **Solidity 0.8.28** with `via_ir` (IR-based compilation for better stack depth handling)
- **Foundry** (forge/cast/anvil) — development, testing, local deployment
- **OpenZeppelin v5.6** — ERC-721 (NFTs), ERC-20 (tokens), Checkpoints (cumulative score binary search)
- **Python** (`/simulations`) — Monte Carlo simulations, adversarial scenarios (future)
- **Base** (chainid 8453) — target deployment chain (deferred to later phase)

All code thoroughly documented — the codebase doubles as a Foundry learning resource.

---

## Terminology

**Players**, not miners. Throughout all code, comments, and documentation.

---

## Project Structure (current)

```
CollaborativeVanity/
├── foundry.toml                    # Foundry config (solc 0.8.28, via_ir, optimizer, fuzz)
├── src/
│   ├── MiningPool.sol              # Central contract — shares, scores, day management,
│   │                               #   currency registration & deployment, NFT deployment
│   ├── CurrencyToken.sol           # ERC-20 deployed at registered CREATE2 address
│   ├── CurrencyNFT.sol             # Registered currency addresses as tradeable NFTs
│   └── PlayerNFT.sol               # Player identity as transferable NFT
├── test/
│   ├── MiningPool.t.sol            # Share submission, scoring, day advancement
│   ├── NFTIntegration.t.sol        # PlayerNFT, CurrencyNFT, registration, deployment flow
│   └── TokenDistribution.t.sol     # Distribution initialization, claims, snapshots, auto-boost
├── IMPLEMENTATION_PLAN.md          # This file
├── GAME_THEORY_ANALYSIS.md         # Attack scenario analysis
└── CryptographicLuck_draft.pdf     # The paper
```

---

## Key Design Principles

1. **Shares recorded under SUBMISSION day**, not dayHash day. The dayHash only determines potential currency discovery day.

2. **Currency discoveries don't expire.** Backdating uses an older score snapshot — no unfair advantage since all players' shares are honestly recorded.

3. **NFT tokenIds = addresses**: PlayerNFT tokenId = `uint256(uint160(walletAddress))`, CurrencyNFT tokenId = `uint256(uint160(vanityAddress))`. Lazy minting.

4. **Player score storage uses Checkpoints**: OpenZeppelin's `Trace256` — `(day, cumulativeScore)` with binary search via `upperLookup()`.

5. **Daily pool snapshots**: first submission on a new day triggers a snapshot of pool-wide totals from the previous day. O(1) advancement regardless of gap — skipped days simply have no hash.

6. **Dual accounting**: player credit is capped (1% of pool max), pool total gets full actual work.

7. **Counter + salt separation**: counter is committed in the hash (ordering), salt is the free search variable (iterated rapidly off-chain).

---

## CREATE2 Architecture

The share hash IS the CREATE2 address computation. Every hash attempt simultaneously produces:
- Leading zeros → share work (proof of work)
- A currency address → optionally vanity, but not judged on-chain

### Formula

```
initCodeHash = keccak256(
    CurrencyToken.creationCode ‖ abi.encode(playerId, dayNumber, targetWork, counter, dayHash)
)

CREATE2 address = keccak256(0xff ‖ MiningPool ‖ salt ‖ initCodeHash)[12:]
```

### Roles of each variable

| Variable | Where | Role | Constraint |
|---|---|---|---|
| `playerId` | initCode | Player identity (= wallet address) | Explicit parameter; must equal `msg.sender` |
| `dayNumber` | initCode | Time anchor | Must have valid dayHash |
| `targetWork` | initCode | Pre-committed work bet | Anti-Sybil: can't retroactively lower |
| `counter` | initCode | Share submission index | Strictly increasing per player per day |
| `dayHash` | initCode | On-chain daily randomness | Prevents pre-computing shares for future days |
| `salt` | CREATE2 salt | Free search variable | No constraint — iterated billions of times |

The counter defines WHICH address space to search. The salt searches WITHIN that space. Changing the counter changes the initCodeHash, producing an entirely different 2^256-sized search space. The dayHash ensures shares can only be computed after a day's randomness is published.

### Off-chain mining workflow

1. Pick `targetWork`, `dayNumber`, `counter` (must be > last submitted)
2. Look up `dayHash = dayHashes(dayNumber)` — must be non-zero (day must exist)
3. Compute `initCodeHash = getInitCodeHash(me, day, work, counter, dayHash)` — fixed per counter
4. Iterate salt: `hash = keccak256(0xff ‖ pool ‖ salt ‖ initCodeHash)`
5. If `hashToWork(hash) >= targetWork`: submit `(counter, salt)` pair
6. If you want that hash to become a coin: register its address as a currency

The initCodeHash is computed on-chain from `type(CurrencyToken).creationCode` — the token bytecode is baked into MiningPool at compile time. No setter or external loading needed. Any change to CurrencyToken automatically updates all hash computations on recompile.

---

## Contract Architecture

### MiningPool (central contract)

The heart of the system. Deploys PlayerNFT and CurrencyNFT in its constructor. Players interact primarily with this contract.

**Responsibilities:**
- Share submission and validation (`submitShare`)
- Per-player cumulative score checkpoints (day → cumulativeScore)
- Pool-wide score checkpoints
- Daily snapshots — frozen when first submission of next day arrives
- Daily hash publication (O(1), only current day)
- Currency registration (`registerCurrency`) and deployment (`deployCurrency`)
- PlayerNFT lazy minting on first share submission

**Key state:**
- `mapping(playerId => Checkpoints.Trace256)` — per-player cumulative scores
- `Checkpoints.Trace256` — pool-wide cumulative scores
- `mapping(day => DaySnapshot)` — frozen daily pool-wide totals
- `mapping(day => bytes32)` — daily anchor hashes
- `mapping(playerId => mapping(day => uint256))` — last submitted counter per player per day
- `uint256 totalIntegratedWork` — running pool total (uncapped)
- `uint256 totalShareCount` — running share count
- `PlayerNFT playerNFT` — deployed by constructor
- `CurrencyNFT currencyNFT` — deployed by constructor

**Key functions:**
- `submitShare(player, targetWork, dayNumber, counter, salt)` — core share submission (requires `msg.sender == player`)
- `registerCurrency(player, counter, salt, dayNumber, targetWork)` → mints CurrencyNFT to current PlayerNFT owner
- `deployCurrency(vanityAddress, totalSupply)` → CREATE2 deploys CurrencyToken, only by NFT owner
- `getPlayerScoreAt(playerId, day)` → checkpoint binary search
- `getPoolScoreAt(day)` → pool-wide checkpoint binary search
- `getInitCodeHash(player, day, work, counter, dayHash)` → for off-chain mining
- `computeVanityAddress(player, counter, salt, day, work, dayHash)` → verify before registering
- `getCurrentDayHash()` → publish current day's hash without submitting a share (resolves dayHash bootstrap)

### CurrencyToken (ERC-20)

Deployed via CREATE2 at registered currency addresses.

**Constructor params** (affect the CREATE2 address):
- `playerId`, `dayNumber`, `targetWork`, `counter`, `dayHash`

**NOT in constructor** (chosen at deployment time):
- `totalSupply` — passed to `MiningPool.deployCurrency()` and stored by `initializeDistribution()`

**Key properties:**
- `miningPool` = msg.sender during CREATE2 (= MiningPool address)
- Only MiningPool can call `initializeDistribution(totalSupply)`
- Players claim through `claim(playerId)`; tokens mint to the current PlayerNFT owner
- Distribution uses `snapshotDay = dayNumber > 0 ? dayNumber - 1 : 0`
- Supply split: 1% discoverer bonus + 99% proportional by score at snapshot day
- Hardcoded name/symbol for now ("Vanity Currency" / "VANITY")

### CurrencyNFT (ERC-721)

Registered currency addresses as tradeable NFTs.

**TokenId** = `uint256(uint160(vanityAddress))`

**Stored per discovery:**
- `counter` — share index (in initCode)
- `salt` — CREATE2 salt (found off-chain)
- `playerId` — registering player
- `dayNumber` — day committed into the CREATE2 address (score snapshot anchor)
- `targetWork` — work target
- `deployed` — whether CurrencyToken has been deployed

**Lifecycle:**
1. Player chooses a hash result as a currency address → calls `MiningPool.registerCurrency()` → NFT minted
2. NFT holder calls `MiningPool.deployCurrency(vanityAddress, totalSupply)` → CurrencyToken deployed at that address
3. NFT becomes souvenir / proof of provenance

Transferable — selling the NFT transfers deployment rights. PlayerNFT ownership controls claim recipients for historical player score rights.

### PlayerNFT (ERC-721)

Player identity as transferable NFT.

**TokenId** = `uint256(uint160(walletAddress))`

Lazy minted by MiningPool on first share submission (idempotent `mintIfNeeded`). Transferable — selling transfers ownership of accumulated mining credits.

### Work Scoring

`MiningPool.hashToWork(hash)` converts a CREATE2 hash into expected work. Lower hashes produce higher work:

```solidity
if (hash == bytes32(0)) return type(uint256).max;
return type(uint256).max / uint256(hash);
```

The all-zero hash saturates to `uint256.max`, which is the largest representable work value.

---

## Game-Theoretic Design

### Pre-Committed Work (Anti-Sybil)

Target work is baked into initCode (constructor params). Can't retroactively lower.

Every share earns the pool average as a participation credit; a valid share adds its target work as a performance bonus; the combined credit is capped once at 1% of the pool total.

- **Valid share** (actual >= target): credit = average + target, capped at 1% of pool total
- **Invalid share** (actual < target): credit = current pool average, capped at 1% of pool total
- **Pool total**: always gets full uncapped actual work

### Dual Accounting

| | Player's Credit | Pool's Total |
|---|---|---|
| Valid share | `min(totalWork / totalShareCount + target, totalWork / 100)` | Full actual work |
| Invalid share | `min(totalWork / totalShareCount, totalWork / 100)` | Full actual work |

Capping the combined credit keeps the 1% per-share ceiling while guaranteeing a valid share always scores at least as much as an invalid one (no incentive to deliberately miss a target to collect the average). Lucky mega-shares boost the pool average for everyone — socialized luck.

### Day Advancement

- Days = `(block.timestamp - dayZeroTimestamp) / 86400`
- Day hash published on first submission of each new day (O(1))
- Skipped days have no hash — shares can't reference them
- Checkpoints bridge gaps automatically (`upperLookup` returns last known value)

---

## Implementation Status

### Phase 1: Core System ✅ COMPLETE

- [x] Foundry project setup, OpenZeppelin installed
- [x] `CurrencyToken.sol` — minimal ERC-20 with CREATE2 constructor params (incl. dayHash)
- [x] `PlayerNFT.sol` — lazy minting, address-as-tokenId
- [x] `CurrencyNFT.sol` — discovery storage, deployment tracking
- [x] `MiningPool.sol` — share submission, scoring, day management, NFT deployment, currency registration & deployment
- [x] `MiningPool.t.sol` — 44 tests covering submission, ordering, work, credits, days, checkpoints, chain lock, dayHash, getCurrentDayHash
- [x] `NFTIntegration.t.sol` — 26 tests covering PlayerNFT, CurrencyNFT, registration, caller-is-player guard, deployment, full flow
- [x] Self-only submission — `submitShare` and `registerCurrency` require `msg.sender == player`; CurrencyNFT minted to current PlayerNFT owner
- [x] Phase 1 tests passing before Phase 2 additions

### Phase 2: Token Distribution ✅ COMPLETE

- [x] Mint logic in CurrencyToken — reads player/pool scores from MiningPool
- [x] 1% discoverer reward + 99% proportional distribution
- [x] Total supply chosen by CurrencyNFT holder at deployment time
- [x] Player claim function (each player calls to receive their share)
- [x] Auto-boost pool on currency deployment — add registered address full-hash work to `totalIntegratedWork` (not `totalShareCount`). Prevents withholding work from the pool. Double-counting with prior share submission is intentional (gift to the commons).
- [x] Integration tests for full mint flow
- [x] `TokenDistribution.t.sol` — 19 tests covering initialization, snapshot timing, claim math, PlayerNFT claim recipients, caller-is-owner guard, duplicate claims, zero-score claims, supply cap, auto-boost, multi-player multi-day flow, multiple independent currencies
- [x] 88 tests total, all passing

### Phase 3: Polish & Edge Cases

- [~] Bootstrap mechanism for empty pool — pre-seed values IMPLEMENTED (`BOOTSTRAP_*` constants seed the pool in the constructor); decay schedule + parameter calibration still pending (needs MC sim)
- [ ] Day 0/1 edge case handling
- [ ] Minimum share work calibration vs Base gas costs
- [ ] Share expiration (practical concern, TBD)
- [ ] Gas optimization
  - [x] submitShare score reads — used `latest()` (O(1) tail read) instead of `upperLookup`/`upperLookupRecent`; valid because checkpoints are keyed by monotonic `today`, so the latest key is always <= today. Invariant documented inline.
  - [ ] **BIG TODO — Minimize the deployed currency contract (proxy/clone pattern) to cut deployment-address gas.**

    **Why.** Every `submitShare` recomputes the CREATE2 init-code hash, which means hashing the *full* `CurrencyToken` creation bytecode (~4,742 bytes ≈ 149 words) concatenated with the 5 committed args — on top of two ~5 KB memory allocations. That is ~3–6K gas **per share** on the hot path, paid purely because the deployed contract is large. The keccak itself is unavoidable (CREATE2 hashes the whole init code; keccak is not prefix-composable, so caching `keccak256(creationCode)` does NOT help), so the only real lever is to **shrink the bytecode that gets hashed**.

    **Approach — minimal proxy with immutable args (clone-with-immutable-args).** Deploy ONE full `CurrencyToken` implementation once (in MiningPool's constructor, alongside PlayerNFT/CurrencyNFT) and store it as `immutable currencyImpl`. Each discovered vanity address becomes a ~55-byte EIP-1167 clone pointing at that impl, with the committed params appended as immutable args. This drops the hashed init code from ~4,900 → ~215 bytes (~22×), taking `submitShare`'s address computation from ~3–6K to sub-1K gas. OZ 5.6 has native support — no external lib:
      - `Clones.predictDeterministicAddressWithImmutableArgs(currencyImpl, args, salt, address(this))` for on-chain address prediction (submitShare / registerCurrency).
      - `Clones.cloneDeterministicWithImmutableArgs(currencyImpl, args, salt)` in `deployCurrency`, then `initializeDistribution(totalSupply)`.
      - `Clones.fetchCloneArgs(address(this))` inside the impl to read the per-instance params.

    **Things to NOT forget / to consider:**
    - **Address binding is preserved.** The committed params `(playerId, dayNumber, targetWork, counter, dayHash)` stay in the init code (as the clone's immutable args), so the vanity address still cryptographically binds to them (anti-Sybil intact). `totalSupply` stays a deploy-time storage value (it doesn't affect the address).
    - **Off-chain mining stays cheap — this is WHY clone, not CREATE3.** Because the commitment stays in the init code, the miner precomputes `initCodeHash` once and does 1 keccak/salt-iteration (unchanged from today). CREATE3 was considered and rejected: it would force the commitment into the *salt* (the per-iteration variable), tripling off-chain hashing (~3 keccaks/iteration) — a bad trade for a system whose core cost is billions of off-chain hashes. CREATE3's only edge (a normal full contract at the vanity address, and cross-chain same-address deploys) doesn't outweigh that.
    - **Delegatecall-safety of the impl.** No constructor runs on a clone, and clones share one impl. Per-instance params MUST be read via `fetchCloneArgs`, NOT constructor `immutable`s (those bake into the shared impl). `miningPool` and `name`/`symbol` can stay impl-level constants (same for all clones). Storage init (mint, totalSupply, `initialized` guard) happens in an explicit `initializeDistribution` call, since clones are born with empty storage.
    - **Storage lives in the proxy.** All ERC20 state (`_balances`, `_allowances`, `totalSupply`) lives at the vanity address's storage; the impl's own storage is unused. Token tracking / events are correctly attributed to the vanity address.
    - **Runtime trade-off.** Token calls (transfer, claim, balanceOf) now delegatecall the impl → ~2.1–2.6K extra per call. Negligible vs. the mining loop (those calls are rare), but worth confirming with a gas profile.
    - **Etherscan / UX caveat.** The vanity address will show the ~55-byte proxy stub, not the full token code (verify source once on the impl). Etherscan auto-detects canonical EIP-1167 well, but the immutable-args variant may show as raw bytecode. Some users/marketplaces may perceive "a proxy at my hard-mined vanity address" as less legit than a standalone contract — a soft cost to weigh.
    - **Security unchanged.** The clone init code is recomputed on-chain from the trusted `currencyImpl` + args, so the proof-of-work is still bound to a genuinely deployable address (a miner can't submit a fake `initCodeHash`).
    - **Scope / test impact.** Sizeable refactor: split CurrencyToken into impl + clone deployment, rework the 3 init-code-hash sites + `deployCurrency` + `getInitCodeHash`/`computeVanityAddress`, update the off-chain client and the test `_findValidSalt` to the clone formula. Credit/scoring logic in `submitShare` is untouched (only the init-code construction changes), so those tests stay; deployment/NFT/distribution suites need rework. Validate with a before/after gas profile. Supersedes the old "creationCode CODECOPY assembly nibble" idea (that recovered only the memory-copy waste, ~1–3K; this attacks the bytecode size itself).
- [x] Move `getCurrentDayHash()` out of "VIEW FUNCTIONS" section (it modifies state) — now in CORE FUNCTIONS with a STATE-CHANGING NatSpec
- [x] Add explicit `player == address(0)` revert (`ZeroPlayer`) in submitShare and registerCurrency
- [x] Replaced `assert` with a descriptive `DeployedAddressMismatch` revert in deployCurrency (assert consumes all gas on failure)

### Phase 4: BountyEscrow (optional)

- [ ] Locked ETH bounties for specific vanity patterns
- [ ] Claim mechanism with proof

### Phase 5: Simulation & Testing

- [ ] Python Monte Carlo simulations of pool dynamics
- [ ] Adversarial scenario modeling
- [ ] Bootstrap/decay parameter calibration

### Phase 6: Deployment

- [ ] Base testnet deployment scripts
- [ ] Base mainnet deployment

---

## Testing Strategy

- **Unit tests per contract** — every function, every edge case
- **Fuzz tests** — Foundry's fuzzer for share verification and future invariants
- **Integration tests** — full flow: submit shares → register currency → deploy → mint
- **Invariant tests** — pool score = sum of player scores, checkpoint ordering
- **Memory-efficient test helpers** — free memory pointer reset in search loops to prevent MemoryOOG
- **Python simulations** — statistical fairness verification (future)

---

## Open Design Questions

1. **Bootstrap mechanism** — pre-seed values, decay schedule, first-share handling
2. **Total supply of currencies** — discoverer-chosen at deployment (not in hash)
3. **Share expiration** — practical concern for stale data, TBD
4. **Minimum share work** — calibrate against Base gas costs (currently 65,536 expected hashes)
5. **Token name/symbol** — hardcoded "Vanity Currency" for now, per-token customization TBD

---

*v4 — June 2026. Incorporates: player terminology, counter/salt separation, initCode-based hash verification, on-chain bytecode hashing, O(1) day advancement, NFT integration, self-only submission/registration/claims (`msg.sender` must match the player), implementation progress tracking.*
