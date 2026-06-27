# Collaborative Vanity Address Mining

First implementation of the collaborative vanity address mining system from the "Capturing and Distributing Cryptographic Luck" paper (Section 4). Players submit proof-of-work shares (low-valued CREATE2 addresses, scored by expected work) to an on-chain MiningPool on Base (Ethereum L2). When a vanity address is discovered, a meme currency token is deployed there with supply distributed proportionally to contributing players.

Author: **Tristan Badface** (0xbadface.eth)

---

## Terminology

**Use "player" everywhere — never "miner".** Variables, function names, comments, docs, discussion. Participants are playing a collaborative game of luck, not mining.

---

## Git

- Author: `Tristan Badface <tristan@0xbadface.xyz>`
- Commit proactively in small, logical steps — don't batch unrelated changes into one commit.
- Prefer each commit to build and pass tests. When a clean split needs a non-functional intermediate (e.g. remove a flag, then migrate tests), commit it anyway but note the broken/WIP state in the commit body. Never commit something broken silently.
- Do NOT push — the user pushes manually.
- Run tests before a commit you expect to pass: `~/.foundry/bin/forge test`

---

## Tech Stack

- Solidity 0.8.28, `via_ir` enabled (required — stack too deep without it)
- Foundry (forge/cast/anvil) — `foundry.toml` has all config
- OpenZeppelin v5.6 — ERC-721, ERC-20, Checkpoints (Trace256)
- `forge` binary is at `~/.foundry/bin/forge` (not on PATH)

---

## Architecture

### Contracts (all in `src/`)

| Contract | Role |
|---|---|
| `MiningPool.sol` | Central contract. Share submission, scoring, day management, NFT deployment, currency registration & deployment. Deploys PlayerNFT, CurrencyNFT, and the shared CurrencyToken implementation (`currencyImpl`) in its constructor. |
| `CurrencyToken.sol` | ERC-20 **implementation** behind every vanity address. Deployed once as `currencyImpl`; each vanity address is a ~45-byte EIP-1167 clone of it (immutable args = the committed params). Per-instance params read via `Clones.fetchCloneArgs`; `name`/`symbol` are pure constants and `miningPool` an impl-level immutable (both survive delegatecall). |
| `PlayerNFT.sol` | ERC-721 player identity. Lazy minted on first share submission. TokenId = wallet address. |
| `CurrencyNFT.sol` | ERC-721 for discovered vanity addresses. Stores all CREATE2 params for later deployment. TokenId = vanity address. |

### Work Scoring

Shares are scored by **expected work**, not leading-zero bits. Work is scored on the **20-byte CREATE2 address** (the low 160 bits of the hash), not the full 32-byte hash. `MiningPool.addressToWork(addr)` converts an address into a continuous work value over a **2^160 domain**:

```solidity
if (uint160(addr) == 0) return type(uint256).max;
return uint256(type(uint160).max) / uint160(addr);   // lower address → more expected hashes → more work
```

Scoring the address (not the full hash) is deliberate: the address is the canonical on-chain object, and a low-valued address is *simultaneously* high work **and** a leading-zero vanity — unifying share work with vanity quality. The numerator is `type(uint160).max` (not `uint256.max`) so the domain matches a 160-bit address: a typical address scores ~2 work, and an address with 16 leading zero bits scores ~2^16 work (≈ 65,536 expected hashes), preserving the `MIN_SHARE_WORK` calibration. Using a `uint256` numerator here would make every address clear `MIN_SHARE_WORK` for free.

This mirrors the Bitcoin-style intuition (a lower value needed more attempts on average) and is a smoother measure of effort than counting discrete zero bits. The zero address saturates to `uint256.max` (unreachable — yielding `address(0)` is itself 2^160 work). There is no separate library — work scoring is a `pure` function on MiningPool. (The former `libraries/LeadingZeros.sol` leading-zero counter was removed in this switch.)

### CREATE2 Hash Construction

The share hash IS the CREATE2 address computation. Every hash attempt simultaneously searches for low-valued hashes (share work) and vanity patterns (currency discovery).

```
cloneInitCode = EIP-1167 proxy(currencyImpl) || abi.encode(playerId, dayNumber, targetWork, counter, dayHash)
initCodeHash = keccak256(cloneInitCode)
address = keccak256(0xff || MiningPool || salt || initCodeHash)[12:]
```

The committed params are the clone's **immutable args** (appended to the EIP-1167 proxy stub), so they live in the init code and the address binds to them — exactly as constructor params did before, but the hashed init code is ~205 bytes instead of ~4.7KB.

