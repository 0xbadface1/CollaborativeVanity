// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Minimal interface CurrencyToken uses to read historical scores from MiningPool.
/// @dev Kept in this file instead of importing MiningPool to avoid a circular dependency:
///      MiningPool imports CurrencyToken for CREATE2 bytecode, while CurrencyToken only
///      needs this small read-only surface at claim time.
interface IMiningPool {
    function getPlayerScoreAt(uint256 playerId, uint256 day) external view returns (uint256);
    function getPoolScoreAt(uint256 day) external view returns (uint256);
    function playerNFT() external view returns (IPlayerNFT);
}

/// @notice Minimal interface for resolving the current owner of a PlayerNFT tokenId.
/// @dev Currency claims are paid to the current owner of the PlayerNFT, so transferring
///      a PlayerNFT transfers the right to claim distributions for that playerId.
interface IPlayerNFT {
    function ownerOf(uint256 tokenId) external view returns (address);
}

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
///     - targetWork: the expected-work bet (prevents retroactive target changes)
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
///   4. MiningPool initializes the chosen distribution supply
///   5. PlayerNFT owners call claim() to mint their share
///   5. Supply split: 1% to discoverer, 99% proportional to all players' scores
contract CurrencyToken is ERC20 {
    /// @notice The player who discovered this vanity address.
    ///         Stored as uint256(uint160(playerWalletAddress)).
    uint256 public immutable playerId;

    /// @notice The day number when this currency was discovered.
    ///         Used to look up historical player/pool scores for distribution.
    uint256 public immutable dayNumber;

    /// @notice The target work the discoverer was mining at.
    ///         Baked into the hash to prevent retroactive target changes.
    uint256 public immutable targetWork;

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
    ///         Only the pool can initialize the distribution.
    address public immutable miningPool;

    /// @notice Total token supply reserved for player distribution.
    ///         Set exactly once by MiningPool immediately after CREATE2 deployment.
    uint256 public distributionSupply;

    /// @notice Historical day used for score lookups.
    ///         For a discovery on day D, claims use scores from day D-1 so players
    ///         cannot rush same-day submissions after seeing a discovery.
    uint256 public snapshotDay;

    /// @notice Pool score at snapshotDay, cached when distribution is initialized.
    ///         Caching freezes the denominator for every later claim and avoids
    ///         repeated external calls to MiningPool.
    uint256 public poolScoreAtSnapshot;

    /// @notice True after MiningPool has set the distribution supply and snapshot.
    bool public initialized;

    /// @notice Tracks whether a playerId has already claimed this currency.
    mapping(uint256 playerId => bool) public claimed;

    error OnlyMiningPool();
    error DistributionAlreadyInitialized();
    error DistributionNotInitialized();
    error DistributionHasNoPoolScore();
    error AlreadyClaimed(uint256 playerId);
    error NothingToClaim(uint256 playerId);

    event DistributionInitialized(uint256 distributionSupply, uint256 snapshotDay, uint256 poolScoreAtSnapshot);

    event Claimed(
        uint256 indexed playerId,
        address indexed recipient,
        uint256 amount,
        uint256 proportionalAmount,
        uint256 discovererBonus
    );

    /// @param _playerId The discovering player's ID
    /// @param _dayNumber The discovery day number
    /// @param _targetWork The expected-work target used during mining
    /// @param _counter The share counter (part of initCode, affects address space)
    /// @param _dayHash The on-chain daily randomness (prevents pre-computation for future days)
    constructor(uint256 _playerId, uint256 _dayNumber, uint256 _targetWork, uint256 _counter, bytes32 _dayHash)
        ERC20("Vanity Currency", "VANITY")
    {
        playerId = _playerId;
        dayNumber = _dayNumber;
        targetWork = _targetWork;
        counter = _counter;
        dayHash = _dayHash;
        miningPool = msg.sender;
    }

    /// @notice Initialize token distribution after CREATE2 deployment.
    ///
    ///         MiningPool calls this exactly once from deployCurrency(), passing the
    ///         total supply chosen by the CurrencyNFT owner. The snapshot day is
    ///         derived from the immutable discovery day:
    ///
    ///           snapshotDay = dayNumber > 0 ? dayNumber - 1 : 0
    ///
    ///         The pool score denominator is cached immediately so every player uses
    ///         the same frozen value, even if future shares change MiningPool scores.
    ///
    /// @param totalDistributionSupply Total ERC-20 supply available for claims
    function initializeDistribution(uint256 totalDistributionSupply) external {
        if (msg.sender != miningPool) revert OnlyMiningPool();
        if (initialized) revert DistributionAlreadyInitialized();

        uint256 snapshot = dayNumber > 0 ? dayNumber - 1 : 0;
        uint256 poolScore = IMiningPool(miningPool).getPoolScoreAt(snapshot);
        if (poolScore == 0) revert DistributionHasNoPoolScore();

        distributionSupply = totalDistributionSupply;
        snapshotDay = snapshot;
        poolScoreAtSnapshot = poolScore;
        initialized = true;

        emit DistributionInitialized(totalDistributionSupply, snapshot, poolScore);
    }

    /// @notice Claim this currency's allocation for a playerId.
    ///
    ///         Claims are pull-based: the contract does not loop over all players
    ///         because the MiningPool cannot enumerate every participant cheaply.
    ///         Any address may call this function, but tokens are minted to the
    ///         current owner of the PlayerNFT for `claimPlayerId`. This makes the
    ///         PlayerNFT the bearer asset for historical score rights.
    ///
    /// TODO: consider allowing only the NFT owner to be able to call this - why?
    /// Claiming the token is the "social" or "attention" proof - so we do not want people
    /// for others. Doing favor to others by giving them shares is fine. Registering currency
    /// for them probably as well (discovered by them or a "friend" mining under foreign address).
    /// But all these should be eventually re-considered again.
    ///
    ///         Distribution formula:
    ///
    ///           proportional = distributionSupply * 99 * playerScore
    ///             / (100 * poolScoreAtSnapshot)
    ///
    ///         The discovering playerId also receives:
    ///
    ///           discovererBonus = distributionSupply / 100
    ///
    ///         Integer division leaves any rounding dust unminted.
    ///
    /// @param claimPlayerId PlayerNFT tokenId whose historical score is being claimed
    /// @return amount Total tokens minted to the current PlayerNFT owner
    function claim(uint256 claimPlayerId) external returns (uint256 amount) {
        if (!initialized) revert DistributionNotInitialized();
        if (claimed[claimPlayerId]) revert AlreadyClaimed(claimPlayerId);

        uint256 playerScore = IMiningPool(miningPool).getPlayerScoreAt(claimPlayerId, snapshotDay);
        // Redundant invariant check: MiningPool should never report a player
        // score above the pool score at the same snapshot.
        assert(playerScore <= poolScoreAtSnapshot);
        uint256 poolAllocation = Math.mulDiv(distributionSupply, 99, 100);
        uint256 proportionalAmount = Math.mulDiv(poolAllocation, playerScore, poolScoreAtSnapshot);
        uint256 discovererBonus = claimPlayerId == playerId ? distributionSupply / 100 : 0;
        amount = proportionalAmount + discovererBonus;

        if (amount == 0) revert NothingToClaim(claimPlayerId);

        claimed[claimPlayerId] = true;

        address recipient = IMiningPool(miningPool).playerNFT().ownerOf(claimPlayerId);
        _mint(recipient, amount);

        emit Claimed(claimPlayerId, recipient, amount, proportionalAmount, discovererBonus);
    }
}
