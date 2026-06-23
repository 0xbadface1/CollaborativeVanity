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
│   ├── CurrencyToken.sol           # ERC-20 deployed at vanity CREATE2 address
│   ├── CurrencyNFT.sol             # Discovered vanity addresses as tradeable NFTs
│   ├── PlayerNFT.sol               # Player identity as transferable NFT
│   └── libraries/
│       └── LeadingZeros.sol        # Leading zero bit counter (difficulty measurement)
├── test/
│   ├── LeadingZeros.t.sol          # Unit + fuzz tests for difficulty counting
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

6. **Dual accounting**: player credit is capped (1% of pool max), pool total gets full actual difficulty.

7. **Counter + salt separation**: counter is committed in the hash (ordering), salt is the free search variable (iterated rapidly off-chain).

---

## CREATE2 Architecture

The share hash IS the CREATE2 address computation. Every hash attempt simultaneously searches for:
- Leading zeros → share difficulty (proof of work)
- Vanity patterns → currency discovery (e.g. 0xBadFace...)

### Formula

```
initCodeHash = keccak256(
    CurrencyToken.creationCode ‖ abi.encode(playerId, dayNumber, targetDifficulty, counter, dayHash)
)

CREATE2 address = keccak256(0xff ‖ MiningPool ‖ salt ‖ initCodeHash)[12:]
```

### Roles of each variable

| Variable | Where | Role | Constraint |
|---|---|---|---|
| `playerId` | initCode | Player identity (= wallet address) | Explicit parameter (third-party submission OK) |
| `dayNumber` | initCode | Time anchor | Must have valid dayHash |
| `targetDifficulty` | initCode | Pre-committed difficulty bet | Anti-Sybil: can't retroactively lower |
| `counter` | initCode | Share submission index | Strictly increasing per player per day |
| `dayHash` | initCode | On-chain daily randomness | Prevents pre-computing shares for future days |
| `salt` | CREATE2 salt | Free search variable | No constraint — iterated billions of times |

The counter defines WHICH address space to search. The salt searches WITHIN that space. Changing the counter changes the initCodeHash, producing an entirely different 2^256-sized search space. The dayHash ensures shares can only be computed after a day's randomness is published.

### Off-chain mining workflow

1. Pick `targetDifficulty`, `dayNumber`, `counter` (must be > last submitted)
2. Look up `dayHash = dayHashes(dayNumber)` — must be non-zero (day must exist)
3. Compute `initCodeHash = getInitCodeHash(me, day, difficulty, counter, dayHash)` — fixed per counter
4. Iterate salt: `hash = keccak256(0xff ‖ pool ‖ salt ‖ initCodeHash)`
5. If `leadingZeros(hash) >= targetDifficulty`: submit `(counter, salt)` pair
6. If the address is also "interesting" (vanity pattern): register as currency

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
- `uint256 totalIntegratedDifficulty` — running pool total (uncapped)
- `uint256 totalShareCount` — running share count
- `PlayerNFT playerNFT` — deployed by constructor
- `CurrencyNFT currencyNFT` — deployed by constructor

**Key functions:**
- `submitShare(player, targetDifficulty, dayNumber, counter, salt)` — core share submission (anyone can submit on behalf of a player)
- `registerCurrency(player, counter, salt, dayNumber, targetDifficulty)` → mints CurrencyNFT to current PlayerNFT owner
- `deployCurrency(vanityAddress, totalSupply)` → CREATE2 deploys CurrencyToken, only by NFT owner
- `getPlayerScoreAt(playerId, day)` → checkpoint binary search
- `getPoolScoreAt(day)` → pool-wide checkpoint binary search
- `getInitCodeHash(player, day, difficulty, counter, dayHash)` → for off-chain mining
- `computeVanityAddress(player, counter, salt, day, difficulty, dayHash)` → verify before registering
- `getCurrentDayHash()` → publish current day's hash without submitting a share (resolves dayHash bootstrap)

### CurrencyToken (ERC-20)

Deployed via CREATE2 at discovered vanity addresses.

**Constructor params** (affect the CREATE2 address):
- `playerId`, `dayNumber`, `targetDifficulty`, `counter`, `dayHash`

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

Discovered vanity addresses as tradeable NFTs.

**TokenId** = `uint256(uint160(vanityAddress))`

**Stored per discovery:**
- `counter` — share index (in initCode)
- `salt` — CREATE2 salt (found off-chain)
- `playerId` — discoverer
- `dayNumber` — discovery day (score snapshot anchor)
- `targetDifficulty` — difficulty target
- `deployed` — whether CurrencyToken has been deployed

**Lifecycle:**
1. Player discovers vanity address → calls `MiningPool.registerCurrency()` → NFT minted
2. NFT holder calls `MiningPool.deployCurrency(vanityAddress, totalSupply)` → CurrencyToken deployed at vanity address
3. NFT becomes souvenir / proof of provenance

Transferable — selling the NFT transfers deployment rights. PlayerNFT ownership controls claim recipients for historical player score rights.

### PlayerNFT (ERC-721)

Player identity as transferable NFT.

**TokenId** = `uint256(uint160(walletAddress))`

Lazy minted by MiningPool on first share submission (idempotent `mintIfNeeded`). Transferable — selling transfers ownership of accumulated mining credits.

