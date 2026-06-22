// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title CurrencyToken
/// @notice ERC-20 meme currency deployed at a vanity CREATE2 address.
///
/// WHY THESE SPECIFIC CONSTRUCTOR PARAMS:
///   The CREATE2 address is determined by:
///     address = keccak256(0xff ‖ factory ‖ salt ‖ keccak256(initCode))[12:]
///
///   initCode = this contract's creation bytecode + abi.encode(constructor args)
///
///   So the constructor params directly affect the vanity address.
///   We include exactly the params that define the mining context:
///     - playerId: who discovered this address (also prevents replay across players)
///     - dayNumber: when it was discovered (anchors to a time window)
///     - targetDifficulty: the difficulty bet (prevents retroactive difficulty changes)
///     - counter: the share submission index (strictly increasing per player per day)
///     - dayHash: on-chain daily randomness (prevents pre-computing shares for future days)
///
///   The salt (CREATE2 salt) is the FREE search variable — iterated rapidly off-chain.
///   The counter is COMMITTED in the initCode — changing it changes the address space.
///
///   totalSupply is NOT a constructor param — it's chosen at deployment time by the
///   CurrencyNFT holder via the mint function. This means players don't need to
///   agree on supply during the search phase.
///
/// DEPLOYMENT FLOW:
///   1. Player discovers a vanity address during mining (off-chain search)
///   2. Player registers it as a CurrencyNFT (on-chain)
///   3. CurrencyNFT holder calls deploy() on MiningPool, which uses CREATE2
///   4. After deployment, holder calls mint() to distribute tokens
///   5. Supply split: 1% to discoverer, 99% proportional to all players' scores
contract CurrencyToken is ERC20 {

    /// @notice The player who discovered this vanity address.
    ///         Stored as uint256(uint160(playerWalletAddress)).
    uint256 public immutable playerId;

    /// @notice The day number when this currency was discovered.
    ///         Used to look up historical player/pool scores for distribution.
    uint256 public immutable dayNumber;

    /// @notice The target difficulty the discoverer was mining at.
    ///         Baked into the hash to prevent retroactive difficulty changes.
    uint256 public immutable targetDifficulty;

    /// @notice The share submission counter. Part of the initCode — changing it
    ///         changes the address space being searched. Strictly increasing per
    ///         player per day, enforced by MiningPool.
    uint256 public immutable counter;

    /// @notice The day hash — on-chain randomness anchoring this share to a specific day.
    ///         Derived from block.prevrandao and published by MiningPool on the first
    ///         submission of each new day. Prevents players from pre-computing shares
    ///         for future days, since the dayHash is unknowable until that day begins.
    bytes32 public immutable dayHash;

    /// @notice The MiningPool that deployed this token (msg.sender during CREATE2).
    ///         Only the pool can call mint().
    address public immutable miningPool;

    error OnlyMiningPool();

    /// @param _playerId The discovering player's ID
    /// @param _dayNumber The discovery day number
    /// @param _targetDifficulty The difficulty target used during mining
    /// @param _counter The share counter (part of initCode, affects address space)
    /// @param _dayHash The on-chain daily randomness (prevents pre-computation for future days)
    constructor(
        uint256 _playerId,
        uint256 _dayNumber,
        uint256 _targetDifficulty,
        uint256 _counter,
        bytes32 _dayHash
    ) ERC20("Vanity Currency", "VANITY") {
        playerId = _playerId;
        dayNumber = _dayNumber;
        targetDifficulty = _targetDifficulty;
        counter = _counter;
        dayHash = _dayHash;
        miningPool = msg.sender;
    }

    /// @notice Mint tokens to a recipient. Only callable by MiningPool.
    ///         Called once per player claiming their proportional share.
    ///         The MiningPool enforces supply caps and distribution logic.
    /// @param to Recipient address
    /// @param amount Amount to mint
    function mint(address to, uint256 amount) external {
        if (msg.sender != miningPool) revert OnlyMiningPool();
        _mint(to, amount);
    }
}
