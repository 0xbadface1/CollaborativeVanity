# Collaborative Vanity Address Mining — Implementation Plan (v4)

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
cloneInitCode = EIP-1167 proxy(currencyImpl) ‖ abi.encode(playerId, dayNumber, targetWork, counter, dayHash)
initCodeHash  = keccak256(cloneInitCode)

CREATE2 address = keccak256(0xff ‖ MiningPool ‖ salt ‖ initCodeHash)[12:]
```

Each vanity address is a ~45-byte EIP-1167 minimal-proxy clone of a single shared `CurrencyToken` implementation (`currencyImpl`). The committed params are the clone's **immutable args**, so CREATE2 hashes ~205 bytes of init code instead of the full ~4.7KB token — see Phase 3 below.

### Roles of each variable

| Variable | Where | Role | Constraint |
|---|---|---|---|
| `playerId` | initCode (clone immutable arg) | Player identity (= wallet address) | Explicit parameter; must equal `msg.sender` |
| `dayNumber` | initCode (clone immutable arg) | Time anchor | Must have valid dayHash |
| `targetWork` | initCode (clone immutable arg) | Pre-committed work bet | Anti-Sybil: can't retroactively lower |
| `counter` | initCode (clone immutable arg) | Share submission index | Strictly increasing per player per day |
| `dayHash` | initCode (clone immutable arg) | On-chain daily randomness | Prevents pre-computing shares for future days |
| `salt` | CREATE2 salt | Free search variable | No constraint — iterated billions of times |

The counter defines WHICH address space to search. The salt searches WITHIN that space. Changing the counter changes the initCodeHash, producing an entirely different 2^256-sized search space. The dayHash ensures shares can only be computed after a day's randomness is published.

### Off-chain mining workflow

1. Pick `targetWork`, `dayNumber`, `counter` (must be > last submitted)
2. Look up `dayHash = dayHashes(dayNumber)` — must be non-zero (day must exist)
3. Compute `initCodeHash = getInitCodeHash(me, day, work, counter, dayHash)` — the clone init-code hash, fixed per counter
4. Iterate salt: `hash = keccak256(0xff ‖ pool ‖ salt ‖ initCodeHash)`; take the address `addr = address(uint160(uint256(hash)))`
5. If `addressToWork(addr) >= targetWork`: submit `(counter, salt)` pair
6. If you want that address to become a coin: register it as a currency

`getInitCodeHash` returns `keccak256` of the EIP-1167 clone init code (proxy stub for `currencyImpl` + the committed params as immutable args). `currencyImpl` is deployed once in MiningPool's constructor. Off-chain miners hash only ~205 bytes per salt iteration; on-chain, the contract derives addresses with OZ `Clones.predictDeterministicAddressWithImmutableArgs`. Any change to `CurrencyToken` updates `currencyImpl` (and thus every clone address) on recompile.

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
- `deployCurrency(vanityAddress, totalSupply)` → CREATE2 deploys a CurrencyToken clone, only by NFT owner
- `getPlayerScoreAt(playerId, day)` → checkpoint binary search
- `getPoolScoreAt(day)` → pool-wide checkpoint binary search
- `getInitCodeHash(player, day, work, counter, dayHash)` → clone init-code hash for off-chain mining (`view`)
- `computeVanityAddress(player, counter, salt, day, work, dayHash)` → verify before registering
- `getCurrentDayHash()` → publish current day's hash without submitting a share (resolves dayHash bootstrap)

### CurrencyToken (ERC-20)

A single shared **implementation** (`currencyImpl`), deployed once in MiningPool's constructor. Each registered currency address is a ~45-byte EIP-1167 minimal-proxy clone of it, deployed via `Clones.cloneDeterministicWithImmutableArgs`.

**Committed params** (clone immutable args — affect the CREATE2 address):
- `playerId`, `dayNumber`, `targetWork`, `counter`, `dayHash` — read at runtime via `Clones.fetchCloneArgs(address(this))` (NOT constructor immutables, which would bake into the shared impl)

**NOT committed** (chosen at deployment time):
- `totalSupply` — passed to `MiningPool.deployCurrency()` and stored by `initializeDistribution()`

**Key properties:**
- `miningPool` = the impl-level immutable set when `currencyImpl` is deployed (= MiningPool); survives delegatecall, shared by all clones
- A clone has no constructor — distribution state is set by the explicit `initializeDistribution(totalSupply)` call; only MiningPool may call it
- Players claim through `claim(playerId)`; tokens mint to the current PlayerNFT owner
- Distribution uses `snapshotDay = dayNumber > 0 ? dayNumber - 1 : 0`
- Supply split: 1% discoverer bonus + 99% proportional by score at snapshot day
- `name`/`symbol` are `pure` constant overrides ("Vanity Currency" / "VANITY") — clone storage is empty, so OZ ERC20's storage-backed name/symbol can't be used

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

`MiningPool.addressToWork(addr)` converts a CREATE2 **address** (the low 160 bits of the hash) into expected work over a **2^160 domain**. Lower addresses produce higher work:

```solidity
if (uint160(addr) == 0) return type(uint256).max;
return uint256(type(uint160).max) / uint160(addr);
```

Work is scored on the address, not the full 32-byte hash, because the address is the canonical on-chain object: a low-valued address is simultaneously high work and a leading-zero vanity. The `type(uint160).max` numerator matches the 160-bit domain so the calibration is preserved (a typical address ≈ 2 work; 16 leading zero bits ≈ 2^16 work ≈ 65,536 expected hashes). The zero address saturates to `uint256.max` (unreachable in practice).

---

## Game-Theoretic Design

### Pre-Committed Work (Anti-Sybil)

Target work is baked into initCode (clone immutable args). Can't retroactively lower.

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
- [x] `CurrencyToken.sol` — minimal ERC-20 (now a clone implementation); committed params (incl. dayHash) live in initCode as the clone's immutable args
- [x] `PlayerNFT.sol` — lazy minting, address-as-tokenId
- [x] `CurrencyNFT.sol` — discovery storage, deployment tracking
- [x] `MiningPool.sol` — share submission, scoring, day management, NFT deployment, currency registration & deployment
- [x] `MiningPool.t.sol` — 52 tests covering submission, ordering, work, credits, days, checkpoints, chain lock, dayHash, getCurrentDayHash
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
- [x] 97 tests total, all passing (52 MiningPool + 26 NFTIntegration + 19 TokenDistribution)

### Phase 3: Polish & Edge Cases

- [~] Bootstrap mechanism for empty pool — pre-seed values IMPLEMENTED (`BOOTSTRAP_*` constants seed the pool in the constructor); decay schedule + parameter calibration still pending (needs MC sim)
- [ ] Day 0/1 edge case handling
- [ ] Minimum share work calibration vs Base gas costs
- [ ] Share expiration (practical concern, TBD)
- [ ] Gas optimization
  - [x] submitShare score reads — used `latest()` (O(1) tail read) instead of `upperLookup`/`upperLookupRecent`; valid because checkpoints are keyed by monotonic `today`, so the latest key is always <= today. Invariant documented inline.
  - [x] **DONE — Currency contracts deployed as minimal-proxy clones (EIP-1167 + immutable args).** `CurrencyToken` is now a shared implementation (`currencyImpl`, deployed in MiningPool's constructor); each vanity address is a ~45-byte clone with the committed params as immutable args, so CREATE2 hashes ~205 bytes instead of the full ~4.7KB token.

    **Result (measured).** `submitShare` median 174,718 → 171,668 (~3K/share saved on the hot path); `deployCurrency` avg 780,402 → 195,073, max 985,364 → 249,304 (deploying a 45-byte proxy instead of the full contract). All 97 tests pass.

    **How.** OZ 5.6 `Clones`, no external lib:
      - `predictDeterministicAddressWithImmutableArgs(currencyImpl, args, salt)` for on-chain address derivation (submitShare / registerCurrency / computeVanityAddress) — returns the address directly, which works because work is now scored on the address (Resolved Design Decision #11), so the full 32-byte hash is no longer needed on the hot path.
      - `cloneDeterministicWithImmutableArgs(currencyImpl, args, salt)` in `deployCurrency`, then `initializeDistribution(totalSupply)`.
      - `fetchCloneArgs(address(this))` inside the impl to read per-instance params.

    **Clone caveats handled (kept for reference):**
    - **Address binding preserved.** Committed params stay in the init code (clone immutable args), so the vanity address still binds to them (anti-Sybil intact). `totalSupply` stays a deploy-time storage value.
    - **Off-chain mining stays cheap — this is WHY clone, not CREATE3.** The commitment stays in the init code, so the miner precomputes `initCodeHash` once and does 1 keccak/salt-iteration. CREATE3 was rejected: it forces the commitment into the *salt* (the per-iteration variable), tripling off-chain hashing.
    - **Delegatecall-safety.** No constructor runs on a clone. Per-instance params read via `fetchCloneArgs`, NOT constructor `immutable`s (those bake into the shared impl). `miningPool` stays an impl immutable and `name`/`symbol` `pure` constants (code, survive delegatecall). Storage init happens in `initializeDistribution` (clones are born with empty storage).
    - **Storage lives in the proxy.** All ERC20 state lives at the vanity address; events attributed there.
    - **`getInitCodeHash` is now `view`** (reads `currencyImpl`) and only an off-chain/testing helper; it holds the one replica of OZ's private clone-bytecode template.
    - **Etherscan / UX caveat.** The vanity address shows the ~45-byte proxy stub, not the full token code (verify source once on the impl). The immutable-args variant may show as raw bytecode. A soft cost — "a proxy at my hard-mined vanity address" may feel less legit to some.
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
