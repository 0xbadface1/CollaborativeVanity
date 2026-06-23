# Collaborative Vanity Address Mining

First implementation of the collaborative vanity address mining system from the **"Capturing and Distributing Cryptographic Luck"** paper (Section 4).

Players submit proof-of-work shares (leading zero bits in CREATE2 addresses) to an on-chain MiningPool on Base (Ethereum L2). When a vanity address is discovered, a meme currency token is deployed there with supply distributed proportionally to contributing players.

**Author:** Tristan Badface (0xbadface.eth)

---

## How It Works

Every hash attempt simultaneously searches for two things:
1. **Leading zeros** — proof of work (share difficulty)
2. **Vanity patterns** — interesting addresses like `0xBadFace...` or `0xDeadBeef...`

The share hash IS the CREATE2 address computation:

```
initCodeHash = keccak256(CurrencyToken.creationCode || abi.encode(playerId, dayNumber, targetDifficulty, counter, dayHash))
address = keccak256(0xff || MiningPool || salt || initCodeHash)[12:]
```

Players pre-commit to a difficulty target (baked into the hash), preventing cherry-picking of lucky results. Valid shares are credited at the target difficulty (capped at 1% of pool). Invalid shares still earn the pool average — rewarding participation.

When someone discovers a vanity address, they register it as a CurrencyNFT and can later deploy an ERC-20 token at that exact address. Token supply is distributed proportionally to all players based on their accumulated scores.

## Contracts

| Contract | Role |
|---|---|
| `MiningPool.sol` | Central contract. Share submission, scoring, day management, currency registration & deployment. |
| `CurrencyToken.sol` | ERC-20 deployed at vanity CREATE2 addresses. |
| `PlayerNFT.sol` | ERC-721 player identity. Lazy minted on first share. Transferable — sells your mining history. |
| `CurrencyNFT.sol` | ERC-721 for discovered vanity addresses. Grants deployment rights + discoverer reward. |
| `LeadingZeros.sol` | Binary search leading zero bit counter. |

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

Current test suite: 95 tests passing.

See `IMPLEMENTATION_PLAN.md` for full roadmap and `GAME_THEORY_ANALYSIS.md` for attack scenario analysis.

## License

MIT