**Counter vs Salt — critical distinction:**
- `counter` is in initCode (clone immutable arg). Defines WHICH address space to search. Strictly increasing per player per day, starting at 1 (the default `lastShareCounter` of 0 means "nothing submitted yet", so counter 0 is reserved and the first share of a day must use counter >= 1 — this lets us avoid a separate "has submitted" flag). Changing counter = entirely different 2^256 search space.
- `salt` is the CREATE2 salt. The FREE search variable iterated billions of times off-chain. No ordering constraint.
- `dayHash` is in initCode (clone immutable arg). On-chain daily randomness that prevents pre-computing shares for future days. Published via `getCurrentDayHash()` or automatically on each day's first submission.

On-chain, `submitShare`/`registerCurrency`/`computeVanityAddress` derive the address with OpenZeppelin's `Clones.predictDeterministicAddressWithImmutableArgs(currencyImpl, args, salt)`. `deployCurrency` deploys with `Clones.cloneDeterministicWithImmutableArgs`. `getInitCodeHash` (off-chain helper) returns the clone init-code hash. No setter or external loading needed — `currencyImpl` is deployed in MiningPool's constructor.

### Scoring

Every accepted share earns the **pool average** (`totalIntegratedWork / totalShareCount`) as a participation credit. A **valid** share (actual work >= its pre-committed target, target > 0) additionally earns its **target work** as a performance bonus. The combined credit is capped **once** at 1% of the pool total:

- **Valid share** (actual >= target): credit = `min(average + target, totalIntegratedWork / 100)`
- **Invalid share** (actual < target): credit = `min(average, totalIntegratedWork / 100)`
- **Pool total**: always gets full uncapped actual work
- Player scores stored as OpenZeppelin Checkpoints (day, cumulativeScore) with binary search via `upperLookup()`

Capping the *combined* credit keeps the 1% per-share ceiling intact while making a valid share always worth at least as much as an invalid one. This closes a wart in the earlier mutually-exclusive scheme, where a below-average player was better off declaring an unreachable target and submitting an "invalid" share to collect the (higher) average instead of honestly hitting a modest target.

### Bootstrap

The pool is pre-seeded in the constructor so early shares score sanely against a non-empty pool (avoids divide-by-zero in the average and gives a minimum valid share full credit under the 1% cap):

- `BOOTSTRAP_SHARE_COUNT = 10`
- `BOOTSTRAP_AVERAGE_WORK = MIN_SHARE_WORK * MAX_SHARE_CREDIT_DIVISOR / BOOTSTRAP_SHARE_COUNT`
- `BOOTSTRAP_INTEGRATED_WORK = BOOTSTRAP_SHARE_COUNT * BOOTSTRAP_AVERAGE_WORK`

`totalShareCount` and `totalIntegratedWork` start at these values. Decay schedule and final parameter calibration still need MC simulation (Phase 3).

### Day Management

- Days = `(block.timestamp - dayZeroTimestamp) / 86400`
- Day hash published on first submission of each new day (O(1), no backfill loop)
- Skipped days have no hash — shares can't reference them
- Checkpoints bridge gaps automatically

### NFT Token IDs

- PlayerNFT: `uint256(uint160(walletAddress))`
- CurrencyNFT: `uint256(uint160(vanityAddress))`

---

## Tests

Three test suites, 97 tests total, all in `test/`:

| Suite | Tests | Coverage |
|---|---|---|
| `MiningPool.t.sol` | 52 | Submission, ordering, work scoring, credits (incl. mature-pool combined credit via test harness), caller-is-player guard, days, checkpoints, chain lock, dayHash, getCurrentDayHash |
| `NFTIntegration.t.sol` | 26 | PlayerNFT, CurrencyNFT, registration, caller-is-player guard, deployment, full mine-register-deploy flow |
| `TokenDistribution.t.sol` | 19 | Distribution initialization, snapshot timing, claim math, PlayerNFT claim recipients, caller-is-owner guard, duplicate claims, auto-boost, multi-day flow, multiple currencies |

Run: `~/.foundry/bin/forge test`
Run with gas: `~/.foundry/bin/forge test --gas-report`
Verbose: `~/.foundry/bin/forge test -vvv`

### Test helper pattern: free memory pointer reset

Tests that search for valid salts in a loop MUST reset the free memory pointer to prevent MemoryOOG. Each `abi.encodePacked` allocates new memory — across ~65K iterations this exhausts memory:

