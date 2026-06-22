# Game-Theoretic Analysis: Attacks, Loopholes & Protections

*Deep analysis of potential attacks and design decisions in the collaborative vanity mining system. This document should be reviewed alongside `IMPLEMENTATION_PLAN.md`.*

---

## Design Context

The system has several properties that interact in non-obvious ways:

- **Shares recorded under submission day** — the dayHash in the seed only determines currency discovery day
- **Pre-committed difficulty** — target baked into the hash, can't be changed after computation
- **Dual accounting** — player credit is capped, pool total gets full difficulty
- **Any share can become a currency** — the dayHash determines discovery day D, distribution uses scores at D-1
- **NFT identities** — tokenId = wallet address, transferable

Each property was designed to close specific attack vectors. This document traces those vectors.

---

## 1. Share Withholding Attack

### The Attack
A large player computes shares offline for weeks, doesn't submit them, then dumps them all at once to inflate their pool position before registering a currency discovery.

### Analysis
**This is largely neutralized by submission-day recording.** Shares are always recorded under the day they're submitted, not the day their dayHash references. So hoarding shares and submitting them later doesn't let you retroactively insert difficulty into past days — all your hoarded shares land in "today."

The dayHash in the share proves a lower bound on when computation happened, but the submission timestamp is what determines your position in the pool's time series.

### Remaining Concern
A player could still accumulate compute offline and submit a large batch on a single day, creating a spike in their score. But this is equivalent to just having a lot of hash power on that day — it's not gaming, it's genuine work submitted honestly.

### Verdict
**Not a significant attack vector** given submission-day recording. Share expiration may still be desirable for practical reasons (e.g., stale dayHashes becoming irrelevant) but is not needed to prevent this specific attack.

---

## 2. Currency Backdating Attack

### The Attack
A player discovers a vanity address and registers it using an old dayHash (say from 30 days ago), trying to cherry-pick a past day where their relative pool share was highest.

### Analysis
The discovery uses a dayHash, which determines the "discovery day" D. Distribution uses all players' cumulative scores at day D-1.

**Key insight: this doesn't create an unfair advantage.** All players' scores from day D-1 are already honestly recorded on-chain. The attacker's score at D-1 is whatever they legitimately accumulated by then. Other players' scores are also locked in. The attacker can't inflate their past scores.

The attacker might pick a day where they had, say, 5% of the pool rather than today's 2% (because the pool grew). But they're also picking a day where the pool was smaller overall — so the currency's community backing is weaker. There's a natural tradeoff.

### Verdict
**Not a significant attack.** The attacker trades distribution advantage for weaker community legitimacy. No expiration needed on currency discoveries.

---

## 3. Sybil Attack via Multiple Wallets

### The Attack
One entity creates 1000 wallets, tries different target difficulties from each, and only submits the lucky hits.

### Why It Doesn't Work
The wallet address (= playerId) is baked into the initCode, which feeds the CREATE2 address:
```
initCodeHash = keccak256(CurrencyToken.creationCode ‖ abi.encode(playerId, dayNumber, targetDifficulty, counter, dayHash))
address = keccak256(0xff ‖ MiningPool ‖ salt ‖ initCodeHash)[12:]
```

Different wallets produce completely different initCodeHashes — and therefore completely different addresses — from the same salt. The attacker must compute separate hashes for each wallet. This doesn't save work — it just parallelizes it, which is equivalent to using one wallet with more compute.

The pre-committed difficulty is also baked into initCode, so you can't compute one hash and retroactively attribute it to whichever wallet's target it happens to meet. The dayHash further anchors computation to a specific day's on-chain randomness.

### Verdict
**Not a viable attack.** The hash construction prevents it by design.

---

## 4. Cross-Identity Difficulty Cherry-Picking

### The Attack
A player creates wallets A, B, C with different target difficulties:
- Wallet A: target = 20 bits (easy, almost certain to hit)
- Wallet B: target = 40 bits (hard, unlikely)
- Wallet C: target = 60 bits (extremely hard, lottery ticket)

Only submit from the wallet(s) that hit their target.

### Analysis
This looks like cherry-picking but isn't exploitative because:
- Each wallet's hash computation is independent (different playerId in initCode)
- The total work across all wallets is the same regardless of the target split
- Expected reward across all wallets ≈ expected reward from one wallet doing all the work
- You can't retroactively attribute a hash to a different wallet

