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
| `MiningPool.sol` | Central contract. Share submission, scoring, day management, NFT deployment, currency registration & deployment. Deploys PlayerNFT and CurrencyNFT in its constructor. |
| `CurrencyToken.sol` | ERC-20 deployed at vanity CREATE2 addresses. Constructor params affect the address. Bytecode baked into MiningPool at compile time. |
| `PlayerNFT.sol` | ERC-721 player identity. Lazy minted on first share submission. TokenId = wallet address. |
| `CurrencyNFT.sol` | ERC-721 for discovered vanity addresses. Stores all CREATE2 params for later deployment. TokenId = vanity address. |

### Work Scoring

Shares are scored by **expected work**, not leading-zero bits. `MiningPool.hashToWork(hash)` converts a CREATE2 hash into a continuous work value:

```solidity
if (hash == bytes32(0)) return type(uint256).max;
return type(uint256).max / uint256(hash);   // lower hash → more expected hashes → more work
```

This mirrors the Bitcoin-style intuition (a lower hash needed more attempts on average) and is a smoother measure of effort than counting discrete zero bits. The all-zero hash saturates to `uint256.max`. There is no separate library — work scoring is a `pure` function on MiningPool. (The former `libraries/LeadingZeros.sol` leading-zero counter was removed in this switch.)

### CREATE2 Hash Construction

The share hash IS the CREATE2 address computation. Every hash attempt simultaneously searches for low-valued hashes (share work) and vanity patterns (currency discovery).

```
initCodeHash = keccak256(CurrencyToken.creationCode || abi.encode(playerId, dayNumber, targetWork, counter, dayHash))
address = keccak256(0xff || MiningPool || salt || initCodeHash)[12:]
```

**Counter vs Salt — critical distinction:**
- `counter` is in initCode (constructor param). Defines WHICH address space to search. Strictly increasing per player per day, starting at 1 (the default `lastShareCounter` of 0 means "nothing submitted yet", so counter 0 is reserved and the first share of a day must use counter >= 1 — this lets us avoid a separate "has submitted" flag). Changing counter = entirely different 2^256 search space.
- `salt` is the CREATE2 salt. The FREE search variable iterated billions of times off-chain. No ordering constraint.
- `dayHash` is in initCode (constructor param). On-chain daily randomness that prevents pre-computing shares for future days. Published via `getCurrentDayHash()` or automatically on each day's first submission.

The initCodeHash is computed on-chain from `type(CurrencyToken).creationCode` — the token bytecode is embedded in MiningPool at compile time. No setter or external loading needed.

### Scoring

- **Valid share** (actual >= target): credit = `min(target, totalIntegratedWork / 100)` (capped at 1% of pool)
- **Invalid share** (actual < target): credit = `min(totalIntegratedWork / totalShareCount, totalIntegratedWork / 100)` (pool average, also capped)
- **Pool total**: always gets full uncapped actual work
- Player scores stored as OpenZeppelin Checkpoints (day, cumulativeScore) with binary search via `upperLookup()`

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

Three test suites, 88 tests total, all in `test/`:

| Suite | Tests | Coverage |
|---|---|---|
| `MiningPool.t.sol` | 44 | Submission, ordering, work scoring, credits, days, checkpoints, chain lock, dayHash, getCurrentDayHash |
| `NFTIntegration.t.sol` | 25 | PlayerNFT, CurrencyNFT, registration, deployment, third-party registration, full mine-register-deploy flow |
| `TokenDistribution.t.sol` | 19 | Distribution initialization, snapshot timing, claim math, PlayerNFT claim recipients, duplicate claims, auto-boost, multi-day flow, multiple currencies |

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
All core contracts and third-party submission/registration implemented.

### Phase 2: Token Distribution — COMPLETE
- CurrencyToken initializes a fixed distribution supply from MiningPool and reads player/pool scores at snapshot day
- 1% discoverer reward + 99% proportional distribution to all players
- Total supply chosen by CurrencyNFT holder at deployment time via `deployCurrency(vanityAddress, totalSupply)`
- Pull-based `claim(playerId)` function; tokens mint to the current PlayerNFT owner
- Auto-boost pool on currency deployment: add vanity address work to totalIntegratedWork (not totalShareCount and not score checkpoints) so discoveries can't be withheld from the pool. Double-counting with prior share submission is intentional — it's a gift to the commons.
- 88 tests passing, including `TokenDistribution.t.sol`

### Phase 3: Polish & Edge Cases
- Bootstrap mechanism for empty pool — pre-seed values IMPLEMENTED (`BOOTSTRAP_*` constants seed the pool in the constructor); decay schedule + parameter calibration still need MC simulation
- Day 0/1 edge case handling
- Minimum share work calibration vs Base gas costs (currently `MIN_SHARE_WORK = 1 << 16`, i.e. ~65,536 expected hashes)
- Share expiration (TBD — practical concern, not security-critical)
- Gas optimization