```solidity
uint256 freeMemPtr;
assembly { freeMemPtr := mload(0x40) }
for (...) {
    bytes32 hash = keccak256(abi.encodePacked(...));
    assembly { mstore(0x40, freeMemPtr) }
    ...
}
```

---

## Documentation Style

This codebase doubles as a Foundry learning resource. Add thorough documentation: NatSpec on all public functions, explain Foundry-specific patterns, document test structure. This overrides the usual "minimal comments" approach.

---

## Key Design Docs

- `IMPLEMENTATION_PLAN.md` — Full architecture, design decisions, implementation status, open questions (v3)
- `GAME_THEORY_ANALYSIS.md` — 12 attack scenarios analyzed, protection matrix, open simulation needs
- `CryptographicLuck_draft.pdf` — The paper this implements (Section 4)

---

## Implementation Status

### Phase 1: Core System — COMPLETE
All core contracts implemented. Share submission and currency registration are
self-only: `msg.sender` must equal the player.

### Phase 2: Token Distribution — COMPLETE
- CurrencyToken initializes a fixed distribution supply from MiningPool and reads player/pool scores at snapshot day
- 1% discoverer reward + 99% proportional distribution to all players
- Total supply chosen by CurrencyNFT holder at deployment time via `deployCurrency(vanityAddress, totalSupply)`
- Pull-based `claim(playerId)` function; tokens mint to the current PlayerNFT owner
- Auto-boost pool on currency deployment: add vanity address work to totalIntegratedWork (not totalShareCount and not score checkpoints) so discoveries can't be withheld from the pool. Double-counting with prior share submission is intentional — it's a gift to the commons.
- 97 tests passing, including `TokenDistribution.t.sol`

