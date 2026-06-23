# When Claude Was Wrong

compiled by Claude, I was too lazy...

---

## Architecture & Design Errors

### 1. Started with the wrong contract
Claude proposed starting Phase 1 with CurrencyToken. The user redirected to MiningPool — the central contract that provides all interfaces.

> "I would start with the central contract with factory instead of the currency token contract. This will provide most of the interfaces people will interact with"

### 2. Missing daily pool snapshots
Claude's plan had no concept of freezing pool-wide totals when a new day starts. The user pointed out this was needed for proportional token distribution.

> "It will also be called to infer and store (I think I forgot about, not sure if it is in your plan) the pool status for every day (once the first submission on the day 'wakes up' the contract)"

### 3. Missing minting logic in CurrencyToken
Claude's plan skipped how CurrencyToken would actually read player scores from MiningPool (binary search to find scores at the day before discovery).

> "I think you missed — some logic needs to be in the currency token contracts — where the minting will need to read the player score"

### 4. Total supply should NOT be in the CREATE2 hash
Claude listed totalSupply as potentially needing to be in initCode. The user corrected: supply is a deployment-time decision.

> "the total supply is definitely not needed. even if configurable, it would be done so during deployment, not fixed in hash"

### 5. Token bytecode should be compiled-in, not loaded via setter
Claude had no mechanism for MiningPool to know the CurrencyToken bytecode. The user pointed out `type(CurrencyToken).creationCode` makes it a compile-time constant.

> "this contract code can be already part of what you write here in solidity so you can get the hash once you have it compiled"

### 6. Auto-boost pool on currency deployment (missing feature)
The user realized a discoverer could skip submitting their high-difficulty share. Claude hadn't considered this. The user proposed: deploying a currency automatically adds its difficulty to the pool. Double-counting is intentional.

> "I think we can allow adding more to the pool (boosting) — one can withhold the share, but when he deploys a currency, its difficulty (if any) is added (possibly again) to the pool."

---

## The Counter/Salt Confusion (biggest error)

### 7. Counter and salt are SEPARATE concepts
Claude merged counter and salt into one value (counter = CREATE2 salt). The user corrected: counter is committed in initCode (defines which address space), salt is the free search variable iterated billions of times off-chain.

> "I thought the share counter will be independent and the salt will be fully 'free' (you do not need to mine from 0 to inf, though this is practically often done). Now you say to mine the counter directly"

### 8. Claude incorrectly argued against the separation
When told to separate them, Claude worried about salt reuse ("someone could resubmit the same salt with counter=1, 2, 3..."). The user corrected: the counter IS in the hash, so changing counter changes everything.

> "what? The counter is still input of the hashing. You commit to counter. Then when submitting share... you also send the counter (among other) info — and we check your current highest submitted counter"

### 9. Counter ordering: strictly increasing with gaps, not sequential
Claude implied sequential counter usage. The user corrected: only ordering matters, gaps are fine, enables parallel searches.

> "no need to use all values, we only check if internal share number submitted is larger (for a given day probably) than the last one. One can make big gaps and run in parallel multiple searches."

### 10. Per-day counters, not global (griefing protection)
Claude suggested global counters as a simplification. The user explained: with third-party submission, an attacker could submit counter=MAX and permanently brick a player with global counters. Per-day limits damage to one day.

> "any attacker could submit a share with maximum counter and block your submissions — in per day design for one day... in global design, it would be forever..."

---

## Security Bug

### 11. dayHash must be IN the CREATE2 computation (critical)
Claude implemented dayHash as only a gate check (does this day exist?) but did NOT include it in the initCode hash. This meant players could pre-compute shares for future days since dayNumber is just a predictable integer.

> "'This means someone could pre-compute shares for dayNumber=5 before day 5 actually starts' ... how? The daily day hash cannot be predicted beforehand (or should not)"

> "Dayhash must be included, so you cannot start hashing for a currency to be deployed in the future."

---

## Overcomplications

### 12. O(1) day advancement, not O(n) backfill loop
Claude implemented `_advanceDay` with a loop backfilling hashes for all skipped days. The user pointed out Checkpoints handle gaps automatically — skipped days simply have no hash.

> "Regarding asking for day hashes for days without submissions, these can return 0 — you cannot hash from these days. But in the moment you ask for current day, the contract refreshes, so you can mine as usual."

### 13. publishDayHash — just advance when anyone asks
After the dayHash fix, there was a chicken-and-egg problem (need hash to mine, hash published on first submission). Claude proposed complex solutions. The user simplified: just advance the day whenever anyone asks.

> "you just advance it the moment anyone asks, no?"

### 14. Currency discoveries don't need expiration
Claude proposed freshness constraints on currency discoveries to prevent "backdating attacks." The user pointed out: shares are recorded under submission day, so backdating just uses an older (honestly recorded) score snapshot.

> "Do we really need the currency discoveries to 'expire'? Shares are registered TO the day they are submitted, the day inside the share seed only dictates the day for the currency to be considered as discovered"