### Verdict
**Not exploitable.** Expected value is identical regardless of how you split targets across wallets.

---

## 5. Front-Running Currency Discoveries

### The Attack
Player A broadcasts a `registerCurrency` transaction. Player B sees it in the mempool, extracts the CREATE2 salt, and front-runs with their own transaction to steal the discovery.

### Analysis
The CREATE2 address depends on:
```
initCodeHash = keccak256(CurrencyToken.creationCode ‖ abi.encode(playerId, dayNumber, targetDifficulty, counter, dayHash))
address = keccak256(0xff ‖ MiningPool ‖ salt ‖ initCodeHash)[12:]
```

**This is prevented by design.** The discoverer's playerId (= wallet address) is baked into the initCode constructor params. A different player using the same salt and counter produces a completely different initCodeHash — and therefore a different address. The vanity pattern won't match.

### Verdict
**Prevented by the discoverer's address being cryptographically bound to the initCode.** This is enforced automatically — `playerId` is derived from `msg.sender` in the contract.

---

## 6. Share Spam / Griefing

### The Attack
Submit thousands of zero-difficulty shares to:
- Inflate the total share count (lowering average reward for everyone)
- Waste pool storage

### Analysis
Every submission costs gas. A very low-difficulty share:
- Adds to `totalShareCount` (denominator goes up)
- Adds near-zero to `totalIntegratedDifficulty` (numerator barely changes)
- This LOWERS `averageReward = totalDifficulty / totalCount`
- The attacker hurts themselves too

### Solution: Minimum Difficulty Threshold
```solidity
require(actualDifficulty >= MIN_SHARE_DIFFICULTY, "Below minimum difficulty");
```

Calibration:
- High enough that gas cost > expected reward from a minimum share (prevents spam)
- Low enough that casual players (phones, CPUs) can occasionally meet it
- Suggested: ~16 bits (1 in 65,536 hashes — findable in well under a second even on a phone)

### Verdict
**Mitigated by minimum difficulty threshold.** Without it, spam is cheap; with it, spam is economically irrational.

---

## 7. Pool Bootstrap Manipulation

### The Attack
First player on Day 1 submits a single low-difficulty share, setting a distorted baseline for the average reward. OR: submits an artificially high-difficulty share to set an unreachable baseline.

### Analysis
With 0 or 1 shares, the average reward is trivially manipulable. This is the cold-start problem.

### Solutions Under Consideration

**A. Pre-seed the pool** with synthetic totals at deployment:
- Initialize `totalIntegratedDifficulty = X`, `totalShareCount = Y`
- Establishes a reasonable average from Day 0
- But values are somewhat arbitrary

**B. Bootstrap by being the first player** with GPU-generated high-difficulty shares:
- More organic, but relies on the deployer going first
- Slightly against the paper's neutrality ethos (though someone has to go first)

**C. Decaying average** — start with artificially high average, converge to actual:
- Halve the gap between current and actual each week
- Upward adjustments (if actual exceeds current) are immediate
- Provides early-adopter incentive (higher initial rewards)
- Naturally transitions from bootstrap to real statistics

**D. Combine A + C:**
- Pre-seed with modest values AND apply decay
- Most robust — doesn't depend on any single actor's behavior

### Verdict
**Needs MC simulation to calibrate exact parameters.** Option D (pre-seed + decay) is likely the best approach.

---

## 8. The 1% Cap Edge Cases

### Scenario: Mega-Share Impact
A player hits an astronomically lucky share (60 leading zero bits when 20-30 are normal). Without the cap, this single share would represent ~50% of all pool difficulty, dominating all future distributions.

### How the Cap Works
- **Player credit:** `min(targetDifficulty, totalIntegratedDifficulty / 100)` — at most 1% of pool
- **Pool total:** gets the FULL actual difficulty, uncapped

### Effects
1. The player gets a bounded reward (decent but not dominant)
2. The pool's total difficulty jumps — boosting the average for everyone
3. All existing players are slightly diluted in proportion — but the average reward per share goes up
4. The excess difficulty is effectively "donated" to the pool commons

### Edge Case: Sequential Mega-Shares
If multiple mega-shares arrive in quick succession, each is capped at 1% of the *growing* total. The pool total ratchets up with each one. This is correct behavior — the cap references the current state.