### Phase 3: Polish & Edge Cases
- Bootstrap mechanism for empty pool — pre-seed values IMPLEMENTED (`BOOTSTRAP_*` constants seed the pool in the constructor); decay schedule + parameter calibration still need MC simulation
- Day 0/1 edge case handling
- Minimum share work calibration vs Base gas costs (currently `MIN_SHARE_WORK = 1 << 16`, i.e. ~65,536 expected hashes)
- Share expiration (TBD — practical concern, not security-critical)
- Gas optimization
  - Work scored on the 20-byte address (2^160 domain) instead of the full 32-byte hash — see Resolved Design Decision #11
  - **DONE — currency contracts deployed as EIP-1167 clones** (see Resolved Design Decision #3): cut `submitShare` ~3K gas and `deployCurrency` ~535–735K gas by hashing ~205 bytes of clone init code instead of the full ~4.7KB token bytecode

### Phase 4: BountyEscrow (optional)
Locked ETH bounties for specific vanity patterns.

### Phase 5: Simulation & Testing
Python Monte Carlo simulations of pool dynamics, adversarial scenarios, bootstrap parameter calibration.

### Phase 6: Deployment
Base testnet then mainnet.

---

## Resolved Design Decisions (do not revisit)

These were discussed and decided. Context preserved here so future sessions don't re-derive them.

1. **Counter in initCode, salt as free variable.** Initially counter=salt (single value). Refactored to separate them: counter is a committed param (clone immutable arg) that defines the address space, salt is iterated freely. Counter must strictly increase per player per day; salt has no constraint.

2. **O(1) day advancement.** Initially considered backfilling skipped days in a loop. User pointed out Checkpoints handle gaps via `upperLookup()` — skipped days simply have no hash and return 0. No loop needed.

3. **CurrencyToken deployed as EIP-1167 clones (was: full bytecode via CREATE2).** Originally each vanity address was a full `CurrencyToken` deployed via `new CurrencyToken{salt:…}`, and the initCodeHash was `keccak256(type(CurrencyToken).creationCode ‖ args)` — re-hashing ~4.7KB on every share. Now `currencyImpl` is deployed once in the constructor and each vanity address is a ~45-byte clone with the committed params as immutable args; addresses come from OZ `Clones` (predict on-chain, `cloneDeterministicWithImmutableArgs` to deploy). This cut `submitShare` ~3K gas and `deployCurrency` ~535–735K gas. Clone caveats handled: no constructor runs on a clone (state set via `initializeDistribution`); `miningPool` stays an impl immutable and `name`/`symbol` pure constants (survive delegatecall); per-instance params read via `Clones.fetchCloneArgs`. Trade-off: the vanity address shows a proxy stub on explorers (verify source on `currencyImpl`).

4. **MiningPool deploys NFTs in constructor.** Atomic setup — no setter, no multi-step deployment. PlayerNFT and CurrencyNFT are deployed and permanently linked.

5. **`via_ir` required.** Stack too deep errors in MiningPool without IR-based compilation. Enabled in `foundry.toml`.

6. **DaySnapshot uses uint256 (not uint128).** Compiler warnings about safe casts were not worth the negligible storage savings.

7. **`getInitCodeHash` is `view` (was `pure`).** It builds the EIP-1167 clone init code, which embeds the `currencyImpl` immutable, so it can no longer be `pure`. (Before the clone refactor it used only the compile-time `type(CurrencyToken).creationCode` and was `pure`.) Caller still passes dayHash explicitly rather than the function looking it up from storage. It is now only an off-chain/testing helper — on-chain code uses the OZ `Clones` predictor directly.

8. **dayHash in initCode (not salt).** The unpredictable daily on-chain randomness is a clone immutable arg (in initCode), not mixed into the CREATE2 salt. This makes it explicit and consistent with the pattern of all committed values living in initCode. Prevents pre-computing shares for future days.

9. **Caller must be the player.** `submitShare` and `registerCurrency` take the player address as a parameter and require `msg.sender == player`. The player is also committed in the CREATE2 hash, so the share/discovery is cryptographically bound to that identity. These are self-only operations — a caller can only mine and register under their own identity. CurrencyNFTs are still minted to the current PlayerNFT owner (not necessarily the original player address), so transferred PlayerNFTs carry discovery rights.

10. **CurrencyNFT minted to PlayerNFT owner.** On `registerCurrency`, the CurrencyNFT goes to whoever currently owns the PlayerNFT for that playerId. If the PlayerNFT doesn't exist yet, it's lazy-minted first. This ensures that if a player sells their PlayerNFT (their "mining account"), all future discoveries associated with that playerId flow to the new owner.

11. **Work scored on the 20-byte address (2^160 domain), not the full 32-byte hash.** `addressToWork(address) = type(uint160).max / uint160(addr)` (address 0 saturates to `uint256.max`). Originally work was `hashToWork(bytes32) = uint256.max / uint256(hash)` on the full hash, but the upper 12 bytes are discarded when forming the address, so a leading-zero *address* (the canonical vanity) did not score as high work. Scoring the address unifies share work with vanity quality and lets the planned clone/proxy refactor predict the address with OpenZeppelin's `predictDeterministicAddressWithImmutableArgs` (which returns only the address). The numerator was redomained from 2^256 → 2^160 so the calibration is preserved: same Pareto law for accepted work, so `MIN_SHARE_WORK` and `BOOTSTRAP_*` need no recalibration. `totalIntegratedWork` stays `uint256` with strictly more headroom (per-share work now bounded by ~2^160 instead of ~2^256).

---

## Open Considerations for Future Work

1. **Token distribution claim pattern.** Each player calls a claim function to receive their proportional share of a deployed CurrencyToken. Need to decide: pull-based (player calls claim) vs push-based (loop through players). Pull is standard for gas reasons but requires players to actively claim.

2. **CurrencyToken name/symbol.** Currently hardcoded "Vanity Currency" / "VANITY" as `pure` overrides (clone storage is empty, so OZ's storage-backed name/symbol can't be used). Per-token customization would require adding name/symbol to the clone's immutable args (which changes the address) or a post-deploy setter writing clone storage.

3. **Multiple currencies from same player.** Nothing prevents this — a player can register many vanity addresses across different counters, days, and target work. Each is an independent currency.

4. **Bootstrap sensitivity.** The 1% cap and average-reward mechanism interact subtly with an empty pool. First share sets the baseline. MC simulation needed to calibrate pre-seed values.

5. **Average reward spike after mega-share.** Self-correcting but duration depends on submission rate. May want simulation data before launch.

6. **CurrencyNFT as pre-deployment marketplace.** NFTs are transferable before deployment. Selling the NFT transfers deployment rights + discoverer reward. This creates a speculative market for vanity addresses. Not a bug — it's a feature — but the economic implications are worth thinking about.

7. **Off-chain mining client.** Not started. The on-chain contracts define the protocol; a GPU mining client (CUDA/OpenCL) would be needed for practical use. The off-chain workflow is documented in MiningPool.sol NatSpec.

8. **Per-day counters (not global).** The counter resets each day. The default `lastShareCounter` of 0 means "nothing submitted yet" for a (player, day), so the first share of a day must use counter >= 1 and no separate "has submitted" flag is needed. Resetting per day also keeps the counter space bounded and means a single accidentally-large counter only locks a player out of one day's address space rather than permanently. The extra storage slot per (player, day) is worth it.