### LeadingZeros (library)

Counts leading zero bits in bytes32. Binary search approach — O(8) steps. Used to measure share difficulty.

---

## Game-Theoretic Design

### Pre-Committed Difficulty (Anti-Sybil)

Target difficulty is baked into initCode (constructor params). Can't retroactively lower.

- **Valid share** (actual >= target): credit = target, capped at 1% of pool total
- **Invalid share** (actual < target): credit = current pool average, capped at 1% of pool total
- **Pool total**: always gets full uncapped actual difficulty

### Dual Accounting

| | Player's Credit | Pool's Total |
|---|---|---|
| Valid share | `min(target, totalDifficulty / 100)` | Full actual difficulty |
| Invalid share | `min(totalDifficulty / totalShareCount, totalDifficulty / 100)` | Full actual difficulty |

Lucky mega-shares boost the pool average for everyone — socialized luck.

### Day Advancement

- Days = `(block.timestamp - dayZeroTimestamp) / 86400`
- Day hash published on first submission of each new day (O(1))
- Skipped days have no hash — shares can't reference them
- Checkpoints bridge gaps automatically (`upperLookup` returns last known value)

---

## Implementation Status

### Phase 1: Core System ✅ COMPLETE

- [x] Foundry project setup, OpenZeppelin installed
- [x] `LeadingZeros.sol` — leading zero bit counter
- [x] `CurrencyToken.sol` — minimal ERC-20 with CREATE2 constructor params (incl. dayHash)
- [x] `PlayerNFT.sol` — lazy minting, address-as-tokenId
- [x] `CurrencyNFT.sol` — discovery storage, deployment tracking
- [x] `MiningPool.sol` — share submission, scoring, day management, NFT deployment, currency registration & deployment
- [x] `LeadingZeros.t.sol` — 11 tests including fuzz test against naive implementation
- [x] `MiningPool.t.sol` — 43 tests covering submission, ordering, difficulty, credits, days, checkpoints, chain lock, dayHash, getCurrentDayHash
- [x] `NFTIntegration.t.sol` — 25 tests covering PlayerNFT, CurrencyNFT, registration, deployment, third-party registration, full flow
- [x] Third-party submission — `submitShare` and `registerCurrency` accept explicit player address; CurrencyNFT minted to current PlayerNFT owner
- [x] 78 Phase 1 tests, all passing before Phase 2 additions

### Phase 2: Token Distribution ✅ COMPLETE

- [x] Mint logic in CurrencyToken — reads player/pool scores from MiningPool
- [x] 1% discoverer reward + 99% proportional distribution
- [x] Total supply chosen by CurrencyNFT holder at deployment time
- [x] Player claim function (each player calls to receive their share)
- [x] Auto-boost pool on currency deployment — add vanity address leading-zero difficulty to `totalIntegratedDifficulty` (not `totalShareCount`). Prevents withholding difficulty from the pool. Double-counting with prior share submission is intentional (gift to the commons).
- [x] Integration tests for full mint flow
- [x] `TokenDistribution.t.sol` — 17 tests covering initialization, snapshot timing, claim math, PlayerNFT claim recipients, duplicate claims, zero-score claims, supply cap, auto-boost, multi-player multi-day flow, multiple independent currencies, third-party claiming
- [x] 96 tests total, all passing

### Phase 3: Polish & Edge Cases

- [ ] Bootstrap mechanism for empty pool (pre-seed values, decay, parameters)
- [ ] Day 0/1 edge case handling
- [ ] Minimum share difficulty calibration vs Base gas costs
- [ ] Share expiration (practical concern, TBD)
- [ ] Gas optimization
  - [ ] Use `upperLookupRecent` instead of `upperLookup` in submitShare (2 lookups per call, always recent keys)
  - [ ] creationCode CODECOPY gas (~3-6K per submitShare) — investigate assembly-level optimization
- [ ] Move `getCurrentDayHash()` out of "VIEW FUNCTIONS" section (it modifies state)
- [ ] Add explicit `player == address(0)` revert in submitShare and registerCurrency (currently relies on downstream ERC721 revert with non-descriptive error)
- [ ] Consider `require` instead of `assert` in deployCurrency line 558 (assert consumes all gas on failure)

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
- **Fuzz tests** — Foundry's fuzzer (1000 runs) for LeadingZeros, share verification
- **Integration tests** — full flow: submit shares → register currency → deploy → mint
- **Invariant tests** — pool score = sum of player scores, checkpoint ordering
- **Memory-efficient test helpers** — free memory pointer reset in search loops to prevent MemoryOOG
- **Python simulations** — statistical fairness verification (future)

---

## Open Design Questions

1. **Bootstrap mechanism** — pre-seed values, decay schedule, first-share handling
2. **Total supply of currencies** — discoverer-chosen at deployment (not in hash)
3. **Share expiration** — practical concern for stale data, TBD
4. **Minimum share difficulty** — calibrate against Base gas costs (currently 16 bits)
5. **Token name/symbol** — hardcoded "Vanity Currency" for now, per-token customization TBD

---

*v4 — June 2026. Incorporates: player terminology, counter/salt separation, initCode-based hash verification, on-chain bytecode hashing, O(1) day advancement, NFT integration, third-party submission/registration, implementation progress tracking.*