### Verdict
**The cap works as intended.** It turns extreme luck into a public good.

---

## 9. Average Reward Exploitation Window

### The Scenario
A mega-share boosts the pool's average. There's a brief window where submitting "invalid" shares (which get the average reward) is unusually profitable.

### Analysis
An invalid share gets `totalIntegratedDifficulty / totalShareCount`. After a mega-share:
- Numerator jumps (full difficulty added)
- Denominator increases by only 1
- Average spikes temporarily

Players could rush to submit invalid shares during this window, each getting the inflated average.

### Why It's Mostly Fine
- Each submission costs gas — there's a floor cost
- Each invalid share adds 1 to the denominator, naturally bringing the average back down
- The minimum difficulty threshold means spam is still bounded
- This is actually a feature: it incentivizes active participation ("be online when something interesting happens")

### Verdict
**A transient effect that self-corrects.** The minimum difficulty threshold prevents pure exploitation. The window is a mild incentive for activity, not a critical vulnerability.

---

## 10. Replay After Chain Fork

### The Attack
Base forks. Both chains initially have chainid 8453. Shares valid on one chain are replayed on the other.

### Protections
1. `block.chainid` stored at construction, checked at runtime
2. `address(this)` included in the share hash — different deployment = different address = different hashes
3. On a legitimate fork, the forking chain should change its chainid

### Verdict
**Low risk.** Base is a centralized-sequencer L2; an uncoordinated fork is extremely unlikely. If it happened, chainid + contract address binding provides reasonable protection.

---

## 11. The "Mining for Yourself" Closed Loop

### The Scenario
A big player owns 80% of pool shares, discovers a currency, and gets 1% discoverer reward + ~79% of remaining supply = ~80% total. Is this a problem?

### Analysis
No — the player invested proportionally more compute and earned proportionally more. The system's protections ensure this dominance comes from sustained legitimate work, not a single lucky hit (which is capped).

Natural checks:
- As more players join, any single player's share decreases
- The 1% per-share cap prevents instant domination
- The discoverer reward (1%) is deliberately small
- Distribution is proportional to proven work

### Verdict
**Working as intended.** This is honest dominance from effort, not gaming.

---

## 12. Strategic Timing Around Discoveries

### The Attack
A player discovers a currency and, before registering it, rushes to submit as many shares as possible to maximize their pool share.

### Analysis
With submission-day recording:
- The discovery's dayHash determines day D
- Distribution uses scores at D-1
- The player would need to boost their D-1 scores
- But D-1 is in the past (the dayHash is from at least yesterday)
- You can't retroactively add to past days

With same-day discovery (dayHash from today):
- Distribution uses yesterday's scores
- Rushing shares TODAY doesn't help — they count for today, but distribution looks at yesterday

### Verdict
**Fully mitigated by submission-day recording + D-1 distribution.** The player can't game the timing.

---

## Summary: Protection Matrix

| Protection | Mitigates |
|---|---|
| **Submission-day recording** | Share withholding, retroactive insertion, timing attacks |
| **D-1 distribution snapshot** | Strategic timing around discoveries |
| **Pre-committed difficulty in hash** | Sybil attacks, retroactive difficulty claims |
| **1% per-share cap** | Single lucky share dominating pool |
| **Full difficulty to pool total** | Socializes luck, boosts average for all |
| **Discoverer playerId in initCode** | Front-running discoveries |
| **dayHash in initCode** | Pre-computing shares for future days |
| **Minimum share difficulty threshold** | Spam/griefing, average reward exploitation |
| **Chain + contract lock in hash** | Cross-chain replay, fork replay |
| **Bootstrap pre-seeding + decay** | Cold-start manipulation |
| **Checkpoints with binary search** | Efficient historical score lookups for distribution |

## Still Open / Needs Simulation

1. **Share expiration window**: probably still useful practically (stale dayHashes), but not critical for security
2. **Minimum difficulty value**: needs calibration against Base gas costs and expected casual player hardware
3. **Bootstrap parameters**: pre-seed values and decay rate — needs MC simulation
4. **Currency discovery dayHash freshness**: optional constraint, not strictly needed for security
5. **Average reward spike duration**: how quickly does it self-correct? Depends on submission rate

---

*Analysis generated June 2026. To be reviewed and refined during implementation. Run adversarial simulations (Python) to validate these conclusions quantitatively.*
