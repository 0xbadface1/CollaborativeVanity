# Collaborative Vanity Address Mining

First implementation of the collaborative vanity address mining system from the **"Capturing and Distributing Cryptographic Luck"** paper (Section 4).

Players submit proof-of-work shares (low CREATE2 hashes scored as expected work) to an on-chain MiningPool on Base (Ethereum L2). Every hash is also a potential currency: anyone can register the resulting CREATE2 address and deploy an ERC-20 there, taking a 1% discoverer bonus while sharing the rest with contributors according to the protocol's snapshot rules.

**Author:** Tristan Badface (0xbadface.eth)

---

## How It Works

Every hash attempt simultaneously produces two things:
1. **Expected work** — proof of work measured from the full hash value
2. **A currency address** — maybe visually interesting, maybe not; the contract does not judge

The share hash IS the CREATE2 address computation:

```
initCodeHash = keccak256(CurrencyToken.creationCode || abi.encode(playerId, dayNumber, targetWork, counter, dayHash))
address = keccak256(0xff || MiningPool || salt || initCodeHash)[12:]
```

Players pre-commit to a work target (baked into the hash), preventing cherry-picking of lucky results. Valid shares are credited at the target work (capped at 1% of pool). Invalid shares still earn the pool average, capped by the same 1% per-share ceiling — rewarding participation without bypassing the cap.

When someone wants to turn a hash into a currency, they register it as a CurrencyNFT and can later deploy an ERC-20 token at that exact address. The "vanity" part is social and optional: people can completely ignore address aesthetics and use this infrastructure to deploy a coin whose supply is distributed across prior share contributors.

## Contracts

| Contract | Role |
|---|---|
| `MiningPool.sol` | Central contract. Share submission, scoring, day management, currency registration & deployment. |
| `CurrencyToken.sol` | ERC-20 deployed at registered CREATE2 addresses. |
| `PlayerNFT.sol` | ERC-721 player identity. Lazy minted on first share. Transferable — sells your mining history. |
| `CurrencyNFT.sol` | ERC-721 for registered currency addresses. Grants deployment rights + discoverer reward. |

## Build & Test

Requires [Foundry](https://book.getfoundry.sh/).

```shell
forge build
forge test
forge test -vvv          # verbose
forge test --gas-report  # with gas reporting
```

## Status

**Phase 1 (Core System)** — Complete.

**Phase 2 (Token Distribution)** — Complete. Mint logic, 1%/99% distribution, player claims.

Current test suite: 88 tests passing.

See `IMPLEMENTATION_PLAN.md` for full roadmap and `GAME_THEORY_ANALYSIS.md` for attack scenario analysis.

## License

MIT