### Phase 4: BountyEscrow (optional)
Locked ETH bounties for specific vanity patterns.

### Phase 5: Simulation & Testing
Python Monte Carlo simulations of pool dynamics, adversarial scenarios, bootstrap parameter calibration.

### Phase 6: Deployment
Base testnet then mainnet.

---

## Resolved Design Decisions (do not revisit)

These were discussed and decided. Context preserved here so future sessions don't re-derive them.

1. **Counter in initCode, salt as free variable.** Initially counter=salt (single value). Refactored to separate them: counter is a constructor param that defines the address space, salt is iterated freely. Counter must strictly increase per player per day; salt has no constraint.

2. **O(1) day advancement.** Initially considered backfilling skipped days in a loop. User pointed out Checkpoints handle gaps via `upperLookup()` — skipped days simply have no hash and return 0. No loop needed.

3. **CurrencyToken bytecode in MiningPool.** The initCodeHash is computed on-chain from `type(CurrencyToken).creationCode`. No need for a setter or external bytecode loading. Compile-time resolution.

4. **MiningPool deploys NFTs in constructor.** Atomic setup — no setter, no multi-step deployment. PlayerNFT and CurrencyNFT are deployed and permanently linked.

5. **`via_ir` required.** Stack too deep errors in MiningPool without IR-based compilation. Enabled in `foundry.toml`.

6. **DaySnapshot uses uint256 (not uint128).** Compiler warnings about safe casts were not worth the negligible storage savings.

7. **`getInitCodeHash` is `pure` not `view`.** Only uses `type(CurrencyToken).creationCode` which is a compile-time constant. Caller passes dayHash explicitly rather than the function looking it up from storage.

8. **dayHash in initCode (not salt).** The unpredictable daily on-chain randomness is included as a CurrencyToken constructor param (in initCode), not mixed into the CREATE2 salt. This makes it explicit and consistent with the pattern of all committed values living in initCode. Prevents pre-computing shares for future days.

9. **Explicit player parameter, not msg.sender.** `submitShare` and `registerCurrency` accept the player address as a parameter. The CREATE2 hash cryptographically binds the share/discovery to that address, so wrong addresses just produce invalid hashes. This enables gasless/relay submission. CurrencyNFTs are minted to the current PlayerNFT owner (not the caller or the original player address), so transferred PlayerNFTs carry discovery rights.

10. **CurrencyNFT minted to PlayerNFT owner.** On `registerCurrency`, the CurrencyNFT goes to whoever currently owns the PlayerNFT for that playerId. If the PlayerNFT doesn't exist yet, it's lazy-minted first. This ensures that if a player sells their PlayerNFT (their "mining account"), all future discoveries associated with that playerId flow to the new owner.

---

## Open Considerations for Future Work

1. **Token distribution claim pattern.** Each player calls a claim function to receive their proportional share of a deployed CurrencyToken. Need to decide: pull-based (player calls claim) vs push-based (loop through players). Pull is standard for gas reasons but requires players to actively claim.

2. **CurrencyToken name/symbol.** Currently hardcoded "Vanity Currency" / "VANITY". Per-token customization would require adding name/symbol to constructor params (which changes the address) or a post-deploy setter.

3. **Multiple currencies from same player.** Nothing prevents this — a player can register many vanity addresses across different counters, days, and target work. Each is an independent currency.

4. **Bootstrap sensitivity.** The 1% cap and average-reward mechanism interact subtly with an empty pool. First share sets the baseline. MC simulation needed to calibrate pre-seed values.

5. **Average reward spike after mega-share.** Self-correcting but duration depends on submission rate. May want simulation data before launch.

6. **CurrencyNFT as pre-deployment marketplace.** NFTs are transferable before deployment. Selling the NFT transfers deployment rights + discoverer reward. This creates a speculative market for vanity addresses. Not a bug — it's a feature — but the economic implications are worth thinking about.

7. **Off-chain mining client.** Not started. The on-chain contracts define the protocol; a GPU mining client (CUDA/OpenCL) would be needed for practical use. The off-chain workflow is documented in MiningPool.sol NatSpec.

8. **Third-party share submission — PARTIALLY IMPLEMENTED.** `submitShare` and `registerCurrency` accept an explicit `player` address parameter (not derived from `msg.sender`). Anyone can submit shares or register currencies on behalf of a player. The CREATE2 hash binds cryptographically to the player address, so incorrect addresses just produce invalid hashes. CurrencyNFTs are minted to the current PlayerNFT owner, not the caller. **Still needed:** opt-in/out flag per player to disable third-party submissions if griefed (attacker could submit counter=max to block submissions). Per-day counters limit griefing damage to one day.

9. **Per-day counters (not global).** The counter resets each day. This is intentional — a global counter would make the max-counter griefing attack (see #8) permanent instead of bounded to one day. The extra storage slot per (player, day) is worth the safety.
